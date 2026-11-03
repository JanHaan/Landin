#!/usr/bin/env python3
"""Flash the prototype-1 board port to a Raspberry Pi Pico 2's Hazard3
cores, boot it from power-on and check its trace against the physical
oracle.

    python3 environments/boards/rp2350_hazard3/board.py --refine REFINE \
        --probehive DIR --probe-rs PROBE_RS --output NEW_DIRECTORY

A developer tool, not a compiler dependency: refine builds the image for
--target=rv32 at --level=rv32imac, and this checks what the board does with
it.  The board is reached through probehive slot 1
(https://github.com/JanHaan/probehive), as the Pico 2's Arm run reaches it,
but through the probe's bridge alone, DIR/scripts/dap_bridge.py: probe-rs
reaches the slot's SWD through the bridge's TCP port and the trace comes
over its UART port, so the two share the slot's one client.  A bridge
already listening is reused and never stopped, and one this starts serves
every slot and is left running, for another board's tool to reuse.  The
Pico 2's power is its USB port on a hub uhubctl can switch.  The steps,
each recorded under NEW_DIRECTORY:

  1. build the image and check, from the ELF and the build report alone,
     that its first word at the start of flash jumps to compiler-owned
     reset, that the trap table is at the address the report gives, its
     slot 11 the meinext dispatch and slots 16, 26 and 30 the handlers, that
     the RISC-V IMAGE_DEF block the boot ROM looks for follows it inside the
     first 4 KiB as the datasheet gives it, and that the image executes an
     amoadd.w on a counter in SRAM;
  2. with --block-control, flash a copy whose block's end marker is
     flipped, cycle the power and require the boot ROM to refuse it and
     enumerate as USB BOOTSEL, 2e8a:000f;
  3. flash the image with probe-rs, as RP235x or RP235x_riscv, whichever
     architecture the cores run when it attaches, verify it, and read the
     entry word, the table and the block back;
  4. with no probe-rs attached, cut the Pico 2's power and restore it,
     after checking that the hub's guarded port holds the device named;
  5. read the boot frame and drive the scenario over the UART, comparing
     every echoed byte and every frame with what the host sent;
  6. read the counters back over SWD as RP235x_riscv, from the cores the
     image runs on, and compare them with the last frame.

The oracle is written here, from what the host sends and from the RP2350
datasheet (release 8), never from the firmware's own idea of itself; see
environments/boards/rp2350_hazard3/README.md.
"""

import argparse
import hashlib
import json
import random
import shutil
import struct
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
SOURCE = ROOT / 'compiler/tests/board/rp2350_hazard3'
# The Arm port's bringup, report and serial, which this port shares over the
# chip's modules (D831).
SHARED_SOURCE = ROOT / 'compiler/tests/board/rp2350'
sys.path.insert(0, str(HERE.parent))
import common  # noqa: E402
from common import (Failed, echo_of, elf_sections, frames_safe,  # noqa: E402,F401
                    require, sha, symbols)

# The board's command bytes, which it also echoes.
USBCTRL, REPORT, STALL = 0x05, 0x11, 0x12
BUDGET = 4096           # the application's DMA epoch
RING = 256              # its receive ring
# POWMAN's CHIP_RESET, HAD_POR alone: the last reset was the power-on
# reset (6.4, CHIP_RESET, p. 429).
CHIP_RESET_HAD_POR = 0x00010000
FLASH = 0x10000000      # the start of flash, where the boot ROM enters a RISC-V image
FIRST_4K = FLASH + 4096 # the block must lie in the first 4 KiB (5.9.5.1)
VECTOR_WORDS = 68       # 16 and the 52 IRQs of Table 95, Xh3irq's IRQ n at 16 + n
# The table: 68 words, aligned to 512, their size rounded up to a power of
# two, the first such address after the entry word (D662).
TABLE = 0x10000200
# mtvec with the table's base in vectored mode, MODE 1 (3.8.9, Table 394).
MTVEC = TABLE | 1
# Hazard3's marchid (3.8.9, MARCHID, Table 440).
MARCHID_HAZARD3 = 0x1b
CLK_REF_XOSC = 4        # CLK_REF_SELECTED's bit for source 2, the crystal
# mcause of a machine external interrupt: INTERRUPT, bit 31, and code 11
# (3.8.9, MCAUSE, Table 403), which every Xh3irq IRQ arrives as.
MCAUSE_EXTERNAL = 0x8000000b
EXTERNAL_SLOT = 11
# TIMER0_IRQ_0 IRQ0, DMA_IRQ_0 IRQ10 and USBCTRL_IRQ IRQ14 (3.2, Table 95,
# p. 81), at slot 16 + IRQ.
HANDLERS = {16: 'timer_irq', 26: 'dma_irq', 16 + 14: 'usb_irq'}
# The minimum RISC-V IMAGE_DEF (5.9.5.1, Table 503, p. 390): the start
# marker, IMAGE_TYPE 0x42 with flags 0x1101, an executable that runs on
# RISC-V on RP2350, the LAST item of one word, a link of zero to itself, and
# the end marker (5.1.5.1, Blocks, p. 329).
IMAGE_DEF = (0xffffded3, 0x11010142, 0x000001ff, 0x00000000, 0xab123579)
# A block the boot ROM refuses leaves it in BOOTSEL, whose USB identity is
# 2e8a:000f (5.6.1, Table 470, p. 370).
BOOTSEL = '2e8a:000f'
# Atomics reach SRAM alone: an AMO anywhere else is a store fault (3.8.9,
# MCAUSE, Table 403, code 7), and SRAM is 0x2000_0000 to 0x2008_2000.
SRAM = (0x20000000, 0x20082000)
# probehive's slot for the Pico 2.
SLOT = 1
# What environments/cortex-m/driver.py feeds the synthetic application.
SHARED = b'1A0'
# probe-rs's names for the chip as each architecture's cores run it (D712).
ARM_CHIP, RISCV_CHIP = 'RP235x', 'RP235x_riscv'


def jal_target(word, at):
    """Where the `jal x0` WORD at AT jumps, or None when it is not one:
    J-type, opcode 0x6f, rd zero, its offset's bits 20, 10:1, 11, 19:12."""
    if word & 0xfff != 0x06f:
        return None
    offset = (((word >> 31) & 1) << 20 | ((word >> 21) & 0x3ff) << 1
              | ((word >> 20) & 1) << 11 | ((word >> 12) & 0xff) << 12)
    if offset & (1 << 20):
        offset -= 1 << 21
    return (at + offset) & 0xffffffff


def block_of(data, sections):
    """The IMAGE_DEF block's address and its words."""
    require('.embedded_block' in sections, 'the image has no IMAGE_DEF block')
    address, offset, size = sections['.embedded_block']
    require(size == 4 * len(IMAGE_DEF), 'the block is %d bytes, not %d' % (size, 4 * len(IMAGE_DEF)))
    return address, offset, struct.unpack_from('<%dI' % len(IMAGE_DEF), data, offset)


def words_at(elf, address, count):
    return struct.unpack('<%dI' % count, common.loaded(elf, address, 4 * count))


def check_layout(elf, names, firmware):
    """The image's head as the boot ROM and the core read it, from the ELF
    and the build report's firmware section."""
    data, sections = elf_sections(elf)
    require(struct.unpack_from('<H', data, 0x12)[0] == 243, 'the image is not EM_RISCV')
    require(firmware['vector_address'] == TABLE and firmware['vector_words'] == VECTOR_WORDS,
            'the report puts %d slots at %#x, not %d at %#x'
            % (firmware['vector_words'], firmware['vector_address'], VECTOR_WORDS, TABLE))
    entry = words_at(elf, FLASH, 1)[0]
    require(jal_target(entry, FLASH) == names['_landin_firmware_reset'],
            'the word at %#x is %08x, not a jump to reset' % (FLASH, entry))
    address, _, size = sections['.isr_vector']
    require(address == TABLE and size == 4 * VECTOR_WORDS,
            'the table is %d bytes at %#x, not %d words at %#x' % (size, address, VECTOR_WORDS, TABLE))
    table = words_at(elf, TABLE, VECTOR_WORDS)
    for slot, word in enumerate(table):
        want = ('_landin_firmware_external' if slot == EXTERNAL_SLOT
                else HANDLERS.get(slot, '_landin_firmware_unhandled'))
        require(jal_target(word, TABLE + 4 * slot) == names[want],
                'slot %d does not jump to %s' % (slot, want))
    block, _, found = block_of(data, sections)
    require(block == TABLE + 4 * VECTOR_WORDS,
            'the block is at %#x, not directly after the table' % block)
    require(block + 4 * len(IMAGE_DEF) <= FIRST_4K, 'the block ends past the first 4 KiB')
    require(firmware['image_block']['address'] == block, 'the report puts the block elsewhere')
    require(found == IMAGE_DEF, 'the block is %s, not the minimum RISC-V IMAGE_DEF'
            % ' '.join('%08x' % w for w in found))
    require(SRAM[0] <= names['reports'] < SRAM[1], 'the AMO counter is not in SRAM')
    return block


def amo_adds(listing):
    """Each amoadd.w of an objdump listing, as (address, function)."""
    found, function = [], None
    for line in listing.splitlines():
        if line.endswith('>:'):
            function = line[line.index('<') + 1:-2]
        fields = line.split('\t')
        if len(fields) >= 3 and fields[2].startswith('amoadd.w'):
            found.append(('%08x' % int(fields[0].strip().rstrip(':'), 16), function))
    return found


def build(run, args):
    elf = run.out / 'board.elf'
    run.command('compile', [args.refine, '--root=' + str(ROOT / 'devices'),
        '--root=' + str(ROOT / 'devices/generated'), '--root=' + str(ROOT / 'compiler/tests/driver'),
        '--root=' + str(SOURCE), '--root=' + str(SHARED_SOURCE), '--target=rv32', '--level=rv32imac',
        '--firmware-entry=start', '--emit=exe',
        '--build-report=' + str(run.out / 'build.json'), str(SOURCE / 'app'), '-o', str(elf)])
    firmware = json.loads((run.out / 'build.json').read_text())['firmware']
    names = symbols(run, args.nm, elf)
    block = check_layout(elf, names, firmware)
    adds = amo_adds(run.command('disassembly', [args.objdump, '-d', elf]))
    require(adds, 'the image executes no amoadd.w')
    head = common.loaded(elf, FLASH, block + 4 * len(IMAGE_DEF) - FLASH)
    return elf, head, names, adds


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
    image is flashed again.  Flashing it again means attaching in BOOTSEL,
    which halts the boot ROM mid-enumeration (D712), so the control runs
    only with --bootsel-attach, on a hub that does not carry the probe."""
    require(args.bootsel_attach, '--block-control ends in BOOTSEL, where flashing the image again'
            ' halts the boot ROM on the bus; it needs --bootsel-attach, on a hub without the probe')
    bad = corrupted(run, elf)
    chip = flash(run, args, bad, head[:-4] + struct.pack('<I', IMAGE_DEF[-1] ^ 0xffffffff),
                 "the corrupted image's head")
    hub = common.InGroup(run, args.hub_group)
    power_cycle(hub, args)
    deadline = time.time() + args.enumerate_seconds
    device = None
    while time.time() < deadline:
        # The cycle re-enumerates the hub's inner hubs, and a listing can
        # meet their new device nodes before udev has given them the group
        # that may read them: such a listing fails, and the next is asked.
        device = common.port_device(hub.command('hub-after-corrupt', ['uhubctl', '-l', args.hub],
                                                check=False), args.port)
        if device and device.startswith(BOOTSEL):
            break
        time.sleep(0.5)
    require(device and device.startswith(BOOTSEL),
            'with its block corrupted the board did not enumerate as BOOTSEL %s; port %d shows %s'
            % (BOOTSEL, args.port, device))
    require(not args.pico_serial or args.pico_serial in device,
            'BOOTSEL enumerated as %s, not with serial %s' % (device, args.pico_serial))
    return dict(corrupted_end_marker='%08x' % (IMAGE_DEF[-1] ^ 0xffffffff), flashed_as=chip,
                enumerated=device)


def attached(run, args, name):
    """probe-rs for the Pico 2 as the architecture its cores run now: the
    boot ROM runs on Arm in BOOTSEL and after probe-rs has flashed as
    RP235x, and there RP235x_riscv's debug module times out; a RISC-V image
    gates the Arm cores' access ports, and RP235x meets a FAULT (D712).
    RP235x is tried first, since its refusal is the quick one.  Neither is
    tried while the chip is in BOOTSEL."""
    refuse_bootsel(common.InGroup(run, args.hub_group), args)
    for chip in ARM_CHIP, RISCV_CHIP:
        attempt = common.Probe(run, args.probe_rs, chip, args.probe)
        run.command('%s-%s' % (name, chip), attempt.argv('read', 'b32', hex(FLASH), '1'),
                    timeout=60, check=False)
        if run.commands[-1]['status'] == 0:
            return attempt
    raise Failed('neither %s nor %s reaches the Pico 2; see %s-*.log' % (ARM_CHIP, RISCV_CHIP, name))


def running(run, args):
    """probe-rs for the RISC-V image the Pico 2 booted, never another chip:
    what it reads is read from the cores the image runs on."""
    return common.Probe(run, args.probe_rs, RISCV_CHIP, args.probe)


def flash(run, args, elf, head, what="the image's entry word, table and block"):
    """Flash ELF and verify it through the architecture the cores run when
    the probe attaches, and read HEAD back; returns the chip it flashed as.

    Flashed through the Arm side, the chip was in BOOTSEL, enumerated on
    USB, and probe-rs leaves its cores halted, so its USB stops answering:
    the host then retries the port for minutes, and on the rig reset the
    hub chain the probe's own USB hangs from, while every probe-rs start
    waited 85 s listing USB probes.  So the power is cycled at once, the
    boot ROM enters what was flashed, and the head is read back from the
    image's cores."""
    probe = attached(run, args, 'attach')
    flashed_as = probe.chip
    paced(args, 'download', lambda: run.command('flash', probe.argv('download', '--verify', elf),
                                                timeout=300))
    if flashed_as == ARM_CHIP:
        power_cycle(common.InGroup(run, args.hub_group), args)
        time.sleep(args.boot_seconds)
        probe = attached(run, args, 'reattach')
    count = len(head) // 4
    back = struct.pack('<%dI' % count, *probe.read_words('flash-readback', FLASH, count))
    require(back == head, 'flash does not hold %s' % what)
    return flashed_as


class Listings:
    """HUB's commands, a listing of a hub asked again while it fails until
    SECONDS have passed: any port switched on the rig's hubs, by this tool
    or another, re-enumerates the whole tree, and a listing that meets it
    gone, or its nodes before udev has regrouped them, fails."""
    def __init__(self, hub, seconds):
        self.hub, self.seconds = hub, seconds

    def command(self, name, argv, **kw):
        if '-a' in argv:
            return self.hub.command(name, argv, **kw)
        deadline = time.time() + self.seconds
        while True:
            try:
                return self.hub.command(name, argv, **kw)
            except Failed:
                if time.time() >= deadline:
                    raise
                time.sleep(0.5)


def paced(args, what, action):
    """ACTION, which may disconnect a device on the rig's hub cascade,
    spaced by args.pace from every other such action on the host."""
    args.pace.before(what)
    try:
        return action()
    finally:
        args.pace.after(what)


def power_cycle(run, args):
    """The Pico 2's port, never the guarded one, only on a hub whose
    guarded port holds the device named, and, with --pico-serial, only
    while the port holds that Pico 2 or no USB device at all: a Pico 2
    running this firmware does not enumerate.  The cycle is paced with
    every other tool's actions on the rig, and waits until the kernel has
    logged nothing of USB for a while, stopping on any trouble it logged
    since the last action (D725), since a cycle met by a port failing
    enumeration reset the whole hub tree above it on the rig (D712); and
    after the cycle the guarded port must show its device again and the
    probe answer on the network, or the run stops."""
    common.off_cascade(args.guard_serial, args.cascade)
    paced(args, 'power cycle', lambda: common.power_cycle(
        Listings(run, args.guard_seconds), args.hub, args.port, args.off_seconds,
        holds_if_any=args.pico_serial))
    deadline = time.time() + args.guard_seconds
    while True:
        try:
            common.off_cascade(args.guard_serial, args.cascade)
            break
        except Failed as error:
            require(time.time() < deadline, 'after the cycle: %s; stopping' % error)
        time.sleep(0.5)
    answer = run.command('probe-ping', ['ping', '-c', '1', '-W', '2', args.probe_host], check=False)
    require(' 0% packet loss' in answer,
            'after the cycle the probe at %s does not answer ping; stopping' % args.probe_host)


def refuse_bootsel(run, args):
    """Refuse to go on while the Pico 2 enumerates as BOOTSEL: a probe-rs
    attach there halts the boot ROM, whose USB then stops answering (D712)."""
    device = common.port_device(Listings(run, args.guard_seconds).command(
        'hub-before-attach', ['uhubctl', '-l', args.hub]), args.port)
    require(args.bootsel_attach or not (device and device.startswith(BOOTSEL)),
            'the Pico 2 enumerates as BOOTSEL %s; no probe attaches to it there. Cycle port %d'
            ' once and wait for it to stop enumerating' % (device, args.port))


def report(console, count):
    """Ask for a telemetry frame and return it."""
    return common.ask(console, REPORT, 't', count)


def scenario(console, run, seed, pins=None):
    """The board-port scenario and its oracle.  Returns the verdicts, the
    last telemetry frame and how many there were."""
    verdicts = {}
    stream = console.wait(lambda s: any(t == 'b' for t, _ in frames_safe(s)), 5, 'the boot frame')
    boot = [f for t, f in frames_safe(stream) if t == 'b'][0]
    require(boot['r'] == CHIP_RESET_HAD_POR,
            'CHIP_RESET is %08x, not a power-on reset alone' % boot['r'])
    require(boot['a'] == MARCHID_HAZARD3, 'marchid is %08x: this is not Hazard3' % boot['a'])
    require(boot['v'] == MTVEC, 'mtvec is %08x, not the table in vectored mode' % boot['v'])
    require(boot['k'] == CLK_REF_XOSC, 'clk_ref is not on the crystal: %08x' % boot['k'])
    verdicts['boot'] = dict(chip_reset=boot['r'], marchid=boot['a'], mtvec=boot['v'],
                            clk_ref_selected=boot['k'])
    seen = 0

    def numbered(frame):
        # Each frame's q is what amoadd.w returned: the frames sent before.
        require(frame['q'] == seen, 'telemetry frame %d carries amoadd.w result %d'
                % (seen, frame['q']))
        return frame
    # The shared scenario (D593), the bytes the emulator lane's application
    # is fed, 1, A and 0: each echoed, 1 setting GPIO3 and 0 clearing it,
    # which the pad's input reads back, its isolation cleared.
    console.send(SHARED[:1])
    high = numbered(report(console, seen)); seen += 1
    wire_high = pins.level('gpio-after-1') if pins else None
    console.send(SHARED[1:])
    low = numbered(report(console, seen)); seen += 1
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
    # IRQ14, forced pending through meifa with USBCTRL held in reset: the
    # core takes a machine external interrupt, and meinext's dispatch calls
    # slot 30's handler once.
    console.send(bytes([USBCTRL]))
    usb = numbered(report(console, seen)); seen += 1
    require(usb['u'] == 1 and usb['p'] == MCAUSE_EXTERNAL,
            'USBCTRL_IRQ ran %d times, mcause %08x' % (usb['u'], usb['p']))
    verdicts['irq14'] = dict(entries=usb['u'], mcause=usb['p'])
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
    overrun = numbered(report(console, seen)); seen += 1
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
    flagged = numbered(report(console, seen)); seen += 1
    require(flagged['c'] == 2 and flagged['d'] == 1,
            'after a burst into an exhausted channel: %d restarts and %d completions, not 2 and 1'
            % (flagged['c'], flagged['d']))
    # An epoch that ends with nothing behind it: exhausted, restarted, and
    # the REPORT that waited in the FIFO meanwhile is the next epoch's.
    fill(32 + 1)
    after = numbered(report(console, seen)); seen += 1
    require(after['c'] == 3 and after['d'] == 2,
            'after an exhausted epoch: %d restarts and %d completions, not 3 and 2'
            % (after['c'], after['d']))
    console.send(bytes(rng.randrange(0x20, 0x7f) for _ in range(3000)))
    final = numbered(report(console, seen)); seen += 1
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
    verdicts['amoadd'] = dict(frames=seen, results=list(range(seen)))
    return verdicts, final, seen


def cross_check(run, args, names, final, reports):
    """The counters as SWD reads them once the scenario has ended, against the frame,
    and the AMO counter against the frames the host received."""
    pairs = [('handled', 'h'), ('recoveries', 'c'), ('dma_events', 'd'), ('usb_events', 'u')]
    swd = running(run, args)
    read = {name: swd.read_words('swd-' + name, names[name], 1)[0] for name, _ in pairs}
    for name, key in pairs:
        require(read[name] == final[key], '%s reads %d over SWD, %d in the frame'
                % (name, read[name], final[key]))
    read['reports'] = swd.read_words('swd-reports', names['reports'], 1)[0]
    require(read['reports'] == reports, 'the AMO counter reads %d over SWD, not the %d frames'
            % (read['reports'], reports))
    # TRANS_COUNT's MODE is bits 31:28 and its count 27:0 (12.6.10).
    count = swd.read_words('swd-trans-count', 0x50000008, 1)[0] & 0x0fffffff
    require(count == final['n'], 'TRANS_COUNT reads %d over SWD, %d in the frame' % (count, final['n']))
    return dict(read, trans_count=count)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--refine', type=Path, required=True)
    parser.add_argument('--probehive', type=Path, required=True, help='a probehive checkout')
    parser.add_argument('--probe-rs', type=Path, default=shutil.which('probe-rs'),
                        help='a probe-rs whose CMSIS-DAP TCP transport reaches the bridge')
    parser.add_argument('--slot', type=int, default=SLOT, help='the probehive slot, 1 on the'
                        " maintainer's rig")
    parser.add_argument('--nm', default=shutil.which('riscv64-elf-nm')
                        or shutil.which('riscv64-unknown-elf-nm'))
    parser.add_argument('--objdump', default=shutil.which('riscv64-elf-objdump')
                        or shutil.which('riscv64-unknown-elf-objdump'))
    parser.add_argument('--output', type=Path, required=True, help='a new directory')
    parser.add_argument('--probe-host', default='10.42.0.50')
    parser.add_argument('--debug-port', type=int, default=4441,
                        help="the bridge's slot 0 SWD port; slot N's is this plus N")
    parser.add_argument('--uart-port', type=int, default=4461,
                        help="the bridge's slot 0 UART port; slot N's is this plus N")
    parser.add_argument('--bridge-slots', type=int, default=6,
                        help='the slots a bridge this starts serves, every one of the probe')
    parser.add_argument('--hub', default='7-2.3.3', help="the Pico 2's hub, as uhubctl -l names it")
    parser.add_argument('--port', type=int, default=2, help="the Pico 2's port on it")
    parser.add_argument('--pico-serial', help="the Pico 2's USB serial, which its port must show"
                        " whenever it shows a device; this firmware does not enumerate")
    parser.add_argument('--cascade', default='7-2',
                        help='the hub cascade whose ports are switched, as sysfs names its root')
    parser.add_argument('--guard-serial', default='210319B3E738',
                        help="a device that must be present and off the switched cascade, the"
                             " probe's Arty on the maintainer's rig, or no port is switched")
    parser.add_argument('--off-seconds', type=float, default=1.0)
    parser.add_argument('--block-control', action='store_true',
                        help='first flash an image whose block is corrupted and require the boot ROM'
                             ' to refuse it, enumerating as BOOTSEL; then flash the good image')
    parser.add_argument('--boot-seconds', type=float, default=1.0,
                        help='how long the boot ROM is given after a power cycle before the probe'
                             ' attaches')
    parser.add_argument('--bootsel-attach', action='store_true',
                        help='let the probe attach to a Pico 2 in BOOTSEL, as --block-control needs;'
                             ' only for a Pico 2 on a hub that does not carry the probe')
    parser.add_argument('--guard-seconds', type=float, default=15.0,
                        help="how long the guarded port may take to show its device after a cycle")
    parser.add_argument('--spacing', type=float, default=120,
                        help='the least time between two actions that may disconnect a USB device'
                             ' on the rig, by any tool')
    parser.add_argument('--quiet', type=float, default=60,
                        help='how long the kernel must have logged nothing of USB before one')
    parser.add_argument('--enumerate-seconds', type=float, default=10.0,
                        help='how long BOOTSEL may take to enumerate after the power cycle')
    parser.add_argument('--hub-group', default='dialout',
                        help="the group that may switch the hub's ports; uhubctl runs through"
                             " sg when the session is not in it")
    parser.add_argument('--indicator-pin', metavar='PIN',
                        help="the probe's GPIO wired to the Pico 2's GPIO3; without it the"
                             " indicator is checked by its pad's readback alone")
    parser.add_argument('--probehive-build', type=Path,
                        help="the loaded bitstream's build directory, DIR/build/slots_ci by default")
    parser.add_argument('--seed', type=int, default=1240)
    parser.add_argument('--record', type=Path,
                        help="also write a passed run's record here")
    args = parser.parse_args()
    require(args.probe_rs, 'no probe-rs: name one with --probe-rs')
    require(args.nm and args.objdump, 'no riscv64-elf-nm and -objdump or riscv64-unknown-elf-nm and'
            ' -objdump on PATH: name them with --nm and --objdump')
    args.probe = common.bridged(args.debug_port + args.slot)
    args.probehive = args.probehive.resolve()
    args.probehive_build = (args.probehive_build or args.probehive / 'build/slots_ci').resolve()
    args.output = args.output.resolve()
    args.output.mkdir(parents=True)
    args.pace = common.Pace(args.spacing, args.quiet)
    run = common.Run(args.output)
    result = dict(status='failed')
    bridge = console = lock = None
    try:
        elf, head, names, adds = build(run, args)
        # Every step from here reaches the rig, which one run holds at a time.
        lock = common.rig_lock('rp2350_hazard3 board.py').acquire()
        result.update(image_sha256=sha(elf), image_name=elf.name,
                      image_block=['%08x' % w for w in IMAGE_DEF],
                      amoadd=[dict(address=a, function=f) for a, f in adds])
        bridge, result['bridge'] = common.shared_bridge(
            run, args.probehive, args.probe_host, args.slot, args.bridge_slots,
            args.debug_port, args.uart_port)
        if args.block_control:
            result['block_control'] = block_control(run, args, elf, head)
        result['flashed_as'] = flash(run, args, elf, head)
        result['flash_readback'] = 'matches'
        pins = (common.ProbehivePins(run, args.probehive, args.probehive_build, args.indicator_pin)
                if args.indicator_pin else None)
        console = common.TcpConsole(args.uart_port + args.slot)
        power_cycle(common.InGroup(run, args.hub_group), args)
        verdicts, final, reports = scenario(console, run, args.seed, pins)
        result['verdicts'] = verdicts
        result['swd'] = cross_check(run, args, names, final, reports)
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
            # Detached: left running for the next tool.
            bridge.close()
        if lock:
            lock.release()
        result['commands'] = run.commands
        common.write_json(args.output / 'result.json', result)
    if args.record and result['status'] == 'passed':
        kept = ('status', 'image_sha256', 'image_name', 'image_block', 'amoadd', 'flashed_as', 'flash_readback',
                'verdicts', 'swd', 'uart_sha256') + (('block_control',) if args.block_control else ())
        common.write_json(args.record, common.record(
            result, kept, (args.output / 'sent.bin').read_bytes(), run.commands, ('b',)))
    print('board %s: %s%s' % (result['status'], args.output,
                              '' if result['status'] == 'passed' else ': ' + result['failure']))
    return 0 if result['status'] == 'passed' else 1


if __name__ == '__main__':
    sys.exit(main())
