#!/usr/bin/env python3
"""Manual UF2 controls with synthetic sysfs, sockets and filesystem writes.

No USB, probe, privileged command, SSH or physical rig is accessed.
"""
import concurrent.futures
import contextlib
import importlib.util
import json
import os
from pathlib import Path
import queue
import socket
import stat
import subprocess
import sys
import tempfile
import threading
from types import SimpleNamespace
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'environments/boards'))
import common
import manual


class ManualCase(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.args = SimpleNamespace(mode='boot', hub='1-1', port=2, pico_serial='PICO',
            guard_serial='ARTY', manual_timeout=1, off_seconds=0.02, enumerate_seconds=0.02,
            boot_seconds=0.01, bootsel_attach=False, block_control=False, bundle=None,
            probe_rs='probe-rs', probe='probe', ram_loader='loader',
            fixed_image=self.root / 'fixed.elf',
            pace=common.Pace(state=self.root / 'pace', kernel=lambda _: []))
        self.args.fixed_image.write_bytes(b'fixed ELF')
        self.elf = self.root / 'app.elf'
        self.elf.write_bytes(b'application ELF')
        self.run = common.Run(self.root)

    def boot(self):
        with mock.patch.object(manual.uf2, 'convert', return_value=b'checked UF2'):
            boot = manual.Boot(self.run, self.args, 'rp2350', self.elf)
        boot.guard = mock.Mock()
        boot.guard.check.return_value = None
        boot.start()
        self.addCleanup(lambda: boot.server.close())
        return boot


class Manual(ManualCase):
    def test_preflight_rejects_ram_relative_hubs_missing_identity_and_bad_waits(self):
        for name, value in (('mode', 'ram'), ('hub', '.3.3'), ('hub', '1-1.3'),
                            ('pico_serial', None), ('guard_serial', 'PICO'),
                            ('manual_timeout', float('nan')), ('off_seconds', 0),
                            ('enumerate_seconds', float('inf')), ('bootsel_attach', True)):
            with self.subTest(name=name, value=value):
                old = getattr(self.args, name)
                setattr(self.args, name, value)
                with self.assertRaises(common.Failed):
                    manual.preflight(self.args)
                setattr(self.args, name, old)
        manual.preflight(self.args)

    def test_ordinary_and_fixed_uf2s_are_checked_before_any_hardware(self):
        with mock.patch.object(manual.uf2, 'convert', side_effect=[b'ordinary UF2', b'fixed UF2']) as convert:
            boot = manual.Boot(self.run, self.args, 'rp2350_hazard3', self.elf)
        self.assertEqual(convert.call_args_list,
            [mock.call(self.elf, 'hazard3'), mock.call(self.args.fixed_image, 'hazard3')])
        self.assertEqual(boot.state['status'], 'prepared')
        self.assertFalse(boot.state['resident_may_have_changed'])
        self.assertEqual(boot.images['fixed'][1].read_bytes(), b'fixed UF2')

    def test_bundle_uf2_mismatch_is_refused_before_start(self):
        import bundle
        self.args.bundle = self.root / 'bundle'
        other = self.root / 'other.uf2'
        other.write_bytes(b'wrong family or bytes')
        with mock.patch.object(manual.uf2, 'convert', return_value=b'checked UF2'), \
                mock.patch.object(bundle, 'validate', return_value={}), \
                mock.patch.object(bundle, 'artifact', return_value=other), \
                self.assertRaisesRegex(common.Failed, 'does not match its ELF'):
            manual.Boot(self.run, self.args, 'rp2350', self.elf)
        self.assertFalse((self.root / 'manual/control.sock').exists())

    def test_real_socket_rejects_stale_tokens_and_accepts_only_current_phase(self):
        boot = self.boot()
        notices = queue.Queue()
        def printed(line, **kwargs):
            if line.startswith('MANUAL '):
                notices.put(json.loads(line[7:]))
        with mock.patch('builtins.print', side_effect=printed), \
                concurrent.futures.ThreadPoolExecutor(max_workers=1) as worker:
            future = worker.submit(boot.request, 'unplug', 'Unplug Pico only')
            request = notices.get(timeout=2)
            with self.assertRaisesRegex(common.Failed, 'does not match'):
                manual.control(self.root, 'ack', request['run'], request['phase'], 'stale')
            self.assertFalse(future.done())
            manual.control(self.root, 'ack', request['run'], request['phase'], request['token'])
            future.result(timeout=2)
            next_step = worker.submit(boot.request, 'replug', 'Reconnect Pico only')
            second = notices.get(timeout=2)
            with self.assertRaises(common.Failed):
                manual.control(self.root, 'ack', request['run'], request['phase'], request['token'])
            manual.control(self.root, 'ack', second['run'], second['phase'], second['token'])
            next_step.result(timeout=2)
        self.assertNotIn('pending', manual.control(self.root, 'status'))
        self.assertEqual(sum(event['event'] == 'acknowledged' for event in boot.state['events']), 2)
        with self.assertRaisesRegex(common.Failed, 'no active manual request'):
            manual.control(self.root, 'ack', second['run'], second['phase'], second['token'])

    def test_cancel_and_timeout_stop_without_restoration_prompts_or_resume(self):
        boot = self.boot()
        notices = queue.Queue()
        with mock.patch('builtins.print', side_effect=lambda line, **_: notices.put(json.loads(line[7:]))), \
                concurrent.futures.ThreadPoolExecutor(max_workers=1) as worker:
            future = worker.submit(boot.request, 'unplug', 'Unplug Pico')
            request = notices.get(timeout=2)
            manual.control(self.root, 'cancel', request['run'], request['phase'], request['token'])
            with self.assertRaisesRegex(common.Failed, 'operator cancelled'):
                future.result(timeout=2)
        self.assertTrue(boot.stopped)
        with self.assertRaisesRegex(common.Failed, 'interaction stopped'):
            boot.restore()
        boot.close({'status': 'failed'})
        self.assertFalse((self.root / 'manual/control.sock').exists())
        self.assertNotIn('pending', manual.control(self.root, 'status'))

    def test_fragmented_ack_cannot_extend_the_phase_deadline(self):
        boot = self.boot()
        self.args.manual_timeout = 0.05
        notices = queue.Queue()
        with mock.patch('builtins.print', side_effect=lambda line, **_: notices.put(json.loads(line[7:]))), \
                concurrent.futures.ThreadPoolExecutor(max_workers=1) as worker:
            future = worker.submit(boot.request, 'unplug', 'Unplug Pico')
            request = notices.get(timeout=1)
            message = json.dumps(dict(action='ack', **{key: request[key]
                for key in ('run', 'phase', 'token')})).encode() + b'\n'
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                client.settimeout(1)
                client.connect(str(boot.directory / 'control.sock'))
                client.sendall(message[:len(message) // 2])
                # A retained partial message cannot borrow a new receive timeout.
                with self.assertRaisesRegex(common.Failed, 'timed out'):
                    future.result(timeout=0.5)
                try:
                    client.sendall(message[len(message) // 2:])
                except BrokenPipeError:
                    pass
                self.assertEqual(client.recv(4096), b'')
        self.assertTrue(boot.stopped)
        self.assertFalse(any(event['event'] == 'acknowledged' for event in boot.state['events']))

    def test_usb_trouble_during_fragmented_receive_stops_before_accepting_ack(self):
        boot = self.boot()
        notices, received, trouble = queue.Queue(), threading.Event(), threading.Event()
        original_recv = socket.socket.recv
        def recv(connection, *args):
            data = original_recv(connection, *args)
            if data:
                received.set()
            return data
        def guard(*args):
            if trouble.is_set():
                raise common.USBGuardError('USB stopped during acknowledgment')
        boot.guard.check.side_effect = guard
        with mock.patch('builtins.print', side_effect=lambda line, **_: notices.put(json.loads(line[7:]))), \
                mock.patch.object(socket.socket, 'recv', new=recv), \
                concurrent.futures.ThreadPoolExecutor(max_workers=1) as worker:
            future = worker.submit(boot.request, 'unplug', 'Unplug Pico')
            notices.get(timeout=1)
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                client.settimeout(1)
                client.connect(str(boot.directory / 'control.sock'))
                client.sendall(b'{"action":')
                self.assertTrue(received.wait(1))
                trouble.set()
                with self.assertRaisesRegex(common.USBGuardError, 'USB stopped during acknowledgment'):
                    future.result(timeout=1)
        self.assertTrue(boot.stopped)
        self.assertFalse(any(event['event'] == 'acknowledged' for event in boot.state['events']))

    def test_wait_timeout_and_usb_stop_are_retained_and_block_the_next_prompt(self):
        boot = self.boot()
        self.args.manual_timeout = 0.01
        with mock.patch('builtins.print'), self.assertRaisesRegex(common.Failed, 'timed out'):
            boot.request('unplug', 'Unplug Pico')
        self.assertTrue(boot.stopped)
        with mock.patch('builtins.print') as output, self.assertRaises(common.Failed):
            boot.request('replug', 'Reconnect Pico')
        output.assert_not_called()
        self.assertEqual(manual.control(self.root, 'status')['status'], 'stopped')

    def test_cold_cycle_waits_and_discards_old_uart_before_requesting_reconnect(self):
        boot = self.boot()
        console = SimpleNamespace(lock=threading.Lock(), received=bytearray(b'old traffic'))
        phases = []
        def request(phase, instruction):
            phases.append(phase)
            if phase.endswith('-replug'):
                self.assertEqual(console.received, b'')
                console.received.extend(b'cold boot')
        with mock.patch.object(boot, 'request', side_effect=request):
            boot.cold_cycle('application', console)
        self.assertEqual(phases, ['application-unplug', 'application-replug'])
        event = next(event for event in boot.state['events'] if event['event'] == 'cold-cycle')
        self.assertGreaterEqual(event['off_wait_seconds'], self.args.off_seconds)
        self.assertEqual(console.received, b'cold boot')
        self.assertEqual((boot.directory / 'application-pre-cold-uart.bin').read_bytes(), b'old traffic')

    def test_usb_stop_blocks_readback_and_restore_without_any_probe_or_prompt(self):
        boot = self.boot()
        boot.guard.check.side_effect = common.USBGuardError('USB controller stopped')
        with mock.patch.object(common, 'Probe') as probe, mock.patch('builtins.print') as output:
            for operation in (lambda: boot.install('application'), boot.restore,
                              lambda: boot.readback('application')):
                with self.assertRaises(common.USBGuardError):
                    operation()
        probe.assert_not_called()
        output.assert_not_called()

    def test_correct_architecture_readback_checks_every_byte_and_marker_after_cold(self):
        boot = self.boot()
        boot.state['resident_may_have_changed'] = True
        probe = mock.Mock()
        probe.read_words.return_value = [0x04030201, 0x00000005]
        with mock.patch.object(common, 'Probe', return_value=probe) as create, \
                mock.patch.object(common, 'elf_segments', return_value=[(0x10000000, bytes(range(1, 6)), 5)]):
            self.assertIs(boot.readback('application'), probe)
        self.assertEqual(create.call_args.args[2], 'RP235x')
        with mock.patch.object(boot, 'install') as install, \
                mock.patch.object(boot, 'cold_cycle') as cold, \
                mock.patch.object(boot, 'readback', return_value=probe) as read, \
                mock.patch.object(common, 'read_fixed_marker', return_value={'value': common.FIXED_READY_MAGIC}) as marker:
            boot.restore()
        install.assert_called_once_with('fixed')
        cold.assert_called_once_with('fixed')
        read.assert_called_once_with('fixed')
        marker.assert_called_once_with(probe, self.args.fixed_image)


class Identity(ManualCase):
    def fixture(self):
        sysfs = self.root / 'usb'
        sysfs.mkdir()
        def usb(name, vid, pid, serial=None, **attrs):
            directory = sysfs / name
            directory.mkdir()
            for key, value in dict(idVendor=vid, idProduct=pid, **attrs).items():
                (directory / key).write_text(value)
            if serial is not None:
                (directory / 'serial').write_text(serial)
            return directory
        usb('1-1', '2109', '3431', bDeviceClass='09', maxchild='4')
        usb('1-1.1', '0403', '6010', 'ARTY')
        pico = usb('1-1.2', '2e8a', '000f', 'PICO')
        self.usb = usb
        return manual.Guard(self.args, sysfs), pico

    def test_identity_requires_known_serial_absent_cascade_and_arty(self):
        guard, pico = self.fixture()
        self.assertEqual(guard.check('bootsel'), '2e8a:000f')
        (pico / 'serial').write_text('OTHER')
        with self.assertRaisesRegex(common.Failed, 'BOOTSEL serial'):
            guard.check()
        (pico / 'serial').write_text('PICO')
        self.usb('1-1.3', '0bda', '5411')
        with self.assertRaisesRegex(common.Failed, 'cascade unplugged'):
            guard.check()

    def test_wrong_identity_missing_hub_and_silent_port_do_not_allow_guessing(self):
        guard, pico = self.fixture()
        (pico / 'idProduct').write_text('0003')
        with self.assertRaisesRegex(common.Failed, 'unexpected USB'):
            guard.check()
        (pico / 'idProduct').write_text('000f')
        with self.assertRaisesRegex(common.Failed, 'still present'):
            guard.check('silent')
        pico.rename(pico.with_name('removed'))
        self.assertIsNone(guard.check('silent'))
        (guard.sysfs / '1-1/maxchild').unlink()
        with self.assertRaisesRegex(common.Failed, 'cannot read'):
            guard.check()

    def test_unreadable_or_incomplete_usb_identity_cannot_hide_a_cascade(self):
        guard, _ = self.fixture()
        cascade = self.usb('1-1.3', '0bda', '5411')
        (cascade / 'idProduct').unlink()
        with self.assertRaisesRegex(common.Failed, 'cannot establish USB identity'):
            guard.check()
        (cascade / 'idProduct').write_text('5411')
        original = Path.read_text
        def read(path, *args, **kwargs):
            if path == cascade / 'idProduct':
                raise PermissionError('identity unreadable')
            return original(path, *args, **kwargs)
        with mock.patch.object(Path, 'read_text', new=read), \
                self.assertRaisesRegex(common.Failed, 'identity unreadable'):
            guard.check()

    def test_volume_ancestry_ambiguity_mounts_and_changed_major_minor_are_refused(self):
        guard, pico = self.fixture()
        blocks, devices = self.root / 'block', self.root / 'dev'
        blocks.mkdir()
        devices.mkdir()
        def block(name, parent, minor):
            directory = parent / name
            directory.mkdir()
            (directory / 'dev').write_text('8:%d' % minor)
            (blocks / name).symlink_to(directory, target_is_directory=True)
            (devices / name).write_bytes(b'device')
            return dict(name=str(devices / name), kname=str(devices / name),
                        **{'maj:min': '8:%d' % minor}, fstype='vfat', mountpoints=[None])
        own = block('sda1', pico, 1)
        foreign = self.root / 'other-usb'
        foreign.mkdir()
        other = block('sdb1', foreign, 17)
        run = mock.Mock()
        run.command.return_value = json.dumps(dict(blockdevices=[other, own]))
        volume = manual.Volume(run, guard, blocks, devices)
        original_stat = Path.stat
        def device_stat(path, **kwargs):
            if path == devices / 'sda1':
                return SimpleNamespace(st_mode=stat.S_IFBLK, st_rdev=os.makedev(8, 1))
            return original_stat(path, **kwargs)
        with mock.patch.object(Path, 'stat', autospec=True, side_effect=device_stat), \
                mock.patch.object(manual, 'mounts', return_value=[]):
            identity = volume.discover()
            self.assertEqual(identity['device'], own['name'])
            with mock.patch.object(manual, 'mounts', return_value=[('8:1', '/elsewhere')]), \
                    self.assertRaisesRegex(common.Failed, 'already mounted'):
                volume.discover()
            with mock.patch.object(manual, 'mounts', return_value=[('8:17', '/private')]), \
                    self.assertRaisesRegex(common.Failed, 'private BOOTSEL mount'):
                volume.verify(identity, Path('/private'))
            (pico / 'sda1/dev').write_text('8:99')
            with self.assertRaisesRegex(common.Failed, 'identity changed'):
                volume.verify(identity)
            (pico / 'sda1/dev').write_text('8:1')
            (devices / 'sda1').unlink()
            with mock.patch.object(volume, 'verify'):
                second = block('sdc1', pico, 33)
                run.command.return_value = json.dumps(dict(blockdevices=[own, second]))
                with self.assertRaisesRegex(common.Failed, 'exactly one'):
                    volume.discover()


class Copy(ManualCase):
    def copy_fixture(self):
        guard = mock.Mock()
        run = mock.Mock()
        volume = manual.Volume(run, guard)
        identity = dict(device='/dev/sda1', major_minor='8:1')
        volume.discover = mock.Mock(return_value=identity)
        volume.verify = mock.Mock()
        image = self.root / 'image.uf2'
        image.write_bytes(b'UF2 bytes')
        def command(name, argv, **kwargs):
            if name.endswith('-copy'):
                result = subprocess.run([str(value) for value in argv], capture_output=True,
                                        text=True, check=True, timeout=kwargs['timeout'])
                return result.stdout
            return ''
        run.command.side_effect = command
        return volume, run, guard, image

    def test_mount_options_write_bookkeeping_and_one_unmount(self):
        volume, run, guard, image = self.copy_fixture()
        before = mock.Mock(side_effect=lambda _: self.assertFalse((self.root / 'mount/LANDIN.UF2').exists()))
        result = volume.copy(image, self.root, before)
        before.assert_called_once()
        self.assertEqual(result['bytes'], len(b'UF2 bytes'))
        self.assertEqual((self.root / 'mount/LANDIN.UF2').read_bytes(), b'UF2 bytes')
        mount, copy, unmount = run.command.call_args_list
        self.assertEqual(mount.args[1][:6], ['sudo', '-n', 'mount', '-t', 'vfat', '-o'])
        self.assertIn('nodev,nosuid,noexec', mount.args[1][6])
        self.assertEqual(copy.kwargs['timeout'], 120)
        self.assertEqual(unmount.args[1], ['sudo', '-n', 'umount', self.root / 'mount'])

    def test_copy_error_unmounts_once_but_usb_stop_blocks_all_cleanup(self):
        volume, run, guard, image = self.copy_fixture()
        def failed_copy(name, argv, **kwargs):
            if name.endswith('-copy'):
                raise common.Failed('copy flush failed')
            return ''
        run.command.side_effect = failed_copy
        with self.assertRaisesRegex(common.Failed, 'copy flush failed'):
            volume.copy(image, self.root, lambda _: None)
        self.assertEqual(sum(call.args[0].endswith('-unmount') for call in run.command.call_args_list), 1)
        (self.root / 'mount').rmdir()
        run.reset_mock()
        guard.check.side_effect = common.USBGuardError('USB stopped')
        with self.assertRaisesRegex(common.Failed, 'unmount pending: USB stopped'):
            volume.copy(image, self.root, lambda _: None)
        self.assertFalse(any(call.args[0].endswith('-unmount') for call in run.command.call_args_list))


class Main(unittest.TestCase):
    def test_both_ports_manual_main_preserves_oracle_and_error_restoration(self):
        for board, hazard in (('rp2350', False), ('rp2350_hazard3', True)):
            spec = importlib.util.spec_from_file_location('manual_main_' + board,
                ROOT / 'environments/boards' / board / 'board.py')
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            for failure in ('none', 'application', 'usb', 'restore-interrupted', 'inherited-lock',
                            'auto-inherited-lock', 'acquire-failed'):
                with self.subTest(board=board, failure=failure), tempfile.TemporaryDirectory() as tmp:
                    root = Path(tmp)
                    elf = root / 'app.elf'
                    elf.write_bytes(b'ELF')
                    fixed = root / 'fixed.elf'
                    fixed.write_bytes(b'fixed')
                    events = []
                    lock = mock.Mock(file=True)
                    auto = failure == 'auto-inherited-lock'
                    if 'inherited-lock' in failure:
                        lock.file = None
                    def acquire():
                        events.append('lock')
                        if failure == 'acquire-failed':
                            raise common.Failed('lock acquisition failed')
                        return lock
                    lock.acquire.side_effect = acquire
                    console = mock.Mock(received=b'', sent=b'')
                    manual_boot = mock.Mock()
                    manual_boot.start.side_effect = lambda: events.append('start')
                    manual_boot.cold_cycle.side_effect = lambda role, uart: self.assertIs(uart, console)
                    manual_boot.restore.return_value = {'value': common.FIXED_READY_MAGIC}
                    if failure == 'restore-interrupted':
                        manual_boot.restore.side_effect = KeyboardInterrupt
                    pace = common.Pace(state=root / 'pace', kernel=lambda _: [])
                    def scenario(*args):
                        if failure == 'usb':
                            pace.blocked = 'USB stopped'
                            raise common.USBGuardError('USB stopped')
                        if failure == 'application':
                            raise common.Failed('ordinary oracle failed')
                        return ({}, {}, 0) if hazard else ({}, {})
                    argv = ['board.py', '--mode=boot', '--boot-transport=manual-uf2',
                        '--hub=1-1', '--port=2', '--pico-serial=PICO', '--refine=refine',
                        '--ram-loader=loader', '--probe-rs=probe', '--nm=nm',
                        '--probehive=' + tmp, '--fixed-image=' + str(fixed), '--output=' + tmp + '/run']
                    if hazard:
                        argv.append('--objdump=objdump')
                    if auto:
                        argv.remove('--boot-transport=manual-uf2')
                        argv.append('--cascade=1-1.3')
                    with contextlib.ExitStack() as stack:
                        def patch(owner, name, **kwargs):
                            return stack.enter_context(mock.patch.object(owner, name, **kwargs))
                        patch(sys, 'argv', new=argv)
                        patch(common, 'board_preflight')
                        place = patch(common, 'place_hubs')
                        patch(common, 'Pace', return_value=pace)
                        patch(common, 'rig_lock', return_value=lock)
                        patch(common, 'shared_bridge', return_value=(None, {}))
                        patch(common, 'TcpConsole', return_value=console)
                        patch(common, 'elf_sections', return_value=(b'', {'.isr_vector': (0x10000000, 0, 272)}))
                        patch(manual, 'Boot', return_value=manual_boot)
                        patch(module, 'build', return_value=(elf, b'head', {}, []) if hazard else (elf, b'head', {}))
                        flash = patch(module, 'flash', return_value='RP235x',
                                      side_effect=None if auto else AssertionError('legacy flash'))
                        power = patch(module, 'power_cycle',
                                      side_effect=None if auto else AssertionError('hub switch'))
                        if auto:
                            restore = patch(module, 'restore_fixed', return_value={'value': common.FIXED_READY_MAGIC})
                        patch(module, 'scenario', side_effect=scenario)
                        patch(module, 'cross_check', return_value={})
                        self.assertEqual(module.main(), 0 if failure in ('none', 'inherited-lock', 'auto-inherited-lock') else 1)
                    if auto or failure == 'acquire-failed':
                        self.assertEqual(events, ['lock'])
                        manual_boot.install.assert_not_called()
                        manual_boot.readback.assert_not_called()
                    else:
                        self.assertEqual(events[:2], ['lock', 'start'])
                        manual_boot.install.assert_called_once_with('application')
                        manual_boot.readback.assert_called_once_with('application')
                    if auto:
                        flash.assert_called_once()
                        # The cold start before the flash, then the application's cycle.
                        self.assertEqual(power.call_count, 2)
                        place.assert_called_once()
                        restore.assert_called_once()
                    else:
                        flash.assert_not_called()
                        power.assert_not_called()
                        place.assert_not_called()
                    result = json.loads((root / 'run/result.json').read_text())
                    if auto:
                        manual_boot.close.assert_not_called()
                    else:
                        manual_boot.close.assert_called_once()
                    if failure == 'acquire-failed':
                        lock.release.assert_not_called()
                        manual_boot.start.assert_not_called()
                        manual_boot.restore.assert_not_called()
                        self.assertNotIn('fixed_restore', result)
                    else:
                        lock.release.assert_called_once()
                    if auto:
                        manual_boot.restore.assert_not_called()
                        self.assertEqual(result['fixed_restore']['status'], 'passed')
                    elif failure == 'usb':
                        manual_boot.restore.assert_not_called()
                        self.assertEqual(result['fixed_restore']['status'], 'pending')
                    elif failure != 'acquire-failed':
                        manual_boot.restore.assert_called_once()
                        self.assertEqual(result['fixed_restore']['status'],
                                         'pending' if failure == 'restore-interrupted' else 'passed')
                        if failure == 'restore-interrupted':
                            self.assertIn('restoration interrupted', result['failure'])
                            self.assertTrue(manual_boot.stopped)


if __name__ == '__main__':
    unittest.main()
