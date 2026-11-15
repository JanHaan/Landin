#!/usr/bin/env python3
"""Entry-module staging controls for the native Xtensa fixture runner."""
from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from environments.xtensa.backend import CommandFailed, configuration, description, stage
from environments.xtensa.corpus import capacity_only, compile_advice, selected_image_limit
from environments.xtensa import corpus, remote


class EntrySources(unittest.TestCase):
    def test_capacity_mixed_with_any_other_linker_error_is_not_a_limit(self):
        pure = ("/tools/bin/ld: program.elf section `.bss' will not fit in region `DRAM'\n"
                "/tools/bin/ld: region `DRAM' overflowed by 10 bytes\n"
                "collect2: error: ld returned 1 exit status\n")
        self.assertTrue(capacity_only(pure))
        for error in ('multiple definition of f', 'file format not recognized',
                      'PHDR segment not covered by LOAD segment', 'undefined reference to f',
                      'relocation truncated to fit', 'unrecognized new linker failure'):
            with self.subTest(error=error):
                self.assertFalse(capacity_only(pure + '/tools/bin/ld: ' + error + '\n'))

    def test_a_compiler_defect_is_not_offered_as_a_refusal(self):
        defect = ('refine: internal compiler defect in emission: unsupported'
                  ' Xtensa word operation \t.balign\n')
        said = compile_advice(defect)
        self.assertIn('internal compiler defect', said)
        self.assertIn('compiler fault to fix', said)
        self.assertNotIn('"mode": "refuse"', said)
        refused = compile_advice('error[L0346]: no C ABI\nerror[L0015]: outside\n')
        self.assertIn('"codes": ["L0015", "L0346"]', refused)

    def test_a_frame_past_the_stack_is_a_recorded_limit_and_no_refusal(self):
        said = ('error[L0507]: the frame of `large` does not fit the stack\n'
                '  --> main.ldn:1:1\n')
        advice = compile_advice(said)
        self.assertIn('"profile_limit": "selected-image"', advice)
        self.assertNotIn('"mode": "refuse"', advice)
        with tempfile.TemporaryDirectory() as directory:
            run = SimpleNamespace(out=Path(directory))
            log = run.out / 'compile.log'
            log.write_text(said)
            failed = CommandFailed('compile', log, 'exited 1')
            limited = {'profile_limit': 'selected-image', 'reason': 'a 16 MiB frame'}
            result = selected_image_limit(run, limited, failed, 'esp32', 'sim')
            self.assertEqual((result['verdict'], result['codes'], result['stack_bytes']),
                             ('selected-image-limit', ['L0507'], 8 * 1024 * 1024))
            self.assertIn('frame exceeds the stack reservation', result['boundary'])
            self.assertTrue((run.out / 'selected-image-limit.json').is_file())
            #  Without the recorded limit, with another code beside it, or
            #  with assembly written, it stays a failure.
            self.assertIsNone(selected_image_limit(run, {}, failed, 'esp32', 'sim'))
            log.write_text(said + 'error[L0346]: no C ABI\n')
            self.assertIsNone(selected_image_limit(run, limited, failed, 'esp32', 'sim'))
            log.write_text(said)
            (run.out / 'program.s').write_text('')
            self.assertIsNone(selected_image_limit(run, limited, failed, 'esp32', 'sim'))

    def test_capacity_does_not_hide_assembler_or_undefined_symbol_failures(self):
        with tempfile.TemporaryDirectory() as directory:
            run = SimpleNamespace(out=Path(directory))
            log = run.out / 'link.log'
            row = {'profile_limit': 'selected-image'}
            log.write_text("region `DRAM' overflowed by 10 bytes\nundefined reference to f\n")
            self.assertIsNone(selected_image_limit(run, row, CommandFailed('link', log, 'failed'),
                                                   'esp32', 'sim'))
            log.write_text("region `DRAM' overflowed by 10 bytes\n")
            self.assertIsNone(selected_image_limit(run, row, CommandFailed('assemble', log, 'failed'),
                                                   'esp32', 'sim'))
            self.assertIsNone(selected_image_limit(run, {}, CommandFailed('link', log, 'failed'),
                                                   'esp32', 'sim'))

    def test_sim_is_explicit_virtual_memory_with_the_same_cpu(self):
        for chip in ('esp32', 'esp32s3'):
            native = configuration(chip)
            virtual = configuration(chip, 'sim')
            self.assertEqual(native['evidence_scope'], 'CHIP_MEMORY_MAP')
            self.assertEqual(native['regions']['IRAM']['bytes'], 128 * 1024)
            self.assertEqual(native['stack_bytes'], 16 * 1024)
            self.assertEqual(virtual['evidence_scope'], 'EMULATOR_ONLY')
            self.assertEqual(virtual['qemu_arguments'], ['-M', 'sim', '-cpu', chip, '-m', '64M'])
            self.assertEqual(virtual['cpu_level'], native['cpu_level'])
            self.assertEqual(virtual['regions']['IRAM']['origin'], 0x60000000)
            self.assertEqual(virtual['regions']['DRAM']['origin'], 0x61000000)
            self.assertEqual(virtual['regions']['DRAM']['origin']
                             + virtual['regions']['DRAM']['bytes'], 0x64000000)
            self.assertEqual(virtual['stack_bytes'], 8 * 1024 * 1024)
            self.assertIn('"xtensa-test-sim-' + chip + '"', description(chip, 'sim'))

    def test_explicit_files_keep_order_contents_and_import_roots(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            one, two = root / 'entry/main.ldn', root / 'library/growth.ldn'
            one.parent.mkdir()
            two.parent.mkdir()
            one.write_bytes(b'main: () -> none = end main\n')
            two.write_bytes(b'-- unchanged companion source\n')
            run = SimpleNamespace(out=root / 'run')
            flags = ['--root=/first', '--root=/second']
            arguments = stage(run, [*flags, one, two], 'esp32')
            self.assertEqual(arguments[:2], flags)
            self.assertEqual(arguments[2], '--root=' + str(run.out / 'source'))
            self.assertEqual([Path(p).name for p in arguments[3:]],
                             ['main.ldn', 'growth.ldn', 'xtensa-oracle.ldn'])
            for original, staged in zip((one, two), arguments[3:5]):
                self.assertEqual(Path(staged).read_bytes(), original.read_bytes())

    def test_equal_basename_content_is_accepted_once(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            one, two = root / 'one/main.ldn', root / 'two/main.ldn'
            one.parent.mkdir()
            two.parent.mkdir()
            for source in (one, two):
                source.write_bytes(b'main: () -> none = end main\n')
            arguments = stage(SimpleNamespace(out=root / 'run'), [one, two], 'esp32')
            self.assertEqual([Path(p).name for p in arguments[1:]],
                             ['main.ldn', 'xtensa-oracle.ldn'])

    def test_unequal_basename_content_is_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            one, two = root / 'one/main.ldn', root / 'two/main.ldn'
            one.parent.mkdir()
            two.parent.mkdir()
            one.write_bytes(b'first\n')
            two.write_bytes(b'second\n')
            with self.assertRaisesRegex(RuntimeError, 'basename has unequal contents'):
                stage(SimpleNamespace(out=root / 'run'), [one, two], 'esp32')

    def test_wrapper_collision_is_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / 'xtensa-oracle.ldn'
            source.write_text('main: () -> none = end main\n')
            with self.assertRaisesRegex(RuntimeError, 'basename has unequal contents'):
                stage(SimpleNamespace(out=root / 'run'), [source], 'esp32')


#  A stand-in for QEMU's remote-protocol stub: it accepts the listener it is
#  given, answers what the oracle asks, and on `c` either stops at the
#  firmware's stopped label, runs without stopping, or never runs, as
#  FAKE_QEMU_MODE says: `never`, `second` (never on its first start, then
#  stops), or `hang`.
FAKE_QEMU = r"""
import os, socket, sys
args = sys.argv[1:]
spec = args[args.index('-chardev') + 1]
fd = int(next(part[3:] for part in spec.split(',') if part.startswith('fd=')))
connection, _ = socket.socket(fileno=fd).accept()
state = os.environ['FAKE_QEMU_STATE']
starts = (int(open(state).read()) if os.path.exists(state) else 0) + 1
open(state, 'w').write(str(starts))
mode = os.environ['FAKE_QEMU_MODE']
stops = mode == 'second' and starts == 2
runs = stops or mode == 'hang'
stop = int(os.environ['FAKE_QEMU_STOP'], 16)
registers = [0x40000400] + [0] * 156
memory = {}

def send(text):
    data = text.encode()
    connection.sendall(b'+$' + data + b'#%02x' % (sum(data) & 255))

def packet():
    while True:
        first = connection.recv(1)
        if not first:
            raise SystemExit(0)
        if first == b'\x03':
            return first.decode()
        if first == b'$':
            data = b''
            while (one := connection.recv(1)) != b'#':
                data += one
            connection.recv(2)
            return data.decode()

while True:
    text = packet()
    if text == 'qSupported':
        send('PacketSize=1000')
    elif text == 'g':
        send(''.join(value.to_bytes(4, 'little').hex() for value in registers))
    elif text.startswith('Z0'):
        send('OK')
    elif text.startswith('M'):
        address, rest = text[1:].split(',')
        memory[int(address, 16)] = rest.split(':')[1]
        send('OK')
    elif text.startswith('m'):
        address, length = (int(part, 16) for part in text[1:].split(','))
        send(memory.get(address, '00' * length))
    elif text == 'c':
        if runs:
            registers[0], registers[2] = (stop if stops else 0x40000440), 0x3ffe0000
        if stops:
            send('T05thread:01;')
    elif text == '\x03':
        send('T02thread:01;')
"""


class GuestStarts(unittest.TestCase):
    def observe(self, mode):
        directory = Path(self.enterContext(tempfile.TemporaryDirectory()))
        qemu = directory / 'qemu'
        qemu.write_text('#!' + sys.executable + '\n' + FAKE_QEMU)
        qemu.chmod(0o755)
        output = directory / 'run'
        output.mkdir()
        environment = {'FAKE_QEMU_MODE': mode, 'FAKE_QEMU_STOP': '40000500',
                       'FAKE_QEMU_STATE': str(directory / 'starts')}
        symbols = {'_landin_firmware_stopped': 0x40000500,
                   '_landin_firmware_stack_bottom': 0x3ffc0000}
        from unittest.mock import patch
        with patch.dict('os.environ', environment):
            try:
                return remote.observe(qemu, 'esp32', directory / 'program.elf', symbols,
                                      output, timeout=1), output
            except RuntimeError as error:
                return error, output

    def test_a_guest_that_never_starts_is_started_again_and_then_named(self):
        error, output = self.observe('never')
        self.assertIsInstance(error, RuntimeError)
        self.assertIn('the guest never started: after 1 seconds its PC is still its reset'
                      ' PC 0x40000400', str(error))
        self.assertIn('on each of 2 starts', str(error))
        self.assertNotIn('timed out', str(error))
        for name in ('not-started-1.json', 'not-started-2.json', 'qemu-1.log', 'qemu-2.log'):
            self.assertTrue((output / name).is_file(), name)
        self.assertFalse((output / 'timeout-remote.json').exists())

    def test_a_guest_that_starts_the_second_time_records_its_starts(self):
        result, output = self.observe('second')
        self.assertIsInstance(result, dict)
        self.assertEqual((result['starts'], result['stop_pc']), (2, 0x40000500))
        self.assertTrue((output / 'not-started-1.json').is_file())

    def test_a_guest_that_ran_and_did_not_stop_timed_out(self):
        error, output = self.observe('hang')
        self.assertIsInstance(error, RuntimeError)
        self.assertIn('guest timed out: it ran 1 seconds without stopping', str(error))
        self.assertTrue((output / 'timeout-remote.json').is_file())
        self.assertFalse((output / 'not-started-1.json').exists())

    def test_only_the_pc_and_address_registers_are_judged(self):
        initial = (0x40000400).to_bytes(4, 'little').hex() + '00' * 4 * 156
        self.assertTrue(remote.unstarted(initial, initial))
        #  A special register past ar63 may move while nothing runs.
        later = initial[:65 * 8] + 'ff' * 4 + initial[66 * 8:]
        self.assertTrue(remote.unstarted(initial, later))
        moved = (0x40000404).to_bytes(4, 'little').hex() + initial[8:]
        self.assertFalse(remote.unstarted(initial, moved))
        self.assertFalse(remote.unstarted(None, initial))


class CorpusOptions(unittest.TestCase):
    def main(self, *arguments, **patches):
        from unittest.mock import patch
        tools = SimpleNamespace(root=patches.pop('root', None), qemu=Path('/q'),
                                finish=lambda output: None)
        called = {}

        def record(name):
            return lambda *args, **kwargs: called.update({name: (args, kwargs)}) or {
                'status': 'passed'}
        with patch.object(corpus, 'Tools', return_value=tools), \
                patch.object(corpus, 'execute_inventory', side_effect=record('inventory')), \
                patch.object(corpus, 'observe_programs', side_effect=record('programs')), \
                patch.object(sys, 'argv', ['corpus.py', '--refine', '/r', '--output', '/o',
                                           '--chip', 'esp32', *arguments]):
            return corpus.main(), called

    def test_an_unlocked_whole_corpus_runs_and_is_not_complete(self):
        status, called = self.main('--all', '--qemu', '/q')
        self.assertEqual(status, 0)
        args, kwargs = called['inventory']
        self.assertEqual(kwargs, {'locked': False})
        self.assertEqual(args[-1], 'sim')
        self.assertEqual(corpus.scope_of([], [], False)[0], 'UNLOCKED')
        self.assertIn('not COMPLETE', corpus.scope_of([], [], False)[1])
        self.assertEqual(corpus.scope_of([], [], True)[0], 'COMPLETE')
        label, said = corpus.scope_of(['runtime/x'], ['none-off'], False)
        self.assertEqual(label, 'FILTERED')
        self.assertIn('--fixture runtime/x, --profile none-off, with tools no --tools lock',
                      said)

    def test_a_locked_run_is_locked_and_defaults_to_the_gates_profile(self):
        _, called = self.main('--all', '--tools', '/t', root=Path('/t'))
        args, kwargs = called['inventory']
        self.assertEqual((args[-1], kwargs), ('sim', {'locked': True}))

    def test_a_program_of_ones_own_runs_apart_from_the_corpus(self):
        _, called = self.main('--program', '/p/one.ldn', '--root', '/lib', '--qemu', '/q',
                              '--profile', 'none/off', '--memory-profile', 'chip')
        args, _ = called['programs']
        self.assertEqual(args[3:], ('esp32', [Path('/p/one.ldn')], ['none/off'], 'chip',
                                    ['/lib']))
        self.assertNotIn('inventory', called)

    def test_options_that_cannot_go_together_are_refused(self):
        from contextlib import redirect_stderr
        import io
        for arguments, said in (
                (('--program', '/p.ldn', '--all'), '--program runs programs of your own'),
                (('--program', '/p.ldn', '--fixture', 'runtime/x'), '--fixture and --all'),
                (('--root', '/lib', '--all'), '--root is a module root for --program'),
                ((), 'select exact --fixture names, request --all, or run --program')):
            with self.subTest(arguments=arguments):
                stream = io.StringIO()
                with redirect_stderr(stream), self.assertRaises(SystemExit) as refused:
                    self.main(*arguments)
                self.assertEqual(refused.exception.code, 2)
                self.assertIn(said, stream.getvalue())

    def test_a_capacity_failure_names_its_profile_and_the_gates(self):
        log = ("/t/ld: program.elf section `.text' will not fit in region `IRAM'\n"
               "/t/ld: region `IRAM' overflowed by 190000 bytes\n"
               "collect2: error: ld returned 1 exit status\n")
        self.assertEqual(corpus.capacity_advice(log, 'chip'),
                         "; the image does not fit the chip memory profile's map: it"
                         " overflows IRAM by 190000 bytes; the gate's corpus runs"
                         " --memory-profile=sim")
        self.assertNotIn('the gate', corpus.capacity_advice(log, 'sim'))
        self.assertEqual(corpus.capacity_advice(log + '/t/ld: undefined reference to f\n',
                                                'chip'), '')

    def test_a_programs_run_says_what_it_returned_or_where_it_trapped(self):
        self.assertEqual(corpus.describe_run({'_landin_firmware_trap_count': 0,
                                              '_landin_xtensa_fixture_status': 42}),
                         'returned 42')
        self.assertEqual(corpus.describe_run({'_landin_firmware_trap_count': 0,
                                              '_landin_xtensa_fixture_status': 0xffffffff}),
                         'returned -1')
        self.assertEqual(corpus.describe_run({
            '_landin_firmware_trap_count': 1, '_landin_firmware_trap_cause': 0,
            '_landin_firmware_trap_pc': 0x60000e19, 'trap_instruction': '000000'}),
            'trapped: cause 0 at 0x60000e19, an ILL trap')


if __name__ == '__main__':
    unittest.main()
