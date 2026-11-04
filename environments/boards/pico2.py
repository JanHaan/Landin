#!/usr/bin/env python3
"""What the Raspberry Pi Pico 2's two board tools share (D832).

The Arm tool, rp2350/board.py, and the Hazard3 tool, rp2350_hazard3/board.py,
run the same board on the same hub port, through the same boot ROM, so
each reaches the hub and the bus the same way:

  * the Pico 2's port is switched only while the probe's Arty is present
    and off the cascade, each switch and download is paced with every
    other tool's on the host, stopping at USB trouble the kernel logged
    since the last (D725), and after each the tool waits for the hub to
    list again, for the Arty to be found again and for the probe to answer
    `ping`;
  * a listing that meets the hub re-enumerating is asked again;
  * probe-rs is told the chip as the architecture its cores run when it
    attaches, and an image flashed through the other one's side is booted
    by a power cycle before its head is read back (D712);
  * no probe attaches while the port shows BOOTSEL, including when the
    obsolete --bootsel-attach flag is supplied; install and verify the
    fixed image by UF2 off the cascade before attaching;
  * RAM-only BOOTSEL checks read the selected hub and port through Linux
    USB sysfs, requiring a valid hub even when the resident is USB-silent;
  * every download as RP235x is followed at once by a power cycle, before
    any wait or attach: probe-rs's RP235x reset leaves the boot ROM's USB
    on the bus with its core halted (D832);
  * malformed-block controls are disabled pending an off-cascade UF2
    recovery workflow.

Each tool's args carry `hub`, `port`, `pico_serial`, `guard_serial`,
`cascade`, `off_seconds`, `guard_seconds`, `enumerate_seconds`,
`probe_host`, `bootsel_attach`, `hub_group` and `pace`, a common.Pace;
`arguments` adds the options that give them.
"""

import re
import stat
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
USB_SYSFS = Path('/sys/bus/usb/devices')


Listings = common.Listings


def paced(args, what, action):
    """ACTION, which may disconnect a device on the rig's hub cascade,
    paced by args.pace with every other such action on the host, and only
    while the Arty is off the cascade."""
    return common.paced(args.pace, what, action, args.guard_serial, args.cascade)


def settle(run, args):
    """Wait for the Pico 2's hub to list again after a download or a
    switch (D725)."""
    return common.wait_for_hub(run, args.hub, [], args.guard_seconds)


def power_cycle(run, args, at_once=False):
    """The Pico 2's port, never another, only while the Arty is off the
    cascade, and, with --pico-serial, only while the port holds that Pico 2
    or no USB device at all: a Pico 2 running its port's firmware does not
    enumerate.  The cycle is paced with every other tool's actions on the
    rig, stopping on any USB trouble the kernel logged since the last action
    (D725), since a cycle met by a port failing enumeration reset the whole
    hub tree above it on the rig (D712).  AT_ONCE takes the cycle without
    that check, after a download as RP235x has halted the boot ROM; it
    is still recorded as the last action.  After the cycle the hub
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


def ram_port_device(hub, port, sysfs=None):
    """Read only the selected Linux USB port, without opening a USB device.

    A resident image may leave the port USB-silent. Only an absent child
    of a readable, validated hub counts as that case; missing or unreadable
    identity attributes must never be mistaken for an absent device.
    SYSFS is injectable for controls, and otherwise uses Linux's USB bus.
    """
    require(isinstance(hub, str) and re.fullmatch(
        r'[1-9][0-9]*-(?:0|[1-9][0-9]*(?:\.[1-9][0-9]*)*)', hub),
        'RAM BOOTSEL guard needs a concrete USB hub path, such as 1-1: %r' % hub)
    require(type(port) is int and port > 0,
            'RAM BOOTSEL guard needs a positive physical USB port: %r' % port)
    sysfs = Path(sysfs) if sysfs is not None else USB_SYSFS
    # uhubctl calls a root hub N-0; Linux calls its directory usbN.
    root = hub.endswith('-0')
    parent = sysfs / ('usb' + hub.split('-')[0] if root else hub)
    child = sysfs / (hub.split('-')[0] + '-' + str(port) if root else hub + '.' + str(port))

    def attribute(device, name, pattern):
        path = device / name
        try:
            value = path.read_text(encoding='ascii').strip()
        except (OSError, UnicodeError) as error:
            raise Failed('RAM BOOTSEL guard cannot read %s: %s' % (path, error)) from error
        require(re.fullmatch(pattern, value),
                'RAM BOOTSEL guard found malformed %s: %r' % (path, value))
        return value.lower()

    def identity(device):
        return ':'.join(attribute(device, name, r'[0-9a-fA-F]{4}')
                        for name in ('idVendor', 'idProduct'))

    def validate_hub():
        try:
            require(stat.S_ISDIR(parent.stat().st_mode),
                    'RAM BOOTSEL guard USB hub is not a directory: %s' % parent)
        except OSError as error:
            raise Failed('RAM BOOTSEL guard cannot inspect USB hub %s: %s'
                         % (parent, error)) from error
        identity(parent)
        require(attribute(parent, 'bDeviceClass', r'[0-9a-fA-F]{2}') == '09',
                'RAM BOOTSEL guard selected USB device %s is not a hub' % parent)
        ports = int(attribute(parent, 'maxchild', r'[0-9]{1,3}'))
        require(1 <= ports <= 255,
                'RAM BOOTSEL guard found invalid physical port count %d at %s' % (ports, parent))
        require(port <= ports,
                'RAM BOOTSEL guard port %d is outside USB hub %s physical ports 1..%d'
                % (port, hub, ports))

    validate_hub()
    try:
        child.lstat()
    except FileNotFoundError:
        # Recheck the parent: its disappearance is not a silent resident.
        validate_hub()
        return None
    except OSError as error:
        raise Failed('RAM BOOTSEL guard cannot inspect USB child %s: %s'
                     % (child, error)) from error
    return identity(child)


def refuse_bootsel(run, args, allowed=None):
    """Never attach to BOOTSEL; install a valid fixed image by UF2 off
    the cascade first. ALLOWED is retained for callers but cannot bypass
    this guard."""
    ram = getattr(args, 'mode', 'boot') == 'ram'
    device = ram_port_device(args.hub, args.port) if ram else bootsel(run, args)
    device = device if device and device.startswith(BOOTSEL) else None
    recovery = ('Install a fixed image by UF2 off the cascade before a RAM run' if ram else
                'Cycle port %d only off the cascade after installing a fixed image by UF2' % args.port)
    require(not device,
            'the Pico 2 enumerates as BOOTSEL %s; no probe attaches to it there. %s'
            % (device, recovery))
    return device


def boot_location(args):
    require(args.mode != 'boot' or not (args.hub == args.cascade
            or args.hub.startswith(args.cascade + '.')),
            'Pico 2 boot checks must be off the cascade; install its fixed image by UF2 there first')


def attached(run, args, name, bootsel_allowed=None):
    """probe-rs for the Pico 2 as the architecture its cores run now: the
    boot ROM runs on Arm in BOOTSEL and after probe-rs has flashed as
    RP235x, and there RP235x_riscv's debug module times out; a RISC-V image
    gates the Arm cores' access ports, and RP235x meets a FAULT (D712).
    RP235x is tried first, since its refusal is the quick one. Neither is
    tried while the chip is in BOOTSEL; BOOTSEL_ALLOWED cannot bypass this
    guard. A valid fixed image must first be installed by UF2 off the cascade."""
    from_bootsel = refuse_bootsel(common.InGroup(run, args.hub_group), args, bootsel_allowed)
    for chip in ARM_CHIP, RISCV_CHIP:
        attempt = common.Probe(run, args.probe_rs, chip, args.probe,
                               ram_loader=getattr(args, 'ram_loader', None))
        command = '%s-%s' % (name, chip)
        try:
            attempt.read_words(command, FLASH, 1)
        except Failed:
            # Only an unsuccessful attach command permits the other
            # architecture. USB guard and evidence failures stop here.
            if (not run.commands or run.commands[-1]['name'] != command
                    or run.commands[-1]['status'] == 0):
                raise
        else:
            attempt.from_bootsel = bool(from_bootsel)
            return attempt
    raise Failed('neither %s nor %s reaches the Pico 2; see %s-*.log' % (ARM_CHIP, RISCV_CHIP, name))


def download(run, args, elf):
    """Attach as the architecture the cores run, flash ELF and verify it;
    returns the probe it flashed through and whether the power has been
    cycled since.

    A download as RP235x is followed at once by the cycle, unpaced but
    recorded, before any listing waits for the hub and before any probe
    attaches or reads.  probe-rs's RP235x system reset, which the download
    makes to load its flash algorithm, reboots the chip into BOOTSEL for
    30 ms so that the boot ROM raises its clocks, then resets it again
    with the reset caught: the boot ROM's USB device is left connected
    while its core is halted, and fails every request the host makes of
    it.  On 2026-11-03 such a download put BOOTSEL on the bus within half
    a second of its start; the kernel's retries hung the host's xHCI
    controller 82 s later.  The cycle ends that device the moment the hub
    lets it switch, which the kernel's enumeration may hold it from for a
    while (D832)."""
    probe = attached(run, args, 'attach')
    paced(args, 'download', lambda: run.command('flash', probe.argv('download', '--verify', elf),
                                                timeout=300))
    if probe.chip != ARM_CHIP:
        return probe, False
    power_cycle(common.InGroup(run, args.hub_group), args, at_once=True)
    return probe, True


def read_head(probe, head, what):
    count = len(head) // 4
    back = struct.pack('<%dI' % count, *probe.read_words('flash-readback', FLASH, count))
    require(back == head, 'flash does not hold %s' % what)


def flash(run, args, elf, head, image_chip, what):
    """Flash ELF and verify it through the architecture the cores run when
    the probe attaches, and read HEAD back from the start of flash; returns
    the chip it flashed as.  IMAGE_CHIP is the architecture the image runs
    on, as probe-rs names it.

    The image is booted by a power cycle before the head is read back from
    its own cores whenever it was flashed as RP235x, which is cycled at
    once, `download`, or through the other architecture's side, as an Arm
    image over a RISC-V one still running, which is cycled paced.  The head
    is never read back while the port shows BOOTSEL (D712, D832)."""
    hub = common.InGroup(run, args.hub_group)
    probe, cycled = download(run, args, elf)
    flashed_as = probe.chip
    if not cycled and flashed_as != image_chip:
        power_cycle(hub, args)
        cycled = True
    if cycled:
        time.sleep(args.boot_seconds)
        probe = attached(run, args, 'reattach', bootsel_allowed=False)
    else:
        settle(hub, args)
    read_head(probe, head, what)
    return flashed_as


def corrupt(run, args, elf, head, what):
    """The block control's flash of ELF, whose block the boot ROM refuses,
    and the board brought to BOOTSEL by its power alone: the image is
    never booted for a probe to read.  Flashed as RP235x the power is
    cycled at once, `download`, and nothing reads the chip again; flashed
    as RP235x_riscv the halted hart, which enumerates nothing, is read back
    before a paced cycle.  Returns the chip it flashed as and what the port
    shows once the boot ROM enumerates as BOOTSEL; no probe attaches while
    it does."""
    require_leave(args)
    hub = common.InGroup(run, args.hub_group)
    probe, cycled = download(run, args, elf)
    if not cycled:
        settle(hub, args)
        read_head(probe, head, what)
        power_cycle(hub, args)
    return probe.chip, await_bootsel(hub, args)


def require_leave(args):
    """Refuse legacy malformed-block controls before any hardware action."""
    raise Failed('--block-control is disabled pending an off-cascade UF2 recovery workflow;'
                 ' BOOTSEL attachment is always refused, including with --bootsel-attach')


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
                        help='obsolete compatibility flag; BOOTSEL attachment is always refused')
    parser.add_argument('--hub-group', default='dialout',
                        help="the group that may switch the hub's ports; uhubctl runs through"
                             " sg when the session is not in it")
    common.pace_arguments(parser)
