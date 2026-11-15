#!/usr/bin/env python3
"""Controls for FreeBSD corpus selection and checked release inputs."""
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import socket
import sys
import tempfile
import threading
import unittest
from types import SimpleNamespace
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('freebsd_lane', ROOT / 'compiler/tests/freebsd/check.py')
LANE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(LANE)
import vm


class FreeBSDControls(unittest.TestCase):
    def test_native_host_controls_require_success_and_all_completed_helpers(self):
        markers = (b'publication native: 20 controls passed\n'
                   b'cancellation native: 16 controls passed\n'
                   b'attached native: 12 controls passed\n'
                   b'runtime ownership native: 7/7 controls passed\n'
                   b'native registry threads: 8 workers, 24 rounds, 768 cross-thread handoffs passed\n')
        with tempfile.TemporaryDirectory() as tmp:
            lane = LANE.Lane.__new__(LANE.Lane)
            lane.output = Path(tmp)
            lane.source_root = Path('/owned source')
            lane.remote_prefix = '/owned guest'
            attempts = [(1, markers), (0, b''), (0, markers)]
            attempts.extend((0, markers.replace(line, b''))
                            for line in markers.splitlines(keepends=True))
            for status, stdout in attempts:
                guest = Mock()
                guest.run.return_value = SimpleNamespace(
                    returncode=status, stdout=stdout, stderr=b'')
                with self.subTest(status=status, stdout=stdout):
                    if status or stdout != markers:
                        with self.assertRaises(ValueError):
                            lane.native_host_controls(guest)
                    else:
                        lane.native_host_controls(guest)
                    self.assertEqual((lane.output / 'native-host-controls.log').read_bytes(), stdout)

    def test_shards_partition_each_lane_by_whole_fixture(self):
        for arch in ('amd64', 'arm64'):
            for kind in ('runtime', 'abi'):
                def work(shard):
                    return LANE.work_items(SimpleNamespace(arch=arch, kind=kind, case=None, shard=shard))
                whole = [(base, o, s, level) for base, _, o, s, level in work(None)]
                parts = [[(base, o, s, level) for base, _, o, s, level in work((i, 3))]
                         for i in (1, 2, 3)]
                with self.subTest(arch=arch, kind=kind):
                    self.assertEqual(sorted(map(repr, sum(parts, []))), sorted(map(repr, whole)))
                    owners = [{base for base, *_ in part} for part in parts]
                    for i, j in ((0, 1), (0, 2), (1, 2)):
                        self.assertFalse(owners[i] & owners[j], 'a fixture is split across shards')

    def test_an_unknown_case_says_the_spelling_the_lane_takes(self):
        def work(*cases):
            return LANE.work_items(SimpleNamespace(arch='amd64', kind='runtime', case=list(cases), shard=None))
        known = {base.name for base, *_ in LANE.work_items(
            SimpleNamespace(arch='amd64', kind='runtime', case=None, shard=None))}
        name = sorted(known)[0]
        self.assertEqual({base.name for base, *_ in work(name)}, {name})
        for spelling in ('runtime/' + name, 'runtime-' + name):
            with self.subTest(spelling=spelling), self.assertRaises(ValueError) as raised:
                work(spelling)
            self.assertIn(repr(spelling) + ' (write ' + name + ')', str(raised.exception))
            self.assertIn('bare directory name', str(raised.exception))
        with self.assertRaises(ValueError) as raised:
            work(name + 'x')
        self.assertIn(repr(name + 'x') + ' (nearest: ', str(raised.exception))
        self.assertNotIn('it holds:', str(raised.exception))
        #  With nothing near, every name the lane knows is in the refusal.
        with self.assertRaises(ValueError) as raised:
            work('zzzz-qqqq-0000')
        said = str(raised.exception)
        self.assertIn("'zzzz-qqqq-0000'", said)
        self.assertTrue(all(' ' + k in said for k in known))

    def test_a_shard_takes_no_selection_or_transfer(self):
        self.assertEqual(LANE.shard('2/3'), (2, 3))
        for text in ('0/3', '4/3', '3', 'a/b', '1/65'):
            with self.subTest(text=text), self.assertRaises(Exception):
                LANE.shard(text)

    def test_lld_symlink_keeps_the_elf_driver_invocation_name(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            output = root / 'output'
            output.mkdir()
            (root / 'lld').write_bytes(b'generic driver')
            (root / 'ld.lld-19').symlink_to('lld')
            refine = root / 'refine'
            refine.write_bytes(b'compiler')
            args = SimpleNamespace(output=output, refine=refine, arch='arm64', kind='runtime',
                                   clang='/usr/bin/clang-19', lld=str(root / 'ld.lld-19'))
            lane = LANE.Lane(args, root / 'sysroot')
            self.assertEqual(lane.lld, str(root / 'ld.lld-19'))
            self.assertIn('-fuse-ld=' + str(root / 'ld.lld-19'), lane.driver.read_text())

    def test_prepared_execution_refuses_missing_architecture_profiles(self):
        with tempfile.TemporaryDirectory() as tmp:
            prepared = Path(tmp)
            manifest = {'arch': 'amd64', 'kind': 'runtime', 'scope': 'complete',
                        'results': [{'case': 'runtime/assembly-operands', 'optimize': 'none',
                                     'specialize': 'off', 'level': None}]}
            (prepared / 'prepared.json').write_text(json.dumps(manifest))
            args = SimpleNamespace(prepared=prepared, arch='amd64', kind='runtime', case=None)
            with self.assertRaisesRegex(ValueError, 'prepared corpus incomplete'):
                LANE.load_prepared(args)
            manifest['results'] = []
            (prepared / 'prepared.json').write_text(json.dumps(manifest))
            with self.assertRaisesRegex(ValueError, 'empty prepared fixture selection'):
                LANE.load_prepared(args)

    def test_prepared_payload_mutation_cannot_execute(self):
        with tempfile.TemporaryDirectory() as tmp:
            prepared = Path(tmp)
            (prepared / 'payload.tar.gz').write_bytes(b'changed')
            manifest = {'arch': 'amd64', 'kind': 'runtime', 'scope': 'filtered',
                        'results': [{}], 'payload_sha256': '0' * 64}
            (prepared / 'prepared.json').write_text(json.dumps(manifest))
            args = SimpleNamespace(prepared=prepared, arch='amd64', kind='runtime', case=None)
            with patch.dict('os.environ', {}, clear=True):
                with self.assertRaisesRegex(ValueError, 'prepared payload checksum'):
                    LANE.load_prepared(args)

    def test_existing_checkout_is_refused_and_not_cleaned_up(self):
        lane = LANE.Lane.__new__(LANE.Lane)
        lane.output = Path('/tmp/output')
        lane.source_root = Path('/real/checkout/Landin')
        lane.remote_prefix = '/tmp/landin-owned'
        lane.transferred = False
        guest = Mock()
        guest.checked.side_effect = ValueError('existing checkout')
        with self.assertRaisesRegex(ValueError, 'existing checkout'):
            lane.transfer(guest)
        self.assertFalse(lane.transferred)
        guest.put.assert_not_called()
        command = guest.checked.call_args.args[0]
        self.assertIn('set -e; test ! -e', command)
        self.assertNotIn('rm', command)

    def test_persistent_guest_limit_is_restored_after_a_failed_lane(self):
        with tempfile.TemporaryDirectory() as tmp:
            lane = SimpleNamespace(args=SimpleNamespace(runner_ssh='ssh ci@freebsd-vm',
                                   output=Path(tmp)), cleanup=Mock())
            guest = Mock()
            guest.checked.side_effect = [b'1073741824', b'', b'kern.maxdsiz: 4294967296', b'']
            with patch.object(LANE, 'Guest', return_value=guest):
                with self.assertRaisesRegex(ValueError, 'execution failed'):
                    with LANE.configured_guest(lane, None):
                        raise ValueError('execution failed')
            self.assertEqual(guest.checked.call_args.args[0], 'sysctl kern.maxdsiz=1073741824')

    def test_runner_transport_preserves_binary_input_and_sudo_quoting(self):
        guest = vm.Guest(ssh='ssh -T ci@freebsd-vm', sudo=True)
        with patch.object(vm.subprocess, 'run') as run:
            guest.run("printf '%s' '$literal'", input=b'\0\xff')
        self.assertEqual(run.call_args.kwargs['input'], b'\0\xff')
        self.assertEqual(run.call_args.args[0][:3], ['ssh', '-T', 'ci@freebsd-vm'])
        self.assertIn('sudo -n /bin/sh -c', run.call_args.args[0][-1])

    def test_each_architecture_has_runtime_operands_and_required_c_peers(self):
        for arch in ('amd64', 'arm64'):
            self.assertIn('assembly-operands', {p.name for p, _ in LANE.select(arch, 'runtime')})
            selected = {p.name for p, _ in LANE.select(arch, 'abi')}
            self.assertTrue(LANE.ABI_REQUIRED <= selected)
            self.assertGreater(len(selected), len(LANE.ABI_REQUIRED))

    def test_linux_fault_paths_have_explicit_bsd_endpoint_peers(self):
        for arch in ('amd64', 'arm64'):
            selected = {p.name: m for p, m in LANE.select(arch, 'runtime')}
            for name in ('core-io-erased-system', 'r440-errno-detail'):
                self.assertEqual(selected[name]['c-sources'], '../../../freebsd/io_endpoints.c')

    def test_empty_selection_cannot_pass(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(LANE, 'ROOT', Path(tmp)):
            for arch in ('amd64', 'arm64'):
                for kind in ('runtime', 'abi'):
                    with self.assertRaisesRegex(ValueError, 'empty fixture selection'):
                        LANE.select(arch, kind)

    def test_removing_an_import_export_peer_cannot_pass(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(LANE, 'ROOT', Path(tmp)):
            fixture = Path(tmp) / 'compiler/tests/fixtures/abi/only-one'
            fixture.mkdir(parents=True)
            (fixture / 'fixture.meta').write_text(
                'class: abi\nsummary: one peer\nprofiles: standard\nprogram: main.ldn\n'
                'constructs: 0300\ntargets: freebsd-x86-64, freebsd-arm64\nc-sources: peer.c\n')
            (fixture / 'peer.c').write_text('int peer(void) { return 0; }\n')
            with self.assertRaisesRegex(ValueError, 'ABI coverage missing'):
                LANE.select('amd64', 'abi')
            with self.assertRaisesRegex(ValueError, 'ABI coverage missing'):
                LANE.select('arm64', 'abi')

    def test_an_abi_fixture_without_a_c_peer_cannot_pass(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(LANE, 'ROOT', Path(tmp)):
            fixture = Path(tmp) / 'compiler/tests/fixtures/abi/only-one'
            fixture.mkdir(parents=True)
            (fixture / 'fixture.meta').write_text(
                'class: abi\nsummary: no peer\nprofiles: standard\nprogram: main.ldn\n'
                'constructs: 0300\ntargets: freebsd-x86-64, freebsd-arm64\n')
            #  The fixture format refuses it before the lane can: an ABI
            #  fixture needs c-sources (compiler/tests/fixture_meta.py).
            with self.assertRaisesRegex(ValueError, 'an ABI fixture needs c-sources'):
                LANE.select('amd64', 'abi')

    def test_linked_checks_use_function_extents_past_local_labels(self):
        symbols = '1000 g F .text 0020 main\n2000 g F .text 0020 _start\n'
        listing = ('1000 <main>:\n 1000: nop\n1010 <.L1_1>:\n'
                   ' 1010: ldaddal w0, w1, [x2]\n2000 <_start>:\n 2000: ldxr w0, [x2]\n')
        code = LANE.fixture_code(symbols, listing, {'main'})
        self.assertIn('ldaddal', code)
        self.assertNotIn('ldxr', code)
        with self.assertRaisesRegex(ValueError, 'missing from linked ELF'):
            LANE.fixture_code(symbols, listing, {'absent'})

    def test_cached_download_must_still_match_its_lock(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'image.xz'
            path.write_bytes(b'changed archive')
            with self.assertRaisesRegex(ValueError, 'cached checksum'):
                vm.download('https://example.invalid/never-fetched', path, '0' * 64)

    def test_a_fixture_input_is_redirected_from_the_guest_copy(self):
        lane = LANE.Lane.__new__(LANE.Lane)
        lane.source_root = Path('/home/runner/work/Landin/Landin')
        lane.remote_prefix = '/tmp/landin-control'
        lane.remote_bundle = Path(lane.remote_prefix) / 'bundle'
        results = [
            {'case': 'runtime/word-count', 'label': 'fed',
             'meta': {'stdin': 'input.txt', 'stream': 'output'}},
            {'case': 'runtime/word-count-no-input', 'label': 'empty',
             'meta': {'stream': 'output'}}]
        written = []

        class Stop(Exception):
            pass

        def checked(command, **keywords):
            written.append(keywords.get('input', b'').decode())
            raise Stop()
        with self.assertRaises(Stop):
            lane.execute(SimpleNamespace(checked=checked), results)
        script = written[0]
        self.assertIn(' </home/runner/work/Landin/Landin/compiler/tests/fixtures/'
                      'runtime/word-count/input.txt >', script)
        #  No `stdin:` key is an empty input, never the guest shell's own.
        self.assertIn('/tmp/landin-control/bundle/empty </dev/null >', script)

    def test_every_outcome_gets_its_verdict_and_failures_are_listed_together(self):
        #  One failing outcome once stopped the lane with a traceback, and
        #  the outcomes after it had no verdict.
        import io
        import tarfile
        with tempfile.TemporaryDirectory() as tmp:
            lane = LANE.Lane.__new__(LANE.Lane)
            lane.args = SimpleNamespace(arch='amd64')
            lane.target = 'freebsd-x86-64'
            lane.output = Path(tmp)
            lane.bundle = Path(tmp) / 'bundle'
            lane.bundle.mkdir()
            lane.source_root = Path('/home/runner/work/Landin/Landin')
            lane.remote_prefix = '/tmp/landin-control'
            lane.remote_bundle = Path(lane.remote_prefix) / 'bundle'
            results = [{'case': 'runtime/' + label, 'label': label, 'level': None,
                        'base': tmp, 'meta': {'status': '42', 'stream': 'merged'}}
                       for label in ('passes', 'wrong-status', 'never-ran', 'also-passes')]
            buffer = io.BytesIO()
            with tarfile.open(fileobj=buffer, mode='w:gz') as tar:
                for label, status in (('passes', b'42\n'), ('wrong-status', b'2\n'),
                                      ('also-passes', b'42\n')):
                    for suffix, data in (('.status', status), ('.stdout', b'')):
                        info = tarfile.TarInfo(label + suffix)
                        info.size = len(data)
                        tar.addfile(info, io.BytesIO(data))

            def checked(command, **keywords):
                return buffer.getvalue() if command.startswith('cat ') else b''
            with patch('sys.stdout', io.StringIO()) as said, \
                    self.assertRaises(LANE.OutcomeFailures) as failed:
                lane.execute(SimpleNamespace(checked=checked), results)
        self.assertEqual([r['status'] for r in results],
                         ['passed', 'failed', 'failed', 'passed'])
        self.assertEqual(len(failed.exception.failures), 2)
        self.assertIn('wrong-status: guest status 2, expected 42', str(failed.exception))
        self.assertIn('never-ran.status', str(failed.exception))
        self.assertTrue(str(failed.exception).startswith('2 of 4 outcomes failed:'))
        self.assertIn('freebsd-x86-64: 2 of 4 outcomes passed', said.getvalue())
        self.assertFalse(any('meta' in r for r in results))

    def test_every_lldb_session_runs_after_one_fails(self):
        lane = LANE.Lane.__new__(LANE.Lane)
        lane.target = 'freebsd-x86-64'
        seen = []

        def session(guest, result):
            seen.append(result['label'])
            if result['label'] == 'debug-none-off':
                raise ValueError('debug-none-off: no source-line stop')
            result['status'] = 'passed'
        lane.source_session = session
        lane.switch_session = session
        results = [{'label': 'debug-none-off'}, {'label': 'switch-none-off',
                                                  'switch_instructions': 9},
                   {'label': 'debug-size-off'}]
        with patch('sys.stdout', new_callable=lambda: __import__('io').StringIO()), \
                self.assertRaises(LANE.OutcomeFailures) as failed:
            lane.debugger(None, results)
        self.assertEqual(seen, ['debug-none-off', 'switch-none-off', 'debug-size-off'])
        self.assertEqual(failed.exception.failures, ['debug-none-off: no source-line stop'])

    def test_a_fixture_is_given_its_shared_objects_by_their_guest_paths(self):
        #  compiler/tests/README.md: `c-shared:` objects travel in the bundle
        #  and are the program's first arguments, before `run_args`.
        lane = LANE.Lane.__new__(LANE.Lane)
        lane.source_root = Path('/home/runner/work/Landin/Landin')
        lane.remote_prefix = '/tmp/landin-control'
        lane.remote_bundle = Path(lane.remote_prefix) / 'bundle'
        results = [{'case': 'runtime/posix-libraries', 'label': 'loads',
                    'shared': ['loads-plugin.so', 'loads-provider.so'],
                    'meta': {'run_args': 'last', 'stream': 'output'}}]
        written = []

        class Stop(Exception):
            pass

        def checked(command, **keywords):
            written.append(keywords.get('input', b'').decode())
            raise Stop()
        with self.assertRaises(Stop):
            lane.execute(SimpleNamespace(checked=checked), results)
        self.assertIn('/tmp/landin-control/bundle/loads '
                      '/tmp/landin-control/bundle/loads-plugin.so '
                      '/tmp/landin-control/bundle/loads-provider.so last <',
                      written[0])

    def test_a_c_archive_fixture_is_compiled_from_its_work_copy(self):
        #  compiler/tests/README.md: each `c-archives` source is compiled
        #  alone and archived as lib<stem>.a in its own directory of a work
        #  copy that refine compiles, `library-directories` its -L.
        base = ROOT / 'compiler/tests/fixtures/runtime/c-library-directories'
        meta = LANE.metadata(base / 'fixture.meta')
        with tempfile.TemporaryDirectory() as tmp:
            lane = LANE.Lane.__new__(LANE.Lane)
            lane.output = Path(tmp)
            lane.bundle = lane.output / 'bundle'
            lane.bundle.mkdir()
            lane.target = 'freebsd-arm64'
            lane.cc = ['clang-19', '--target=aarch64-unknown-freebsd14.4', '-fuse-ld=lld']
            lane.driver = lane.output / 'freebsd-clang'
            lane.args = SimpleNamespace(refine=Path('/opt/refine'), ar='llvm-ar-19', arch='arm64')
            ran = []

            def command(argv, label, *, expected=0):
                argv = list(map(str, argv))
                ran.append(argv)
                Path(argv[argv.index('-o') + 1] if '-o' in argv else argv[2]).write_bytes(b'made')
                return b''
            lane.command = command
            result = lane.build(base, meta, 'none', 'off')
        copy = lane.output / 'copies' / result['label']
        self.assertEqual(ran[0], ['clang-19', '--target=aarch64-unknown-freebsd14.4',
                                  '-std=c11', '-Wall', '-Wextra', '-Werror', '-fPIC', '-O2',
                                  '-c', str(base / 'lib/mixed.c'),
                                  '-o', str(copy / 'lib/libmixed.a.o')])
        self.assertEqual(ran[1], ['llvm-ar-19', 'rcs', str(copy / 'lib/libmixed.a'),
                                  str(copy / 'lib/libmixed.a.o')])
        self.assertEqual(ran[3][:3], ['llvm-ar-19', 'rcs', str(copy / 'vendor/libpoint.a')])
        refine = ran[4]
        self.assertEqual(refine[refine.index('-L'):refine.index('-L') + 3],
                         ['-L', str(copy / 'vendor'), str(copy / 'main.ldn')])
        self.assertNotIn('--link=libc', refine)
        self.assertEqual([peer['source'] for peer in result['c_peers']],
                         ['lib/mixed.c', 'vendor/point.c'])

    def test_guest_failure_cannot_supply_a_feature_verdict(self):
        guest = vm.Guest(1)
        with patch.object(guest, 'run', return_value=type('Result', (), {
                'returncode': 2, 'stdout': b'no LSE', 'stderr': b''})()):
            with self.assertRaisesRegex(ValueError, 'guest command failed'):
                guest.checked('processor')


class FakeGuestConsole:
    """A guest's serial console on a Unix socket: a login prompt, then a
    shell answering each framed command the way the admitted guest does."""

    HOST_KEY = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFCXJa36qK58/EJzE8P+dBPHrAbaV/XYQQa/VVhzHMcd'

    def __init__(self, path, settings):
        self.settings, self.typed = settings, []
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(str(path))
        self.server.listen(1)
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.thread.start()

    def serve(self):
        connection, _ = self.server.accept()
        with connection:
            connection.sendall(b'FreeBSD/amd64 (freebsd) (ttyu0)\r\n\r\nlogin: ')
            pending = b''
            while True:
                piece = connection.recv(4096)
                if not piece:
                    return
                pending += piece
                while b'\r' in pending:
                    line, pending = pending.split(b'\r', 1)
                    self.typed.append(line.decode())
                    connection.sendall(line + b'\r\n' + self.answer(line.decode()) + b'root@freebsd:~ # ')

    def answer(self, line):
        if line == 'root':
            return b''
        command = re.fullmatch(r"printf '%s-%s\\n' LANDIN BEGIN; (.*); printf '%s-%s %s\\n' LANDIN END \$\?",
                               line).group(1)
        output = ''
        if command.startswith('sshd -T'):
            output = ''.join(f'{key} {value}\r\n' for key, value in self.settings.items())
        elif command.startswith('cat /etc/ssh/ssh_host_ed25519_key.pub'):
            output = self.HOST_KEY + ' root@freebsd\r\n'
        return f'LANDIN-BEGIN\r\n{output}LANDIN-END 0\r\n'.encode()

    def close(self):
        self.server.close()


class FreeBSDGuestAdmission(unittest.TestCase):
    """The lane's guest admits only the key made for its boot, and the
    client holds the guest to the host key it reported on its console."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.alive = Mock()
        self.alive.poll.return_value = None

    def admitted(self, settings):
        console_path = self.root / 'console.sock'
        guest = FakeGuestConsole(console_path, settings)
        self.addCleanup(guest.close)
        console = vm.Console(console_path, self.alive, vm.time.monotonic() + 30)
        try:
            return guest, vm.admit(console, 'ssh-ed25519 AAAAexample landin-freebsd-lane')
        finally:
            console.close()

    def test_a_booted_guest_is_reached_only_with_its_boot_key_and_host_key(self):
        guest = vm.Guest(2222, identity=self.root / 'client', known_hosts=self.root / 'known_hosts')
        options = [guest.ssh[i + 1] for i, word in enumerate(guest.ssh) if word == '-o']
        self.assertIn('StrictHostKeyChecking=yes', options)
        self.assertIn('UserKnownHostsFile=' + str(self.root / 'known_hosts'), options)
        self.assertIn('IdentitiesOnly=yes', options)
        self.assertIn('PreferredAuthentications=publickey', options)
        self.assertEqual(guest.ssh[guest.ssh.index('-i') + 1], str(self.root / 'client'))
        self.assertEqual(guest.ssh[guest.ssh.index('-F') + 1], 'none')
        self.assertNotIn('StrictHostKeyChecking=no', options)
        self.assertNotIn('UserKnownHostsFile=/dev/null', options)
        self.assertEqual(guest.ssh[-3:], ['-p', '2222', 'root@127.0.0.1'])
        # A development VM is the caller's: its identity and known hosts.
        development = vm.Guest(2222)
        self.assertFalse({'-F', '-i'} & set(development.ssh))
        self.assertFalse(any('HostKeyChecking' in word or 'KnownHosts' in word for word in development.ssh))
        with self.assertRaisesRegex(ValueError, 'unusable SSH key path'):
            vm.Guest(2222, identity=self.root / 'a key', known_hosts=self.root / 'known_hosts')

    @unittest.skipUnless(shutil.which('ssh-keygen'), 'needs OpenSSH ssh-keygen')
    def test_each_boot_makes_its_own_private_client_key(self):
        first, second = self.root / 'first', self.root / 'second'
        first.mkdir()
        second.mkdir()
        key, public = vm.client_key(first)
        _, other = vm.client_key(second)
        self.assertNotEqual(public, other)
        self.assertTrue(public.startswith('ssh-ed25519 '))
        self.assertEqual(os.stat(key).st_mode & 0o077, 0)

    def test_admission_replaces_the_empty_password_login_with_the_boot_key(self):
        commands = vm.admission('ssh-ed25519 AAAAexample landin-freebsd-lane')
        self.assertIn("printf '%s\\n' 'ssh-ed25519 AAAAexample landin-freebsd-lane'"
                      ' > /root/.ssh/authorized_keys', commands)
        removed = next(c for c in commands if c.startswith("sed -i '' -E"))
        for setting in ('PermitRootLogin', 'PasswordAuthentication', 'PermitEmptyPasswords'):
            self.assertIn(setting, removed)
        added = ' '.join(c for c in commands if '>> /etc/ssh/sshd_config' in c)
        for setting in ("'PermitEmptyPasswords no'", "'PasswordAuthentication no'",
                        "'AuthenticationMethods publickey'", "'PermitRootLogin prohibit-password'"):
            self.assertIn(setting, added)
        self.assertLess(commands.index(removed), commands.index('sshd -t && service sshd restart'))
        # Every framed line fits the guest's canonical input line.
        real = ('ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIGwO9Ma/0gN2Vas3XHyUd5ugh4lETuVModK+qLlwEma'
                ' landin-freebsd-lane')
        self.assertLess(max(len(vm.Console.frame(c)) for c in vm.admission(real)), vm.Console.LINE)

    def test_the_console_admits_the_key_and_returns_the_reported_host_key(self):
        settings = {key: values[0] for key, values in vm.ADMITTED.items()}
        guest, host_key = self.admitted(settings)
        self.assertEqual(host_key, FakeGuestConsole.HOST_KEY)
        self.assertEqual(guest.typed[0], 'root')
        self.assertEqual(len(guest.typed), 1 + len(vm.admission('ssh-ed25519 AAAAexample landin-freebsd-lane')))

    def test_a_guest_still_admitting_empty_passwords_is_refused(self):
        settings = {key: values[0] for key, values in vm.ADMITTED.items()}
        settings['permitemptypasswords'] = 'yes'
        with self.assertRaisesRegex(ValueError, 'still admits more than the boot key'):
            self.admitted(settings)

    def test_a_vm_that_exits_before_admission_is_reported(self):
        self.alive.poll.return_value = 1
        with self.assertRaisesRegex(ValueError, 'VM exited before it was admitted'):
            vm.Console(self.root / 'never.sock', self.alive, vm.time.monotonic() + 30)

    def test_the_guest_forwards_no_port_until_admission(self):
        firmware = self.root / 'code.fd'
        firmware.write_bytes(b'')
        private = self.root / 'private'
        with patch.dict(os.environ, {'LANDIN_FREEBSD_EFI': str(firmware)}):
            argv = vm.qemu_argv('arm64', self.root / 'guest.qcow2', self.root, private)
        self.assertFalse(any('hostfwd' in word for word in argv))
        self.assertIn('user,id=net0', argv)
        console = argv[argv.index('-chardev') + 1]
        self.assertIn('path=' + str(private / 'console.sock'), console)
        self.assertIn('logfile=' + str(self.root / 'console.log'), console)
        self.assertEqual(argv[argv.index('-monitor') + 1],
                         'unix:' + str(private / 'monitor.sock') + ',server=on,wait=off')

    def test_a_forward_counts_only_once_the_monitor_lists_it(self):
        def monitor(table):
            path = self.root / ('monitor-%d.sock' % len(table))
            server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            server.bind(str(path))
            server.listen(1)
            self.addCleanup(server.close)
            asked = []
            def serve():
                connection, _ = server.accept()
                with connection, connection.makefile('rb') as lines:
                    connection.sendall(b'QEMU monitor\r\n(qemu) ')
                    for line in lines:
                        asked.append(line.decode().strip())
                        answer = table if line.startswith(b'info usernet') else b''
                        connection.sendall(line.rstrip() + b'\r\n' + answer + b'(qemu) ')
            threading.Thread(target=serve, daemon=True).start()
            return path, asked
        listed = (b'Hub -1 (net0):\r\n  Protocol[State]    FD  Source Address  Port   Dest. Address  Port RecvQ SendQ\r\n'
                  b'  TCP[HOST_FORWARD]  13       127.0.0.1 40123       10.0.2.15    22     0     0\r\n')
        path, asked = monitor(listed)
        self.assertTrue(vm.forward(path, 40123))
        self.assertEqual(asked, ['hostfwd_add net0 tcp:127.0.0.1:40123-:22', 'info usernet'])
        path, _ = monitor(b"Could not set up host forwarding rule 'tcp:127.0.0.1:40124-:22'\r\n")
        self.assertFalse(vm.forward(path, 40124))


class ExpectedOutput(unittest.TestCase):
    def test_only_declared_output_is_compared(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            (base / 'expected.txt').write_bytes(b'listed\n')
            self.assertEqual(LANE.expected_output({'run_expect': 'expected.txt'}, base), b'listed\n')
            self.assertEqual(LANE.expected_output({'stdout': 'x'}, base), b'x')
            self.assertEqual(LANE.expected_output({'stdout': ''}, base), b'')
            self.assertIsNone(LANE.expected_output({}, base))


if __name__ == '__main__':
    unittest.main()
