#!/usr/bin/env python3
"""What the ESP32-C3's and the ESP32-C5's board tools share (D723).

The two chips' ROMs load the same application image, write the same boot
log, and the two ports run the same scenario with interrupt-driven receive
(D721); what differs is each chip's facts, which each board's tool gives as
a `Chip`: its identity and revisions, where its ROM reads and enters the
image, the trap vector its core takes, its indicator, the causes its
interrupts arrive with, the atomics its level executes and what they must
leave, its console and how its power is cut.  Every expectation here is
written from what the host sent, the TRMs and ESP-IDF's image format,
never from the firmware's idea of itself; nothing is taken from refine's
own reading of the image but what the oracle compares it with.

The steps, each recorded under the run's output directory:

  1. build the image with refine: the ELF and OUT.bin;
  2. read OUT.bin apart from refine (common.esp_image): its header, chip,
     revisions, every segment against the ELF's loadable segments, its
     checksum, its SHA-256, and refine's build report against it; and the
     linked image's instructions against the level: no A-extension
     instruction at rv32imc, an AMO and an LR/SC pair at rv32imac;
  3. with --image-control, flash a copy whose checksum byte is flipped,
     cut the power, and require the ROM to name the checksum it computed,
     the image's own, refuse the image and never enter it; then a copy
     whose SHA-256 is flipped, which the ROM, without secure boot, names
     and boots anyway, so only the hash it computed is required;
  4. flash OUT.bin at the description's offset with probe-rs, verified;
  5. open the console, cut the board's power and restore it;
  6. read the ROM's log: a power-on reset, a flash boot, one `load:` per
     segment at its address and length, and the header's entry;
  7. drive the scenario and check every frame and the echo;
  8. read over JTAG the counters and atomic cells, which must equal the
     last frames, and the image's read-only segments as the ROM left
     them in SRAM, which must be OUT.bin's.
"""

import hashlib
import json
import random
import re
import shutil
import struct
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))
import common  # noqa: E402
from common import Failed, echo_of, frames_safe, require, tagged  # noqa: E402

# The board's command bytes, which it also echoes (D721).
ATOMICS, REPORT, STALL, MASK = 0x06, 0x11, 0x12, 0x13
RING = 256              # the application's receive ring
BURST = 300             # longer than the ring and than the 128-byte FIFO
WINDOW_MS = 100         # how long STALL and MASK last
# What environments/cortex-m/driver.py feeds the synthetic application.
SHARED = b'1A0'
# ESP-IDF v6.1's esp_app_format.h: the flash mode DIO, and a size and
# frequency byte the ROM does not read for a RAM-only image (D683).
FLASH_MODE_DIO = 2
SIZE_FREQ = 0x20
# Table 6.1-1 of the C3's TRM and 7.1-1 of the C5's: 0x01 is the chip
# reset, which a power-on is; the ROM names it POWERON.
POWER_ON = 1
# The A extension's instructions, as objdump spells them.
AMO = re.compile(r'\t(amo[a-z]+\.w(\.aqrl|\.aq|\.rl)?|lr\.w(\.aqrl|\.aq|\.rl)?|sc\.w(\.aqrl|\.aq|\.rl)?)\s')


class Chip:
    """One chip's facts, which its board's tool gives.  `atomics(x, y)` is
    the `a` frame the host expects for operands x and y, and `cells` the
    atomic cells the probe reads, each name the field it must equal and
    its width in bytes."""
    name = probe_chip = level = None
    chip_id = min_revision = max_revision = offset = origin = None
    indicator = uart_cause = timer_cause = cause_mask = None
    a_extension = False
    cells = {}

    def mtvec(self, sections, names):
        raise NotImplementedError

    def atomics(self, x, y):
        raise NotImplementedError


def build(run, args, chip):
    """refine's ELF and OUT.bin for the chip's board port, and its report."""
    elf = run.out / 'board.elf'
    source = ROOT / 'compiler/tests/board' / chip.name
    run.command('compile', [args.refine, '--root=' + str(ROOT / 'devices'),
        '--root=' + str(ROOT / 'devices/generated'), '--root=' + str(ROOT / 'compiler/tests/driver'),
        '--root=' + str(source), '--target=rv32', '--level=' + chip.level,
        '--firmware-entry=start', '--emit=exe',
        '--build-report=' + str(run.out / 'build.json'), str(source / 'app'), '-o', str(elf)])
    image = elf.with_name(elf.name + '.bin')
    require(image.is_file(), 'refine wrote no %s' % image.name)
    return elf, image, json.loads((run.out / 'build.json').read_text())


def check_image(chip, data, elf, report):
    """OUT.bin read on its own and held to the ELF, the chip and refine's
    report; returns the parsed image."""
    image = common.esp_image(data)
    require(image['chip'] == chip.chip_id, 'the image names chip %d, not %d'
            % (image['chip'], chip.chip_id))
    require((image['min_revision'], image['max_revision']) == (chip.min_revision, chip.max_revision),
            'the image runs on revisions %d to %d, not %d to %d'
            % (image['min_revision'], image['max_revision'], chip.min_revision, chip.max_revision))
    require(image['legacy_min_revision'] == 0, 'the legacy minimum revision is not zero')
    require((image['flash_mode'], image['size_freq']) == (FLASH_MODE_DIO, SIZE_FREQ),
            'the flash mode and size bytes are %#x and %#x' % (image['flash_mode'], image['size_freq']))
    entry = struct.unpack_from('<I', Path(elf).read_bytes(), 0x18)[0]
    require(image['entry'] == entry == chip.origin,
            'the image enters at %#x and the ELF at %#x, not the region origin %#x'
            % (image['entry'], entry, chip.origin))
    segments = [(address, body) for address, body, _ in common.elf_segments(elf)]
    require(image['segments'] == segments,
            'the image\'s segments are not the ELF\'s: %s against %s'
            % ([(hex(a), len(b)) for a, b in image['segments']],
               [(hex(a), len(b)) for a, b in segments]))
    made = report['firmware']['esp_image']
    seen = dict(offset=chip.offset, entry=image['entry'], chip=image['chip'],
                min_revision=image['min_revision'], max_revision=image['max_revision'],
                segments=[dict(address=a, bytes=len(b)) for a, b in image['segments']],
                checksum=image['checksum'], sha256=image['sha256'], bytes=image['bytes'])
    require(made == seen, 'refine\'s build report says %s of the image, which reads as %s'
            % (made, seen))
    return image


def instructions(chip, listing):
    """The linked image's A-extension instructions against the level: none
    at rv32imc (D696), and both an AMO and an LR/SC pair at rv32imac."""
    found = sorted(set(m.group(1) for m in AMO.finditer(listing)))
    if chip.a_extension:
        require(any(f.startswith('amo') for f in found), 'the image holds no AMO')
        require(any(f.startswith('lr.w') for f in found) and any(f.startswith('sc.w') for f in found),
                'the image holds no LR/SC pair')
    else:
        require(not found, 'the rv32imc image holds A-extension instructions: %s' % ', '.join(found))
    return found


def corrupted(data, where):
    """DATA with its checksum byte, the byte before the SHA-256, or the
    SHA-256's last byte flipped."""
    bad = bytearray(data)
    bad[len(data) - 33 if where == 'checksum' else len(data) - 1] ^= 0xff
    return bytes(bad)


def boot_log(text, image):
    """The ROM's log of a good image's boot from power-on."""
    log = common.rom_log(text)
    require(log['reset'] == (POWER_ON, 'POWERON'), 'the ROM reported reset %s, not 0x1 POWERON'
            % (log['reset'],))
    require(log['boot'] is not None and log['boot'][1] == 'SPI_FAST_FLASH_BOOT',
            'the ROM booted in mode %s, not from flash' % (log['boot'],))
    expected = [(address, len(body)) for address, body in image['segments']]
    require(log['loads'] == expected, 'the ROM loaded %s, not the image\'s segments %s'
            % ([(hex(a), n) for a, n in log['loads']], [(hex(a), n) for a, n in expected]))
    require(log['checksum'] is None and log['sha'] is None, 'the ROM found the image wrong')
    require(log['entry'] == image['entry'], 'the ROM entered %s, not %#x'
            % (log['entry'] and hex(log['entry']), image['entry']))
    return dict(reset=log['reset'][1], boot=log['boot'][1],
                loads=['%#x+%#x' % (a, n) for a, n in log['loads']], entry='%#x' % log['entry'])


def refused_checksum(text, image):
    """The ROM's log of the image whose checksum byte was flipped: the
    checksum it computed is the image's own, the one stored the flipped
    byte, and it never entered the image."""
    log = common.rom_log(text)
    require(log['reset'] is not None, 'the ROM wrote no boot log')
    require(log['checksum'] == (image['checksum'], image['checksum'] ^ 0xff),
            'the ROM reported checksum %s, not computed %#04x and stored %#04x'
            % (log['checksum'], image['checksum'], image['checksum'] ^ 0xff))
    require(log['entry'] is None, 'the ROM entered the image whose checksum is wrong')
    require(not any(t == 'b' for t, _ in frames_safe(text.encode('latin-1'))),
            'the program ran from the image whose checksum is wrong')
    return dict(calculated='%#04x' % log['checksum'][0], stored='%#04x' % log['checksum'][1])


def warned_sha(text, image):
    """The ROM's log of the image whose SHA-256 was flipped: the hash it
    computed is the image's own, the one expected the flipped one."""
    log = common.rom_log(text)
    bad = image['sha256'][:-2] + '%02x' % (int(image['sha256'][-2:], 16) ^ 0xff)
    require(log['sha'] == (image['sha256'], bad), 'the ROM reported SHA-256 %s, not computed %s'
            ' and expected %s' % (log['sha'], image['sha256'], bad))
    return dict(calculated=log['sha'][0], expected=log['sha'][1],
                entered=log['entry'] is not None)


def report(console, count):
    return common.ask(console, REPORT, 't', count)


def operands(rng):
    """Two printable bytes that are neither a command nor the indicator's."""
    choices = [b for b in range(0x20, 0x7f) if b not in (0x30, 0x31)]
    return rng.choice(choices), rng.choice(choices)


def scenario(console, chip, seed):
    """The board-port scenario and its oracle; returns the verdicts, the
    last telemetry frame and the atomics frame."""
    verdicts, seen = {}, 0
    rng = random.Random(seed)
    stream = console.wait(lambda s: tagged(s, 'b'), 5, 'the boot frame')
    boot = tagged(stream, 'b')[0]
    require(boot['r'] == POWER_ON, 'the reset cause reads %#x, not the chip reset of a power-on'
            % boot['r'])
    require(boot['v'] == chip.expected_mtvec, 'mtvec reads %#x, not %#x'
            % (boot['v'], chip.expected_mtvec))
    verdicts['boot'] = dict(reset_cause=boot['r'], mtvec='%#x' % boot['v'])
    if 't' in boot:
        verdicts['boot']['rom_threshold'] = boot['t']
    # The shared scenario (D593): 1 sets the indicator, 0 clears it, which
    # the pad's input reads back.
    console.send(SHARED[:1])
    high = report(console, seen); seen += 1
    console.send(SHARED[1:])
    low = report(console, seen); seen += 1
    require(high['g'] == chip.indicator and low['g'] == 0,
            'the indicator read back %#x after 1 and %#x after 0' % (high['g'], low['g']))
    require(echo_of(console.received).startswith(SHARED[:1] + bytes([REPORT]) + SHARED[1:]),
            'the shared scenario was not echoed')
    verdicts['shared'] = dict(input=SHARED.decode(), echo=SHARED.decode(),
                              indicator_after_1=high['g'], indicator_after_0=low['g'])
    require(high['p'] & chip.cause_mask == chip.uart_cause,
            'the receive interrupt arrived with mcause %#x' % high['p'])
    require(high['q'] & chip.cause_mask == chip.timer_cause,
            'the timer interrupt arrived with mcause %#x' % high['q'])
    verdicts['interrupts'] = dict(receive_mcause='%#x' % high['p'], timer_mcause='%#x' % high['q'])
    # The atomics, over two operands the host chose.
    x, y = operands(rng)
    console.send(bytes([x, y, ATOMICS]))
    got = console.wait(lambda s: tagged(s, 'a'), 5, 'the atomics frame')
    atomics = tagged(got, 'a')[0]
    expected = chip.atomics(x, y)
    require(atomics == expected, 'the atomics over %#x and %#x left %s, not %s'
            % (x, y, atomics, expected))
    verdicts['atomics'] = dict(x=x, y=y, **atomics)
    before = report(console, seen); seen += 1
    require(before['c'] == 0 and before['l'] == 0 and before['o'] == 0,
            'the receiver lost bytes before the overruns')
    # STALL: the application stops reading for 100 ms while the interrupt
    # keeps filling the ring, and a burst longer than the ring arrives: the
    # ring takes 256, the interrupt drops the rest and counts them, the
    # application restarts on the loss, and none of the burst is echoed.
    console.send(bytes([STALL]))
    console.wait(lambda s: bytes([STALL]) in echo_of(s), 2, 'the echo of STALL')
    burst = bytes(rng.randrange(0x20, 0x7f) for _ in range(BURST))
    console.send(burst, pace=BURST)
    time.sleep(0.3)
    stalled = report(console, seen); seen += 1
    require(stalled['c'] == 1 and stalled['l'] == BURST - RING and stalled['o'] == 0,
            'after a burst into a full ring: %d restarts, %d bytes dropped, %d FIFO overflows,'
            ' not 1, %d and 0' % (stalled['c'], stalled['l'], stalled['o'], BURST - RING))
    verdicts['ring_overrun'] = dict(burst=BURST, ring=RING, dropped=stalled['l'],
                                    restarts=stalled['c'])
    # MASK: the threshold holds the receive interrupt off for 100 ms while
    # the timer's, above it, keeps arriving; a burst then overflows the
    # UART's FIFO, which flags it once, and none of it is echoed.
    console.send(bytes([MASK]))
    console.wait(lambda s: bytes([MASK]) in echo_of(s), 2, 'the echo of MASK')
    flood = bytes(rng.randrange(0x20, 0x7f) for _ in range(BURST))
    console.send(flood, pace=BURST)
    time.sleep(0.3)
    masked = report(console, seen); seen += 1
    require(masked['c'] == 2 and masked['o'] == 1 and masked['l'] == BURST - RING,
            'after a burst into a held-off FIFO: %d restarts, %d FIFO overflows, %d dropped,'
            ' not 2, 1 and %d' % (masked['c'], masked['o'], masked['l'], BURST - RING))
    require(WINDOW_MS - 1 <= masked['k'] <= WINDOW_MS + 1,
            '%d timer interrupts arrived in the %d ms the receive interrupt was held off'
            % (masked['k'], WINDOW_MS))
    verdicts['threshold'] = dict(burst=BURST, fifo_overflows=masked['o'], restarts=masked['c'],
                                 timer_interrupts_meanwhile=masked['k'])
    # A stream at the line's rate, every byte echoed.
    console.send(bytes(rng.randrange(0x20, 0x7f) for _ in range(3000)))
    final = report(console, seen); seen += 1
    require(final['c'] == 2 and final['l'] == BURST - RING and final['o'] == 1,
            'the stream lost bytes')
    require(final['m'] > masked['m'] > high['m'], 'the timer did not advance')
    echo = echo_of(console.wait(lambda s: True, 1, 'the stream'))
    sent = bytes(console.sent)
    expected_echo = expected_stream(sent, [burst, flood])
    require(echo == expected_echo, 'the echo differs from what was sent, first at byte %d'
            % next((i for i, (a, b) in enumerate(zip(echo, expected_echo)) if a != b),
                   min(len(echo), len(expected_echo))))
    require(final['h'] == len(expected_echo), 'handled %d bytes, not %d'
            % (final['h'], len(expected_echo)))
    verdicts['stream'] = dict(timer_events=final['m'], receive_interrupts=final['i'],
                              echoed=len(echo), sent=len(sent))
    return verdicts, final, atomics


def expected_stream(sent, discarded):
    """SENT without each of the DISCARDED bursts, the first occurrence of
    each after the one before."""
    out, at = bytearray(), 0
    for burst in discarded:
        begin = sent.index(burst, at)
        out += sent[at:begin]
        at = begin + len(burst)
    return bytes(out + sent[at:])


def cross_check(probe, chip, names, final, atomics):
    """The counters and atomic cells as JTAG reads them, against the last
    frames: the probe reads what the firmware counted, not what it said."""
    read = {}
    for name, key in (('handled', 'h'), ('recoveries', 'c'), ('dropped', 'l'),
                      ('overflows', 'o'), ('entries', 'i')):
        read[name] = probe.read_words('jtag-' + name, names[name], 1)[0]
        require(read[name] == final[key], '%s reads %d over JTAG, %d in the frame'
                % (name, read[name], final[key]))
    for name, (key, width) in chip.cells.items():
        address = names[name]
        word = probe.read_words('jtag-' + name, address & ~3, 1)[0]
        value = (word >> (8 * (address & 3))) & ((1 << (8 * width)) - 1)
        require(value == atomics[key], '%s reads %#x over JTAG, %#x in the frame'
                % (name, value, atomics[key]))
        read[name] = value
    return read


def readback(probe, image, elf):
    """The image's read-only segments as the ROM left them in SRAM, read
    over JTAG, against OUT.bin's bytes: what the ROM loaded is the image."""
    writable = {address for address, _, w in common.elf_segments(elf) if w}
    checked = []
    for address, body in image['segments']:
        if address in writable:
            continue
        size = len(body) // 4 * 4
        got = probe.read_bytes('jtag-readback-%x' % address, address, size)
        require(got == body[:size], 'SRAM at %#x does not hold the image\'s segment' % address)
        checked.append('%#x+%#x' % (address, size))
    require(checked, 'the image has no read-only segment to read back')
    return checked


def objdump(run, args, elf):
    return run.command('disassemble', [args.objdump, '-d', '--no-show-raw-insn', elf])


def run_board(chip, args, console_for, cycle):
    """The whole run: CONSOLE_FOR(run) opens the console, before the power
    is cut where the console survives it; CYCLE(run, open_console) cuts
    and restores the power and returns the console, opening it with
    OPEN_CONSOLE where it must wait for the power."""
    args.output = args.output.resolve()
    args.output.mkdir(parents=True)
    run = common.Run(args.output)
    result = dict(status='failed')
    console = None
    probe = common.Probe(run, args.probe_rs, chip.probe_chip, args.probe)
    try:
        elf, path, made = build(run, args, chip)
        data = path.read_bytes()
        image = check_image(chip, data, elf, made)
        names = common.symbols(run, args.nm, elf)
        _, sections = common.elf_sections(elf)
        chip.expected_mtvec = chip.mtvec(sections, names)
        result.update(image_sha256=common.sha(path), image_name=path.name,
                      elf_sha256=common.sha(elf),
                      image=dict(chip=image['chip'], revisions=[image['min_revision'],
                                 image['max_revision']], entry='%#x' % image['entry'],
                                 segments=['%#x+%#x' % (a, len(b)) for a, b in image['segments']],
                                 checksum='%#04x' % image['checksum'], sha256=image['sha256']),
                      instructions=instructions(chip, objdump(run, args, elf)))
        if args.image_control:
            controls = {}
            for where, judge in (('checksum', refused_checksum), ('sha256', warned_sha)):
                bad = run.out / ('%s-flipped.bin' % where)
                bad.write_bytes(corrupted(data, where))
                probe.download_bin(bad, chip.offset)
                console = cycle(run, console_for)
                time.sleep(args.control_seconds)
                console.close()
                text = bytes(console.received).decode('latin-1')
                (run.out / ('rom-%s.log' % where)).write_text(text)
                controls[where] = judge(text, image)
                console = None
            result['image_control'] = controls
        probe.download_bin(path, chip.offset)
        result['flash'] = dict(offset='%#x' % chip.offset, verified=True)
        console = cycle(run, console_for)
        stream = console.wait(lambda s: tagged(s, 'b'), 10, 'the ROM log and the boot frame')
        text = stream[:stream.index(b'\x02')].decode('latin-1')
        (run.out / 'rom.log').write_text(text)
        result['rom'] = boot_log(text, image)
        verdicts, final, atomics = scenario(console, chip, args.seed)
        result['verdicts'] = verdicts
        console.close()
        result['jtag'] = cross_check(probe, chip, names, final, atomics)
        result['readback'] = readback(probe, image, elf)
        result['status'] = 'passed'
    except (Failed, subprocess.TimeoutExpired, OSError) as error:
        result['failure'] = str(error)
    finally:
        if console:
            console.close()
            (args.output / 'uart.bin').write_bytes(bytes(console.received))
            (args.output / 'sent.bin').write_bytes(bytes(console.sent))
            result['uart_sha256'] = hashlib.sha256(bytes(console.received)).hexdigest()
            result['frames'] = common.frame_record(bytes(console.received))
        result['commands'] = run.commands
        common.write_json(args.output / 'result.json', result)
    if args.record and result['status'] == 'passed':
        kept = ('status', 'image_sha256', 'image_name', 'elf_sha256', 'image', 'instructions',
                'flash', 'rom', 'verdicts', 'jtag', 'readback', 'uart_sha256') + (
                    ('image_control',) if args.image_control else ())
        common.write_json(args.record, common.record(
            result, kept, (args.output / 'sent.bin').read_bytes(), run.commands, ('b', 'a')))
    print('board %s: %s%s' % (result['status'], args.output,
                              '' if result['status'] == 'passed' else ': ' + result['failure']))
    return 0 if result['status'] == 'passed' else 1


def arguments(parser, chip):
    """The options both ESP tools take."""
    parser.add_argument('--refine', type=Path, required=True)
    parser.add_argument('--probe-rs', type=Path, default=shutil.which('probe-rs'),
                        help='a probe-rs that reaches the board\'s USB-Serial-JTAG')
    parser.add_argument('--nm', default=shutil.which('riscv64-elf-nm')
                        or shutil.which('riscv64-unknown-elf-nm'))
    parser.add_argument('--objdump', default=shutil.which('riscv64-elf-objdump')
                        or shutil.which('riscv64-unknown-elf-objdump'))
    parser.add_argument('--output', type=Path, required=True, help='a new directory')
    parser.add_argument('--hub', default='7-2.3.4', help="the board's hub, as uhubctl -l names it")
    parser.add_argument('--guard-port', type=int, default=1, help='a port never switched')
    parser.add_argument('--guard-device', default='1366:0105',
                        help='what the guarded port must show, or the hub is not switched')
    parser.add_argument('--hub-group', default='dialout',
                        help="the group that may switch the hub's ports and open the tty;"
                             ' uhubctl runs through sg when the session is not in it')
    parser.add_argument('--off-seconds', type=float, default=1.0)
    parser.add_argument('--image-control', action='store_true',
                        help='first flash a copy whose checksum is flipped, which the ROM must'
                             ' refuse, and one whose SHA-256 is flipped, whose hash it must name')
    parser.add_argument('--control-seconds', type=float, default=3.0,
                        help='how long a control\'s boot log is read for')
    parser.add_argument('--seed', type=int, default=1240)
    parser.add_argument('--record', type=Path, help="also write a passed run's record here")


def required_tools(args):
    require(args.probe_rs, 'no probe-rs: name one with --probe-rs')
    require(args.nm, 'no riscv64-elf-nm or riscv64-unknown-elf-nm on PATH: name one with --nm')
    require(args.objdump, 'no riscv64-elf-objdump on PATH: name one with --objdump')
