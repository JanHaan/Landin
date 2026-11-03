#!/usr/bin/env python3
"""Flash the prototype-1 board port to a Raspberry Pi Pico 2, boot it from
power-on and check its trace against the physical oracle.

    python3 environments/boards/rp2350/board.py --refine REFINE \
        --probehive DIR --probe-rs PROBE_RS --output NEW_DIRECTORY

A developer tool, not a compiler dependency: refine builds the image at
--level=armv8-m.main, and this checks what the board does with it.  The
board is reached through probehive slot 1 (https://github.com/JanHaan/probehive):
probe-rs reaches its SWD through `--probe`, and the probe's bridge,
DIR/scripts/dap_bridge.py, serves its UART as a TCP port while the scenario
runs; the two never hold the slot at once.  The Pico 2's power is its USB
port on a hub uhubctl can switch.  The steps, each recorded under
NEW_DIRECTORY:

  1. build the image and check, from the ELF alone, that its vector table
     is at the start of flash, that the IMAGE_DEF block the boot ROM looks
     for follows it as the datasheet gives it, and that vector word 30 is
     the USBCTRL_IRQ handler;
  2. with --block-control, flash a copy whose block's end marker is
     flipped, cycle the power and require the boot ROM to refuse it and
     enumerate as USB BOOTSEL, 2e8a:000f;
  3. flash the image with probe-rs, verify it, and read the vector table
     and the block back; flashed from BOOTSEL, which only --bootsel-attach
     allows, the power is cycled at once and the head read back from the
     image the boot ROM entered (D712);
  4. with the probe detached, cut the Pico 2's power and restore it, after
     checking that the probe's Arty is off the cascade, and wait for the
     hub to list again;
  5. read the boot frame and drive the scenario over the UART, comparing
     every echoed byte and every frame with what the host sent;
  6. read the counters back over SWD and compare them with the last frame.

The oracle is written here, from what the host sends and from the RP2350
datasheet (release 8), never from the firmware's own idea of itself; see
environments/boards/rp2350/README.md.
"""

import argparse
import hashlib
import random
import shutil
import struct
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
SOURCE = ROOT / 'compiler/tests/board/rp2350'
sys.path.insert(0, str(HERE.parent))
import common  # noqa: E402
import pico2  # noqa: E402
from common import (Failed, echo_of, elf_sections, frames, frames_safe,  # noqa: E402,F401
                    require, sha, symbols)
from pico2 import BOOTSEL  # noqa: E402,F401

# The board's command bytes, which it also echoes.
USBCTRL, REPORT, STALL = 0x05, 0x11, 0x12
BUDGET = 4096           # the application's DMA epoch
RING = 256              # its receive ring
# POWMAN's CHIP_RESET, HAD_POR alone: the last reset was the power-on
# reset (6.4, CHIP_RESET, p. 429).
CHIP_RESET_HAD_POR = 0x00010000
VECTORS = 0x10000000    # the start of flash, where the boot ROM enters it
VECTOR_WORDS = 68       # 16 and the 52 interrupts of Table 95
CLK_REF_XOSC = 4        # CLK_REF_SELECTED's bit for source 2, the crystal
USBCTRL_SLOT = 16 + 14  # USBCTRL_IRQ (3.2, Table 95, p. 81)
# The minimum Arm IMAGE_DEF (5.9.5.1, Table 503, p. 390): the start
# marker, IMAGE_TYPE 0x42 with flags 0x1021, an executable that runs on
# Arm in Secure state on RP2350, the LAST item of one word, a link of zero
# to itself, and the end marker (5.1.5.1, Blocks, p. 329).
IMAGE_DEF = (0xffffded3, 0x10210142, 0x000001ff, 0x00000000, 0xab123579)
# probehive's slot for the Pico 2.
SLOT = 1
# What environments/cortex-m/driver.py feeds the synthetic application.
SHARED = b'1A0'


def block_of(data, sections):
    """The IMAGE_DEF block's address and its words."""
    require('.embedded_block' in sections, 'the image has no IMAGE_DEF block')
    address, offset, size = sections['.embedded_block']
    require(size == 4 * len(IMAGE_DEF), 'the block is %d bytes, not %d' % (size, 4 * len(IMAGE_DEF)))
    return address, offset, struct.unpack_from('<%dI' % len(IMAGE_DEF), data, offset)


def build(run, args):
    elf = run.out / 'board.elf'
    run.command('compile', [args.refine, '--root=' + str(ROOT / 'devices'),
        '--root=' + str(ROOT / 'devices/generated'), '--root=' + str(ROOT / 'compiler/tests/driver'),
        '--root=' + str(SOURCE), '--target=cortex-m0', '--level=armv8-m.main',
        '--firmware-entry=start', '--emit=exe',
        '--build-report=' + str(run.out / 'build.json'), str(SOURCE / 'app'), '-o', str(elf)])
    data, sections = elf_sections(elf)
    address, offset, size = sections['.isr_vector']
    require(address == VECTORS and size == 4 * VECTOR_WORDS,
            'the vector table is not %d words at %#x' % (VECTOR_WORDS, VECTORS))
    words = struct.unpack_from('<%dI' % VECTOR_WORDS, data, offset)
    names = symbols(run, args.nm, elf)
    require(words[USBCTRL_SLOT] == names['usb_irq'] | 1,
            'vector word 30 is not the USBCTRL_IRQ handler')
    block, _, found = block_of(data, sections)
    require(block == VECTORS + size, 'the block is at %#x, not directly after the table' % block)
    require(found == IMAGE_DEF, 'the block is %s, not the minimum Arm IMAGE_DEF'
            % ' '.join('%08x' % w for w in found))
    head = common.loaded(elf, VECTORS, block + 4 * len(IMAGE_DEF) - VECTORS)
    return elf, head, names


def corrupted(run, elf):
    """A copy of ELF whose block's end marker is flipped, which the boot ROM
    must not take for a block."""
    data, sections = elf_sections(elf)
    _, offset, words = block_of(data, sections)
    at = offset + 4 * (len(IMAGE_DEF) - 1)
    bad = bytearray(data)
    struct.pack_into('<I', bad, at, words[-1] ^ 0xffffffff)
    copy = run.out / 'corrupted.elf'
    copy.write_bytes(bytes(bad))
    return copy


def block_control(run, args, elf, head):
    """The physical negative control: an image whose block is corrupted is
    not booted, so the boot ROM falls back to USB BOOTSEL; then the good
    image is flashed again, from BOOTSEL, which only --bootsel-attach
    allows (D712)."""
    pico2.require_leave(args)
    bad = corrupted(run, elf)
    flash(run, args, bad, head[:-4] + struct.pack('<I', IMAGE_DEF[-1] ^ 0xffffffff),
          "the corrupted image's head")
    hub = common.InGroup(run, args.hub_group)
    power_cycle(hub, args)
    device = pico2.await_bootsel(hub, args)
    return dict(corrupted_end_marker='%08x' % (IMAGE_DEF[-1] ^ 0xffffffff), enumerated=device)


def probe(run, args):
    return common.Probe(run, args.probe_rs, 'RP235x', args.probe)


def flash(run, args, elf, head, what="the image's vector table and block"):
    """Flash ELF through the architecture the cores run when the probe
    attaches, and read HEAD back from the Arm image's cores, as pico2.flash
    does: a board the Hazard3 tool left running a RISC-V image refuses
    RP235x with a FAULT, and is flashed as RP235x_riscv and power-cycled
    into this image; one in BOOTSEL is power-cycled at once (D712, D832).
    Returns the chip it flashed as."""
    return pico2.flash(run, args, elf, head, pico2.ARM_CHIP, what)


def power_cycle(run, args, at_once=False):
    """The Pico 2's port, as pico2.power_cycle switches it: a Pico 2
    running this firmware does not enumerate."""
    pico2.power_cycle(run, args, at_once)


def report(console, count):
    """Ask for a telemetry frame and return it."""
    return common.ask(console, REPORT, 't', count)


def scenario(console, run, seed, pins=None):
    """The board-port scenario and its oracle.  Returns the verdicts and
    the last telemetry frame."""
    verdicts = {}
    stream = console.wait(lambda s: any(t == 'b' for t, _ in frames_safe(s)), 5, 'the boot frame')
    boot = [f for t, f in frames_safe(stream) if t == 'b'][0]
    require(boot['r'] == CHIP_RESET_HAD_POR,
            'CHIP_RESET is %08x, not a power-on reset alone' % boot['r'])
    require(boot['v'] == VECTORS, 'VTOR is %08x: the boot ROM did not enter this image' % boot['v'])
    require(boot['k'] == CLK_REF_XOSC, 'clk_ref is not on the crystal: %08x' % boot['k'])
    verdicts['boot'] = dict(chip_reset=boot['r'], vtor=boot['v'], clk_ref_selected=boot['k'])
    seen = 0
    # The shared scenario (D593), the bytes the emulator lane's application
    # is fed, 1, A and 0: each echoed, 1 setting GPIO3 and 0 clearing it,
    # which the pad's input reads back, its isolation cleared.
    console.send(SHARED[:1])
    high = report(console, seen); seen += 1
    wire_high = pins.level('gpio-after-1') if pins else None
    console.send(SHARED[1:])
    low = report(console, seen); seen += 1
    wire_low = pins.level('gpio-after-0') if pins else None
    require(high['g'] == 8 and low['g'] == 0,
            'GPIO3 read back %x after 1 and %x after 0' % (high['g'], low['g']))
    # The probe's pin is pulled up when nothing drives it, so low after 0
    # is what shows the Pico 2's pin driving the wire.
    require(pins is None or (wire_high, wire_low) == (1, 0),
            'the wire from GPIO3 read %s after 1 and %s after 0' % (wire_high, wire_low))
    require(echo_of(console.received).startswith(SHARED[:1] + bytes([REPORT]) + SHARED[1:]),
            'the shared scenario was not echoed')
    verdicts['shared'] = dict(input=SHARED.decode(), echo=SHARED.decode(),
                              indicator_after_1=high['g'], indicator_after_0=low['g'])
    if pins:
        verdicts['shared'].update(wire=pins.pin, wire_after_1=wire_high,
                                  wire_after_0=wire_low)
    # IRQ14, set pending in the NVIC with USBCTRL held in reset: slot 30's
    # handler runs once, in exception 30.
    console.send(bytes([USBCTRL]))
    usb = report(console, seen); seen += 1
    require(usb['u'] == 1 and usb['p'] == USBCTRL_SLOT,
            'USBCTRL_IRQ ran %d times in exception %d' % (usb['u'], usb['p']))
    verdicts['irq14'] = dict(entries=usb['u'], exception=usb['p'])
    epoch = len(console.sent)
    require(epoch < RING, 'the scenario overran before its burst')
    # An overrun: the application stops reading for 100 ms after echoing
    # STALL, and a burst longer than the ring arrives meanwhile.  It is
    # discarded, never echoed, and the ring restarts.
    console.send(bytes([STALL]))
    console.wait(lambda s: STALL in echo_of(s), 2, 'the echo of STALL')
    rng = random.Random(seed)
    burst = bytes(rng.randrange(0x20, 0x7f) for _ in range(300))
    console.send(burst, pace=300)
    time.sleep(0.3)
    overrun = report(console, seen); seen += 1
    require(overrun['c'] == 1, 'the overrun made %d recoveries, not 1' % overrun['c'])
    verdicts['overrun'] = dict(burst=len(burst), recoveries=overrun['c'])
    # The restarted ring's epoch holds that REPORT.  Each epoch is now filled
    # to its 4096 bytes and no further, then the host waits: while a channel
    # is exhausted the UART's 32-byte FIFO holds what arrives, and only that.
    def fill(epoch, last=b''):
        part = bytes(rng.randrange(0x20, 0x7f) for _ in range(BUDGET - epoch - len(last)))
        console.send(part + last)
        return part
    # An epoch that ends in STALL: the channel is exhausted while the
    # application stops reading, and a 100-byte burst then overflows the
    # FIFO.  The UART flags the loss, the application restarts on it, and of
    # the burst only the 32 bytes the FIFO held reach the new epoch.
    fill(1, bytes([STALL]))
    console.wait(lambda s: echo_of(s).count(STALL) == 2, 30, 'the second echo of STALL')
    lost = bytes(rng.randrange(0x20, 0x7f) for _ in range(100))
    console.send(lost, pace=100)
    time.sleep(0.3)
    flagged = report(console, seen); seen += 1
    require(flagged['c'] == 2 and flagged['d'] == 1,
            'after a burst into an exhausted channel: %d restarts and %d completions, not 2 and 1'
            % (flagged['c'], flagged['d']))
    # An epoch that ends with nothing behind it: exhausted, restarted, and
    # the REPORT that waited in the FIFO meanwhile is the next epoch's.
    fill(32 + 1)
    after = report(console, seen); seen += 1
    require(after['c'] == 3 and after['d'] == 2,
            'after an exhausted epoch: %d restarts and %d completions, not 3 and 2'
            % (after['c'], after['d']))
    console.send(bytes(rng.randrange(0x20, 0x7f) for _ in range(3000)))
    final = report(console, seen); seen += 1
    require(final['c'] == 3 and final['d'] == 2, 'the last epoch restarted the ring')
    require(final['m'] > after['m'] > high['m'], 'the timer did not advance')
    echo = echo_of(console.wait(lambda s: True, 1, 'the stream'))
    sent = bytes(console.sent)
    discarded = [(sent.index(burst), len(burst)), (sent.index(lost) + 32, len(lost) - 32)]
    expected, at = bytearray(), 0
    for begin, length in discarded:
        expected += sent[at:begin]
        at = begin + length
    expected += sent[at:]
    expected = bytes(expected)
    require(echo == expected, 'the echo differs from what was sent, first at byte %d'
            % next((i for i, (a, b) in enumerate(zip(echo, expected)) if a != b),
                   min(len(echo), len(expected))))
    require(final['h'] == len(expected), 'handled %d bytes, not %d' % (final['h'], len(expected)))
    verdicts['epochs'] = dict(flagged_burst=len(lost), held_by_fifo=32,
                              restarts=final['c'], dma_completions=final['d'],
                              timer_events=final['m'], echoed=len(echo), sent=len(sent))
    return verdicts, final


def cross_check(run, args, names, final):
    """The counters as SWD reads them, without halting, against the frame."""
    pairs = [('handled', 'h'), ('recoveries', 'c'), ('dma_events', 'd'), ('usb_events', 'u')]
    swd = probe(run, args)
    read = {name: swd.read_words('swd-' + name, names[name], 1)[0] for name, _ in pairs}
    for name, key in pairs:
        require(read[name] == final[key], '%s reads %d over SWD, %d in the frame'
                % (name, read[name], final[key]))
    # TRANS_COUNT's MODE is bits 31:28 and its count 27:0 (12.6.10).
    count = swd.read_words('swd-trans-count', 0x50000008, 1)[0] & 0x0fffffff
    require(count == final['n'], 'TRANS_COUNT reads %d over SWD, %d in the frame' % (count, final['n']))
    return dict(read, trans_count=count)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--refine', type=Path, required=True)
    parser.add_argument('--probehive', type=Path, required=True, help='a probehive checkout')
    parser.add_argument('--probe-rs', type=Path, default=shutil.which('probe-rs'),
                        help='a probe-rs that reaches the probe named by --probe')
    parser.add_argument('--slot', type=int, default=SLOT, help='the probehive slot, 1 on the'
                        " maintainer's rig; its UART is the bridge's UART port plus the slot")
    parser.add_argument('--probe',
                        help="probe-rs's --probe for the slot: its CMSIS-DAP UDP transport,"
                             " 0000:0002:HOST/SLOT, by default, or 0000:0001:HOST:PORT for TCP"
                             " through a bridge of its own")
    parser.add_argument('--nm', default=shutil.which('arm-eabi-nm') or shutil.which('arm-none-eabi-nm'))
    parser.add_argument('--output', type=Path, required=True, help='a new directory')
    parser.add_argument('--probe-host', default='10.42.0.50')
    parser.add_argument('--debug-port', type=int, default=4441)
    parser.add_argument('--uart-port', type=int, default=4461)
    pico2.arguments(parser)
    parser.add_argument('--block-control', action='store_true',
                        help='first flash an image whose block is corrupted and require the boot ROM'
                             ' to refuse it, enumerating as BOOTSEL; then flash the good image, from'
                             ' BOOTSEL, which needs --bootsel-attach')
    parser.add_argument('--indicator-pin', metavar='PIN',
                        help="the probe's GPIO wired to the Pico 2's GPIO3; without it the"
                             " indicator is checked by its pad's readback alone")
    parser.add_argument('--probehive-build', type=Path,
                        help="the loaded bitstream's build directory, DIR/build/slots_ci by default")
    parser.add_argument('--seed', type=int, default=1230)
    parser.add_argument('--record', type=Path,
                        help="also write a passed run's record here")
    args = parser.parse_args()
    require(args.probe_rs, 'no probe-rs: name one with --probe-rs')
    require(args.nm, 'no arm-eabi-nm or arm-none-eabi-nm on PATH: name one with --nm')
    args.probe = args.probe or common.udp_slot(args.probe_host, args.slot)
    args.probehive = args.probehive.resolve()
    args.probehive_build = (args.probehive_build or args.probehive / 'build/slots_ci').resolve()
    args.output = args.output.resolve()
    args.output.mkdir(parents=True)
    args.pace = common.Pace(args.spacing, args.quiet)
    run = common.Run(args.output)
    result = dict(status='failed')
    bridge = console = lock = None
    try:
        elf, head, names = build(run, args)
        # Every step from here reaches the rig, which one run holds at a
        # time (D725).
        lock = common.rig_lock('rp2350 board.py').acquire()
        result.update(image_sha256=sha(elf), image_name=elf.name, image_block=['%08x' % w for w in IMAGE_DEF])
        if args.block_control:
            result['block_control'] = block_control(run, args, elf, head)
        result['flashed_as'] = flash(run, args, elf, head)
        result['flash_readback'] = 'matches'
        pins = (common.ProbehivePins(run, args.probehive, args.probehive_build, args.indicator_pin)
                if args.indicator_pin else None)
        bridge = common.ProbehiveBridge(run, args.probehive, args.probe_host, args.slot + 1,
                                        args.debug_port, args.uart_port)
        console = common.TcpConsole(args.uart_port + args.slot)
        power_cycle(common.InGroup(run, args.hub_group), args)
        verdicts, final = scenario(console, run, args.seed, pins)
        result['verdicts'] = verdicts
        console.close()
        bridge.close()
        bridge = None
        result['swd'] = cross_check(run, args, names, final)
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
        if bridge:
            bridge.close()
        if lock:
            lock.release()
        result['commands'] = run.commands
        common.write_json(args.output / 'result.json', result)
    if args.record and result['status'] == 'passed':
        kept = ('status', 'image_sha256', 'image_name', 'image_block', 'flash_readback', 'verdicts', 'swd',
                'uart_sha256') + (('block_control',) if args.block_control else ())
        common.write_json(args.record, common.record(
            result, kept, (args.output / 'sent.bin').read_bytes(), run.commands, ('b',)))
    print('board %s: %s%s' % (result['status'], args.output,
                              '' if result['status'] == 'passed' else ': ' + result['failure']))
    return 0 if result['status'] == 'passed' else 1


if __name__ == '__main__':
    sys.exit(main())
