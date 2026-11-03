#!/usr/bin/env python3
"""What the Raspberry Pi Pico 2's two board tools share (D832).

The Arm tool, rp2350/board.py, and the Hazard3 tool, rp2350_hazard3/board.py,
run the same board on the same hub port, through the same boot ROM, so
each reaches the hub and the bus the same way:

  * the Pico 2's port is switched only while the probe's Arty is present
    and off the cascade, each switch and download is paced with every
    other tool's on the host (D725), and after each the tool waits for the
    hub to list again, for the Arty to be found again and for the probe to
    answer `ping`;
  * a listing that meets the cascade re-enumerating is asked again;
  * probe-rs is told the chip as the architecture its cores run when it
    attaches, and an image flashed through the other one's side is booted
    by a power cycle before its head is read back (D712);
  * no probe-rs attaches while the port shows BOOTSEL unless the run was
    told it may, since an attach halts the boot ROM, whose USB then stops
    answering; and when one has flashed from BOOTSEL the power is cycled
    at once, unpaced, rather than leaving the halted BOOTSEL on the bus for
    the pace's two minutes (D712);
  * a block control's power cycle must end in BOOTSEL.

Each tool's args carry `hub`, `port`, `pico_serial`, `guard_serial`,
`cascade`, `off_seconds`, `guard_seconds`, `enumerate_seconds`,
`probe_host`, `bootsel_attach`, `hub_group` and `pace`, a common.Pace;
`arguments` adds the options that give them.
"""

import struct
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import common  # noqa: E402
from common import Failed, require  # noqa: E402

# A block the boot ROM refuses leaves it in BOOTSEL, whose USB identity is
# 2e8a:000f (RP2350 datasheet, 5.6.1, Table 470, p. 370).
BOOTSEL = '2e8a:000f'
# The start of flash, where the boot ROM enters an image of either kind.
FLASH = 0x10000000
# probe-rs's names for the chip as each architecture's cores run it (D712).
ARM_CHIP, RISCV_CHIP = 'RP235x', 'RP235x_riscv'


Listings = common.Listings


def paced(args, what, action):
    """ACTION, which may disconnect a device on the rig's hub cascade,
    spaced by args.pace from every other such action on the host, and only
    while the Arty is off the cascade."""
    return common.paced(args.pace, what, action, args.guard_serial, args.cascade)


def settle(run, args):
    """Wait for the Pico 2's hub to list again after a download or a
    switch, which re-enumerates the cascade (D725)."""
    return common.wait_for_hub(run, args.hub, [], args.guard_seconds)


def power_cycle(run, args, at_once=False):
    """The Pico 2's port, never another, only while the Arty is off the
    cascade, and, with --pico-serial, only while the port holds that Pico 2
    or no USB device at all: a Pico 2 running its port's firmware does not
    enumerate.  The cycle is paced with every other tool's actions on the
    rig, and waits until the kernel has logged nothing of USB for a while,
    stopping on any trouble it logged since the last action (D725), since a
    cycle met by a port failing enumeration reset the whole hub tree above
    it on the rig (D712).  AT_ONCE takes the cycle without waiting, after a
    flash from BOOTSEL, whose halted boot ROM is the trouble; it is still
    recorded, so the next action waits for it.  After the cycle the hub
    must list again, the Arty be found off the cascade and the probe answer
    on the network, or the run stops."""
    def cycle():
        return common.power_cycle(Listings(run, args.guard_seconds), args.hub, args.port,
                                  args.off_seconds, holds_if_any=args.pico_serial)
    if at_once:
        common.off_cascade(args.guard_serial, args.cascade)
        try:
            cycle()
        finally:
            args.pace.after('power cycle at once')
    else:
        paced(args, 'power cycle', cycle)
    settle(run, args)
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


def bootsel(run, args, name='hub-before-attach'):
    """What the Pico 2's port shows when it is BOOTSEL, or None."""
    device = common.port_device(Listings(run, args.guard_seconds).command(
        name, ['uhubctl', '-l', args.hub]), args.port)
    return device if device and device.startswith(BOOTSEL) else None


def refuse_bootsel(run, args, allowed=None):
    """Refuse to go on while the Pico 2 enumerates as BOOTSEL, unless
    ALLOWED, by default --bootsel-attach: a probe-rs attach there halts the
    boot ROM, whose USB then stops answering (D712).  Returns what the port
    shows when it is BOOTSEL, or None."""
    device = bootsel(run, args)
    allowed = args.bootsel_attach if allowed is None else allowed
    require(allowed or not device,
            'the Pico 2 enumerates as BOOTSEL %s; no probe attaches to it there. Cycle port %d'
            ' once and wait for it to stop enumerating' % (device, args.port))
    return device


def attached(run, args, name, bootsel_allowed=None):
    """probe-rs for the Pico 2 as the architecture its cores run now: the
    boot ROM runs on Arm in BOOTSEL and after probe-rs has flashed as
    RP235x, and there RP235x_riscv's debug module times out; a RISC-V image
    gates the Arm cores' access ports, and RP235x meets a FAULT (D712).
    RP235x is tried first, since its refusal is the quick one.  Neither is
    tried while the chip is in BOOTSEL, unless BOOTSEL_ALLOWED, by default
    --bootsel-attach; the probe returned says in `from_bootsel` whether it
    was."""
    from_bootsel = refuse_bootsel(common.InGroup(run, args.hub_group), args, bootsel_allowed)
    for chip in ARM_CHIP, RISCV_CHIP:
        attempt = common.Probe(run, args.probe_rs, chip, args.probe)
        run.command('%s-%s' % (name, chip), attempt.argv('read', 'b32', hex(FLASH), '1'),
                    timeout=60, check=False)
        if run.commands[-1]['status'] == 0:
            attempt.from_bootsel = bool(from_bootsel)
            return attempt
    raise Failed('neither %s nor %s reaches the Pico 2; see %s-*.log' % (ARM_CHIP, RISCV_CHIP, name))


def flash(run, args, elf, head, image_chip, what):
    """Flash ELF and verify it through the architecture the cores run when
    the probe attaches, and read HEAD back from the start of flash; returns
    the chip it flashed as.  IMAGE_CHIP is the architecture the image runs
    on, as probe-rs names it.

    Flashed through the other architecture's side, as an Arm image is over
    a RISC-V one still running, or a Hazard3 image from BOOTSEL or over an
    Arm one, the image is booted by a power cycle before the head is read
    back from its own cores.  When the chip was in BOOTSEL it was enumerated
    on USB, and halted its USB stops answering: the host then retries the
    port for minutes, and on the rig reset the hub chain the probe's own USB
    hangs from.  So that cycle is taken at once rather than paced, and the
    head is never read back from BOOTSEL (D712, D832)."""
    hub = common.InGroup(run, args.hub_group)
    probe = attached(run, args, 'attach')
    flashed_as = probe.chip
    paced(args, 'download', lambda: run.command('flash', probe.argv('download', '--verify', elf),
                                                timeout=300))
    if probe.from_bootsel or flashed_as != image_chip:
        power_cycle(hub, args, at_once=probe.from_bootsel)
        time.sleep(args.boot_seconds)
        probe = attached(run, args, 'reattach', bootsel_allowed=False)
    else:
        settle(hub, args)
    count = len(head) // 4
    back = struct.pack('<%dI' % count, *probe.read_words('flash-readback', FLASH, count))
    require(back == head, 'flash does not hold %s' % what)
    return flashed_as


def require_leave(args):
    """The block control ends in BOOTSEL, where flashing the image again
    halts the boot ROM on the bus: it runs only with --bootsel-attach."""
    require(args.bootsel_attach, '--block-control ends in BOOTSEL, where flashing the image again'
            ' halts the boot ROM on the bus; it needs --bootsel-attach, on a hub without the probe')


def await_bootsel(run, args):
    """After the block control's cycle, what the port shows once the boot
    ROM, refusing the image, enumerates as BOOTSEL."""
    deadline = time.time() + args.enumerate_seconds
    device = None
    while time.time() < deadline:
        # common.listing retries a listing refused while udev regroups the
        # re-enumerated hubs' nodes, as every poll after a cycle may be.
        device = common.port_device(
            common.listing(run, args.hub, max(1.0, deadline - time.time()),
                           name='hub-after-corrupt'), args.port)
        if device and device.startswith(BOOTSEL):
            break
        time.sleep(0.5)
    require(device and device.startswith(BOOTSEL),
            'with its block corrupted the board did not enumerate as BOOTSEL %s; port %d shows %s'
            % (BOOTSEL, args.port, device))
    require(not args.pico_serial or args.pico_serial in device,
            'BOOTSEL enumerated as %s, not with serial %s' % (device, args.pico_serial))
    return device


def arguments(parser):
    """The options both tools take for the hub, the guard and the pace."""
    parser.add_argument('--hub', default='.3.3',
                        help="the Pico 2's hub, as uhubctl -l names it or relative to the cascade")
    parser.add_argument('--port', type=int, default=2, help="the Pico 2's port on it")
    parser.add_argument('--pico-serial', help="the Pico 2's USB serial, which its port must show"
                        " whenever it shows a device; its port's firmware does not enumerate")
    parser.add_argument('--guard-serial', default='210319B3E738',
                        help="a device that must be present and off the switched cascade, the"
                             " probe's Arty on the maintainer's rig, or no port is switched")
    common.cascade_argument(parser)
    parser.add_argument('--off-seconds', type=float, default=1.0)
    parser.add_argument('--guard-seconds', type=float, default=15.0,
                        help='how long the hub may take to list again, and the guarded device to'
                             ' be found again, after a download or a cycle')
    parser.add_argument('--enumerate-seconds', type=float, default=10.0,
                        help='how long BOOTSEL may take to enumerate after the power cycle')
    parser.add_argument('--boot-seconds', type=float, default=1.0,
                        help='how long the boot ROM is given after a power cycle before the probe'
                             ' attaches')
    parser.add_argument('--bootsel-attach', action='store_true',
                        help='let the probe attach to a Pico 2 in BOOTSEL, as --block-control needs;'
                             ' only for a Pico 2 on a hub that does not carry the probe')
    parser.add_argument('--hub-group', default='dialout',
                        help="the group that may switch the hub's ports; uhubctl runs through"
                             " sg when the session is not in it")
    common.pace_arguments(parser)
