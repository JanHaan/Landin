#!/usr/bin/env python3
"""Run the board port from SRAM by default and check its physical oracle.

RAM runs consume --bundle or build with --refine, then use --ram-loader
without flash writes or resets. --mode=boot checks a flash/cold boot and
restores --fixed-image; the numbered flash steps below describe that mode.

    python3 environments/boards/stm32h753/board.py --refine REFINE \\
        --probe-rs PROBE_RS --ram-loader LOADER --output NEW_DIRECTORY

A developer tool, not a compiler dependency: refine builds the image, and
this checks what the board does with it.  The board is reached through its
own ST-LINK V3: probe-rs flashes and reads it over SWD, named by the
ST-LINK's USB serial, and its virtual COM port, a tty found by the same
serial, carries USART3.  The board's power is the ST-LINK's USB port on a
hub uhubctl can switch.  The steps, each recorded under NEW_DIRECTORY:

  1. build the image at --level=armv7e-m and check, from the ELF alone,
     its vector table at the boot address and the handlers at slots 27
     and 55, and, from its disassembly, whether the float routines use the
     float unit or software helpers;
  2. flash it with probe-rs, verify it, and, once the hub lists the
     ST-LINK again, read the vector table back;
  3. cut the board's power and restore it, after checking that the port
     holds the ST-LINK named and that the probe's Arty is off the cascade,
     the cycle paced with every other tool's actions on the rig, and wait
     for the hub to list the ST-LINK again;
  4. find the virtual COM port again once it re-enumerates, send the start
     byte, read the boot frame and drive the scenario, comparing every
     echoed byte and every frame with what the host sent and with RM0433;
  5. read the counters and the stream's configuration back over SWD and
     compare them with the last frame and with RM0433.

The oracle is written here, from what the host sends, from RM0433 Rev 9
and from IEEE 754 as the host computes it, never from the firmware's own
idea of itself; see environments/boards/stm32h753/README.md.
"""

import argparse
import hashlib
import math
import os
import random
import re
import shutil
import struct
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
SOURCE = ROOT / 'compiler/tests/board/stm32h753'
sys.path.insert(0, str(HERE.parent))
import common  # noqa: E402
from common import Failed, echo_of, require  # noqa: E402,F401

CHIP = 'STM32H753ZITx'
# The board's command bytes, which it also echoes, and the start byte.
START = b'S'
REPORT, STALL, F32, F64 = 0x11, 0x12, 0x14, 0x15
BUDGET = 4096           # the application's DMA epoch
RING = 256              # its receive ring
# In FIFO mode USART3's receiver holds 17 bytes while nothing reads it:
# its RXFIFO's 16 (Table 402, p. 2018) and one in the receive data
# register, the 17th not setting ORE (48.5.4, p. 2023; note 2, p. 2067).
# ORE flags the next as lost (48.5.6, p. 2030).
HELD = 17
VECTORS = 0x08000000    # the boot address, BOOT_ADD0's reset value (2.6, p. 138)
VECTOR_WORDS = 166      # 16 and the 150 interrupts of Table 147, p. 759
DMA_SLOT = 16 + 11      # DMA_STR0 (Table 147, p. 754)
USART3_SLOT = 16 + 39   # USART3 (Table 147, p. 755)
# RCC_RSR's named flags, and those Table 56 (p. 333) sets at a power-on
# reset: PORRSTF, PINRSTF, BORRSTF, D2RSTF, D1RSTF and CPURSTF (8.7.39,
# p. 450); SFTRSTF, the watchdogs' and LPWRRSTF stay clear.
RSR_FLAGS = 0x55fa0000
RSR_POWER_ON = 0x00fa0000
# PWR_CSR1 (6.8.2, p. 305): ACTVOS in 15:14 reads VOS3, 01, from reset,
# and ACTVOSRDY, bit 13, is set once the supply is configured and the
# voltage levels are valid (6.4.1, p. 262).  PWR_CR3's lower byte (6.8.4,
# p. 308), as the description's stage writes it before reset (D653): LDOEN
# set, BYPASS and SCUEN clear.
ACTVOS, VOS3, ACTVOSRDY = 0xc000, 0x4000, 0x2000
CR3_SUPPLY, CR3_LDO = 0x7, 0x2
# SCB_CPACR's CP10 and CP11, full access, and SCB_CCR's IC and DC.
CPACR_FPU = 0x00f00000
CCR_CACHES = 0x00030000
# DMA1 stream 0 (15.5.5, p. 662; 15.5.6, p. 665): S0CR, and its TRBUFF,
# which must be set for a stream that serves a USART; S0NDTR.
DMA1_S0CR, DMA1_S0NDTR = 0x40020010, 0x40020014
TRBUFF = 0x00100000
# What environments/cortex-m/driver.py feeds the synthetic application.
SHARED = b'1A0'
# The float routines whose instructions are checked, and what checks them.
FLOAT_ROUTINES = ('exercise32', 'order32', 'exercise64', 'order64')
SOFT_FLOAT = re.compile(r'<(__aeabi_c?[fd]\w*|__\w+[sd]f[23])>')
VFP = {width: ['v%s.%s' % (op, width) for op in ('add', 'sub', 'mul', 'div')]
       for width in ('f32', 'f64')}


# The operands of the float exercise, as the host encodes them: each
# nibble of each operand, most significant first, as 'a' to 'p'.
def letters(*words):
    return bytes(0x61 + ((w >> s) & 15) for w, bits in words for s in range(bits - 4, -4, -4))


def f32(bits):
    return struct.unpack('<f', struct.pack('<I', bits))[0]


def f64(bits):
    return struct.unpack('<d', struct.pack('<Q', bits))[0]


def bits32(value):
    """VALUE, a Python float, rounded once to binary32, as its bits."""
    try:
        return struct.unpack('<I', struct.pack('<f', value))[0]
    except OverflowError:
        # struct refuses only a finite value that rounds to infinity.
        return 0xff800000 if value < 0 else 0x7f800000


def bits64(value):
    return struct.unpack('<Q', struct.pack('<d', value))[0]


def quotient(a, b):
    """IEEE 754's division, which Python's refuses by zero."""
    if b == 0:
        if a == 0 or math.isnan(a):
            return math.nan
        return math.copysign(math.inf, math.copysign(1, a) * math.copysign(1, b))
    return a / b


def root(a):
    """IEEE 754's square root: -0 is -0, and below it is NaN."""
    if math.isnan(a) or a < 0:
        return math.nan
    return a if a == 0 or math.isinf(a) else math.sqrt(a)


def order(a, b):
    """The six comparisons as the firmware packs them."""
    return ((a < b) | (a <= b) << 1 | (a == b) << 2 | (a != b) << 3
            | (a >= b) << 4 | (a > b) << 5)


def expected(width, x, y):
    """The results IEEE 754 gives for operands X and Y, as bit patterns:
    f64's from Python's own binary64 arithmetic, f32's from the binary64
    result of binary32 operands rounded once to binary32, which is
    correctly rounded for these operations."""
    a, b = (f32(x), f32(y)) if width == 32 else (f64(x), f64(y))
    pack = bits32 if width == 32 else bits64
    return dict(sum=pack(a + b), difference=pack(a - b), product=pack(a * b),
                quotient=pack(quotient(a, b)), order=order(a, b), root=pack(root(a)))


def is_nan(width, bits):
    if width == 32:
        return (bits & 0x7f800000) == 0x7f800000 and (bits & 0x007fffff) != 0
    return (bits & 0x7ff0000000000000) == 0x7ff0000000000000 and (bits & 0x000fffffffffffff) != 0


def results(width, frame):
    """A float frame's results; a 64-bit one gives each in two fields, its
    key the high word and the next letter the low."""
    def field(key):
        if width == 32:
            return frame.get(key)
        if key not in frame:
            return None
        return frame[key] << 32 | frame[chr(ord(key) + 1)]
    out = dict(sum=field('a'), difference=field('s'), product=field('m'),
               quotient=field('d'), order=frame.get('c'))
    if 'q' in frame:
        out['root'] = field('q')
    return out


def compare(width, got, want):
    """Where GOT differs from WANT: a NaN matches any NaN, since IEEE 754
    fixes no NaN's bits, and every other result matches bit for bit."""
    wrong = []
    for name, value in want.items():
        if name not in got:
            continue
        if name != 'order' and is_nan(width, value):
            if not is_nan(width, got[name]):
                wrong.append(name)
        elif got[name] != value:
            wrong.append(name)
    return wrong


# The operand pairs: the special values and the boundaries, then seeded
# finite ones of every exponent.
SPECIAL32 = [0x3f800000, 0x40490fdb, 0x00000000, 0x80000000, 0x7f800000, 0xff800000,
             0x7fc00000, 0x00000001, 0x007fffff, 0x7f7fffff, 0x3eaaaaab]
SPECIAL64 = [0x3ff0000000000000, 0x400921fb54442d18, 0x0, 0x8000000000000000,
             0x7ff0000000000000, 0xfff0000000000000, 0x7ff8000000000000, 0x1,
             0x000fffffffffffff, 0x7fefffffffffffff, 0x3fd5555555555555]


def operand_pairs(width, rng, count=24):
    special = SPECIAL32 if width == 32 else SPECIAL64
    pairs = [(a, b) for a in special[:7] for b in special[:7]][::3]
    pairs += [(special[i], special[-1 - i]) for i in range(len(special))]
    return pairs + [(rng.getrandbits(width), rng.getrandbits(width)) for _ in range(count)]


def float_routines(listing, sizes):
    """The instructions of FLOAT_ROUTINES in objdump's LISTING, by routine,
    from their extents in SIZES, {name: (address, size)}."""
    found = {name: [] for name in FLOAT_ROUTINES if name in sizes}
    for line in listing.splitlines():
        m = re.match(r'\s*([0-9a-f]+):\t', line)
        if not m:
            continue
        at = int(m.group(1), 16)
        for name in found:
            start, size = sizes[name]
            if start <= at < start + size:
                found[name].append(line)
    return found


def float_unit(found):
    """'passed' when the float routines use the float unit and call no
    software helper, 'pending' when they call software helpers and use no
    float instruction, as before the M7's float unit is selected, and a
    failure otherwise."""
    # The comparisons may be inlined into the exercises; the exercises
    # themselves are the routines the application calls.
    require({'exercise32', 'exercise64'} <= set(found), 'the image lacks float routines %s'
            % ', '.join(sorted({'exercise32', 'exercise64'} - set(found))))
    text = '\n'.join(line for lines in found.values() for line in lines)
    helpers = sorted(set(SOFT_FLOAT.findall(text)))
    present = [op for ops in VFP.values() for op in ops if re.search(r'\t%s\b' % re.escape(op), text)]
    compares = [w for w in ('f32', 'f64') if re.search(r'\tvcmpe?\.%s\b' % w, text)]
    if helpers and not present and not compares:
        return 'pending', helpers
    require(not helpers, 'the float routines call software helpers %s' % ', '.join(helpers))
    missing = [op for ops in VFP.values() for op in ops if op not in present]
    missing += ['vcmp.' + w for w in ('f32', 'f64') if w not in compares]
    require(not missing, 'the float routines lack %s' % ', '.join(missing))
    return 'passed', []


def build(run, args):
    if getattr(args, 'bundle', None):
        elf, meta, names = common.consume_board(run, args, 'stm32h753')
        return elf, bytes.fromhex(meta['table']), names, meta['image']
    elf = run.out / getattr(args, 'image_name', 'board.elf')
    run.command('compile', [args.refine, '--root=' + str(ROOT / 'devices'),
        '--root=' + str(ROOT / 'devices/generated'), '--root=' + str(ROOT / 'compiler/tests/driver'),
        '--root=' + str(SOURCE), '--target=cortex-m0', '--level=armv7e-m',
        '--firmware-entry=start', '--emit=exe', *common.firmware_layout(args),
        '--build-report=' + str(run.out / 'build.json'), str(SOURCE / 'app'), '-o', str(elf)])
    data, sections = common.elf_sections(elf)
    address, offset, size = sections['.isr_vector']
    expected = common.validate_ram_image(elf, 'stm32h753') if getattr(args, 'mode', 'boot') == 'ram' else VECTORS
    require(address == expected and size == 4 * VECTOR_WORDS,
            'the vector table is not %d words at %#x' % (VECTOR_WORDS, VECTORS))
    words = struct.unpack_from('<%dI' % VECTOR_WORDS, data, offset)
    names = common.symbols(run, args.nm, elf)
    # D653: the reset word enters the description's supply stage, which
    # enters compiler-owned reset once ACTVOSRDY says RAM may be written.
    require(words[1] == names['_landin_firmware_reset_stage'] | 1,
            'vector word 1 is not the supply stage that enters reset')
    require(words[DMA_SLOT] == names['dma_irq'] | 1, 'vector word 27 is not the DMA_STR0 handler')
    require(words[USART3_SLOT] == names['usart3_irq'] | 1,
            'vector word 55 is not the USART3 handler')
    sizes = {f[3]: (int(f[0], 16), int(f[1], 16))
             for f in (l.split() for l in run.command('symbol-sizes', [args.nm, '-S', elf]).splitlines())
             if len(f) == 4}
    listing = run.command('disassembly', [args.objdump, '-d', elf])
    attributes = run.command('attributes', [args.readelf, '-A', elf])
    unit, helpers = float_unit(float_routines(listing, sizes))
    table = data[offset:offset + size]
    return elf, table, names, dict(float_unit=unit, helpers=helpers,
                                   fp_attributes=[l.strip() for l in attributes.splitlines()
                                                  if 'FP' in l or 'VFP' in l])


def probe(run, args):
    return common.Probe(run, args.probe_rs, CHIP, args.probe)


def settle(run, args):
    """Wait for the hub to list the ST-LINK on its port again: a download
    resets the chip, and a switch drops the ST-LINK for a few seconds
    (D725)."""
    common.wait_for_hub(run, args.hub, [(args.port, args.serial)], args.hub_seconds)


def flash(run, args, elf, table):
    """Flash and verify the image, paced with every other tool's actions on
    the rig, as any download is, and read its vector table back once the hub
    lists the ST-LINK again (D832)."""
    swd = probe(run, args)
    common.paced(args.pace, 'download', lambda: run.command(
        'flash', swd.argv('download', '--verify', elf), timeout=300),
        args.guard_serial, args.cascade)
    settle(common.InGroup(run, args.hub_group), args)
    back = swd.read_bytes('flash-readback', VECTORS, len(table))
    require(back == table, "flash does not hold the image's vector table")
    return back


def power_cycle(run, args):
    """The ST-LINK's port, only when the hub's listing shows it there and
    the probe's Arty is off the cascade, paced with every other tool's
    actions on the rig, and then the ST-LINK listed again (D725).  The
    first listing is asked again while it fails: one that resumed a hub the
    kernel had suspended re-enumerated the cascade under it on its earlier
    port (D832)."""
    common.paced(args.pace, 'power cycle', lambda: common.power_cycle(
        common.Listings(run, args.hub_seconds), args.hub, args.port, args.off_seconds,
        holds=args.serial), args.guard_serial, args.cascade)
    settle(run, args)


def report(console):
    """Ask for the next telemetry frame and return it."""
    return common.ask(console, REPORT, 't', len(common.tagged(bytes(console.received), 't')))


def echoed(console, data, seconds=5):
    """Send DATA and wait until the echo ends with it."""
    console.send(data)
    console.wait(lambda s: echo_of(s).endswith(data), seconds, 'the echo of %r' % data[:8])


def wait_for_path(path, seconds):
    """PATH, a tty named on the command line, once it can be opened again
    after the power cycle."""
    deadline = time.time() + seconds
    while time.time() < deadline:
        if path.exists() and os.access(path, os.R_OK | os.W_OK):
            return path
        time.sleep(0.1)
    raise Failed('%s could not be opened within %g s' % (path, seconds))


def boot(console, mode='boot', vector=None):
    """The boot frame, which the firmware writes once a byte has arrived."""
    stream = console.wait(lambda s: common.tagged(s, 'b'), 5, 'the boot frame')
    b = common.tagged(stream, 'b')[0]
    if mode == 'boot':
        require(b['r'] & RSR_FLAGS == RSR_POWER_ON,
                'RCC_RSR is %08x, not the flags of a power-on reset alone' % b['r'])
    require(b['v'] == (VECTORS if vector is None else vector), 'VTOR is %08x, not the boot address' % b['v'])
    require(b['c'] & CCR_CACHES == 0, 'SCB_CCR is %08x: a cache is enabled' % b['c'])
    require(b['q'] & CR3_SUPPLY == CR3_LDO,
            'PWR_CR3 reads %08x: the stage did not configure the LDO supply' % b['q'])
    require(b['y'] & (ACTVOS | ACTVOSRDY) == VOS3 | ACTVOSRDY,
            'PWR_CSR1 reads %08x: the voltage levels are not valid at VOS3' % b['y'])
    require(b['w'] == len(START), '%d bytes had arrived when the boot frame was written; the'
            ' host sent %d' % (b['w'], len(START)))
    return dict(rcc_rsr=b['r'], vtor=b['v'], cpacr=b['a'], ccr=b['c'],
                pwr_cr3=b['q'], pwr_csr1=b['y'])


def discarded(sent, spans):
    """What SENT echoes when the bytes of SPANS, each (start, length), are
    lost: the oracle's expected echo."""
    out, at = bytearray(), 0
    for begin, length in sorted(spans):
        out += sent[at:begin]
        at = begin + length
    return bytes(out + sent[at:])


def scenario(console, seed, mode='boot', vector=None):
    """The board-port scenario and its oracle.  Returns the verdicts, the
    last telemetry frame and the bytes the epoch then running has taken."""
    verdicts = {}
    echoed(console, START, 10)
    verdicts['boot'] = boot(console, mode, vector)
    # The shared scenario (D593), the bytes the emulator lane's application
    # is fed, 1, A and 0: each echoed, 1 setting PB0 and 0 clearing it,
    # which its input data register reads back.
    echoed(console, SHARED[:1])
    high = report(console)
    echoed(console, SHARED[1:])
    low = report(console)
    require(high['g'] == 1 and low['g'] == 0,
            'PB0 read back %x after 1 and %x after 0' % (high['g'], low['g']))
    require(echo_of(console.received).startswith(
        START + SHARED[:1] + bytes([REPORT]) + SHARED[1:] + bytes([REPORT])),
            'the shared scenario was not echoed')
    verdicts['shared'] = dict(input=SHARED.decode(), echo=SHARED.decode(),
                              indicator_after_1=high['g'], indicator_after_0=low['g'])
    # USART3's IDLE interrupt woke the application for every byte it has
    # echoed, in its handler at slot 55, in exception 55.
    require(high['u'] >= 1 and high['p'] == USART3_SLOT,
            'USART3 entered %d times, in exception %d' % (high['u'], high['p']))
    require(low['u'] > high['u'], 'USART3 did not enter again for the second report')
    verdicts['usart3'] = dict(entries=low['u'], exception=low['p'])
    epoch = len(console.sent)
    require(epoch < RING, 'the scenario overran before its burst')
    # An overrun: the application stops reading for 100 ms after echoing
    # STALL, and a burst longer than the ring arrives meanwhile.  The
    # stream keeps lapping the ring, the snapshot sees more than the ring
    # holds, and all of it is discarded and the ring restarted.
    echoed(console, bytes([STALL]))
    rng = random.Random(seed)
    burst = bytes(rng.randrange(0x20, 0x7f) for _ in range(300))
    console.send(burst, pace=300)
    time.sleep(0.3)
    overrun = report(console)
    require(overrun['c'] == 1, 'the overrun made %d recoveries, not 1' % overrun['c'])
    require(overrun['w'] >= 1, 'the burst completed no lap of the ring')
    verdicts['overrun'] = dict(burst=len(burst), recoveries=overrun['c'])
    # The restarted epoch holds that REPORT.  Each epoch is now filled to
    # its 4096 bytes and no further, then the host waits: while a stream is
    # exhausted the USART's receive register holds one byte, and only that.
    def fill(epoch, last=b''):
        part = bytes(rng.randrange(0x20, 0x7f) for _ in range(BUDGET - epoch - len(last)))
        console.send(part + last)
        return part
    # An epoch that ends in STALL: the stream is exhausted while the
    # application stops reading, and a 100-byte burst then overruns the
    # USART.  ORE flags the loss, the application restarts on it, and of
    # the burst only the byte the receive register held reaches the new
    # epoch.
    fill(1, bytes([STALL]))
    console.wait(lambda s: echo_of(s).count(STALL) == 2, 30, 'the second echo of STALL')
    lost = bytes(rng.randrange(0x20, 0x7f) for _ in range(100))
    console.send(lost, pace=100)
    time.sleep(0.3)
    flagged = report(console)
    require(flagged['c'] == 2 and flagged['d'] == 1,
            'after a burst into an exhausted stream: %d restarts and %d epochs, not 2 and 1'
            % (flagged['c'], flagged['d']))
    # An epoch that ends with nothing behind it: exhausted, restarted, and
    # the REPORT that waited in the receive register meanwhile is the next
    # epoch's.
    fill(HELD + 1)
    after = report(console)
    require(after['c'] == 3 and after['d'] == 2,
            'after an exhausted epoch: %d restarts and %d epochs, not 3 and 2'
            % (after['c'], after['d']))
    tail = 1000
    console.send(bytes(rng.randrange(0x20, 0x7f) for _ in range(tail)))
    final = report(console)
    require(final['c'] == 3 and final['d'] == 2, 'the last epoch restarted the ring')
    require(final['w'] > after['w'] > high['w'], 'the stream did not keep lapping the ring')
    require(final['m'] > after['m'] > high['m'], 'SysTick did not advance')
    echo = echo_of(console.wait(lambda s: True, 1, 'the stream'))
    sent = bytes(console.sent)
    expect = discarded(sent, [(sent.index(burst), len(burst)),
                              (sent.index(lost) + HELD, len(lost) - HELD)])
    require(echo == expect, 'the echo differs from what was sent, first at byte %d'
            % next((i for i, (a, b) in enumerate(zip(echo, expect)) if a != b),
                   min(len(echo), len(expect))))
    require(final['h'] == len(expect), 'handled %d bytes, not %d' % (final['h'], len(expect)))
    verdicts['epochs'] = dict(flagged_burst=len(lost), held_by_receiver=HELD,
                              restarts=final['c'], epochs=final['d'], laps=final['w'],
                              echoed=len(echo), sent=len(sent))
    # The epoch running holds after's REPORT, the tail and final's REPORT.
    return verdicts, final, 1 + tail + 1


def floats(console, seed, used):
    """The float exercise against IEEE 754 as the host computes it.  The
    square root is pending until the firmware sends it.  USED is what the
    epoch running has taken: the exercise must fit in what is left, with
    the closing REPORT, since an epoch exhausted under a command's
    operands would lose them."""
    rng = random.Random(seed + 1)
    verdict = {}
    exercises = [(32, F32, 'f', operand_pairs(32, rng)), (64, F64, 'F', operand_pairs(64, rng))]
    room = BUDGET - used - 1
    need = sum(len(pairs) * (1 + width // 2) for width, _, _, pairs in exercises)
    require(need <= room, 'the float exercise needs %d bytes, and the epoch has %d' % (need, room))
    for width, command, tag, pairs in exercises:
        rooted = 0
        for count, (x, y) in enumerate(pairs):
            console.send(bytes([command]) + letters((x, width), (y, width)), pace=16)
            stream = console.wait(lambda s: len(common.tagged(s, tag)) > count, 5,
                                  'float frame %s %d' % (tag, count + 1))
            got = results(width, common.tagged(stream, tag)[count])
            wrong = compare(width, got, expected(width, x, y))
            require(not wrong, 'f%d %x, %x: %s differ from IEEE 754'
                    % (width, x, y, ', '.join(wrong)))
            rooted += 'root' in got
        verdict['f%d' % width] = dict(pairs=len(pairs), square_roots=rooted)
    verdict['square_root'] = ('passed' if all(verdict[w]['square_roots'] == verdict[w]['pairs']
                                              for w in ('f32', 'f64')) else 'pending')
    return verdict


def cross_check(run, args, names, final):
    """The counters as SWD reads them, without halting, against the frame,
    and the stream's configuration against RM0433."""
    swd = probe(run, args)
    pairs = [('handled', 'h'), ('recoveries', 'c'), ('dma_entries', 'k'), ('usart_entries', 'u')]
    read = {name: swd.read_words('swd-' + name, names[name], 1)[0] for name, _ in pairs}
    for name, key in pairs:
        require(read[name] == final[key], '%s reads %d over SWD, %d in the frame'
                % (name, read[name], final[key]))
    count = swd.read_words('swd-s0ndtr', DMA1_S0NDTR, 1)[0]
    require(count == final['n'], 'S0NDTR reads %d over SWD, %d in the frame' % (count, final['n']))
    config = swd.read_words('swd-s0cr', DMA1_S0CR, 1)[0]
    read.update(s0ndtr=count, s0cr=config)
    require(config & TRBUFF, 'DMA1_S0CR reads %08x: TRBUFF, which RM0433 15.5.5 (p. 662) requires'
            ' for a stream serving a USART, is clear' % config)
    return read


def restore_fixed(run, args):
    """Restore and cold-start the board's validated resident image."""
    data, sections = common.elf_sections(args.fixed_image)
    address, offset, size = sections['.isr_vector']
    require(address == VECTORS, 'fixed image vectors are not at the flash boot address')
    flash(run, args, args.fixed_image, data[offset:offset + size])
    power_cycle(common.InGroup(run, args.hub_group), args)
    return common.read_fixed_marker(probe(run, args), common.fixed_elf(args, "stm32h753"))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--refine', type=Path)
    common.board_arguments(parser)
    parser.add_argument('--probe-rs', type=Path, default=shutil.which('probe-rs'),
                        help='a probe-rs that reaches the ST-LINK')
    parser.add_argument('--serial', default='001900293137511339383538',
                        help="the ST-LINK's USB serial, the maintainer's rig's by default: it names"
                             " the probe, the virtual COM port and the hub port that is switched")
    parser.add_argument('--probe', help="probe-rs's --probe; 0483:374e:SERIAL, an STLINK-V3E, by default")
    tool = lambda name: shutil.which('arm-eabi-' + name) or shutil.which('arm-none-eabi-' + name)  # noqa: E731
    parser.add_argument('--nm', default=tool('nm'))
    parser.add_argument('--objdump', default=tool('objdump'))
    parser.add_argument('--readelf', default=tool('readelf'))
    parser.add_argument('--output', type=Path, required=True, help='a new directory')
    parser.add_argument('--hub', default='.3', help="the ST-LINK's hub, as uhubctl -l names it or"
                        " relative to the cascade; the maintainer's rig's by default")
    parser.add_argument('--port', type=int, default=2, help="the ST-LINK's port on it")
    parser.add_argument('--hub-group', default='dialout',
                        help="the group that may switch the hub's ports and open the virtual COM"
                             " port; the tool runs itself through sg when the session is not in it")
    parser.add_argument('--off-seconds', type=float, default=1.0)
    parser.add_argument('--guard-serial', default='210319B3E738',
                        help="a device that must be present and off the switched cascade, the"
                             " probe's Arty on the maintainer's rig, or no port is switched")
    common.cascade_argument(parser)
    parser.add_argument('--hub-seconds', type=float, default=60.0,
                        help='how long the hub may take to list the ST-LINK again after a download'
                             ' or a cycle')
    common.pace_arguments(parser)
    parser.add_argument('--console', type=Path,
                        help="the virtual COM port's tty, found by --serial's USB serial under"
                             " /sys/class/tty by default")
    parser.add_argument('--tty-seconds', type=float, default=20.0,
                        help='how long the virtual COM port may take to come back')
    parser.add_argument('--seed', type=int, default=1230)
    parser.add_argument('--record', type=Path,
                        help="also write a passed run's record here")
    args = parser.parse_args()
    common.board_preflight(args, 'stm32h753')
    # The virtual COM port's tty belongs to --hub-group (D836).
    common.rerun_in_group(args.hub_group)
    common.place_hubs(parser, args, 'hub')
    require(args.probe_rs, 'no probe-rs: name one with --probe-rs')
    for name in ('nm', 'objdump', 'readelf'):
        require(args.bundle or getattr(args, name), 'no arm-eabi-%s or arm-none-eabi-%s on PATH: name one with --%s'
                % (name, name, name))
    args.probe = args.probe or common.stlink(args.serial)
    args.output = args.output.resolve()
    args.output.mkdir(parents=True)
    args.pace = common.Pace(args.spacing, args.quiet)
    run = common.Run(args.output)
    run.pace = args.pace
    result = dict(status='failed', mode=args.mode)
    began = time.monotonic()
    console = None
    # The run holds the rig's lock (D725).
    lock = common.rig_lock('stm32h753 board.py')
    lock_held = False
    try:
        elf, table, names, image = build(run, args)
        lock.acquire()
        # A borrowed parent lock is held without owning a file here.
        lock_held = True
        result.update(image_sha256=common.sha(elf), image_name=elf.name, image=image)
        if args.mode == 'boot':
            flash(run, args, elf, table)
            result['flash_readback'] = 'matches'
            power_cycle(common.InGroup(run, args.hub_group), args)
        tty = (wait_for_path(args.console, args.tty_seconds) if args.console
               else common.wait_for_tty(args.serial, args.tty_seconds))
        result['tty'] = str(tty)
        console = common.TtyConsole(tty)
        if args.mode == 'ram':
            result['warm_load'] = common.ram_load(run, args, 'stm32h753', elf)
        verdicts, final, used = scenario(console, args.seed, args.mode,
            common.elf_sections(elf)[1]['.isr_vector'][0])
        verdicts['floats'] = floats(console, args.seed, used)
        last = report(console)
        require(last['c'] == final['c'], 'the float exercise restarted the ring')
        result['verdicts'] = verdicts
        console.close()
        result['swd'] = cross_check(run, args, names, last)
        boot = verdicts['boot']
        # The float unit is the M7's only once the image uses it, the
        # compiler-owned startup grants CP10 and CP11, and the square root
        # runs on it; until then the run is pending, never passed.
        pending = [what for what, done in (
            ('the float routines use software helpers', image['float_unit'] == 'passed'),
            ('CPACR grants no float unit access', boot['cpacr'] & CPACR_FPU == CPACR_FPU),
            ('the square root is not sent', verdicts['floats']['square_root'] == 'passed'))
            if not done]
        result['pending'] = pending
        args.pace.before('board scenario completion')
        result['status'] = 'pending' if pending else 'passed'
    except (Failed, subprocess.TimeoutExpired, OSError) as error:
        result['failure'] = str(error)
    finally:
        if console:
            console.close()
            (args.output / 'uart.bin').write_bytes(bytes(console.received))
            (args.output / 'sent.bin').write_bytes(bytes(console.sent))
            result['uart_sha256'] = hashlib.sha256(bytes(console.received)).hexdigest()
            result['frames'] = common.frame_record(bytes(console.received))
            result['echo_gaps'] = common.gaps(bytes(console.sent),
                                              echo_of(bytes(console.received)))
        if lock_held:
            common.finish_boot(args, result, lambda: restore_fixed(run, args))
        common.retain_kernel_usb(args.pace, result)
        lock.release()
        result['seconds'] = round(time.monotonic() - began, 3)
        result['commands'] = run.commands
        common.write_json(args.output / 'result.json', result)
    if args.record and result['status'] == 'passed':
        kept = ('status', 'image_sha256', 'image_name', 'image', 'flash_readback', 'verdicts', 'swd', 'uart_sha256')
        common.write_json(args.record, common.record(
            result, tuple(k for k in (*kept, 'mode', 'warm_load', 'fixed_restore', 'seconds') if k in result), (args.output / 'sent.bin').read_bytes(), run.commands, ('b',)))
    print('board %s: %s%s' % (result['status'], args.output,
                              ': ' + result['failure'] if result['status'] == 'failed'
                              else ': ' + '; '.join(result['pending']) if result['status'] == 'pending'
                              else ''))
    return 0 if result['status'] == 'passed' else 1


if __name__ == '__main__':
    sys.exit(main())
