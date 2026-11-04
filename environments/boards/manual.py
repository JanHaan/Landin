#!/usr/bin/env python3
"""Pico-only physical steps for an explicit manual-UF2 boot check.

The board process owns the rig lock and a private control socket. This CLI
only reports state or acknowledges the exact outstanding human step; it
never takes that lock, clears USB trouble, resumes a run or touches hardware.
"""
import argparse
import json
import math
import os
from pathlib import Path
import re
import secrets
import socket
import stat
import struct
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
import common
import pico2
import uf2

# Run file I/O in a timed, unprivileged child, including its flush. No shell
# or general root Python is involved. Exclusive creation refuses stale files.
COPY_PROGRAM = '''import os, pathlib, sys
data = pathlib.Path(sys.argv[1]).read_bytes()
fd = os.open(sys.argv[2], os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
with os.fdopen(fd, 'wb') as stream:
    if stream.write(data) != len(data):
        raise OSError('short UF2 write')
    stream.flush()
    os.fsync(stream.fileno())
print(len(data))
'''


def selected(args):
    return getattr(args, 'boot_transport', 'auto') == 'manual-uf2'


def interrupted(boot, result, where):
    """Cancel from either the main try block or restoration's finally block."""
    boot.stopped = True
    reason = 'manual %s interrupted; no automatic restoration' % where
    result['status'] = 'failed'
    result['failure'] = (result.get('failure', '') + '; ' + reason).lstrip('; ')
    result['fixed_restore'] = dict(status='pending', reason=reason)


def preflight(args):
    """No USB access, mount or prompt before arguments are coherent."""
    common.require(args.mode == 'boot', '--boot-transport=manual-uf2 requires --mode=boot')
    common.require(re.fullmatch(r'[1-9][0-9]*-[0-9]+', args.hub or ''),
                   'manual UF2 needs a concrete direct hub, for example --hub=1-1')
    common.require(type(args.port) is int and args.port > 0, 'manual UF2 needs a positive port')
    common.require(args.pico_serial and re.fullmatch(r'[A-Za-z0-9_-]+', args.pico_serial),
                   'manual UF2 needs the known --pico-serial')
    common.require(args.guard_serial and args.guard_serial != args.pico_serial,
                   'manual UF2 needs a distinct Arty --guard-serial')
    for name in ('manual_timeout', 'off_seconds', 'enumerate_seconds', 'boot_seconds'):
        value = getattr(args, name)
        common.require(math.isfinite(value) and value > 0, '%s must be finite and positive' % name)
    common.require(not args.bootsel_attach and not args.block_control,
                   'manual UF2 never attaches to BOOTSEL or runs corrupt-image controls')


def usb_node(args):
    return (args.hub.split('-')[0] + '-' + str(args.port)
            if args.hub.endswith('-0') else args.hub + '.' + str(args.port))


class Guard:
    def __init__(self, args, sysfs=None):
        self.args = args
        self.sysfs = Path(sysfs) if sysfs is not None else pico2.USB_SYSFS
        self.node = usb_node(args)

    def check(self, expect=None):
        """Read sysfs only: cascade absent, Arty present, correct Pico port."""
        self.args.pace.check('manual UF2 guard')
        arty = []
        for entry in self.sysfs.iterdir():
            if not re.fullmatch(r'(?:usb[1-9][0-9]*|[1-9][0-9]*-[1-9][0-9]*(?:\.[1-9][0-9]*)*)', entry.name):
                continue
            try:
                attributes = [(entry / name).read_text(encoding='ascii').strip()
                              for name in ('idVendor', 'idProduct')]
            except (OSError, UnicodeError) as error:
                # The selected Pico may disappear normally between listing
                # and reading it. Its validated parent is checked below.
                if isinstance(error, FileNotFoundError) and entry.name == self.node and not entry.exists():
                    continue
                raise common.Failed('cannot establish USB identity at %s: %s' % (entry, error)) from error
            common.require(all(re.fullmatch('[0-9a-fA-F]{4}', value) for value in attributes),
                           'malformed USB identity at %s' % entry)
            identity = ':'.join(attributes).lower()
            common.require(identity != common.CASCADE_HUB,
                           'manual UF2 requires the entire Realtek cascade unplugged')
            try:
                if (entry / 'serial').read_text().strip() == self.args.guard_serial:
                    arty.append(entry.name)
            except FileNotFoundError:
                pass
        common.require(len(arty) == 1 and arty[0] != self.node,
                       'manual UF2 requires exactly one Arty with --guard-serial, away from Pico')
        identity = pico2.ram_port_device(self.args.hub, self.args.port, self.sysfs)
        if identity is not None:
            common.require(identity == pico2.BOOTSEL,
                           'unexpected USB device at Pico port %s: %s' % (self.node, identity))
            serial = (self.sysfs / self.node / 'serial').read_text().strip()
            common.require(serial == self.args.pico_serial,
                           'BOOTSEL serial at %s is %r, expected %r'
                           % (self.node, serial, self.args.pico_serial))
        if expect == 'bootsel':
            common.require(identity == pico2.BOOTSEL, 'the selected Pico is not in BOOTSEL')
        elif expect == 'silent':
            common.require(identity is None, 'BOOTSEL is still present; no probe may attach')
        return identity


def mounts(path=Path('/proc/self/mountinfo')):
    def unescape(value):
        return re.sub(r'\\([0-7]{3})', lambda match: chr(int(match[1], 8)), value)
    rows = []
    for line in Path(path).read_text().splitlines():
        fields = line.split()
        common.require(len(fields) >= 10 and '-' in fields, 'cannot parse mountinfo')
        rows.append((fields[2], unescape(fields[4])))
    return rows


class Volume:
    """Bind one VFAT filesystem to the exact selected USB device."""
    def __init__(self, run, guard, block_root=Path('/sys/class/block'), dev_root=Path('/dev'), role='uf2'):
        self.run, self.guard = run, guard
        self.block_root, self.dev_root = Path(block_root), Path(dev_root)
        self.prefix = 'manual-' + role + '-'

    def discover(self):
        self.guard.check('bootsel')
        usb = (self.guard.sysfs / self.guard.node).resolve(strict=True)
        listing = json.loads(self.run.command(self.prefix + 'lsblk',
            ['lsblk', '--json', '--paths', '--output', 'NAME,KNAME,MAJ:MIN,FSTYPE,TYPE,MOUNTPOINTS']))
        found = []
        def visit(rows):
            for row in rows:
                path = Path(row['name'])
                sys = self.block_root / Path(row['kname']).name
                if sys.resolve(strict=True).is_relative_to(usb) and row.get('fstype') == 'vfat':
                    common.require(not any(row.get('mountpoints') or []),
                                   'Pico BOOTSEL volume is already mounted; unmount it before the run')
                    common.require(path == self.dev_root / path.name,
                                   'lsblk returned an unexpected device path')
                    found.append(dict(device=str(path), major_minor=row['maj:min'],
                                      sysfs=str(sys.resolve()), usb=str(usb), serial=self.guard.args.pico_serial))
                visit(row.get('children') or [])
        visit(listing['blockdevices'])
        common.require(len(found) == 1, 'expected exactly one unmounted Pico BOOTSEL VFAT volume')
        result = found[0]
        self.verify(result)
        common.require(not any(dev == result['major_minor'] for dev, _ in mounts()),
                       'Pico BOOTSEL volume is already mounted')
        return result

    def verify(self, identity, mountpoint=None):
        self.guard.check('bootsel')
        sys = self.block_root / Path(identity['device']).name
        common.require(str(sys.resolve(strict=True)) == identity['sysfs']
                       and sys.resolve().is_relative_to(Path(identity['usb']))
                       and str((self.guard.sysfs / self.guard.node).resolve(strict=True)) == identity['usb']
                       and (sys / 'dev').read_text().strip() == identity['major_minor'],
                       'BOOTSEL block device identity changed')
        device = Path(identity['device']).stat()
        common.require(stat.S_ISBLK(device.st_mode)
                       and '%d:%d' % (os.major(device.st_rdev), os.minor(device.st_rdev)) == identity['major_minor'],
                       'BOOTSEL device node does not match sysfs major/minor')
        if mountpoint is not None:
            common.require([(dev, at) for dev, at in mounts() if at == str(mountpoint)]
                           == [(identity['major_minor'], str(mountpoint))],
                           'private BOOTSEL mount does not match the selected block device')

    def copy(self, image, directory, before_write):
        identity = self.discover()
        mountpoint = directory / 'mount'
        mountpoint.mkdir(mode=0o700)
        mounted = False
        original = None
        try:
            self.verify(identity)
            self.run.command(self.prefix + 'mount', ['sudo', '-n', 'mount', '-t', 'vfat', '-o',
                'rw,sync,nodev,nosuid,noexec,uid=%d,gid=%d,umask=077' % (os.getuid(), os.getgid()),
                identity['device'], mountpoint])
            mounted = True
            self.verify(identity, mountpoint)
            before_write(identity)
            started = time.monotonic()
            target = mountpoint / 'LANDIN.UF2'
            size = Path(image).stat().st_size
            copied = self.run.command(self.prefix + 'copy', [sys.executable, '-c', COPY_PROGRAM, image, target],
                                      timeout=120)
            common.require(copied.strip() == str(size), 'UF2 copy did not report the complete byte count')
            identity.update(bytes=size, copy_seconds=round(time.monotonic() - started, 3))
        except BaseException as error:
            original = error
        # Even error cleanup is hardware work. Never unmount after a USB stop.
        if mounted:
            try:
                self.guard.check()
                self.run.command(self.prefix + 'unmount', ['sudo', '-n', 'umount', mountpoint])
            except BaseException as error:
                if original is not None:
                    raise common.Failed('%s; unmount pending: %s' % (original, error)) from error
                raise
        if original is not None:
            raise original
        return identity


class Boot:
    """One non-resumable run; constructed offline, started under RigLock."""
    def __init__(self, run, args, board, elf):
        self.run, self.args, self.board = run, args, board
        preflight(args)
        self.architecture = 'arm' if board == 'rp2350' else 'hazard3'
        self.directory = run.out / 'manual'
        self.directory.mkdir(mode=0o700)
        self.guard = Guard(args)
        self.server = None
        self.stopped = False
        self.counter = 0
        self.state = dict(run=secrets.token_hex(16), status='prepared', transport='manual-uf2',
                          board=board, usb_node=usb_node(args), pico_serial=args.pico_serial,
                          resident_may_have_changed=False, events=[])
        self.images = {}
        for role, source in (('application', elf), ('fixed', args.fixed_image)):
            data = uf2.convert(source, self.architecture)
            if getattr(args, 'bundle', None):
                import bundle
                try:
                    prepared = bundle.validate(args.bundle, board=board, mode='boot')
                    bundled = bundle.artifact(prepared, 'uf2' if role == 'application' else 'fixed_uf2')
                except bundle.Invalid as error:
                    raise common.Failed('manual UF2 bundle: ' + str(error)) from error
                common.require(bundled.read_bytes() == data, '%s UF2 does not match its ELF' % role)
            target = self.directory / (role + '.uf2')
            target.write_bytes(data)
            self.images[role] = (Path(source), target)
        self.save()

    def save(self):
        temporary = self.directory / 'state.tmp'
        temporary.write_text(json.dumps(self.state, indent=2) + '\n')
        os.replace(temporary, self.directory / 'state.json')

    def event(self, kind, **values):
        event = dict(event=kind, time=time.time(), **values)
        self.state['events'].append(event)
        with (self.directory / 'events.jsonl').open('a') as stream:
            stream.write(json.dumps(event) + '\n')
        self.save()

    def start(self):
        self.guard.check()
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(str(self.directory / 'control.sock'))
        os.chmod(self.directory / 'control.sock', 0o600)
        self.server.listen(4)
        self.server.settimeout(0.25)
        self.state['status'] = 'running'
        self.event('started')

    def check(self):
        common.require(not self.stopped, 'manual interaction stopped; resident restoration remains pending')
        common.require(self.server is not None, 'manual run did not start; resident restoration remains pending')
        self.guard.check()

    def request(self, phase, instruction):
        self.check()
        self.args.pace.before(phase)
        self.counter += 1
        pending = dict(phase='%d-%s' % (self.counter, phase), token=secrets.token_hex(16),
                       instruction=instruction, deadline=time.time() + self.args.manual_timeout)
        self.state['pending'] = pending
        self.event('requested', **pending)
        helper = Path(__file__).resolve()
        print('MANUAL ' + json.dumps(dict(run=self.state['run'], output=str(self.run.out),
            helper=str(helper), **pending)), flush=True)
        deadline = time.monotonic() + self.args.manual_timeout
        self.server.settimeout(min(0.25, self.args.manual_timeout))
        try:
            while time.monotonic() < deadline:
                self.check()
                self.server.settimeout(min(0.25, max(0.001, deadline - time.monotonic())))
                try:
                    connection, _ = self.server.accept()
                except socket.timeout:
                    continue
                with connection:
                    try:
                        raw = bytearray()
                        while b'\n' not in raw and len(raw) < 4096:
                            self.check()
                            remaining = deadline - time.monotonic()
                            common.require(remaining > 0,
                                           'timed out waiting for manual step ' + pending['phase'])
                            connection.settimeout(min(0.25, remaining))
                            try:
                                piece = connection.recv(4096 - len(raw))
                            except socket.timeout:
                                continue
                            if not piece:
                                break
                            raw.extend(piece)
                        common.require(time.monotonic() < deadline,
                                       'timed out waiting for manual step ' + pending['phase'])
                        if b'\n' not in raw:
                            raise ValueError('unterminated acknowledgment')
                        message = json.loads(raw)
                        valid = (isinstance(message, dict) and message.get('run') == self.state['run']
                                 and message.get('phase') == pending['phase']
                                 and message.get('token') == pending['token']
                                 and message.get('action') in ('ack', 'cancel'))
                        self.check()
                        common.require(time.monotonic() < deadline,
                                       'timed out waiting for manual step ' + pending['phase'])
                        connection.sendall(json.dumps(dict(accepted=valid)).encode())
                        if not valid:
                            self.event('rejected', phase=pending['phase'])
                            continue
                        if message['action'] == 'cancel':
                            raise common.Failed('operator cancelled ' + pending['phase'])
                        self.args.pace.after(phase)
                        self.state.pop('pending')
                        self.event('acknowledged', phase=pending['phase'])
                        return
                    except (ValueError, socket.timeout):
                        self.event('rejected', phase=pending['phase'])
            raise common.Failed('timed out waiting for manual step ' + pending['phase'])
        except BaseException:
            self.stopped = True
            self.state['status'] = 'stopped'
            self.state.pop('pending', None)
            self.event('stopped', phase=pending['phase'])
            raise

    def wait(self, seconds, predicate=None):
        """Bounded physical settling; also watches kernel trouble."""
        deadline = time.monotonic() + seconds
        while True:
            self.check()
            if predicate is not None and predicate():
                return
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                common.require(predicate is None, 'BOOTSEL did not disappear after UF2 copy')
                return
            # Socket timeout provides an interruptible wait without a sleep/log loop.
            self.server.settimeout(min(0.25, remaining))
            try:
                connection, _ = self.server.accept()
            except socket.timeout:
                continue
            with connection:
                connection.sendall(b'{"accepted": false}')

    def install(self, role):
        self.check()
        self.request(role + '-bootsel', 'Unplug only Pico 2; reconnect holding BOOTSEL, then acknowledge.')
        self.guard.check('bootsel')
        directory = self.directory / role
        directory.mkdir()
        def before_write(identity):
            self.state['resident_may_have_changed'] = True
            self.event('write-started', role=role, identity=dict(identity))
        identity = common.paced(self.args.pace, role + ' UF2 copy', lambda:
            Volume(self.run, self.guard, role=role).copy(self.images[role][1], directory, before_write))
        self.event('installed', role=role, identity=identity)
        self.wait(self.args.enumerate_seconds, lambda: self.guard.check() is None)
        self.wait(self.args.boot_seconds)

    def cold_cycle(self, role, console=None):
        self.request(role + '-unplug', 'Unplug only Pico 2 USB power, then acknowledge. Leave it unplugged.')
        began = time.monotonic()
        self.wait(self.args.off_seconds)
        off_wait = time.monotonic() - began
        if console is not None:
            with console.lock:
                discarded = bytes(console.received)
                console.received.clear()
            (self.directory / (role + '-pre-cold-uart.bin')).write_bytes(discarded)
        self.request(role + '-replug', 'Reconnect only Pico 2 WITHOUT holding BOOTSEL, then acknowledge.')
        self.guard.check('silent')
        self.event('cold-cycle', role=role, off_wait_seconds=round(off_wait, 3),
                   attestation_interval_seconds=round(time.monotonic() - began, 3),
                   evidence='operator unplug/replug attestations; application POR oracle remains required')
        self.wait(self.args.boot_seconds)

    def readback(self, role):
        self.check()
        self.guard.check('silent')
        elf = self.images[role][0]
        chip = pico2.ARM_CHIP if self.architecture == 'arm' else pico2.RISCV_CHIP
        probe = common.Probe(self.run, self.args.probe_rs, chip, self.args.probe,
                             ram_loader=self.args.ram_loader)
        total = 0
        for index, (address, data, _) in enumerate(common.elf_segments(elf)):
            common.require(address % 4 == 0 and len(data) > 0, 'unaligned UF2 readback segment')
            self.guard.check('silent')
            count = (len(data) + 3) // 4
            words = probe.read_words('manual-%s-readback-%d' % (role, index), address, count)
            actual = struct.pack('<%dI' % count, *words)[:len(data)]
            common.require(actual == data, 'manual %s flash bytes differ from ELF' % role)
            total += len(data)
        self.event('readback', role=role, bytes=total, elf_sha256=common.sha(elf))
        return probe

    def restore(self):
        self.check()
        common.require(self.state['resident_may_have_changed'],
                       'no UF2 write started; resident left unchanged and restoration not attempted')
        self.install('fixed')
        self.cold_cycle('fixed')
        probe = self.readback('fixed')
        marker = common.read_fixed_marker(probe, self.images['fixed'][0])
        self.event('resident-ready', marker=marker)
        return marker

    def close(self, result):
        self.state['status'] = result['status']
        self.state.pop('pending', None)
        self.event('finished', status=result['status'])
        if self.server:
            self.server.close()
            (self.directory / 'control.sock').unlink(missing_ok=True)
        result['manual_boot'] = self.state


def control(output, action, run=None, phase=None, token=None):
    directory = Path(output).resolve() / 'manual'
    state = json.loads((directory / 'state.json').read_text())
    if action == 'status':
        return state
    common.require(state['status'] == 'running' and state.get('pending'),
                   'there is no active manual request; a stopped run cannot be resumed')
    message = dict(action=action, run=run, phase=phase, token=token)
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(5)
        client.connect(str(directory / 'control.sock'))
        client.sendall(json.dumps(message).encode() + b'\n')
        reply = json.loads(client.recv(4096))
    common.require(reply.get('accepted') is True, 'acknowledgment does not match the outstanding request')
    return reply


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('status', 'ack', 'cancel'))
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--run')
    parser.add_argument('--phase')
    parser.add_argument('--token')
    args = parser.parse_args(argv)
    try:
        print(json.dumps(control(args.output, args.action, args.run, args.phase, args.token), indent=2))
    except (common.Failed, OSError, ValueError) as error:
        parser.error(str(error))


if __name__ == '__main__':
    main()
