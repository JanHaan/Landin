#!/usr/bin/env python3
"""Shared ESP board images, physical scenarios and RAM/boot workflows (D723).

The default --mode=ram consumes a checked --bundle or builds an ELF with
--refine, then uses --ram-loader for a warm halt/load/resume session. The
loader reinitializes the running core, writes and verifies SRAM, sets the
stack and vector/trap entry and resumes. The resident flash image stays
in place; this run neither resets through the ROM nor proves a cold boot.
The scenario, instruction checks and JTAG readback apply in both modes.

With explicit --mode=boot, each chip's ROM loads its application image
and writes its chip-specific boot log. The ports run the same scenario with
interrupt-driven receive (D721); what differs is each chip's facts, which
each board's tool gives as a `Chip`: its identity and revisions, where its ROM reads and enters the
image, the trap vector its core takes, its indicator, the causes its
interrupts arrive with, the atomics its level executes and what they must
leave, its console and how its power is cut.  Every expectation here is
written from what the host sent, the TRMs and ESP-IDF's image format,
never from the firmware's idea of itself; nothing is taken from refine's
own reading of the image but what the oracle compares it with.

The boot-mode steps, each recorded under the run's output directory:

  1. build the image with refine: the ELF and OUT.bin;
  2. read OUT.bin apart from refine (common.esp_image): its header, chip,
     revisions, every segment against the ELF's loadable segments, its
     checksum, its SHA-256, and refine's build report against it; and the
     linked image's instructions against the level: no A-extension
     instruction at rv32imc, an AMO and an LR/SC pair at rv32imac, or
     windowed frames and calls for Xtensa;
  3. on C3/C5 with --image-control, flash a copy whose checksum byte is flipped,
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
     them in SRAM, which must be OUT.bin's;
  9. restore --fixed-image (or the bundle's resident image), cold-start it
     and require its readiness marker. A failed restoration fails the run;
     the USB stop guard can leave restoration pending for the operator.

--image-control and --recover require --mode=boot.
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

# The board's command bytes, which it also echoes (D721), and PARK, which
# a port that parks before the probe's reads takes last (D1254).
ATOMICS, REPORT, STALL, MASK, PARK = 0x06, 0x11, 0x12, 0x13, 0x14
# The app_state a parked program writes and its last frame carries.
PARKED = 4
RING = 256              # the application's receive ring
BURST = 300             # longer than the ring and than the 128-byte FIFO
WINDOW_MS = 100         # how long STALL and MASK last
PIECE = 64              # the stream's pieces, each sent after the last's echo
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
    expected_mtvt = None
    a_extension = False
    target = 'rv32'
    tool_prefixes = ('riscv64-elf-', 'riscv64-unknown-elf-')
    vector_register = 'mtvec'
    # What the scenario's interrupt snapshots read, and the keys the result
    # gives them: mcause on RISC-V; Xtensa names its own.
    cause_register = 'mcause'
    interrupt_keys = ('receive_mcause', 'timer_mcause')
    entry_at_origin = True
    uart_cause_mask = timer_cause_mask = None
    power_on_names = ('POWERON',)
    cells = {}
    # The line exchange (D962): what the port's UART does, from its TRM
    # (the C3's 26.4.3.1, which the others share): the clocks its port may
    # run UART0 from, the largest CLKDIV with FRAG, whether two stop bits
    # are offered, and the plan, (setting, outcome) pairs.  A port without
    # a plan, or whose console's line is fixed, does not run it.
    line_clocks = ()
    clkdiv_most = 0xffff
    two_stop_bits = True
    line_plan = None
    # Whether the port parks before the probe reads it (D1254): PARK, after
    # the last frame, holds every interrupt off and loops, and its frame is
    # the one the probe's reads must equal.
    parks = False

    def mtvec(self, sections, names):
        raise NotImplementedError

    def mtvt(self, elf, names):
        """What mtvt must read, the CLIC's table of handler addresses, held
        to the image; None for a core without a CLIC."""
        return None

    def boot(self, frame):
        """The verdicts of the boot frame's fields the chip's own port adds,
        refusing what they must not be; none by default."""
        return {}

    def atomics(self, x, y):
        raise NotImplementedError


def line_oracle(chip):
    """The `l` frame an ESP port must give for a setting at the clock it
    names: UART0 divides that clock by CLKDIV plus FRAG sixteenths, CLKDIV
    at least 16, since the TRM gives 5 Mbaud at 80 MHz as the fastest;
    CONF0's PARITY 0, odd when set, PARITY_EN 1, BIT_NUM 3:2 the data bits
    less five, STOP_BIT_NUM 5:4, 1 for one stop bit and 3 for two."""
    def oracle(setting, clock):
        require(any(abs(clock - known) * 1000 <= known for known in chip.line_clocks),
                'the port runs UART0 from %d Hz, not one of %s' % (clock, list(chip.line_clocks)))
        rate, data_bits, parity, stop_bits = setting
        if rate == 0:
            return 'unsupported_rate', None
        if not 5 <= data_bits <= 8 or (stop_bits == 2 and not chip.two_stop_bits):
            return 'unsupported_format', None
        value = common.nearest_divisor(clock, rate, 1, 4, 16 << 4, chip.clkdiv_most)
        if value is None:
            return 'unsupported_rate', None
        frame = ((data_bits - 5) << 2 | (0x30 if stop_bits == 2 else 0x10)
                 | dict(none=0, even=2, odd=3)[parity])
        return 'accepted', dict(b=(value >> 4) | (value & 15) << 20, f=frame)
    return oracle


def build(run, args, chip):
    """refine's ELF and OUT.bin for the chip's board port, and its report."""
    if getattr(args, 'bundle', None):
        import bundle
        try:
            prepared = bundle.consume(run, args, chip.name)
        except bundle.Invalid as error:
            raise Failed('board bundle: ' + str(error)) from error
        elf = bundle.artifact(prepared, 'elf')
        args.prepared_bundle = prepared
        image = bundle.artifact(prepared, 'image') if 'image' in prepared['files'] else None
        return elf, image, json.loads(bundle.artifact(prepared, 'report').read_text())
    elf = run.out / getattr(args, 'image_name', 'board.elf')
    source = ROOT / 'compiler/tests/board' / chip.name
    run.command('compile', [args.refine, '--root=' + str(ROOT / 'devices'),
        '--root=' + str(ROOT / 'devices/generated'), '--root=' + str(ROOT / 'compiler/tests/driver'),
        '--root=' + str(source), '--target=' + chip.target, '--level=' + chip.level,
        '--firmware-entry=start', '--emit=exe', *common.firmware_layout(args),
        '--build-report=' + str(run.out / 'build.json'), str(source / 'app'), '-o', str(elf)])
    if getattr(args, 'mode', 'boot') == 'ram':
        common.validate_ram_image(elf, chip.name)
        return elf, None, json.loads((run.out / 'build.json').read_text())
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
    expected_entry = chip.origin if chip.entry_at_origin else chip.origin + 1024
    require(image['entry'] == entry == expected_entry,
            'the image enters at %#x and the ELF at %#x, expected entry %#x'
            % (image['entry'], entry, expected_entry))
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
    if chip.target == 'xtensa':
        found = sorted(set(re.findall(r'\t(entry|call8|callx8|retw(?:\.n)?)\s', listing)))
        require('entry' in found and any(op.startswith('retw') for op in found),
                'the image has no windowed routine frame and return')
        require(any(op in found for op in ('call8', 'callx8')), 'the image has no windowed call')
        return found
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


def boot_log(text, image, chip=None):
    """The ROM's log of a good image's boot from power-on."""
    log = common.rom_log(text)
    accepted = chip.power_on_names if chip else ('POWERON',)
    require(log['reset'] is not None and log['reset'][0] == POWER_ON
            and log['reset'][1] in accepted, 'the ROM reported reset %s, not power-on'
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


def interrupts(chip, frame):
    """The receive and timer interrupts' snapshots in a frame, `p` and
    `q`, held to the chip's lines and named by the register they read."""
    register = chip.cause_register
    require(frame['p'] & (chip.uart_cause_mask or chip.cause_mask) == chip.uart_cause,
            'the receive interrupt arrived with %s %#x' % (register, frame['p']))
    require(frame['q'] & (chip.timer_cause_mask or chip.cause_mask) == chip.timer_cause,
            'the timer interrupt arrived with %s %#x' % (register, frame['q']))
    receive, timer = chip.interrupt_keys
    return {receive: '%#x' % frame['p'], timer: '%#x' % frame['q']}


def operands(rng):
    """Two printable bytes that are neither a command nor the indicator's."""
    choices = [b for b in range(0x20, 0x7f) if b not in (0x30, 0x31)]
    return rng.choice(choices), rng.choice(choices)


def scenario(console, chip, seed, mode='boot'):
    """The board-port scenario and its oracle; returns the verdicts, the
    last telemetry frame and the atomics frame."""
    verdicts, seen = {}, 0
    rng = random.Random(seed)
    stream = console.wait(lambda s: tagged(s, 'b'), 5, 'the boot frame')
    boot = tagged(stream, 'b')[0]
    # The echo begins after the boot frame; what came before it is the ROM's.
    begin = stream.index(b'\x03', stream.index(b'\x02b')) + 2

    def echoed(s):
        return echo_of(s[begin:])
    if mode == 'boot':
        require(boot['r'] == POWER_ON, 'the reset cause reads %#x, not the chip reset of a power-on'
                % boot['r'])
    require(boot['v'] == chip.expected_mtvec, '%s reads %#x, not %#x'
            % (chip.vector_register, boot['v'], chip.expected_mtvec))
    verdicts['boot'] = dict(reset_cause=boot['r'], **{chip.vector_register: '%#x' % boot['v']})
    if chip.expected_mtvt is not None:
        require(boot.get('w') == chip.expected_mtvt, 'mtvt reads %s, not %#x'
                % ('%#x' % boot['w'] if 'w' in boot else 'nothing', chip.expected_mtvt))
        verdicts['boot']['mtvt'] = '%#x' % boot['w']
    verdicts['boot'].update(chip.boot(boot))
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
    require(echoed(bytes(console.received)).startswith(SHARED[:1] + bytes([REPORT]) + SHARED[1:]),
            'the shared scenario was not echoed')
    verdicts['shared'] = dict(input=SHARED.decode(), echo=SHARED.decode(),
                              indicator_after_1=high['g'], indicator_after_0=low['g'])
    verdicts['interrupts'] = interrupts(chip, high)
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
    console.wait(lambda s: bytes([STALL]) in echoed(s), 2, 'the echo of STALL')
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
    console.wait(lambda s: bytes([MASK]) in echoed(s), 2, 'the echo of MASK')
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
    # A stream, every byte echoed: 3000 bytes in pieces of 64, each sent
    # once the one before it is echoed, so the verdict is the echo's and not
    # whether the core keeps pace with the line; the C3 runs from its reset
    # clock, 20 MHz, at which it does not (D727).
    stream = bytes(rng.randrange(0x20, 0x7f) for _ in range(3000))
    for at in range(0, len(stream), PIECE):
        piece = stream[at:at + PIECE]
        echoed_before = len(echoed(bytes(console.received)))
        console.send(piece)
        console.wait(lambda s: len(echoed(s)) >= echoed_before + len(piece), 5,
                     'the echo of the stream\'s bytes from %d' % at)
    final = report(console, seen); seen += 1
    require(final['c'] == 2 and final['l'] == BURST - RING and final['o'] == 1,
            'the stream lost bytes')
    require(final['m'] > masked['m'] > high['m'], 'the timer did not advance')
    echo = echoed(console.wait(lambda s: True, 1, 'the stream'))
    sent = bytes(console.sent)
    expected_echo = expected_stream(sent, [burst, flood])
    require(echo == expected_echo, 'the echo differs from what was sent, first at byte %d'
            % next((i for i, (a, b) in enumerate(zip(echo, expected_echo)) if a != b),
                   min(len(echo), len(expected_echo))))
    require(final['h'] == len(expected_echo), 'handled %d bytes, not %d'
            % (final['h'], len(expected_echo)))
    verdicts['stream'] = dict(timer_events=final['m'], receive_interrupts=final['i'],
                              echoed=len(echo), sent=len(sent))
    # The line exchange (D962), last, so nothing above depends on it: on a
    # tty console the port changes lines and comes back; the C3's bridge
    # keeps its one line, so that port's verdict says it was not run.
    if chip.line_plan is None:
        verdicts['line'] = common.line_not_run()
    else:
        verdicts['line'], last = common.line_phase(
            console, chip.line_plan, line_oracle(chip),
            lambda c: report(c, len(tagged(bytes(c.received), 't'))), rng)
        if last is not None:
            require(last['h'] == final['h'] + len(console.sent) - len(sent)
                    and (last['c'], last['l'], last['o']) == (final['c'], final['l'], final['o']),
                    'the line exchange handled %d bytes, not %d, or lost some'
                    % (last['h'] - final['h'], len(console.sent) - len(sent)))
            final = last
    if chip.parks:
        verdicts['parked'], final = parked(console, final, echoed)
    final = dict(final, r=boot['r'])
    return verdicts, final, atomics


def parked(console, last, echoed):
    """PARK, after LAST, the scenario's last frame: the program holds
    every interrupt off, writes a frame of what it counted and loops
    waiting for nothing, so that what the probe then reads can no longer
    change and no probe-rs session's halt or single step meets an
    interrupt (D1254).  Its frame is LAST with the one byte PARK handled,
    consumed and echoed, its arrival's receive interrupt, app_state
    PARKED, and nothing lost; it is the frame the probe's reads must
    equal.  Returns the verdict and that frame."""
    frame = common.ask(console, PARK, 't', len(tagged(bytes(console.received), 't')))
    require(frame['s'] == PARKED, 'the program did not park: its app_state reads %d, not %d'
            % (frame['s'], PARKED))
    require(echoed(bytes(console.received)).endswith(bytes([PARK])), 'PARK was not echoed')
    require(frame['h'] == last['h'] + 1 and frame['e'] == last['e'] + 1,
            'parking handled %d bytes and consumed %d, not the one PARK'
            % (frame['h'] - last['h'], frame['e'] - last['e']))
    require((frame['c'], frame['l'], frame['o']) == (last['c'], last['l'], last['o']),
            'the program lost bytes as it parked: %d restarts, %d dropped, %d FIFO overflows,'
            ' not %d, %d and %d' % (frame['c'], frame['l'], frame['o'],
                                    last['c'], last['l'], last['o']))
    require(frame['i'] > last['i'], 'PARK arrived with no receive interrupt')
    return dict(app_state=frame['s'], handled=frame['h']), frame


def expected_stream(sent, discarded):
    """SENT without each of the DISCARDED bursts, the first occurrence of
    each after the one before."""
    out, at = bytearray(), 0
    for burst in discarded:
        begin = sent.index(burst, at)
        out += sent[at:begin]
        at = begin + len(burst)
    return bytes(out + sent[at:])


# What compiler-owned unhandled entry records before its loop, count last
# (D656): a trap no handler owns, readable over JTAG memory reads.
TRAP_CELLS = ('cause', 'pc', 'value', 'sp', 'count')


def trap_cells(probe, names):
    """The five trap cells as JTAG reads them, count last."""
    return {cell: probe.read_words('jtag-trap-' + cell, names['_landin_firmware_trap_' + cell], 1)[0]
            for cell in TRAP_CELLS}


def cross_check(probe, chip, names, final, atomics):
    """The counters and atomic cells as JTAG reads them, against the last
    frames: the probe reads what the firmware counted, not what it said;
    and no trap reached the unhandled entry.  A port that parks is read
    parked, which its app_state shows first (D1254)."""
    trap = trap_cells(probe, names)
    require(trap['count'] == 0, 'the unhandled entry took %d trap(s), the last mcause %#x at %#x,'
            ' mtval %#x, sp %#x' % (trap['count'], trap['cause'], trap['pc'], trap['value'],
                                     trap['sp']))
    read = {'trap_count': 0}
    if chip.parks:
        read['app_state'] = probe.read_words('jtag-app_state', names['app_state'], 1)[0]
        require(read['app_state'] == final['s'] == PARKED,
                'app_state reads %d over JTAG, %d in the frame, not %d: the probe did not read'
                ' the parked program' % (read['app_state'], final['s'], PARKED))
    # Every cell is read before any is judged, and a failure names each
    # that differs: one wrong counter alone does not say what moved.
    wrong = []
    for name, key in (('handled', 'h'), ('recoveries', 'c'), ('dropped', 'l'),
                      ('overflows', 'o'), ('entries', 'i'), ('boot_reason', 'r')):
        read[name] = probe.read_words('jtag-' + name, names[name], 1)[0]
        if read[name] != final[key]:
            wrong.append('%s reads %d over JTAG, %d in the frame' % (name, read[name], final[key]))
    for name, (key, width) in chip.cells.items():
        address = names[name]
        word = probe.read_words('jtag-' + name, address & ~3, 1)[0]
        value = (word >> (8 * (address & 3))) & ((1 << (8 * width)) - 1)
        if value != atomics[key]:
            wrong.append('%s reads %#x over JTAG, %#x in the frame' % (name, value, atomics[key]))
        read[name] = value
    require(not wrong, '; '.join(wrong))
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


def download_mode(serial, seconds=10.0):
    """Reset the chip into its ROM's download mode through its own
    USB-Serial-JTAG, whose CDC-ACM port turns DTR and RTS into a chip reset
    with the boot strap held low, in esptool's USB-JTAG-serial sequence: a
    probe then reaches a chip whose image left JTAG unanswered."""
    console = common.TtyConsole(common.wait_for_tty(serial, seconds), quiet=True)
    try:
        common.set_lines(console.fd, rts=False, dtr=False)
        time.sleep(0.1)
        common.set_lines(console.fd, dtr=True)
        common.set_lines(console.fd, rts=False)
        time.sleep(0.1)
        common.set_lines(console.fd, rts=True)
        common.set_lines(console.fd, dtr=False)
        common.set_lines(console.fd, rts=True)
        time.sleep(0.1)
        common.set_lines(console.fd, dtr=False)
        common.set_lines(console.fd, rts=False)
    finally:
        console.close()


def restore(probe, image, offset, tries=20):
    """Write IMAGE back over a refused one while the ROM resets the chip
    over and over: each reset drops the USB-Serial-JTAG for a moment, so a
    download that finds no probe tries again."""
    for attempt in range(tries):
        try:
            return probe.download_bin(image, offset)
        except common.USBGuardError:
            raise
        except Failed:
            if attempt == tries - 1:
                raise
            time.sleep(1)


def paced(args, what, action):
    """ACTION, which disconnects a device on the rig's hub cascade, spaced
    by args.pace."""
    # The probe's Arty must never lose power or re-enumerate, so nothing
    # disturbs the cascade while it is on it (D725).
    return common.paced(args.pace, what, action, args.arty_serial, args.cascade)


def power_cycle(args, off, on, wait=lambda: None):
    """A power cycle: OFF, args.off_seconds, WAIT for the hubs, and ON, the
    two switches each paced.  It is one action to a cancellation, which
    waits for its end.  Each switch alone already was; the port was off
    between them, and a SIGINT or SIGTERM arriving then, or deferred by
    the first switch and raised as it ended, stopped the tool with the
    port off, where no later run switches it on.

    A cycle that fails of itself, the off half done, the hub not listing
    again, is not left there either: ON is still tried, once, through the
    same pacing and guards, and the failure is raised as it was.  Where
    ON itself fails, or the pace guard refuses it after USB trouble, the
    port is off and nothing here may force it, so the failure says so and
    how it is switched on by hand."""
    with common.uninterrupted():
        try:
            paced(args, 'power off', off)
            time.sleep(args.off_seconds)
            wait()
        except common.Failed as error:
            try:
                paced(args, 'power on', on)
            except (common.Failed, OSError, subprocess.TimeoutExpired) as second:
                raise type(error)('%s; %s: %s' % (error, LEFT_OFF, second)) from error
            raise type(error)('%s; the port was switched on again' % error) from error
        try:
            paced(args, 'power on', on)
        except common.Failed as error:
            raise type(error)('%s; %s' % (error, LEFT_OFF)) from error


def power_at_start(run, args, places):
    """Switch on each port of this run's own board that its hub lists
    switched off, as a power cycle that failed between its two switches
    leaves it (D1253), and return what was done for the run's result: None
    when every port had power, the usual case, in which nothing is
    switched and nothing recorded.

    PLACES is (hub location, port, keeps) in the order the ports are
    switched on, KEEPS the hub's guarded port as `switch_ports` takes it.
    Reading a listing disconnects nothing and is not paced.  A switch is
    one action through `paced`, as any other: the pace guard stops it
    after USB trouble, the Arty must be off the cascade, the hub must show
    its guard, and the caller holds the rig's lock.  A hub that does not
    list is named and left alone, the run going on to find its board or
    not; a switch that fails or is refused fails the run and says the
    port is still off."""
    hub = common.InGroup(run, args.hub_group)
    switched, unread = [], []
    for location, port, keeps in places:
        status = hub.command('hub-start', ['uhubctl', '-l', location], check=False)
        if 'Current status for hub %s ' % location not in status:
            unread.append('hub %s' % location)
            continue
        if not common.ports_off(status, [port]):
            continue
        try:
            paced(args, 'power on at start', lambda: common.switch_ports(
                hub, location, [port], 'on', keeps=keeps, name='power-on-at-start'))
        except common.Failed as error:
            raise type(error)('port %d of hub %s was listed switched off when the run'
                              ' started and could not be switched on: %s; %s'
                              % (port, location, error, LEFT_OFF)) from error
        switched.append('hub %s port %d' % (location, port))
    found = {}
    if switched:
        found.update(switched_on=switched,
                     reason='the hub listed the port switched off when the run started')
    if unread:
        found['unread'] = unread
    return found or None


#  What a failed power cycle says when it could not switch the port on.
LEFT_OFF = ('the port is left off, and later runs end `unavailable` until it'
            ' is on: once the hub lists again, `uhubctl -l HUB -p PORT -a on`'
            " with the run's --hub and --port")


def restore_fixed(run, args, chip, probe, console_for, cycle, settle):
    """Flash, cold-start and prove the fixed image reached its park loop."""
    paced(args, 'restore resident image', lambda: probe.download_bin(args.fixed_image, chip.offset))
    settle(run)
    fixed_elf = common.fixed_elf(args, chip.name)
    # Xtensa's UART bridge shares board power. The chip-specific cycle
    # proves cold startup and retains its reset contract and ROM trace.
    names = common.elf_symbols(fixed_elf) if chip.target == 'xtensa' else None
    restored, cold = cycle(run, console_for, probe, names)
    try:
        fixed = common.esp_image(args.fixed_image.read_bytes())
        stream = restored.wait(lambda body: common.rom_log(body.decode('latin-1'))['entry']
            == fixed['entry'], 10, 'the resident image ROM entry')
        boot_log(stream.decode('latin-1'), fixed, chip)
        marker = common.read_fixed_marker(probe, fixed_elf)
        if cold:
            marker['power_on'] = cold
        return marker
    finally:
        restored.close()


def run_board(chip, args, console_for, cycle, settle, places=()):
    """The whole run: SETTLE(run) waits for the hub to list the board again
    after a download resets the chip, or after PLACES, the board's own
    ports as `power_at_start` takes them, had one switched on as the run
    started; CONSOLE_FOR(run) opens the console,
    before the power
    is cut where the console survives it; CYCLE(run, open_console, probe,
    names) cuts and restores the power and returns the console, which has
    read or will read the ROM's log, and what it found of the power-on
    boot itself, or None; NAMES is None for a control, whose image does not
    run."""
    args.output = args.output.resolve()
    args.output.mkdir(parents=True)
    run = common.Run(args.output)
    run.pace = args.pace
    result = dict(status='failed')
    began = time.monotonic()
    console = None
    xtensa = getattr(chip, 'target', 'rv32') == 'xtensa'
    probe = common.Probe(run, args.probe_rs, chip.probe_chip, args.probe,
                         ram_loader=getattr(args, 'ram_loader', None),
                         require_cpu1_stalled=xtensa and args.mode == 'ram',
                         read_mode='boot-read' if xtensa and args.mode == 'boot' else 'read')
    lock = common.rig_lock('%s board.py' % chip.name)
    lock_held = False
    names = None
    try:
        elf, path, made = build(run, args, chip)
        ram = args.mode == 'ram'
        prepared = getattr(args, 'prepared_bundle', None)
        if ram:
            common.validate_ram_image(elf, chip.name)
            image = dict(segments=[(a, body) for a, body, _ in common.elf_segments(elf)],
                         entry=struct.unpack_from('<I', elf.read_bytes(), 0x18)[0])
        else:
            data = path.read_bytes()
            image = check_image(chip, data, elf, made)
        names = prepared['symbols'] if prepared else common.symbols(run, args.nm, elf)
        _, sections = common.elf_sections(elf)
        chip.expected_mtvec = chip.mtvec(sections, names)
        chip.expected_mtvt = chip.mtvt(elf, names)
        result.update(mode=args.mode, image_sha256=common.sha(elf if ram else path),
                      image_name=(elf if ram else path).name, elf_sha256=common.sha(elf))
        if prepared:
            result['instructions'] = prepared['metadata']['instructions']
        else:
            result['instructions'] = instructions(chip, objdump(run, args, elf))
        if not ram:
            result['image'] = dict(chip=image['chip'], revisions=[image['min_revision'],
                image['max_revision']], entry='%#x' % image['entry'],
                segments=['%#x+%#x' % (a, len(body)) for a, body in image['segments']],
                checksum='%#04x' % image['checksum'], sha256=image['sha256'])
        # The hardware phase, from the first flash to the last JTAG read,
        # holds the rig's lock.
        lock.acquire()
        # A borrowed parent lock is held without owning a file here.
        lock_held = True
        if places:
            # A port an earlier run's failed cycle left off (D1253).
            start = power_at_start(run, args, places)
            if start:
                result['power_at_start'] = start
                if 'switched_on' in start:
                    settle(run)
        if ram:
            console = console_for(run)
            result['warm_load'] = common.ram_load(run, args, chip.name, elf)
        else:
            if args.recover:
                paced(args, 'download mode', lambda: download_mode(args.serial))
                settle(run)
            if args.image_control:
                controls = {}
                # The SHA-256 control first: its image boots.  Then the checksum
                # control, whose refused image leaves the ROM resetting the chip
                # over and over, each reset dropping its USB-Serial-JTAG from the
                # hub cascade: the good image is written back the moment the
                # refusal is read, without waiting for a quiet the loop never
                # gives (D722, D725).
                for where, judge in (('sha256', warned_sha), ('checksum', refused_checksum)):
                    bad = run.out / ('%s-flipped.bin' % where)
                    bad.write_bytes(corrupted(data, where))
                    paced(args, 'download', lambda: probe.download_bin(bad, chip.offset))
                    settle(run)
                    try:
                        console, _ = cycle(run, console_for, probe, None)
                        time.sleep(args.control_seconds)
                        console.close()
                    finally:
                        if where == 'checksum':
                            restore(probe, path, chip.offset)
                            args.pace.after('restore')
                    text = bytes(console.received).decode('latin-1')
                    (run.out / ('rom-%s.log' % where)).write_text(text)
                    console = None
                    settle(run)
                    controls[where] = judge(text, image)
                result['image_control'] = controls
            else:
                paced(args, 'download', lambda: probe.download_bin(path, chip.offset))
                settle(run)
            result['flash'] = dict(offset='%#x' % chip.offset, verified=True)
            console, power_on = cycle(run, console_for, probe, names)
            if power_on:
                result['power_on'] = power_on
            stream = console.wait(lambda s: tagged(s, 'b'), 10, 'the ROM log and the boot frame')
            text = stream[:stream.index(b'\x02')].decode('latin-1')
            (run.out / 'rom.log').write_text(text)
            result['rom'] = boot_log(text, image, chip)
        verdicts, final, atomics = scenario(console, chip, args.seed, args.mode)
        result['verdicts'] = verdicts
        console.close()
        result['jtag'] = cross_check(probe, chip, names, final, atomics)
        result['readback'] = readback(probe, image, elf)
        args.pace.before('board scenario completion')
        result['status'] = 'passed'
    except (Failed, subprocess.TimeoutExpired, OSError) as error:
        common.fail(result, error)
        if lock_held and names and not isinstance(error, common.USBGuardError) \
                and not any(USB in str(error) for USB in ('USB trouble', 'HC died')):
            # Until the loader confirms entry into this RAM image, these
            # addresses may hold unrelated SRAM from the preceding image.
            if args.mode == 'ram' and 'warm_load' not in result:
                result['trap'] = 'skipped: RAM loader did not confirm starting this application'
            else:
                # Keep startup traps too: entry may fail before a boot frame.
                try:
                    result['trap'] = {k: '%#x' % v for k, v in trap_cells(probe, names).items()}
                except (Failed, subprocess.TimeoutExpired, OSError) as reading:
                    result['trap'] = 'unread: %s' % reading
    finally:
        if console:
            console.close()
        if lock_held:
            common.finish_boot(args, result, lambda: restore_fixed(
                run, args, chip, probe, console_for, cycle, settle))
        common.retain_kernel_usb(args.pace, result)
        lock.release()
        if console:
            console.close()
            (args.output / 'uart.bin').write_bytes(bytes(console.received))
            (args.output / 'sent.bin').write_bytes(bytes(console.sent))
            result['uart_sha256'] = hashlib.sha256(bytes(console.received)).hexdigest()
            result['frames'] = common.frame_record(bytes(console.received))
        result['seconds'] = round(time.monotonic() - began, 3)
        result['commands'] = run.commands
        common.write_result(args.output / 'result.json', result, run)
    if args.record and result['status'] == 'passed':
        kept = ('status', 'source_commit', 'image_sha256', 'image_name', 'elf_sha256', 'image', 'instructions',
                'flash', 'power_on', 'rom', 'verdicts', 'jtag', 'readback', 'uart_sha256') + (
                    ('image_control',) if args.image_control else ())
        kept = tuple(k for k in (*kept, 'mode', 'warm_load', 'fixed_restore', 'seconds') if k in result)
        common.write_json(args.record, common.record(
            result, kept, (args.output / 'sent.bin').read_bytes(), run.commands, ('b', 'a')))
    print('board %s: %s%s' % (result['status'], args.output,
                              '' if result['status'] == 'passed' else ': ' + result['failure']))
    return 0 if result['status'] == 'passed' else 1


def arguments(parser, chip):
    """The options both ESP tools take."""
    parser.add_argument('--refine', type=Path)
    common.board_arguments(parser)
    parser.add_argument('--probe-rs', type=Path, default=shutil.which('probe-rs'),
                        help='a probe-rs that reaches the board\'s USB-Serial-JTAG')
    parser.add_argument('--nm', default=next((path for prefix in chip.tool_prefixes
                                           if (path := shutil.which(prefix + 'nm'))), None))
    parser.add_argument('--objdump', default=next((path for prefix in chip.tool_prefixes
                                                if (path := shutil.which(prefix + 'objdump'))), None))
    parser.add_argument('--output', type=Path, required=True, help='a new directory')
    parser.add_argument('--hub', default='.3.4',
                        help="the board's hub, as uhubctl -l names it or relative to the cascade")
    parser.add_argument('--guard-port', type=int, default=1, help='a port never switched')
    parser.add_argument('--guard-device', default='1366:0105',
                        help='what the guarded port must show, or the hub is not switched')
    parser.add_argument('--hub-group', default='dialout',
                        help="the group that may switch the hub's ports and open the tty;"
                             ' the tool runs itself through sg when the session is not in it')
    parser.add_argument('--off-seconds', type=float, default=1.0)
    parser.add_argument('--image-control', action='store_true',
                        help='first flash a copy whose checksum is flipped, which the ROM must'
                             ' refuse, and one whose SHA-256 is flipped, whose hash it must name')
    parser.add_argument('--control-seconds', type=float, default=3.0,
                        help='how long a control\'s boot log is read for')
    parser.add_argument('--arty-serial', default='210319B3E738',
                        help="a device that must be present and off the switched cascade, the"
                             " probe's Arty on the maintainer's rig, or nothing is done to the hub")
    common.cascade_argument(parser)
    common.pace_arguments(parser)
    parser.add_argument('--recover', action='store_true',
                        help="first reset the chip into its ROM's download mode through its own"
                             ' USB-Serial-JTAG, for an image that left JTAG unanswered')
    parser.add_argument('--seed', type=int, default=1240)
    parser.add_argument('--record', type=Path, help="also write a passed run's record here")


def required_tools(args):
    common.warn_stale_refine(args)
    args.pace = common.Pace(args.spacing, args.quiet)
    require(args.probe_rs, 'no probe-rs: name one with --probe-rs')
    require(args.bundle or args.nm, 'no riscv64-elf-nm or riscv64-unknown-elf-nm on PATH: name one with --nm')
    require(args.bundle or args.objdump, 'no riscv64-elf-objdump on PATH: name one with --objdump')
