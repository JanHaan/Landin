#!/usr/bin/env python3
"""Flash the prototype-1 board port to a Raspberry Pi Pico, boot it from
power-on and check its trace against the physical oracle.

    python3 environments/boards/rp2040/board.py --refine REFINE \
        --probehive DIR --probe-rs PROBE_RS --output NEW_DIRECTORY

A developer tool, not a compiler dependency: refine builds the image, and
this checks what the board does with it.  The board is reached through a
probehive slot (https://github.com/JanHaan/probehive): probe-rs reaches
its SWD through `--probe`, and the probe's bridge, DIR/scripts/dap_bridge.py,
serves its UART as a TCP port while the scenario runs; the two never hold
the slot at once.  The Pico's power is its USB port on
a hub uhubctl can switch.  The steps, each recorded under NEW_DIRECTORY:

  1. build the image and check, from the ELF alone, that its second stage
     carries the CRC-32 the boot ROM checks and that vector word 21 is the
     USBCTRL_IRQ handler;
  2. flash it with probe-rs, verify it, and read the first 256 bytes of
     flash back to compare with the image, once the hub lists again;
  3. with the probe detached, cut the Pico's power and restore it, after
     checking that the probe's Arty, whose bitstream lives in SRAM, is off
     the cascade, the cycle paced with every other tool's actions on the
     rig, and wait for the hub to list again;
  4. read the boot frame and drive the scenario over the UART, comparing
     every echoed byte and every frame with what the host sent;
  5. read the counters back over SWD and compare them with the last frame.

The oracle is written here, from what the host sends and from the RP2040
datasheet, never from the firmware's own idea of itself; see
environments/boards/rp2040/README.md.
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
SOURCE = ROOT / 'compiler/tests/board/rp2040'
sys.path.insert(0, str(HERE.parent))
import common  # noqa: E402
from common import (Failed, echo_of, elf_sections, frames, frames_safe,  # noqa: E402,F401
                    require, sha, symbols)

# The board's command bytes, which it also echoes.
IRQ5, REPORT, STALL = 0x05, 0x11, 0x12
BUDGET = 4096           # the application's DMA epoch
RING = 256              # its receive ring
CHIP_RESET_HAD_POR = 0x100
VECTORS = 0x10000100    # the second stage points VTOR past itself
CLK_REF_XOSC = 4        # CLK_REF_SELECTED's bit for source 2, the crystal
USBCTRL_SLOT = 21
# What environments/cortex-m/driver.py feeds the synthetic application.
SHARED = b'1A0'


def crc32_mpeg2(data):
    """The boot ROM's CRC-32: poly 0x04C11DB7, initial 0xFFFFFFFF, no
    reflection and no final XOR (RP2040 datasheet, 2.8.1.3.1)."""
    crc = 0xFFFFFFFF
    for byte in data:
        crc ^= byte << 24
        for _ in range(8):
            crc = ((crc << 1) ^ 0x04C11DB7 if crc & 0x80000000 else crc << 1) & 0xFFFFFFFF
    return crc


def build(run, args):
    elf = run.out / 'board.elf'
    run.command('compile', [args.refine, '--root=' + str(ROOT / 'devices'),
        '--root=' + str(ROOT / 'devices/generated'), '--root=' + str(ROOT / 'compiler/tests/driver'),
        '--root=' + str(SOURCE), '--target=cortex-m0', '--firmware-entry=start', '--emit=exe',
        '--build-report=' + str(run.out / 'build.json'), str(SOURCE / 'app'), '-o', str(elf)])
    data, sections = elf_sections(elf)
    address, offset, size = sections['.boot2']
    require(address == 0x10000000 and size == 256, '.boot2 is not 256 bytes at 0x10000000')
    stage = data[offset:offset + 256]
    crc = crc32_mpeg2(stage[:252])
    require(struct.unpack_from('<I', stage, 252)[0] == crc,
            'the second stage does not carry its CRC-32 %08x' % crc)
    require(any(stage[:252]), 'the second stage is empty')
    address, offset, size = sections['.isr_vector']
    require(address == VECTORS, 'the vector table is not at 0x10000100')
    words = struct.unpack_from('<%dI' % (size // 4), data, offset)
    names = symbols(run, args.nm, elf)
    require(words[USBCTRL_SLOT] == names['usb_irq'] | 1, 'vector word 21 is not the USBCTRL_IRQ handler')
    return elf, stage, crc, names


def probe(run, args):
    return common.Probe(run, args.probe_rs, 'RP2040', args.probe)


def flash(run, args, elf, stage):
    """Flash and verify the image, paced with every other tool's actions on
    the rig, then, once the hub lists again, read the second stage back: a
    download resets the chip, and on the rig the whole cascade above the
    Pico once disconnected within a second of one, although the Pico
    enumerates nothing (D725, D832)."""
    swd = probe(run, args)
    common.paced(args.pace, 'download', lambda: run.command(
        'flash', swd.argv('download', '--verify', elf), timeout=300),
        args.guard_serial, args.cascade)
    common.wait_for_hub(common.InGroup(run, args.hub_group), args.hub, [], args.hub_seconds)
    back = swd.read_bytes('flash-readback', 0x10000000, len(stage))
    require(back == stage, "flash does not hold the image's second stage")
    return back


def power_cycle(run, args):
    """The Pico's port, only while the probe's Arty is off the cascade,
    paced with every other tool's actions on the rig, and then the hub
    listing again (D725).  The first listing is asked again while it fails:
    one that resumes a hub the kernel suspended re-enumerates the cascade
    under it."""
    common.paced(args.pace, 'power cycle', lambda: common.power_cycle(
        common.Listings(run, args.hub_seconds), args.hub, args.port, args.off_seconds),
        args.guard_serial, args.cascade)
    common.wait_for_hub(run, args.hub, [], args.hub_seconds)


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
    require(boot['v'] == VECTORS, 'VTOR is %08x: the second stage did not run' % boot['v'])
    require(boot['k'] == CLK_REF_XOSC, 'clk_ref is not on the crystal: %08x' % boot['k'])
    verdicts['boot'] = dict(chip_reset=boot['r'], vtor=boot['v'], clk_ref_selected=boot['k'])
    seen = 0
    # The shared scenario (D593), the bytes the emulator lane's application
    # is fed, 1, A and 0: each echoed, 1 setting GPIO3 and 0 clearing it,
    # which the pad's input reads back.
    console.send(SHARED[:1])
    high = report(console, seen); seen += 1
    wire_high = pins.level('gpio-after-1') if pins else None
    console.send(SHARED[1:])
    low = report(console, seen); seen += 1
    wire_low = pins.level('gpio-after-0') if pins else None
    require(high['g'] == 8 and low['g'] == 0,
            'GPIO3 read back %x after 1 and %x after 0' % (high['g'], low['g']))
    # The probe's pin is pulled up when nothing drives it, so low after 0
    # is what shows the Pico's pin driving the wire.
    require(pins is None or (wire_high, wire_low) == (1, 0),
            'the wire from GPIO3 read %s after 1 and %s after 0' % (wire_high, wire_low))
    require(echo_of(console.received).startswith(SHARED[:1] + bytes([REPORT]) + SHARED[1:]),
            'the shared scenario was not echoed')
    verdicts['shared'] = dict(input=SHARED.decode(), echo=SHARED.decode(),
                              indicator_after_1=high['g'], indicator_after_0=low['g'])
    if pins:
        verdicts['shared'].update(wire=pins.pin, wire_after_1=wire_high,
                                  wire_after_0=wire_low)
    # IRQ5, set pending in the NVIC: slot 21's handler runs once, in
    # exception 21.
    console.send(bytes([IRQ5]))
    usb = report(console, seen); seen += 1
    require(usb['u'] == 1 and usb['p'] == USBCTRL_SLOT,
            'USBCTRL_IRQ ran %d times in exception %d' % (usb['u'], usb['p']))
    verdicts['irq5'] = dict(entries=usb['u'], exception=usb['p'])
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
    count = swd.read_words('swd-trans-count', 0x50000008, 1)[0]
    require(count == final['n'], 'TRANS_COUNT reads %d over SWD, %d in the frame' % (count, final['n']))
    return dict(read, trans_count=count)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--refine', type=Path, required=True)
    parser.add_argument('--probehive', type=Path, required=True, help='a probehive checkout')
    parser.add_argument('--probe-rs', type=Path, default=shutil.which('probe-rs'),
                        help='a probe-rs that reaches the probe named by --probe')
    parser.add_argument('--probe', default='0000:0002:10.42.0.50/0',
                        help="probe-rs's --probe for the slot: its CMSIS-DAP UDP transport by default,"
                             " or 0000:0001:HOST:PORT for TCP through a bridge of its own")
    parser.add_argument('--nm', default=shutil.which('arm-eabi-nm') or shutil.which('arm-none-eabi-nm'))
    parser.add_argument('--output', type=Path, required=True, help='a new directory')
    parser.add_argument('--probe-host', default='10.42.0.50')
    parser.add_argument('--debug-port', type=int, default=4441)
    parser.add_argument('--uart-port', type=int, default=4461)
    parser.add_argument('--hub', default='7-2.3.3', help="the Pico's hub, as uhubctl -l names it")
    parser.add_argument('--port', type=int, default=1, help="the Pico's port on it")
    parser.add_argument('--guard-serial', default='210319B3E738',
                        help="a device that must be present and off the switched cascade, the"
                             " probe's Arty on the maintainer's rig, or no port is switched")
    parser.add_argument('--cascade', default='7-2',
                        help='the hub cascade whose ports are switched, as sysfs names its root')
    parser.add_argument('--off-seconds', type=float, default=1.0)
    parser.add_argument('--hub-seconds', type=float, default=60.0,
                        help='how long the hub may take to list again after a download or a cycle')
    common.pace_arguments(parser)
    parser.add_argument('--hub-group', default='dialout',
                        help="the group that may switch the hub's ports; uhubctl runs through"
                             " sg when the session is not in it")
    parser.add_argument('--indicator-pin', metavar='PIN',
                        help="the probe's GPIO wired to the Pico's GPIO3, IO32 on the maintainer's"
                             " rig; without it the indicator is checked by its pad's readback alone")
    parser.add_argument('--probehive-build', type=Path,
                        help="the loaded bitstream's build directory, DIR/build/slots_ci by default")
    parser.add_argument('--seed', type=int, default=1220)
    parser.add_argument('--record', type=Path,
                        help="also write a passed run's record here, as record.json is")
    args = parser.parse_args()
    require(args.probe_rs, 'no probe-rs: name one with --probe-rs')
    require(args.nm, 'no arm-eabi-nm or arm-none-eabi-nm on PATH: name one with --nm')
    args.probehive = args.probehive.resolve()
    args.probehive_build = (args.probehive_build or args.probehive / 'build/slots_ci').resolve()
    args.output = args.output.resolve()
    args.output.mkdir(parents=True)
    args.pace = common.Pace(args.spacing, args.quiet)
    run = common.Run(args.output)
    result = dict(status='failed')
    bridge = console = None
    # The run holds the rig's lock (D725).
    lock = common.rig_lock('rp2040 board.py').acquire()
    try:
        elf, stage, crc, names = build(run, args)
        result.update(image_sha256=sha(elf), image_name=elf.name, second_stage_crc32='%08x' % crc,
                      second_stage_sha256=hashlib.sha256(stage).hexdigest())
        flash(run, args, elf, stage)
        result['flash_readback'] = 'matches'
        pins = (common.ProbehivePins(run, args.probehive, args.probehive_build, args.indicator_pin)
                if args.indicator_pin else None)
        bridge = common.ProbehiveBridge(run, args.probehive, args.probe_host, 1,
                                        args.debug_port, args.uart_port)
        console = common.TcpConsole(args.uart_port)
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
        lock.release()
        result['commands'] = run.commands
        common.write_json(args.output / 'result.json', result)
    if args.record and result['status'] == 'passed':
        kept = ('status', 'image_sha256', 'image_name', 'second_stage_crc32', 'second_stage_sha256',
                'flash_readback', 'verdicts', 'swd', 'uart_sha256')
        common.write_json(args.record, common.record(
            result, kept, (args.output / 'sent.bin').read_bytes(), run.commands, ('b',)))
    print('board %s: %s%s' % (result['status'], args.output,
                              '' if result['status'] == 'passed' else ': ' + result['failure']))
    return 0 if result['status'] == 'passed' else 1


if __name__ == '__main__':
    sys.exit(main())
