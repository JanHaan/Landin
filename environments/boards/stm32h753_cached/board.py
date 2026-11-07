#!/usr/bin/env python3
"""Run the STM32H753's cached profile from SRAM and check its physical oracle.

    python3 environments/boards/stm32h753_cached/board.py --bundle=RAM_BUNDLE \\
        --probe-rs PROBE_RS --ram-loader LOADER --output NEW_DIRECTORY

The NUCLEO-H753ZI the cacheless port runs on, through the same ST-LINK V3
and its virtual COM port, built from compiler/tests/board/stm32h753_cached
against devices/descriptions/stm32h753_cached (D974, D975).  The run is a
RAM run alone: the SRAM helper loads it exactly as it loads the cacheless
port, its warm contract unchanged and requiring the caches off when it
loads, and the image's own reset enables them (D973).  The steps, each
recorded under NEW_DIRECTORY:

  1. build the image at --level=armv7e-m, or take it from --bundle, and
     check its vector table at the loaded address, the handlers at slots
     15, 27 and 55, and that its literals reach the SCB's cache registers
     the profile declares and no other;
  2. load it with the SRAM helper, which refuses a chip whose caches are
     on, open the virtual COM port, and send the start byte;
  3. check the boot frame: CCR's IC and DC set, the caches on, and CCSIDR
     the 16 KiB four-way data cache of 32-byte lines; read CCR over SWD
     while the run goes on, also on;
  4. drive the receive control, the maintained stream, the CPU's controls
     and the two transmits, each against what the host sent and what the
     cache predicts (environments/boards/stm32h753_cached/README.md);
  5. once the entry has returned, read CCR over SWD: IC and DC clear.

The oracle is the host's: what it sent, FNV-1a over it, and what a
write-back data cache does when D227's maintenance is left out, never the
firmware's own idea of itself; see
environments/boards/stm32h753_cached/README.md.  It is physical evidence only on the chip: an emulator models
no cache.
"""

import argparse
import hashlib
import json
import os
import random
import shutil
import struct
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
SOURCE = ROOT / 'compiler/tests/board/stm32h753_cached'
SHARED = ROOT / 'compiler/tests/board/stm32h753'
sys.path.insert(0, str(HERE.parent))
import common  # noqa: E402
from common import Failed, require  # noqa: E402

BOARD = 'stm32h753_cached'
# The chip the SRAM helper knows: the cached profile loads as the cacheless
# port's image does, so the helper's plan names that board.
HELPER_BOARD = 'stm32h753'
CHIP = 'STM32H753ZITx'
START = b'S'
VECTOR_WORDS = 166      # 16 and the 150 interrupts of RM0433 Table 147, p. 759
SLOTS = dict(tick_irq=15, dma_irq=16 + 11, usart3_irq=16 + 39)
# SCB_CCR (0xE000ED14): IC, bit 17, and DC, bit 16.
CCR, CCR_CACHES = 0xE000ED14, 0x00030000
# CCSIDR of the level 1 data cache: LineSize 2:0 is log2(words) - 2,
# Associativity 12:3 the ways less one, NumSets 27:13 the sets less one.
# The STM32H753's M7 has a 16 KiB four-way data cache of 32-byte lines,
# 128 sets (RM0433 2.1, p. 101; the Cortex-M7 TRM's CCSIDR encodings).
LINE, WAYS, SETS = 32, 4, 128
# The SCB registers the cached image's literals may reach, as D976 says:
# CCR, CCSIDR, CSSELR and CPACR; ICIALLU, DCIMVAC, DCISW, DCCMVAC,
# DCCIMVAC and DCCISW.  The others of 0xE000EF50 to 0xE000EF78 are none
# of the profile's.
DECLARED = {0xE000ED14, 0xE000ED80, 0xE000ED84, 0xE000ED88,
            0xE000EF50, 0xE000EF5C, 0xE000EF60, 0xE000EF68, 0xE000EF70, 0xE000EF74}
MAINTENANCE = range(0xE000EF50, 0xE000EF79)
# What the application's controls leave cached, and the sizes it uses.
RING_FILL, TRANSMIT_MEMORY = 0x5A, 0x6F
CONTROL, STREAM, TRANSMIT = 64, 1024, 64
# The lost-dirty probe's line and the ranges the application asks for that
# are not whole lines, each refused.
REFUSED = 4


def fnv(data, value=0x811C9DC5):
    """FNV-1a, 32 bits, as the application hashes what it read."""
    for byte in data:
        value = ((value ^ byte) * 16777619) & 0xFFFFFFFF
    return value


def message():
    """What a maintained transmit carries: A to Z, again and again."""
    return bytes(65 + i % 26 for i in range(TRANSMIT))


def literals(data, segments):
    """Every little-endian word of the loadable segments SEGMENTS, each
    (address, offset, size), of ELF bytes DATA."""
    words = set()
    for _, offset, size in segments:
        words.update(struct.unpack_from('<%dI' % (size // 4), data, offset))
    return words


def loadable(data):
    """Each PT_LOAD segment of an ELF32 as (address, file offset, size)."""
    phoff, = struct.unpack_from('<I', data, 0x1c)
    phentsize, phnum = struct.unpack_from('<HH', data, 0x2a)
    found = []
    for index in range(phnum):
        kind, offset, vaddr, _, filesz = struct.unpack_from('<IIIII', data, phoff + index * phentsize)
        if kind == 1 and filesz:
            found.append((vaddr, offset, filesz))
    return found


def cache_registers(data):
    """The SCB cache registers the image's literals reach, refusing any
    the profile does not declare (D976)."""
    words = literals(data, loadable(data))
    require(CCR in words, "the image's reset reaches no CCR: the profile is not cached")
    stray = sorted(w for w in words if w in MAINTENANCE and w not in DECLARED)
    require(not stray, 'the image reaches undeclared cache registers: %s'
            % ', '.join('%#010x' % w for w in stray))
    return sorted('%#010x' % w for w in words if w in DECLARED)


def build(run, args):
    if getattr(args, 'bundle', None):
        elf, meta, names = common.consume_board(run, args, BOARD)
        return elf, bytes.fromhex(meta['table']), names, meta['image']
    elf = run.out / getattr(args, 'image_name', 'board.elf')
    run.command('compile', [args.refine, '--root=' + str(ROOT / 'devices'),
        '--root=' + str(ROOT / 'devices/generated'), '--root=' + str(ROOT / 'compiler/tests/driver'),
        '--root=' + str(SHARED), '--root=' + str(SOURCE), '--target=cortex-m0', '--level=armv7e-m',
        '--firmware-entry=start', '--emit=exe', '--firmware-layout=ram',
        '--build-report=' + str(run.out / 'build.json'), str(SOURCE / 'app'), '-o', str(elf)])
    data, sections = common.elf_sections(elf)
    address, offset, size = sections['.isr_vector']
    expected = common.validate_ram_image(elf, BOARD)
    require(address == expected and size == 4 * VECTOR_WORDS,
            'the vector table is not %d words at %#x' % (VECTOR_WORDS, expected))
    words = struct.unpack_from('<%dI' % VECTOR_WORDS, data, offset)
    names = common.symbols(run, args.nm, elf)
    require(words[1] == names['_landin_firmware_reset_stage'] | 1,
            'vector word 1 is not the supply stage that enters reset')
    for handler, slot in SLOTS.items():
        require(words[slot] == names[handler] | 1, 'vector word %d is not %s' % (slot, handler))
    run.command('disassembly', [args.objdump, '-d', elf])
    report = json.loads((run.out / 'build.json').read_text())
    require(report['firmware'].get('cache') == 'armv7-m-l1',
            'the build report names no armv7-m-l1 cache: the image was not built for the cached profile')
    return elf, data[offset:offset + size], names, dict(cache_registers=cache_registers(data))


def probe(run, args):
    return common.Probe(run, args.probe_rs, CHIP, args.probe)


def segments(stream):
    """STREAM as frames and the raw bytes between them, in order: each
    ('frame', tag, fields) or ('raw', bytes).  A frame is STX, a tag
    letter, fields and ETX, then LF; what lies outside one is a
    transmit's bytes."""
    found, raw, i = [], bytearray(), 0
    while i < len(stream):
        if stream[i] == common.STX:
            if common.ETX not in stream[i:]:
                break
            if raw:
                found.append(('raw', bytes(raw)))
                raw = bytearray()
            end = stream.index(common.ETX, i)
            text = stream[i + 1:end].decode('ascii')
            fields = dict((k, int(v, 16)) for k, v in common.FIELD.findall(text))
            found.append(('frame', text[0], fields))
            i = end + 2 if end + 1 < len(stream) and stream[end + 1] == common.LF else end + 1
        else:
            raw.append(stream[i])
            i += 1
    if raw:
        found.append(('raw', bytes(raw)))
    return found


def run_stream(raw):
    """RAW from the boot frame on: what the board wrote before it, the last
    application's output before the helper halted it, is not this run's."""
    start = raw.find(bytes([common.STX]) + b'b')
    return raw[start:] if start >= 0 else b''


def frame(console, tag, seconds, what):
    """The fields of the first frame of this run tagged TAG, once it has
    arrived, refusing a halt the application reported first."""
    def tagged(stream, wanted):
        return [p[2] for p in segments(run_stream(stream)) if p[0] == 'frame' and p[1] == wanted]
    stream = console.wait(lambda s: tagged(s, tag) or tagged(s, 'h'), seconds, what)
    halted = tagged(stream, 'h')
    require(not halted, 'the application halted at step %d' % (halted[0].get('s', 0) if halted else 0))
    return tagged(stream, tag)[0]


def between(stream, opening, closing):
    """The raw bytes between the frames tagged OPENING and CLOSING."""
    parts = segments(stream)
    tags = [p[1] if p[0] == 'frame' else None for p in parts]
    require(opening in tags and closing in tags, 'no %s and %s frames' % (opening, closing))
    first, last = tags.index(opening), tags.index(closing)
    require(first < last, 'the %s frame follows the %s frame' % (opening, closing))
    return b''.join(p[1] for p in parts[first + 1:last] if p[0] == 'raw')


def mixes(stale, fresh, line=LINE):
    """Every mix of STALE and FRESH by whole lines that holds at least one
    stale line, each as (mask, bytes), bit n set for a stale line n."""
    count = len(fresh) // line
    found = []
    for mask in range(1, 1 << count):
        found.append((mask, b''.join(stale[i * line:(i + 1) * line] if mask >> i & 1
                                     else fresh[i * line:(i + 1) * line] for i in range(count))))
    return found


def geometry(ccsidr):
    """CCSIDR's line in bytes, its ways and its sets."""
    return 16 << (ccsidr & 7), ((ccsidr >> 3) & 0x3FF) + 1, ((ccsidr >> 13) & 0x7FFF) + 1


def scenario(console, swd, seed, vector):
    """Every phase's verdict, each against the host's oracle."""
    rng = random.Random(seed)
    verdicts = {}
    console.send(START)
    b = frame(console, 'b', 5, 'the boot frame')
    require(set(b) == set('cglvs'), 'boot frame has missing or unexpected fields')
    require(b['c'] & CCR_CACHES == CCR_CACHES,
            'SCB_CCR is %08x: reset did not enable both caches' % b['c'])
    require(geometry(b['g']) == (LINE, WAYS, SETS),
            'CCSIDR is %08x: not a 16 KiB four-way data cache of 32-byte lines' % b['g'])
    require(b['l'] == LINE, 'the provider says %d-byte lines, not %d' % (b['l'], LINE))
    require(b['v'] == vector, 'VTOR is %08x, not the loaded table' % b['v'])
    require(b['s'] == START[0], 'the maintained ring read %02x, not the start byte' % b['s'])
    running = swd.read_words('swd-ccr-running', CCR, 1)[0]
    require(running & CCR_CACHES == CCR_CACHES,
            'SCB_CCR reads %08x over SWD while the run goes on: a cache is off' % running)
    verdicts['boot'] = dict(ccr=b['c'], ccsidr=b['g'], line=b['l'], vtor=b['v'], swd_ccr=running)

    c = frame(console, 'c', 5, 'the stale-read control')
    require(c['n'] == CONTROL, 'the control asks for %d bytes, not %d' % (c['n'], CONTROL))
    block = bytes(rng.choice([v for v in range(256) if v != RING_FILL]) for _ in range(CONTROL))
    console.send(block)
    r = frame(console, 'C', 5, 'the stale-read verdict')
    require(r['n'] == CONTROL, 'the control read %d bytes, not %d' % (r['n'], CONTROL))
    require(r['m'] == fnv(block), 'memory, once invalidated, does not hold the %d bytes sent'
            % CONTROL)
    # A line the cache kept is the stale fill throughout; one evicted in
    # between was fetched again, so it reads as sent.  At least one stale.
    predicted = {mask: fnv(data) for mask, data in mixes(bytes([RING_FILL]) * CONTROL, block)}
    require(r['k'] in predicted and r['s'] == LINE * bin(r['k']).count('1')
            and r['a'] == predicted[r['k']],
            'the read without an invalidate returned %d of %d bytes stale, lines %#x, which no'
            ' mix of whole stale and fresh lines with one stale gives' % (r['s'], CONTROL, r['k']))
    verdicts['stale_read'] = dict(sent=CONTROL, stale=r['s'], stale_lines=r['k'],
                                  memory_matches=True)

    stream = bytes(rng.randrange(256) for _ in range(STREAM))
    console.send(stream)
    e = frame(console, 'E', 10, 'the maintained stream')
    require(e['n'] == STREAM and e['x'] == fnv(stream),
            'the maintained ring read %d bytes hashing %08x; the host sent %d hashing %08x'
            % (e['n'], e['x'], STREAM, fnv(stream)))
    require(e['w'] >= (CONTROL + STREAM) // 256,
            'the ring completed %d laps, fewer than its %d bytes need' % (e['w'], CONTROL + STREAM))
    verdicts['receive'] = dict(bytes=e['n'], laps=e['w'])

    d = frame(console, 'd', 5, "the CPU's controls")
    require(d['l'] == LINE, 'an invalidated dirty line kept %d of its %d bytes: the invalidate'
            ' did not discard them as predicted' % (LINE - d['l'], LINE))
    require(d['r'] == REFUSED, '%d of the %d ranges that are not whole lines were refused'
            % (d['r'], REFUSED))
    require(d['k'] == LINE and d['w'] == LINE,
            'the line under the refused ranges kept %d and wrote %d of its %d dirty bytes'
            % (d['k'], d['w'], LINE))
    verdicts['lost_dirty'] = dict(lost=d['l'], refused=d['r'], kept=d['k'], written=d['w'])

    y = frame(console, 'Y', 5, 'the maintained transmit')
    taken = run_stream(bytes(console.received))
    for tag in ('x', 'X', 'y'):
        require(any(p[0] == 'frame' and p[1] == tag for p in segments(taken)), 'no %s frame' % tag)
    unclean, cleaned = between(taken, 'x', 'X'), between(taken, 'y', 'Y')
    x_end = [p[2] for p in segments(taken) if p[0] == 'frame' and p[1] == 'X'][0]
    require(x_end['t'] == 1 and y['t'] == 1, 'a transmit did not complete without an error')
    # A line the cache kept dirty leaves memory's stale `o`s for the
    # stream; one evicted in between was written back, so it carries the
    # message.  At least one stale.
    lines = dict((data, mask) for mask, data in mixes(bytes([TRANSMIT_MEMORY]) * TRANSMIT,
                                                      message()))
    require(unclean in lines, 'the transmit without a clean carried %r, which no mix of whole'
            ' stale lines of memory\'s %r and lines of the message with one stale gives'
            % (unclean[:16], bytes([TRANSMIT_MEMORY])))
    require(cleaned == message(), 'the cleaned transmit carried %r, not the message' % cleaned[:16])
    verdicts['transmit'] = dict(unclean_stale=unclean.count(TRANSMIT_MEMORY),
                                unclean_lines=lines[unclean], cleaned=len(cleaned))

    end = frame(console, 'e', 5, 'the last frame')
    require(end['c'] & CCR_CACHES == CCR_CACHES, 'SCB_CCR is %08x before the return' % end['c'])
    outside = [p[1] for p in segments(run_stream(bytes(console.received))) if p[0] == 'raw']
    require(len(outside) == 2, 'bytes arrived outside the frames and the two transmits')
    time.sleep(0.2)
    after = swd.read_words('swd-ccr-returned', CCR, 1)[0]
    require(after & CCR_CACHES == 0,
            'SCB_CCR reads %08x over SWD once the entry returned: a cache is still on' % after)
    verdicts['returned'] = dict(ccr=after)
    return verdicts


def wait_for_path(path, seconds):
    """PATH, a tty named on the command line, once it can be opened."""
    deadline = time.time() + seconds
    while time.time() < deadline:
        if path.exists() and os.access(path, os.R_OK | os.W_OK):
            return path
        time.sleep(0.1)
    raise Failed('%s could not be opened within %g s' % (path, seconds))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--refine', type=Path)
    common.board_arguments(parser)
    parser.add_argument('--probe-rs', type=Path, default=shutil.which('probe-rs'),
                        help='a probe-rs that reaches the ST-LINK')
    parser.add_argument('--serial', default='001900293137511339383538',
                        help="the ST-LINK's USB serial, the maintainer's rig's by default")
    parser.add_argument('--probe', help="probe-rs's --probe; 0483:374e:SERIAL, an STLINK-V3E, by default")
    tool = lambda name: shutil.which('arm-eabi-' + name) or shutil.which('arm-none-eabi-' + name)  # noqa: E731
    parser.add_argument('--nm', default=tool('nm'))
    parser.add_argument('--objdump', default=tool('objdump'))
    parser.add_argument('--output', type=Path, required=True, help='a new directory')
    parser.add_argument('--hub-group', default='dialout',
                        help='the group that may open the virtual COM port; the tool runs itself'
                             ' through sg when the session is not in it')
    common.pace_arguments(parser)
    parser.add_argument('--console', type=Path,
                        help="the virtual COM port's tty, found by --serial's USB serial by default")
    parser.add_argument('--tty-seconds', type=float, default=20.0)
    parser.add_argument('--seed', type=int, default=1230)
    parser.add_argument('--record', type=Path, help="also write a passed run's record here")
    args = parser.parse_args()
    require(args.mode == 'ram', 'the cached profile runs from SRAM alone; the boot check is the'
            ' cacheless port\'s, environments/boards/stm32h753/board.py --mode=boot')
    common.board_preflight(args, BOARD)
    common.rerun_in_group(args.hub_group)
    require(args.probe_rs, 'no probe-rs: name one with --probe-rs')
    for name in ('nm', 'objdump'):
        require(args.bundle or getattr(args, name), 'no arm-eabi-%s or arm-none-eabi-%s on PATH: name'
                ' one with --%s' % (name, name, name))
    args.probe = args.probe or common.stlink(args.serial)
    args.output = args.output.resolve()
    args.output.mkdir(parents=True)
    args.pace = common.Pace(args.spacing, args.quiet)
    run = common.Run(args.output)
    run.pace = args.pace
    result = dict(status='failed', mode=args.mode)
    began = time.monotonic()
    console = None
    lock = common.rig_lock('stm32h753_cached board.py')
    try:
        elf, _, names, image = build(run, args)
        lock.acquire()
        result.update(image_sha256=common.sha(elf), image_name=elf.name, image=image)
        tty = (wait_for_path(args.console, args.tty_seconds) if args.console
               else common.wait_for_tty(args.serial, args.tty_seconds))
        result['tty'] = str(tty)
        console = common.TtyConsole(tty)
        result['warm_load'] = common.ram_load(run, args, HELPER_BOARD, elf)
        result['verdicts'] = scenario(console, probe(run, args), args.seed,
                                      common.elf_sections(elf)[1]['.isr_vector'][0])
        console.close()
        args.pace.before('board scenario completion')
        result['status'] = 'passed'
    except (Failed, subprocess.TimeoutExpired, OSError) as error:
        common.fail(result, error)
    finally:
        if console:
            console.close()
            raw = bytes(console.received)
            (args.output / 'uart.bin').write_bytes(raw)
            (args.output / 'sent.bin').write_bytes(bytes(console.sent))
            result['uart_sha256'] = hashlib.sha256(raw).hexdigest()
            result['frames'] = [dict(tag=p[1], **{k: '%08x' % v for k, v in p[2].items()})
                                for p in segments(run_stream(raw)) if p[0] == 'frame']
        common.retain_kernel_usb(args.pace, result)
        lock.release()
        result['seconds'] = round(time.monotonic() - began, 3)
        result['commands'] = run.commands
        common.write_result(args.output / 'result.json', result, run)
    if args.record and result['status'] == 'passed':
        kept = ('status', 'image_sha256', 'image_name', 'image', 'verdicts', 'uart_sha256',
                'mode', 'warm_load', 'seconds')
        common.write_json(args.record, common.record(
            result, tuple(k for k in kept if k in result), (args.output / 'sent.bin').read_bytes(),
            run.commands, ('b', 'C', 'E', 'd', 'X', 'Y')))
    print('board %s: %s%s' % (result['status'], args.output,
                              ': ' + result['failure'] if result['status'] == 'failed' else ''))
    return 0 if result['status'] == 'passed' else 1


if __name__ == '__main__':
    sys.exit(common.tool_main(main))
