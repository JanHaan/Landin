#!/usr/bin/env python3
"""Controls for the shared board tooling, without a board, a probe or a hub
(D646): every part environments/boards/common.py gives a board's tool, held
to fixed inputs on the standard library alone."""
import argparse
import contextlib
import importlib.util
import io
import json
import os
import select
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'environments/boards'))
SPEC = importlib.util.spec_from_file_location('common', ROOT / 'environments/boards/common.py')
COMMON = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(COMMON)

#  Seconds to wait for bytes that are coming.  A wait ends as soon as they
#  arrive, so the margin costs nothing on an idle host, and it is wide
#  because scripts/script_tests.py's own workers load the host this runs on.
PATIENCE = 60


def read_exactly(source, count):
    """COUNT bytes from SOURCE, a descriptor or a socket, however many
    reads they take to arrive, or what came before PATIENCE ran out.

    One read of a pty or a socket returns what has arrived, which on a
    loaded host was b'S' of b'S1'; the rest is waited for rather than
    missed.
    """
    got = b''
    deadline = time.monotonic() + PATIENCE
    while len(got) < count:
        left = deadline - time.monotonic()
        if left <= 0 or not select.select([source], [], [], left)[0]:
            break
        if isinstance(source, int):
            piece = os.read(source, count - len(got))
        else:
            piece = source.recv(count - len(got))
        if not piece:
            break
        got += piece
    return got


class Recorded:
    """A tool's commands as the shared code sees them: every call kept, and
    the answer each name is given."""
    def __init__(self, **answers):
        self.answers, self.calls = answers, []

    def command(self, name, argv, **_):
        self.calls.append((name, [str(a) for a in argv]))
        return self.answers.get(name, '')


def elf32(sections, segments):
    """A little-endian ELF32 with SECTIONS, [(name, address, bytes)], and
    program headers SEGMENTS, [(physical address, section name)]."""
    names = b'\0' + b''.join(n.encode() + b'\0' for n, _, _ in sections) + b'.shstrtab\0'
    body, placed, at = bytearray(), {}, 52 + 32 * len(segments)
    for name, address, data in sections:
        placed[name] = (at + len(body), address, len(data))
        body += data
    strings = at + len(body)
    body += names
    shoff = at + len(body)
    header = bytearray(b'\x7fELF\x01\x01\x01' + bytes(9))
    header += struct.pack('<HHIIIIIHHHHHH', 2, 40, 1, 0, 52, shoff, 0, 52, 32,
                          len(segments), 40, len(sections) + 2, len(sections) + 1)
    programs = b''.join(struct.pack('<8I', 1, placed[n][0], placed[n][1], paddr,
                                    placed[n][2], placed[n][2], 5, 4)
                        for paddr, n in segments)
    table = bytes(40)
    offset = 1
    for name, address, data in sections:
        table += struct.pack('<10I', offset, 1, 2, address, placed[name][0], len(data),
                             0, 0, 4, 0)
        offset += len(name) + 1
    table += struct.pack('<10I', offset, 3, 0, 0, strings, len(names), 0, 0, 1, 0)
    return bytes(header) + programs + bytes(body) + table


def symbol_elf(symbols=None):
    """An ELF symbol table independently assembled beside a writable datum."""
    symbols = symbols if symbols is not None else [(COMMON.FIXED_READY_SYMBOL, 0x20000000, 4, 0x11, 1)]
    names = b'\0' + b''.join(name.encode() + b'\0' for name, *_ in symbols)
    entries, at = bytearray(bytes(16)), 1
    for name, address, size, info, section in symbols:
        entries += struct.pack('<IIIBBH', at, address, size, info, 0, section)
        at += len(name.encode()) + 1
    result = bytearray(elf32([('.data', 0x20000000, bytes(4)),
                             ('.strtab', 0, names), ('.symtab', 0, entries)],
                            [(0x10001000, '.data')]))
    shoff = struct.unpack_from('<I', result, 32)[0]
    struct.pack_into('<I', result, shoff + 40 + 8, 3)  # data is SHF_ALLOC|WRITE
    struct.pack_into('<I', result, shoff + 80 + 4, 3)  # string table
    struct.pack_into('<I', result, shoff + 120 + 4, 2)  # symbol table
    struct.pack_into('<I', result, shoff + 120 + 24, 2) # linked string table
    struct.pack_into('<I', result, shoff + 120 + 36, 16)
    return bytes(result)


STATUS = """Current status for hub 7-2.3 [0bda:5411 Generic USB2.1 Hub, USB 2.10, 4 ports, ppps]
  Port 1: 0100 power
  Port 2: 0103 power enable connect [0483:374e STMicroelectronics STLINK-V3 001900293137511339383538]
  Port 3: 0100 power
  Port 4: 0503 power highspeed enable connect [0403:6010 Digilent Digilent USB Device 210319B3E738]
"""


class ROMLog(unittest.TestCase):
    def test_loads_require_complete_decimal_or_hexadecimal_lines(self):
        text = ('load:0x40378000,len:1028\r\n'
                'load:0x40378404,len:0xac40\n')
        self.assertEqual(COMMON.rom_log(text)['loads'],
                         [(0x40378000, 1028), (0x40378404, 44096)])
        for damaged in ('0', '0x', '0x1z\n', '24garbage\r\n', '0\xf8\xff'):
            with self.subTest(damaged=damaged):
                self.assertEqual(COMMON.rom_log(
                    text + 'load:0x3fca8000,len:' + damaged)['loads'],
                    [(0x40378000, 1028), (0x40378404, 44096)])

    def test_entry_requires_its_complete_line(self):
        for suffix in ('', 'garbage\n'):
            self.assertIsNone(COMMON.rom_log('entry 0x40378400' + suffix)['entry'])
        self.assertEqual(COMMON.rom_log('entry 0x40378400\r\n')['entry'], 0x40378400)


class Framing(unittest.TestCase):
    def test_frames_are_found_between_echoed_bytes(self):
        stream = b'ab\x02t h=0000000a g=00000004\x03\ncd\x02b r=00000100\x03\n'
        found, echo = COMMON.frames(stream)
        self.assertEqual(found, [('t', {'h': 10, 'g': 4}), ('b', {'r': 0x100})])
        self.assertEqual(echo, b'abcd')

    def test_a_frame_without_its_line_feed_still_ends_at_etx(self):
        self.assertEqual(COMMON.frames(b'\x02f a=00000001\x03x'),
                         ([('f', {'a': 1})], b'x'))

    def test_a_frame_still_arriving_is_left_out(self):
        stream = b'ab\x02t h=0000000a\x03\ncd\x02t h=000'
        self.assertEqual(COMMON.frames_safe(stream), [('t', {'h': 10})])
        self.assertEqual(COMMON.echo_of(stream), b'abcd')
        self.assertEqual(COMMON.tagged(stream, 't'), [{'h': 10}])

    def test_an_echo_s_gaps_are_where_it_leaves_the_sent_bytes(self):
        sent = bytes(range(40, 120))
        echo = sent[:5] + sent[15:30] + sent[31:]
        self.assertEqual(COMMON.gaps(sent, echo), [(5, 10), (30, 1)])
        self.assertEqual(COMMON.gaps(sent, sent), [])
        self.assertEqual(COMMON.gaps(sent, sent[:3] + b'\x00' * 9), [(3, None)])

    def test_a_result_writes_each_field_as_eight_digits(self):
        self.assertEqual(COMMON.frame_record(b'\x02b r=00fa0000 v=08000000\x03\n'),
                         [dict(tag='b', r='00fa0000', v='08000000')])

    def test_asking_sends_the_command_and_waits_for_its_frame(self):
        class Line:
            def __init__(self):
                self.sent, self.received = bytearray(), b'\x02t h=00000001\x03\n'

            def send(self, data):
                self.sent += data
                self.received += b'\x02t h=00000002\x03\n'

            def wait(self, predicate, seconds, what):
                if not predicate(self.received):
                    raise COMMON.Failed(what)
                return self.received
        line = Line()
        self.assertEqual(COMMON.ask(line, 0x11, 't', 1), {'h': 2})
        self.assertEqual(bytes(line.sent), b'\x11')


class Commands(unittest.TestCase):
    def test_each_command_is_logged_with_its_status(self):
        with tempfile.TemporaryDirectory() as out:
            run = COMMON.Run(Path(out))
            self.assertEqual(run.command('say', [sys.executable, '-c', 'print("hi")']), 'hi\n')
            with self.assertRaises(COMMON.Failed):
                run.command('fail', [sys.executable, '-c', 'raise SystemExit(3)'])
            run.command('tolerated', [sys.executable, '-c', 'raise SystemExit(4)'], check=False)
            self.assertEqual([(c['name'], c['status']) for c in run.commands],
                             [('say', 0), ('fail', 3), ('tolerated', 4)])
            self.assertEqual([c['log'] for c in run.commands],
                             ['say.log', 'fail.log', 'tolerated.log'])
            self.assertTrue((Path(out) / 'say.log').read_text().endswith('hi\n'))

    def test_failed_flash_and_restoration_keep_distinct_logs_and_failure_links(self):
        with tempfile.TemporaryDirectory() as out:
            root = Path(out)
            run = COMMON.Run(root)
            failures = []
            for status, message in ((3, 'initial flash stderr'), (4, 'restore stderr')):
                with self.assertRaises(COMMON.Failed) as raised:
                    run.command('flash', [sys.executable, '-c',
                        'import sys; print(%r, file=sys.stderr); raise SystemExit(%d)'
                        % (message, status)])
                failures.append(str(raised.exception))
            self.assertEqual(run.command('flash', [sys.executable, '-c', 'print("restored")']),
                             'restored\n')
            self.assertEqual([(c['name'], c['status'], c['log']) for c in run.commands],
                             [('flash', 3, 'flash.log'), ('flash', 4, 'flash-2.log'),
                              ('flash', 0, 'flash-3.log')])
            for index, message in enumerate(('initial flash stderr', 'restore stderr', 'restored')):
                path = root / run.commands[index]['log']
                self.assertTrue(path.read_text().endswith(message + '\n'))
                if index < 2:
                    self.assertEqual(failures[index], 'flash failed (%d); see %s'
                                     % (index + 3, path))
            self.assertNotIn('restore stderr', (root / 'flash.log').read_text())

    def test_existing_logs_and_suffix_collisions_are_never_overwritten(self):
        with tempfile.TemporaryDirectory() as out:
            root = Path(out)
            (root / 'flash.log').write_text('previous attempt')
            (root / 'flash-2.log').write_text('previous recovery')
            first, second = COMMON.Run(root), COMMON.Run(root)
            first.command('flash', [sys.executable, '-c', 'print("first")'])
            second.command('flash', [sys.executable, '-c', 'print("second")'])
            second.command('flash-3', [sys.executable, '-c', 'print("suffix")'])
            self.assertEqual(first.commands[0]['log'], 'flash-3.log')
            self.assertEqual([c['log'] for c in second.commands],
                             ['flash-4.log', 'flash-3-2.log'])
            self.assertEqual((root / 'flash.log').read_text(), 'previous attempt')
            self.assertEqual((root / 'flash-2.log').read_text(), 'previous recovery')
            for record, message in ((first.commands[0], 'first'),
                                    (second.commands[0], 'second'),
                                    (second.commands[1], 'suffix')):
                self.assertTrue((root / record['log']).read_text().endswith(message + '\n'))

    def test_launch_and_timeout_errors_keep_their_log_and_exception_semantics(self):
        with tempfile.TemporaryDirectory() as out:
            root = Path(out)
            run = COMMON.Run(root)
            errors = (COMMON.subprocess.TimeoutExpired(['tool'], 120,
                          output=b'partial stdout\n', stderr=b'partial stderr\n'),
                      FileNotFoundError('missing executable'))
            for error in errors:
                with mock.patch.object(COMMON.subprocess, 'run', side_effect=error), \
                        self.assertRaises(type(error)) as raised:
                    run.command('flash', ['tool'])
                self.assertIs(raised.exception, error)
            self.assertEqual([c['log'] for c in run.commands], ['flash.log', 'flash-2.log'])
            self.assertTrue(all(c['status'] is None for c in run.commands))
            self.assertIn('partial stdout\npartial stderr\n', (root / 'flash.log').read_text())
            for record, error in zip(run.commands, errors):
                self.assertEqual(record['error'], str(error))
                self.assertIn(str(error), (root / record['log']).read_text())


class Images(unittest.TestCase):
    def test_sections_and_loaded_bytes_come_from_the_headers(self):
        vectors = struct.pack('<4I', 0x24080000, 0x08000101, 0, 0x08000201)
        data = struct.pack('<2I', 7, 9)
        image = elf32([('.isr_vector', 0x08000000, vectors), ('.data', 0x24000000, data)],
                      [(0x08000000, '.isr_vector'), (0x08000010, '.data')])
        with tempfile.TemporaryDirectory() as out:
            path = Path(out) / 'board.elf'
            path.write_bytes(image)
            raw, sections = COMMON.elf_sections(path)
            address, offset, size = sections['.isr_vector']
            self.assertEqual((address, size), (0x08000000, 16))
            self.assertEqual(raw[offset:offset + size], vectors)
            self.assertEqual(sections['.data'][0], 0x24000000)
            # A programmer writes .data's initial image at its load address.
            self.assertEqual(COMMON.loaded(path, 0x08000004, 4), vectors[4:8])
            self.assertEqual(COMMON.loaded(path, 0x08000010, 8), data)
            with self.assertRaises(COMMON.Failed):
                COMMON.loaded(path, 0x08000014, 8)
            path.write_bytes(b'\x7fELF\x02' + image[5:])
            with self.assertRaises(COMMON.Failed):
                COMMON.elf_sections(path)

    def test_nm_s_listing_names_addresses(self):
        listing = '24000000 B handled\n         U __aeabi_fadd\n08000101 t start\n'
        self.assertEqual(COMMON.parse_nm(listing), {'handled': 0x24000000, 'start': 0x08000101})


class ResidentReadiness(unittest.TestCase):
    def test_symbol_address_comes_from_the_elf_without_nm(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'fixed.elf'
            path.write_bytes(symbol_elf())
            self.assertEqual(COMMON.elf_symbols(path), {COMMON.FIXED_READY_SYMBOL: 0x20000000})
            probe = mock.Mock()
            probe.read_words.return_value = [COMMON.FIXED_READY_MAGIC]
            proof = COMMON.read_fixed_marker(probe, path)
            probe.read_words.assert_called_once_with('resident-ready', 0x20000000, 1)
            self.assertEqual(proof, dict(symbol=COMMON.FIXED_READY_SYMBOL, address=0x20000000,
                                         value=COMMON.FIXED_READY_MAGIC, elf_sha256=COMMON.sha(path)))
            probe.read_words.return_value = [0]
            with self.assertRaisesRegex(COMMON.Failed, 'did not reach its park loop'):
                COMMON.read_fixed_marker(probe, path)

    def test_repeated_local_mapping_names_do_not_hide_the_global_marker(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'fixed.elf'
            path.write_bytes(symbol_elf([
                (COMMON.FIXED_READY_SYMBOL, 0x20000000, 4, 0x11, 1),
                ('$d', 0x10000100, 0, 0, 1), ('$d', 0x10000200, 0, 0, 1)]))
            self.assertEqual(COMMON.elf_symbols(path), {COMMON.FIXED_READY_SYMBOL: 0x20000000})

    def test_bad_tables_and_marker_definitions_fail_before_a_probe_read(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'fixed.elf'
            bad_table = bytearray(symbol_elf())
            struct.pack_into('<I', bad_table, 32, len(bad_table) - 3)
            cases = [b'\x7fELF', bytes(bad_table), symbol_elf([]),
                     symbol_elf([(COMMON.FIXED_READY_SYMBOL, 0x20000000, 8, 0x11, 1)]),
                     symbol_elf([(COMMON.FIXED_READY_SYMBOL, 0x20000000, 4, 0x12, 1)]),
                     symbol_elf([(COMMON.FIXED_READY_SYMBOL, 0x10000000, 4, 0x11, 1)]),
                     symbol_elf([(COMMON.FIXED_READY_SYMBOL, 0x20000000, 4, 0x11, 1),
                                 (COMMON.FIXED_READY_SYMBOL, 0x20000004, 4, 0x11, 1)])]
            for data in cases:
                with self.subTest(length=len(data)):
                    path.write_bytes(data)
                    probe = mock.Mock()
                    with self.assertRaises(COMMON.Failed):
                        COMMON.read_fixed_marker(probe, path)
                    probe.read_words.assert_not_called()

    def test_each_swd_restore_reads_readiness_after_the_cold_cycle(self):
        for board in ('rp2040', 'rp2350', 'rp2350_hazard3', 'stm32h753'):
            with self.subTest(board=board):
                spec = importlib.util.spec_from_file_location('resident_' + board,
                    ROOT / 'environments/boards' / board / 'board.py')
                module = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(module)
                events = []
                sections = {'.boot2': (0x10000000, 0, 256),
                            '.isr_vector': (0x08000000, 0, 64),
                            '.embedded_block': (0x10000110, 0, 20)}
                args = SimpleNamespace(fixed_image=Path('fixed.elf'), hub_group=None,
                                       hub='hub', hub_seconds=1, port=2)
                factory = 'running' if board == 'rp2350_hazard3' else 'probe'
                proof = dict(value=COMMON.FIXED_READY_MAGIC)
                with mock.patch.object(module.common, 'elf_sections', return_value=(bytes(256), sections)), \
                        mock.patch.object(module.common, 'loaded', return_value=bytes(64)), \
                        mock.patch.object(module.common, 'InGroup'), \
                        mock.patch.object(module.common, 'fixed_elf', return_value=Path('fixed.elf')), \
                        mock.patch.object(module.common, 'read_fixed_marker',
                            side_effect=lambda *_: events.append('marker') or proof), \
                        mock.patch.object(module, factory), \
                        mock.patch.object(module, 'flash', side_effect=lambda *_: events.append('flash')), \
                        mock.patch.object(module, 'power_cycle', side_effect=lambda *_: events.append('cold')), \
                        mock.patch.object(module.common, 'listing'), \
                        mock.patch.object(module.common, 'port_device', return_value=None):
                    if hasattr(module, 'pico2'):
                        with mock.patch.object(module.pico2, 'refuse_bootsel'):
                            self.assertEqual(module.restore_fixed(mock.Mock(), args), proof)
                    else:
                        self.assertEqual(module.restore_fixed(mock.Mock(), args), proof)
                self.assertEqual(events, ['flash', 'cold', 'marker'])

    def test_successful_restoration_retains_proof_and_missing_proof_is_pending(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'fixed.elf'
            path.write_bytes(symbol_elf())
            args = SimpleNamespace(mode='boot', pace=mock.Mock(), fixed_image=path)
            proof = dict(value=COMMON.FIXED_READY_MAGIC, address=0x20000000)
            result = dict(status='passed')
            COMMON.finish_boot(args, result, lambda: proof)
            self.assertEqual(result['fixed_restore']['marker'], proof)
            self.assertEqual(result['fixed_restore']['status'], 'passed')
            COMMON.finish_boot(args, result, lambda: None)
            self.assertEqual(result['fixed_restore']['status'], 'pending')
            self.assertEqual(result['status'], 'failed')


class HelperIdentity(unittest.TestCase):
    def identity(self):
        return dict(protocol_version=1,
            source_sha256=COMMON.sha(ROOT / 'environments/boards/ram-run/main.rs'),
            probe_rs_revision=COMMON.HELPER_PROBE_REVISION)

    def test_matching_helper_is_described_without_a_probe_or_plan(self):
        args = SimpleNamespace(ram_loader=Path('/helper with spaces'))
        reply = SimpleNamespace(returncode=0, stdout=json.dumps(self.identity()), stderr='')
        with mock.patch.object(COMMON.subprocess, 'run', return_value=reply) as describe:
            self.assertEqual(COMMON.verify_ram_helper(args), self.identity())
        describe.assert_called_once_with(['/helper with spaces', '--describe'],
            capture_output=True, text=True, timeout=10)
        self.assertEqual(args.helper_identity, self.identity())
        self.assertEqual(args.helper_source_sha256, self.identity()['source_sha256'])

    def test_stale_and_malformed_helpers_name_the_rebuild_command(self):
        valid = self.identity()
        for broken in ('not JSON', '[]', json.dumps(dict(valid, protocol_version=True)),
                json.dumps(dict(valid, source_sha256='old source')),
                json.dumps(dict(valid, probe_rs_revision='another fork'))):
            with self.subTest(metadata=broken), \
                    mock.patch.object(COMMON.subprocess, 'run', return_value=SimpleNamespace(
                        returncode=0, stdout=broken, stderr='')):
                with self.assertRaisesRegex(COMMON.Failed, r'nix build .*board-ram-run'):
                    COMMON.verify_ram_helper(SimpleNamespace(ram_loader='loader'))

    def test_missing_timed_out_and_failed_describe_are_clear_preflight_failures(self):
        for error in (FileNotFoundError('missing helper'),
                      COMMON.subprocess.TimeoutExpired('loader', 10)):
            with self.subTest(error=error), mock.patch.object(COMMON.subprocess, 'run', side_effect=error):
                with self.assertRaisesRegex(COMMON.Failed, 'cannot describe SRAM helper.*rebuild'):
                    COMMON.verify_ram_helper(SimpleNamespace(ram_loader='loader'))
        reply = SimpleNamespace(returncode=2, stdout='', stderr='unknown option --describe')
        with mock.patch.object(COMMON.subprocess, 'run', return_value=reply), \
                self.assertRaisesRegex(COMMON.Failed, 'unknown option.*rebuild'):
            COMMON.verify_ram_helper(SimpleNamespace(ram_loader='loader'))

    def test_preflight_verifies_every_ram_and_rp_boot_helper_after_flag_validation(self):
        reply = SimpleNamespace(returncode=0, stdout=json.dumps(self.identity()), stderr='')
        with tempfile.TemporaryDirectory() as tmp:
            fixed = Path(tmp) / 'fixed.elf'
            fixed.write_bytes(b'fixed')
            for mode in ('ram', 'boot'):
                for board in ('rp2040', 'rp2350', 'rp2350_hazard3', 'stm32h753', 'esp32c3', 'esp32c5'):
                    args = SimpleNamespace(mode=mode, ram_loader='loader', bundle=None,
                        refine='refine', fixed_image=fixed, record=None)
                    with self.subTest(mode=mode, board=board), \
                            mock.patch.object(COMMON.subprocess, 'run', return_value=reply) as describe, \
                            mock.patch.object(COMMON, 'validate_fixed_image'), \
                            mock.patch.object(COMMON, 'fixed_elf', return_value=fixed), \
                            mock.patch.object(COMMON, 'fixed_marker_address'):
                        COMMON.board_preflight(args, board)
                        self.assertEqual(describe.call_count, int(mode == 'ram' or board.startswith('rp')))
            args = SimpleNamespace(mode='ram', ram_loader='loader', bundle=None,
                                   refine='refine', recover=True)
            with mock.patch.object(COMMON.subprocess, 'run') as describe:
                with self.assertRaisesRegex(COMMON.Failed, 'require --mode=boot'):
                    COMMON.board_preflight(args, 'rp2040')
                describe.assert_not_called()


class ProbeRegrouping(unittest.TestCase):
    """A probe command refused for permissions is asked again: udev
    regroups a unit's new node after its hub lists it."""

    def refusing(self, directory, refusals, then):
        script = Path(directory) / 'probe'
        script.write_text('#!/bin/sh\n'
                          'count=$(cat "$0.count" 2>/dev/null || echo 0)\n'
                          'echo $((count + 1)) > "$0.count"\n'
                          'if [ "$count" -lt %d ]; then\n'
                          '  echo "Error: open probe" >&2\n'
                          '  echo "    2: permission denied (errno 13)" >&2\n'
                          '  exit 1\n'
                          'fi\n%s\n' % (refusals, then))
        script.chmod(0o755)
        return script

    def test_a_refused_open_is_repeated_and_each_attempt_keeps_its_log(self):
        with tempfile.TemporaryDirectory() as directory:
            run = COMMON.Run(Path(directory))
            script = self.refusing(directory, 2, 'echo words')
            with mock.patch.object(COMMON, 'PROBE_REGROUP_INTERVAL', 0):
                self.assertEqual(COMMON.probe_command(run, 'read', [script]), 'words\n')
            self.assertEqual([c['status'] for c in run.commands], [1, 1, 0])
            self.assertEqual([c['log'] for c in run.commands],
                             ['read.log', 'read-2.log', 'read-3.log'])

    def test_another_failure_is_not_repeated(self):
        with tempfile.TemporaryDirectory() as directory:
            run = COMMON.Run(Path(directory))
            script = self.refusing(directory, 0, 'echo "Error: no chip" >&2; exit 1')
            with self.assertRaises(COMMON.Failed):
                COMMON.probe_command(run, 'read', [script])
            self.assertEqual(len(run.commands), 1)

    def test_a_node_refused_past_the_wait_fails_as_the_command_does(self):
        with tempfile.TemporaryDirectory() as directory:
            run = COMMON.Run(Path(directory))
            script = self.refusing(directory, 1000, 'echo words')
            with mock.patch.object(COMMON, 'PROBE_REGROUP_INTERVAL', 0), \
                    mock.patch.object(COMMON, 'PROBE_REGROUP_SECONDS', 0):
                with self.assertRaisesRegex(COMMON.Failed, r'read failed \(1\)'):
                    COMMON.probe_command(run, 'read', [script])
            self.assertEqual(len(run.commands), 1)


class Probes(unittest.TestCase):
    def test_xtensa_boot_reads_observe_cpu1_but_ram_reads_require_stall_proof(self):
        for board in ('esp32', 'esp32s3'):
            with self.subTest(board=board), tempfile.TemporaryDirectory() as tmp:
                out = Path(tmp)
                state = dict(cpu1_stalled=False, stall_code=0, options_value=0, stall_value=0)
                report = dict(format_version=1, status='passed', mode='boot-read', board=board,
                              address=0x60008034, count=1, words=[1], flash_written=False,
                              helper_source_sha256=COMMON.helper_source_hash(),
                              cpu1_stalled=False, other_core=state)
                run = mock.Mock(out=out, pace=None)
                def command(name, argv, **kwargs):
                    request = json.loads((out / 'cause-plan.json').read_text())
                    self.assertIn(request['mode'], ('read', 'boot-read'))
                    self.assertEqual(request.get('require_cpu1_stalled', False),
                                     request['mode'] == 'read')
                    (out / 'cause.json').write_text(json.dumps(report))
                run.command.side_effect = command
                boot = COMMON.Probe(run, 'probe-rs', board, 'P', ram_loader='loader',
                                    read_mode='boot-read')
                self.assertEqual(boot.read_words('cause', 0x60008034, 1), [1])
                report['cpu1_stalled'] = True
                with self.assertRaisesRegex(COMMON.Failed, 'observed CPU1 stall state'):
                    boot.read_words('cause', 0x60008034, 1)
                report['cpu1_stalled'] = False
                state['stall_code'] = 0x86
                with self.assertRaisesRegex(COMMON.Failed, 'observed CPU1 stall state'):
                    boot.read_words('cause', 0x60008034, 1)
                state.update(cpu1_stalled=True, options_value=2, stall_value=0x21 << 20)
                report['cpu1_stalled'] = True
                self.assertEqual(boot.read_words('cause', 0x60008034, 1), [1])
                with self.assertRaisesRegex(COMMON.Failed, 'retained CPU1 stall evidence'):
                    COMMON.Probe(run, 'probe-rs', board, 'P', ram_loader='loader')
                ram = COMMON.Probe(run, 'probe-rs', board, 'P', ram_loader='loader',
                                   require_cpu1_stalled=True)
                with self.assertRaisesRegex(COMMON.Failed, 'mismatched evidence'):
                    ram.read_words('cause', 0x60008034, 1)
                report['mode'] = 'read'
                self.assertEqual(ram.read_words('cause', 0x60008034, 1), [1])
                report['cpu1_stalled'] = False
                with self.assertRaisesRegex(COMMON.Failed, 'CPU1 remains stalled'):
                    ram.read_words('cause', 0x60008034, 1)
        for chip in ('RP2040', 'RP235x_riscv', 'ESP32-C3', 'ESP32-C5', 'STM32H753ZITx'):
            with self.assertRaisesRegex(COMMON.Failed, 'only for Xtensa'):
                COMMON.Probe(mock.Mock(), 'probe-rs', chip, 'P', read_mode='boot-read')

    def test_rp_reads_use_one_core_and_reject_mismatched_evidence(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            report = dict(format_version=1, status='passed', mode='read', board='rp2350',
                          address=0x20000000, count=2, words=[42, 7], flash_written=False,
                          helper_source_sha256=COMMON.helper_source_hash())
            run = mock.Mock(out=out, pace=mock.Mock())
            def command(name, argv, **kwargs):
                self.assertEqual(argv[0], 'loader')
                plan = json.loads((out / 'cells-plan.json').read_text())
                self.assertEqual(plan['mode'], 'read')
                self.assertEqual(plan['board'], 'rp2350')
                self.assertNotIn('require_hart1_halted', plan)
                (out / 'cells.json').write_text(json.dumps(report))
            run.command.side_effect = command
            probe = COMMON.Probe(run, 'probe-rs', 'RP235x', 'P', ram_loader='loader')
            self.assertEqual(probe.read_words('cells', 0x20000000, 2), [42, 7])
            self.assertEqual(run.pace.before.call_args_list,
                             [mock.call('probe read'), mock.call('probe read completion')])
            for field, value in (('board', 'rp2040'), ('address', 0x20000004),
                                 ('helper_source_sha256', 'stale'),
                                 ('flash_written', True), ('count', 1),
                                 ('words', [True, 7]), ('words', [-1, 7])):
                original = report[field]
                report[field] = value
                with self.assertRaises(COMMON.Failed):
                    probe.read_words('cells', 0x20000000, 2)
                report[field] = original
            with self.assertRaisesRegex(COMMON.Failed, '--ram-loader'):
                COMMON.Probe(run, 'probe-rs', 'RP235x', 'P').read_words('cells', 0x20000000, 2)

    def test_hazard3_ram_readback_requires_explicit_halted_hart_evidence(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            report = dict(format_version=1, status='passed', mode='read', board='rp2350_hazard3',
                          address=0x20000000, count=1, words=[42], flash_written=False,
                          helper_source_sha256=COMMON.helper_source_hash(), hart1_halted=True)
            run = mock.Mock(out=out, pace=None)
            def command(name, argv, **kwargs):
                request = json.loads((out / 'cells-plan.json').read_text())
                self.assertIs(request['require_hart1_halted'], True)
                self.assertEqual(request['board'], 'rp2350_hazard3')
                (out / 'cells.json').write_text(json.dumps(report))
            run.command.side_effect = command
            probe = COMMON.Probe(run, 'probe-rs', 'RP235x_riscv', 'P', ram_loader='loader',
                                 require_hart1_halted=True)
            self.assertEqual(probe.read_words('cells', 0x20000000, 1), [42])
            for value in (False, None, 0, 1, 'true', [], {}):
                with self.subTest(evidence=value):
                    report['hart1_halted'] = value
                    with self.assertRaisesRegex(COMMON.Failed, 'hart 1 remains halted'):
                        probe.read_words('cells', 0x20000000, 1)
            del report['hart1_halted']
            with self.assertRaisesRegex(COMMON.Failed, 'hart 1 remains halted'):
                probe.read_words('cells', 0x20000000, 1)

    def test_hazard3_boot_readback_does_not_require_hart_halt(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            run = mock.Mock(out=out, pace=None)
            def command(name, argv, **kwargs):
                request = json.loads((out / 'cells-plan.json').read_text())
                self.assertNotIn('require_hart1_halted', request)
                report = dict(request, status='passed', words=[42], flash_written=False,
                              helper_source_sha256=COMMON.helper_source_hash(), hart1_halted=False)
                (out / 'cells.json').write_text(json.dumps(report))
            run.command.side_effect = command
            probe = COMMON.Probe(run, 'probe-rs', 'RP235x_riscv', 'P', ram_loader='loader')
            self.assertEqual(probe.read_words('cells', 0x20000000, 1), [42])

    def test_selectors_name_a_slot_or_an_st_link(self):
        self.assertEqual(COMMON.udp_slot('10.42.0.50'), '0000:0002:10.42.0.50/0')
        self.assertEqual(COMMON.stlink('001900293137511339383538'),
                         '0483:374e:001900293137511339383538')

    def test_words_are_read_for_the_chip_through_the_probe(self):
        run = Recorded(**{'swd-handled': '0x24000000: 0000002a 00000007\n'})
        probe = COMMON.Probe(run, 'probe-rs', 'STM32H753ZITx', '0483:374e:S')
        self.assertEqual(probe.read_words('swd-handled', 0x24000000, 2), [42, 7])
        self.assertEqual(run.calls, [('swd-handled', [
            'probe-rs', 'read', 'b32', '0x24000000', '2', '--chip', 'STM32H753ZITx',
            '--probe', '0483:374e:S'])])
        with self.assertRaises(COMMON.Failed):
            probe.read_words('swd-handled', 0x24000000, 3)

    def test_flashing_verifies_and_reads_the_bytes_back(self):
        expected = struct.pack('<2I', 0x24080000, 0x08000101)
        run = Recorded(**{'flash-readback': '0x08000000: 24080000 08000101\n'})
        probe = COMMON.Probe(run, 'probe-rs', 'STM32H753ZITx', 'P')
        self.assertEqual(probe.flash('board.elf', 0x08000000, expected, 'the vectors'), expected)
        self.assertEqual([n for n, _ in run.calls], ['flash', 'flash-readback'])
        self.assertIn('--verify', run.calls[0][1])
        run = Recorded(**{'flash-readback': '0x08000000: 24080000 00000000\n'})
        with self.assertRaisesRegex(COMMON.Failed, 'the vectors'):
            COMMON.Probe(run, 'probe-rs', 'X', 'P').flash('board.elf', 0x08000000, expected,
                                                          'the vectors')


class Hubs(unittest.TestCase):
    def test_ports_are_read_from_the_listing(self):
        ports = COMMON.hub_ports(STATUS)
        self.assertEqual(sorted(ports), [1, 2, 3, 4])
        self.assertIn('001900293137511339383538', ports[2])

    def test_a_port_is_switched_only_when_it_holds_the_device_named(self):
        serial = '001900293137511339383538'
        for status in (STATUS.replace(serial, 'SOMEONE-ELSE'), STATUS.replace('  Port 2:', '  Port 5:')):
            hub = Recorded(**{'hub-status': status})
            with self.assertRaises(COMMON.Failed):
                COMMON.power_cycle(hub, '7-2.3', 2, 1.0, holds=serial)
            self.assertEqual([n for n, _ in hub.calls], ['hub-status'])
        hub = Recorded(**{'hub-status': STATUS})
        COMMON.power_cycle(hub, '7-2.3', 2, 1.5, holds=serial)
        self.assertEqual(hub.calls, [('hub-status', ['uhubctl', '-l', '7-2.3']),
                                     ('power-cycle', ['uhubctl', '-l', '7-2.3', '-p', '2',
                                                      '-a', 'cycle', '-d', '1.5'])])

    def test_a_guarded_port_is_never_switched(self):
        keeps = (4, '210319B3E738')
        hub = Recorded(**{'hub-status': STATUS})
        with self.assertRaises(COMMON.Failed):
            COMMON.power_cycle(hub, '7-2.3', 4, 1.0, keeps=keeps)
        hub = Recorded(**{'hub-status': STATUS.replace('210319B3E738', 'X')})
        with self.assertRaises(COMMON.Failed):
            COMMON.power_cycle(hub, '7-2.3', 1, 1.0, keeps=keeps)
        hub = Recorded(**{'hub-status': STATUS})
        COMMON.power_cycle(hub, '7-2.3', 1, 1.0, keeps=keeps)
        self.assertEqual([n for n, _ in hub.calls], ['hub-status', 'power-cycle'])

    def test_a_session_without_the_group_reaches_it_through_sg(self):
        argv = ['uhubctl', '-l', '7-2.3', '-p', '2', '-a', 'cycle', '-d', '1']
        with mock.patch.object(COMMON, 'in_group', return_value=True):
            self.assertEqual(COMMON.as_group(argv, 'dialout', '/run/wrappers/bin/sg'), argv)
        with mock.patch.object(COMMON, 'in_group', return_value=False):
            run = Recorded()
            COMMON.InGroup(run, 'dialout').command('power-cycle', argv)
            self.assertEqual(run.calls, [('power-cycle', [
                '/run/wrappers/bin/sg', 'dialout', '-c',
                'uhubctl -l 7-2.3 -p 2 -a cycle -d 1'])])
        self.assertEqual(COMMON.as_group(argv, None, 'sg'), argv)

    def test_a_tool_that_opens_a_tty_runs_itself_in_the_group(self):
        execs = []
        tool = ['environments/boards/esp32c5/board.py', '--output', 'run 1']
        with mock.patch.object(COMMON, 'in_group', return_value=True):
            COMMON.rerun_in_group('dialout', argv=tool, execv=lambda *a: execs.append(a))
        COMMON.rerun_in_group(None, argv=tool, execv=lambda *a: execs.append(a))
        self.assertEqual(execs, [])
        with mock.patch.object(COMMON, 'in_group', return_value=False):
            COMMON.rerun_in_group('dialout', argv=tool, execv=lambda *a: execs.append(a))
        self.assertEqual(execs, [('/run/wrappers/bin/sg', [
            '/run/wrappers/bin/sg', 'dialout', '-c',
            "%s environments/boards/esp32c5/board.py --output 'run 1'" % sys.executable])])

    def test_a_port_s_device_is_read_from_the_listing(self):
        self.assertTrue(COMMON.port_device(STATUS, 2).startswith('0483:374e'))
        self.assertIsNone(COMMON.port_device(STATUS, 1))
        self.assertIsNone(COMMON.port_device(STATUS, 9))

    def test_a_port_that_shows_a_device_must_show_the_one_named(self):
        quiet = STATUS.replace('0103 power enable connect [0483:374e STMicroelectronics STLINK-V3'
                               ' 001900293137511339383538]', '0101 power connect')
        hub = Recorded(**{'hub-status': quiet})
        COMMON.power_cycle(hub, '7-2.3', 2, 1.0, holds_if_any='001900293137511339383538')
        self.assertEqual([n for n, _ in hub.calls], ['hub-status', 'power-cycle'])
        hub = Recorded(**{'hub-status': STATUS})
        with self.assertRaises(COMMON.Failed):
            COMMON.power_cycle(hub, '7-2.3', 2, 1.0, holds_if_any='SOMEONE-ELSE')
        self.assertEqual([n for n, _ in hub.calls], ['hub-status'])

    def test_a_group_the_host_lacks_is_none_to_lack(self):
        self.assertTrue(COMMON.in_group('no-such-group-on-any-host-1230'))

    def test_the_hub_is_waited_for_until_it_lists_what_it_must_show(self):
        # D725: a listing taken while the cascade re-enumerates finds no
        # hub, and uhubctl then lists nothing at all, which shows nothing.
        hub = Recorded()
        hub.answers['hub-wait'] = ''
        with mock.patch.object(COMMON.time, 'sleep'), \
                self.assertRaisesRegex(COMMON.Failed, 'hub 7-2.3 did not list within 0 s'):
            COMMON.wait_for_hub(hub, '7-2.3', [], 0)
        with self.assertRaisesRegex(COMMON.Failed, 'did not list SOMEONE on port 2 within'):
            COMMON.wait_for_hub(hub, '7-2.3', [(2, 'SOMEONE')], 0)
        hub = Recorded(**{'hub-wait': STATUS})
        self.assertEqual(COMMON.wait_for_hub(hub, '7-2.3', [], 0), STATUS)
        self.assertEqual(COMMON.wait_for_hub(hub, '7-2.3', [(2, '001900293137511339383538')], 0),
                         STATUS)


class Consoles(unittest.TestCase):
    def test_a_tty_is_found_by_its_usb_serial(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            device = root / 'devices/usb7/7-2/7-2.3/7-2.3.2'
            for interface, name in (('02', 'ttyACM1'), ('00', 'ttyACM0')):
                at = device / ('7-2.3.2:1.' + interface)
                (at / 'tty' / name).mkdir(parents=True)
                (at / 'bInterfaceNumber').write_text(interface + '\n')
                (root / 'class/tty').mkdir(parents=True, exist_ok=True)
                os.symlink(at / 'tty' / name, root / 'class/tty' / name)
                os.symlink(at, at / 'tty' / name / 'device')
            (device / 'serial').write_text('001900293137511339383538\n')
            (device / 'idVendor').write_text('0483\n')
            (root / 'class/tty/console').mkdir()
            found = COMMON.find_tty('001900293137511339383538', root / 'class/tty', Path('/dev'))
            self.assertEqual(found, Path('/dev/ttyACM0'))
            self.assertIsNone(COMMON.find_tty('ELSE', root / 'class/tty', Path('/dev')))
            with self.assertRaises(COMMON.Failed):
                COMMON.wait_for_tty('ELSE', 0.2, root / 'class/tty', Path('/dev'))
            # Present but not to be opened, as a tty of a group the session
            # lacks: refused as such, not as absent.
            dev = root / 'dev'
            dev.mkdir()
            (dev / 'ttyACM0').write_text('')
            with mock.patch.object(COMMON.os, 'access', return_value=False), \
                    self.assertRaisesRegex(COMMON.Failed, 'appeared but this process may not open'):
                COMMON.wait_for_tty('001900293137511339383538', 0.2, root / 'class/tty', dev)
            with self.assertRaisesRegex(COMMON.Failed, 'no tty for USB serial ELSE appeared'):
                COMMON.wait_for_tty('ELSE', 0.2, root / 'class/tty', dev)

    def test_a_tty_console_keeps_every_byte_each_way(self):
        controller, line = os.openpty()
        sender = None
        try:
            console = COMMON.TtyConsole(os.ttyname(line))
            errors = []

            def send():
                try:
                    console.send(b'S1', pace=1)
                except Exception as error:
                    errors.append(error)

            try:
                # Darwin's pty drains only as its controller reads.  Keep
                # the real tcdrain, with a peer consuming bytes concurrently.
                # A broken transmit must also leave the test's waits bounded.
                sender = threading.Thread(target=send, daemon=True)
                sender.start()
                self.assertEqual(read_exactly(controller, 2),
                                 b'S1')
                os.write(controller, b'\x02b r=00fa0000\x03\nS')
                sender.join(PATIENCE)
                self.assertFalse(sender.is_alive(), 'tty transmit did not finish')
                if errors:
                    raise errors[0]
                stream = console.wait(lambda s: s.endswith(b'S'), PATIENCE, 'the echo')
                self.assertEqual(COMMON.tagged(stream, 'b'), [{'r': 0x00fa0000}])
                self.assertEqual(COMMON.echo_of(stream), b'S')
                self.assertEqual(bytes(console.sent), b'S1')
            finally:
                console.close()
        finally:
            os.close(controller)
            os.close(line)
            if sender is not None:
                sender.join(1)

    def test_a_tty_console_sets_each_line_the_exchange_asks_for(self):
        import termios
        controller, line = os.openpty()
        try:
            console = COMMON.TtyConsole(os.ttyname(line))
            # A Linux pty keeps neither parity nor a character size but
            # eight, so the attributes are read where they are set.
            written = []
            real = termios.tcsetattr

            def capture(fd, when, attributes):
                written.append((when, list(attributes)))
                real(fd, when, attributes)
            try:
                for setting, size, parity, stop in (
                        ((9600, 8, 'even', 1), termios.CS8, termios.PARENB, 0),
                        ((57600, 7, 'odd', 2), termios.CS7, termios.PARENB | termios.PARODD,
                         termios.CSTOPB),
                        ((921600, 8, 'none', 1), termios.CS8, 0, 0)):
                    with mock.patch.object(COMMON.termios, 'tcsetattr', capture):
                        console.line(*setting)
                    when, flags = written[-1]
                    self.assertEqual(when, termios.TCSADRAIN)
                    self.assertEqual(flags[2] & (termios.CSIZE | termios.PARENB | termios.PARODD
                                                 | termios.CSTOPB | termios.CRTSCTS),
                                     size | parity | stop, setting)
                    self.assertEqual(flags[4:6], [COMMON.BAUDS[setting[0]]] * 2)
                    self.assertEqual(console.baud, setting[0])
                with self.assertRaisesRegex(COMMON.Failed, 'no tty line'):
                    console.line(300)
            finally:
                console.close()
        finally:
            os.close(controller)
            os.close(line)

    def test_a_tcp_console_reads_a_bridge(self):
        server = socket.socket()
        server.bind(('127.0.0.1', 0))
        server.listen(1)
        accepted = []
        thread = threading.Thread(target=lambda: accepted.append(server.accept()[0]))
        thread.start()
        console = COMMON.TcpConsole(server.getsockname()[1])
        try:
            thread.join(PATIENCE)
            peer = accepted[0]
            console.send(b'1A0')
            self.assertEqual(read_exactly(peer, 3), b'1A0')
            peer.sendall(b'1A0')
            self.assertEqual(console.wait(lambda s: len(s) == 3, PATIENCE, 'the echo'),
                             b'1A0')
            with self.assertRaisesRegex(COMMON.Failed, 'waited'):
                console.wait(lambda s: len(s) > 3, 0.1, 'more')
            peer.close()
        finally:
            console.close()
            server.close()


class Bridges(unittest.TestCase):
    def test_the_bridge_is_running_once_every_slot_listens(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            (root / 'scripts').mkdir()
            (root / 'scripts/dap_bridge.py').write_text(
                'import sys, time\n'
                'slots = int(sys.argv[sys.argv.index("--slots") + 1])\n'
                'for n in range(2 * slots): print("listening on", n, flush=True)\n'
                'time.sleep(30)\n')
            run = COMMON.Run(root)
            bridge = COMMON.ProbehiveBridge(run, root, '10.42.0.50', slots=2)
            try:
                self.assertEqual(bridge.path.read_text().count('listening on'), 4)
            finally:
                bridge.close()


    def test_a_detached_bridge_outlives_its_run(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            (root / 'scripts').mkdir()
            (root / 'scripts/dap_bridge.py').write_text(
                'import time\nprint("listening on", flush=True)\nprint("listening on", flush=True)\n'
                'time.sleep(30)\n')
            bridge = COMMON.ProbehiveBridge(COMMON.Run(root), root, '10.42.0.50', detached=True)
            try:
                bridge.close()
                self.assertIsNone(bridge.process.poll())
            finally:
                bridge.process.kill()
                bridge.process.wait(5)

    def test_a_bridge_listening_on_both_of_a_slot_s_ports_is_reused(self):
        servers = [socket.socket() for _ in range(2)]
        try:
            for server in servers:
                server.bind(('127.0.0.1', 0))
                server.listen()
            debug, uart = (s.getsockname()[1] for s in servers)
            self.assertTrue(COMMON.listening(debug))
            run = Recorded()
            self.assertEqual(COMMON.shared_bridge(run, '/nonexistent', '10.42.0.50', 1,
                                                  debug_port=debug - 1, uart_port=uart - 1),
                             (None, 'reused'))
            self.assertEqual(run.calls, [])
            servers[1].close()
            self.assertFalse(COMMON.listening(uart))
            with self.assertRaisesRegex(COMMON.Failed, 'only one of ports'):
                COMMON.shared_bridge(run, '/nonexistent', '10.42.0.50', 1,
                                     debug_port=debug - 1, uart_port=uart - 1)
        finally:
            for server in servers:
                server.close()

    def test_a_bridge_s_slot_is_named_by_its_tcp_port(self):
        self.assertEqual(COMMON.bridged(4442), '0000:0001:127.0.0.1:4442')


class Pins(unittest.TestCase):
    def test_the_shell_is_found_without_touching_the_pin(self):
        class Shell:
            calls = []

            def command(self, name, argv, **kw):
                self.calls.append(name)
                return 'building\n["/nix/store/python3", {"PYTHONPATH": "/litex"}]\n'
        pins = COMMON.ProbehivePins(Shell(), '/src/probehive', '/build', 'IO32')
        self.assertEqual((Shell.calls, pins.python, pins.env),
                         (['gpio-environment'], '/nix/store/python3', {'PYTHONPATH': '/litex'}))

    def test_a_shell_that_does_not_open_names_how_to_build_it(self):
        class Building:
            def command(self, name, argv, timeout, **kw):
                raise COMMON.subprocess.TimeoutExpired(argv, timeout)
        with self.assertRaisesRegex(COMMON.Failed, r'nix develop /src/probehive#gpio -c true'):
            COMMON.ProbehivePins(Building(), '/src/probehive', '/build', 'IO32', seconds=1)


class Records(unittest.TestCase):
    def test_record_retains_the_actual_kernel_usb_evidence(self):
        evidence = dict(since=1.0, until=2.0, status='captured',
                        lines=[dict(time=1.5, text='usb target disconnected')])
        result = dict(status='passed', frames=[], kernel_usb=evidence)
        self.assertEqual(COMMON.record(result, ('status',), b'', [], ())['kernel_usb'], evidence)

    def test_a_record_keeps_the_boot_frames_and_the_last(self):
        result = dict(status='passed', image_sha256='ab', extra=1,
                      frames=[dict(tag='b', r='1'), dict(tag='t', h='1'), dict(tag='t', h='2')])
        commands = [dict(name='compile', status=0), dict(name='flash', status=0)]
        made = COMMON.record(result, ('status', 'image_sha256'), b'', commands, ('b',))
        self.assertEqual(made, {
            'status': 'passed', 'image_sha256': 'ab',
            'sent_sha256': 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
            'frames': [dict(tag='b', r='1'), dict(tag='t', h='2')],
            'commands': ['compile', 'flash']})
        with tempfile.TemporaryDirectory() as out:
            COMMON.write_json(Path(out) / 'r.json', made)
            self.assertTrue((Path(out) / 'r.json').read_text().endswith('}\n'))



class RigLock(unittest.TestCase):
    def test_the_holder_is_named_while_held_and_cleared_after(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'rig.lock'
            with COMMON.RigLock('esp32c3 board.py', path, report=self.fail):
                self.assertTrue(path.read_text().startswith('esp32c3 board.py, process %d,'
                                                            % os.getpid()))
            self.assertEqual(path.read_text(), '')

    def test_a_second_run_waits_and_says_for_whom(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'rig.lock'
            said, errors = [], []
            reported, done = threading.Event(), threading.Event()
            path.touch()
            locks = Path(tmp) / 'locks'
            locks.write_text('1: FLOCK  ADVISORY  WRITE 31 00:22:%d 0 EOF\n'
                             % os.stat(path).st_ino)

            def report(text):
                said.append(text)
                reported.set()

            def second():
                try:
                    with COMMON.RigLock('esp32c5 board.py', path, report=report, locks=locks):
                        done.set()
                except Exception as error:
                    errors.append(error)

            # The holder is this process itself, not one of its parents;
            # the waiter must still acquire the real flock after release.
            with COMMON.RigLock('rp2350 board.py', path) as first, \
                    mock.patch.object(COMMON, 'ancestors', return_value=[31, 41, 9]):
                waiter = threading.Thread(target=second, daemon=True)
                try:
                    waiter.start()
                    self.assertTrue(reported.wait(PATIENCE), errors)
                    self.assertFalse(done.is_set())
                    self.assertEqual(len(said), 1)
                    self.assertIn('esp32c5 board.py waits for the rig lock', said[0])
                    self.assertIn('held by rp2350 board.py, process %d' % os.getpid(), said[0])
                finally:
                    first.release()
                    waiter.join(PATIENCE)
                self.assertFalse(waiter.is_alive(), 'rig lock waiter did not finish')
                self.assertEqual(errors, [])
                self.assertTrue(done.is_set())

    def test_a_run_under_its_parent_s_flock_goes_on(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'rig.lock'
            with COMMON.RigLock('flock by hand', path):
                locks = Path(tmp) / 'locks'
                locks.write_text('1: FLOCK  ADVISORY  WRITE 41 00:22:%d 0 EOF\n'
                                 % os.stat(path).st_ino)
                flock = COMMON.fcntl.flock

                def nonblocking_only(file, operation):
                    self.assertNotEqual(operation, COMMON.fcntl.LOCK_EX,
                                        'a child must not wait on its parent lock')
                    return flock(file, operation)

                with mock.patch.object(COMMON, 'ancestors', return_value=[31, 41, 9]), \
                        mock.patch.object(COMMON.fcntl, 'flock', side_effect=nonblocking_only):
                    with COMMON.RigLock('esp32c3 board.py', path, report=self.fail, locks=locks):
                        self.assertTrue(path.read_text().startswith('flock by hand,'))
                # Releasing a child that borrowed its parent's lock must
                # neither unlock it nor clear its holder's description.
                self.assertTrue(path.read_text().startswith('flock by hand,'))
                with path.open() as contender, self.assertRaises(BlockingIOError):
                    COMMON.fcntl.flock(contender, COMMON.fcntl.LOCK_EX | COMMON.fcntl.LOCK_NB)

    def test_holders_are_read_by_inode(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'rig.lock'
            path.write_text('')
            inode = os.stat(path).st_ino
            locks = Path(tmp) / 'locks'
            locks.write_text('1: FLOCK  ADVISORY  WRITE 41 00:22:%d 0 EOF\n'
                             '2: POSIX  ADVISORY  WRITE 42 00:22:%d 0 EOF\n'
                             '3: FLOCK  ADVISORY  WRITE 43 00:22:%d 0 EOF\n'
                             % (inode, inode, inode + 1))
            self.assertEqual(COMMON.lock_holders(path, locks), {41})

    def test_ancestors_follow_parent_ids_after_a_command_with_parentheses(self):
        with tempfile.TemporaryDirectory() as tmp:
            for pid, parent in ((31, 23), (23, 9), (9, 1)):
                process = Path(tmp) / str(pid)
                process.mkdir()
                (process / 'stat').write_text('%d (a command ) with (spaces)) S %d 0 0\n'
                                             % (pid, parent))
            with mock.patch.object(COMMON.os, 'getpid', return_value=31):
                self.assertEqual(COMMON.ancestors(proc=Path(tmp)), [31, 23, 9])
            self.assertEqual(COMMON.ancestors(23, proc=Path(tmp)), [23, 9])
            self.assertEqual(COMMON.ancestors(1, proc=Path(tmp)), [])

    @unittest.skipUnless(sys.platform == 'linux', 'live lock discovery uses Linux /proc/locks')
    def test_live_linux_flock_holder_is_this_process(self):
        # Deliberate Linux kernel integration; portable lock policy tests
        # above supply their own kernel records instead.
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'rig.lock'
            with COMMON.RigLock('live discovery', path):
                self.assertEqual(COMMON.lock_holders(path), {os.getpid()})
            self.assertEqual(COMMON.lock_holders(path), set())

    @unittest.skipUnless(sys.platform == 'linux', 'live ancestry discovery uses Linux /proc/PID/stat')
    def test_live_linux_ancestors_begin_with_this_process(self):
        found = COMMON.ancestors()
        self.assertEqual(found[0], os.getpid())
        self.assertEqual(found[1:2], [os.getppid()] if os.getppid() > 1 else [])



class Pace(unittest.TestCase):
    """The watch over actions that disconnect a device on the hub cascade,
    with a spacing and a quiet time as options."""
    def pace(self, tmp, lines, now=1000.0, spacing=120, quiet=60):
        clock = [now]
        waited = []

        def sleep(seconds):
            waited.append(seconds)
            clock[0] += seconds
        options = {} if spacing is None else dict(spacing=spacing, quiet=quiet)
        pace = COMMON.Pace(state=Path(tmp) / 'rig.pace',
                           kernel=lambda seconds: [l for l in lines if clock[0] - seconds <= l[0] <= clock[0]],
                           clock=lambda: clock[0], sleep=sleep, report=lambda text: None,
                           **options)
        return pace, clock, waited

    def test_by_default_an_action_follows_the_last_at_once(self):
        with tempfile.TemporaryDirectory() as tmp:
            lines = [(1001.0, 'usb 3-2.3.4.2: USB disconnect, device number 9'),
                     (1003.0, 'usb 3-2.3.4.2: new full-speed USB device number 10 using xhci_hcd')]
            pace, clock, waited = self.pace(tmp, lines, spacing=None)
            pace.after('power cycle')
            clock[0] = 1004.0
            pace.before('power cycle')
            self.assertEqual((waited, clock[0]), ([], 1004.0))

    def test_by_default_trouble_since_the_last_action_still_stops_the_run(self):
        with tempfile.TemporaryDirectory() as tmp:
            lines = [(1002.0, 'usb 3-2.3.4.3: device descriptor read/64, error -71')]
            pace, clock, _ = self.pace(tmp, lines, spacing=None)
            pace.after('power cycle')
            clock[0] = 1004.0
            with self.assertRaisesRegex(COMMON.Failed, 'error -71'):
                pace.before('power cycle')

    def test_the_options_wait_for_nothing_by_default(self):
        parser = argparse.ArgumentParser()
        COMMON.pace_arguments(parser)
        args = parser.parse_args([])
        self.assertEqual((args.spacing, args.quiet), (0.0, 0.0))
        pace = COMMON.Pace(args.spacing, args.quiet)
        self.assertEqual((pace.spacing, pace.quiet), (0.0, 0.0))

    def test_a_quiet_rig_long_after_the_last_action_goes_at_once(self):
        with tempfile.TemporaryDirectory() as tmp:
            pace, clock, waited = self.pace(tmp, [])
            pace.before('download')
            pace.after('download')
            self.assertEqual(waited, [])
            self.assertEqual(pace.last(), clock[0])

    def test_the_next_action_waits_for_the_spacing_and_a_quiet_minute(self):
        with tempfile.TemporaryDirectory() as tmp:
            lines = [(1010.0, 'usb 7-2.3.4.2: USB disconnect, device number 9')]
            pace, clock, waited = self.pace(tmp, lines)
            pace.after('download')
            clock[0] = 1030.0
            pace.before('power cycle')
            self.assertGreaterEqual(clock[0], 1120.0)
            self.assertTrue(all(w <= 30 for w in waited))

    def test_a_kernel_usb_line_restarts_the_quiet_minute(self):
        with tempfile.TemporaryDirectory() as tmp:
            lines = [(1150.0, 'usb 7-2.3.4.3: new full-speed USB device number 12')]
            pace, clock, _ = self.pace(tmp, lines, now=1160.0)
            Path(tmp, 'rig.pace').write_text('900.0 download\n')
            pace.before('power on')
            self.assertGreaterEqual(clock[0], 1210.0)

    def test_a_paced_action_is_recorded_even_when_it_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            pace, clock, _ = self.pace(tmp, [])

            def fails():
                raise COMMON.Failed('the switch failed')
            with self.assertRaisesRegex(COMMON.Failed, 'the switch failed'):
                COMMON.paced(pace, 'power cycle', fails)
            self.assertEqual(pace.last(), clock[0])
            self.assertEqual(COMMON.paced(pace, 'download', lambda: 'done'), 'done')

    def test_usb_errors_during_an_action_never_advance_or_allow_another_action(self):
        for action_fails in (False, True):
            with self.subTest(action_fails=action_fails), tempfile.TemporaryDirectory() as tmp:
                lines = []
                pace, clock, _ = self.pace(tmp, lines, spacing=0, quiet=0)
                pace.state.write_text('900.0 previous action\n')
                def action():
                    lines.append((1001.0, 'xhci_hcd: HC died'))
                    clock[0] = 1002.0
                    if action_fails:
                        raise COMMON.Failed('download failed')
                    return 'done'
                with self.assertRaisesRegex(COMMON.USBGuardError, 'HC died') as caught:
                    COMMON.paced(pace, 'download', action)
                if action_fails:
                    self.assertIn('download failed', str(caught.exception))
                self.assertEqual(pace.state.read_text(), '900.0 previous action\n')
                with self.assertRaises(COMMON.USBGuardError):
                    COMMON.paced(pace, 'power cycle', lambda: self.fail('guard retried hardware'))
                self.assertEqual(pace.state.read_text(), '900.0 previous action\n')

    def test_cancellation_checks_completion_without_hiding_the_interrupt(self):
        with tempfile.TemporaryDirectory() as tmp:
            lines = []
            pace, clock, _ = self.pace(tmp, lines, spacing=0, quiet=0)
            def cancel():
                lines.append((1001.0, 'xhci_hcd: HC died'))
                clock[0] = 1002.0
                raise KeyboardInterrupt()
            with self.assertRaises(KeyboardInterrupt) as caught:
                COMMON.paced(pace, 'download', cancel)
            self.assertIsInstance(caught.exception.__cause__, COMMON.USBGuardError)
            self.assertEqual(pace.last(), 0.0)

    def test_scan_end_covers_concurrent_lines_without_advancing_the_saved_timestamp(self):
        with tempfile.TemporaryDirectory() as tmp:
            pace, _, _ = self.pace(tmp, [], spacing=0, quiet=0)
            pace.kernel = lambda _: [(1000.5, 'usb target connected during journal scan')]
            pace.after('load')
            self.assertEqual(pace.last(), 1000.0)
            self.assertEqual(pace.evidence()['until'], 1000.5)

    def test_snapshot_collects_only_run_lines_deduplicates_and_keeps_late_lines(self):
        with tempfile.TemporaryDirectory() as tmp:
            lines = [(999.0, 'usb old event'), (1001.0, 'usb target disconnected')]
            pace, clock, _ = self.pace(tmp, lines, spacing=0, quiet=0)
            clock[0] = 1002.0
            pace.before('load')
            pace.after('load')
            pace.before('read')
            lines.append((1003.0, 'usb target connected'))
            clock[0] = 1004.0
            result = dict(status='passed')
            COMMON.retain_kernel_usb(pace, result)
            self.assertEqual(result['status'], 'passed')
            self.assertEqual(result['kernel_usb'], dict(since=1000.0, until=1004.0,
                status='captured', lines=[dict(time=1001.0, text='usb target disconnected'),
                                         dict(time=1003.0, text='usb target connected')]))

    def test_final_usb_failure_preserves_the_original_and_blocks_restoration(self):
        with tempfile.TemporaryDirectory() as tmp:
            lines = []
            pace, clock, _ = self.pace(tmp, lines, spacing=0, quiet=0)
            pace.after('load')
            lines.append((1001.0, 'usb descriptor read error -71'))
            clock[0] = 1002.0
            result = dict(status='failed', failure='original scenario failure')
            COMMON.retain_kernel_usb(pace, result)
            self.assertEqual(result['status'], 'failed')
            self.assertIn('original scenario failure', result['failure'])
            self.assertIn('error -71', result['failure'])
            self.assertEqual(result['kernel_usb']['lines'], [dict(time=1001.0, text=lines[0][1])])
            self.assertEqual(pace.last(), 1000.0)
            restore = mock.Mock()
            COMMON.finish_boot(SimpleNamespace(mode='boot', pace=pace), result, restore)
            restore.assert_not_called()

    def test_unreadable_journal_stops_completion_and_preserves_existing_failure(self):
        with tempfile.TemporaryDirectory() as tmp:
            pace, _, _ = self.pace(tmp, [], spacing=0, quiet=0)
            pace.state.write_text('900.0 previous action\n')
            pace.kernel = mock.Mock(side_effect=OSError('journal unavailable'))
            with self.assertRaisesRegex(COMMON.USBGuardError, 'journal unavailable'):
                pace.after('load')
            self.assertEqual(pace.last(), 900.0)
            result = dict(status='failed', failure='the build failed')
            COMMON.retain_kernel_usb(pace, result)
            self.assertIn('the build failed', result['failure'])
            self.assertEqual(result['kernel_usb']['status'], 'failed')

    def test_a_late_usb_error_turns_a_pass_into_failure(self):
        with tempfile.TemporaryDirectory() as tmp:
            lines = []
            pace, clock, _ = self.pace(tmp, lines, spacing=0, quiet=0)
            lines.append((1001.0, 'xhci_hcd: HC died'))
            clock[0] = 1002.0
            result = dict(status='passed')
            COMMON.retain_kernel_usb(pace, result)
            self.assertEqual(result['status'], 'failed')
            self.assertIn('HC died', result['failure'])

    def test_a_guarded_paced_action_waits_for_nothing_while_the_arty_is_away(self):
        with tempfile.TemporaryDirectory() as tmp:
            pace, _, _ = self.pace(tmp, [])
            for where in ('7-2.3.3.4', None):
                with mock.patch.object(COMMON, 'device_location', return_value=where), \
                        self.assertRaises(COMMON.Failed):
                    COMMON.paced(pace, 'power cycle', lambda: self.fail('switched'),
                                 '210319B3E738', '7-2')
            self.assertEqual(pace.last(), 0.0)

    def test_a_usb_error_since_the_last_action_stops_the_run(self):
        with tempfile.TemporaryDirectory() as tmp:
            lines = [(1005.0, 'usb 7-2.3: device not accepting address 41, error -71')]
            pace, _, _ = self.pace(tmp, lines, now=1200.0)
            Path(tmp, 'rig.pace').write_text('1000.0 download\n')
            with self.assertRaises(COMMON.Failed):
                pace.before('power cycle')

    def test_acknowledged_trouble_stops_no_run_and_later_trouble_still_does(self):
        with tempfile.TemporaryDirectory() as tmp:
            lines = [(1005.0, 'usb 7-2.3: device not accepting address 41, error -71')]
            pace, clock, _ = self.pace(tmp, lines, now=1200.0)
            Path(tmp, 'rig.pace').write_text('1000.0 download\n')
            with self.assertRaisesRegex(COMMON.Failed, 'common.py acknowledge REASON'):
                pace.before('power cycle')
            with self.assertRaises(COMMON.Failed):
                pace.acknowledge('  ')
            pace.acknowledge('the hub  dropped\nfrom its port')
            self.assertEqual(Path(tmp, 'rig.pace').read_text(),
                             '1200.000000 acknowledged: the hub dropped from its port\n')
            pace.before('power cycle')
            self.assertGreaterEqual(clock[0], 1320.0)
            lines.append((clock[0] + 1, 'usb 5-1: device descriptor read/64, error -71'))
            clock[0] += 200
            with self.assertRaises(COMMON.Failed):
                pace.before('power cycle')

    def test_a_cascade_that_never_goes_quiet_stops_the_run(self):
        with tempfile.TemporaryDirectory() as tmp:
            pace, clock, _ = self.pace(tmp, [])
            pace.kernel = lambda seconds: [(clock[0] - 1, 'usb 7-2.3.4.2: USB disconnect')]
            with self.assertRaises(COMMON.Failed):
                pace.before('download')
            self.assertLess(clock[0], 1000.0 + 600 + 31)

    def test_an_error_before_the_last_action_does_not(self):
        with tempfile.TemporaryDirectory() as tmp:
            lines = [(990.0, 'usb 7-2-port3: attempt power cycle')]
            pace, _, _ = self.pace(tmp, lines, now=1200.0)
            Path(tmp, 'rig.pace').write_text('1000.0 download\n')
            pace.before('power cycle')



class Cascade(unittest.TestCase):
    def tree(self, tmp, devices):
        for name, serial in devices.items():
            (Path(tmp) / name).mkdir()
            if serial:
                (Path(tmp) / name / 'serial').write_text(serial + '\n')
        return Path(tmp)

    def test_a_device_is_found_by_its_serial(self):
        with tempfile.TemporaryDirectory() as tmp:
            sysfs = self.tree(tmp, {'7-2.3.4.2': 'A0:76', '7-2.3.4.2:1.0': None,
                                    '9-1.2': '210319B3E738', 'usb7': '0000:42:00.3'})
            self.assertEqual(COMMON.device_location('210319B3E738', sysfs), '9-1.2')
            self.assertIsNone(COMMON.device_location('NOBODY', sysfs))

    def test_only_a_device_present_and_off_the_cascade_passes(self):
        with tempfile.TemporaryDirectory() as tmp:
            sysfs = self.tree(tmp, {'9-1.2': 'ARTY'})
            self.assertEqual(COMMON.off_cascade('ARTY', '7-2', sysfs), '9-1.2')
            self.assertEqual(COMMON.off_cascade('ARTY', '9-1.20', sysfs), '9-1.2')
            for cascade in ('9-1', '9-1.2'):
                with self.assertRaises(COMMON.Failed):
                    COMMON.off_cascade('ARTY', cascade, sysfs)
            with self.assertRaises(COMMON.Failed):
                COMMON.off_cascade('GONE', '7-2', sysfs)


class Root(unittest.TestCase):
    """The hub cascade's root found by its hub's identity, and each board's
    hub placed relative to it (D833), in a fake sysfs tree."""
    HUB, HUB3 = ('0bda', '5411'), ('0bda', '0411')

    def tree(self, tmp, devices):
        for name, identity in devices.items():
            (Path(tmp) / name).mkdir()
            if identity:
                (Path(tmp) / name / 'idVendor').write_text(identity[0] + '\n')
                (Path(tmp) / name / 'idProduct').write_text(identity[1] + '\n')
        return Path(tmp)

    def rig(self, tmp, root):
        """The rig's cascade under ROOT, its USB3 side, a root hub and a
        hub of another make beside it."""
        bus = root.split('-')[0]
        return self.tree(tmp, {
            'usb' + bus: ('1d6b', '0002'), root: self.HUB, root + '.3': self.HUB,
            root + '.3.3': self.HUB, root + '.3.4': self.HUB, root + '.4': self.HUB,
            root + '.3.4.2': ('303a', '1001'), root + '.3.4.2:1.0': None,
            '6-1': self.HUB3, '6-1.3': self.HUB3, '3-2': ('0403', '6010'),
            '5-2': ('0557', '7000'), '5-2.1': ('0557', '2419')})

    def test_the_root_is_the_hub_whose_parent_is_not_one(self):
        for root in ('7-2', '5-1', '1-10'):
            with tempfile.TemporaryDirectory() as tmp:
                self.assertEqual(COMMON.cascade_root(sysfs=self.rig(tmp, root)), root)

    def test_none_or_several_are_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            sysfs = self.tree(tmp, {'usb5': ('1d6b', '0002'), '6-1': self.HUB3})
            with self.assertRaisesRegex(COMMON.Failed, 'no USB hub 0bda:5411 .*--cascade'):
                COMMON.cascade_root(sysfs=sysfs)
        with tempfile.TemporaryDirectory() as tmp:
            sysfs = self.rig(tmp, '5-1')
            (sysfs / '7-2.1').mkdir()
            (sysfs / '7-2.1' / 'idVendor').write_text('0bda\n')
            (sysfs / '7-2.1' / 'idProduct').write_text('5411\n')
            with self.assertRaisesRegex(COMMON.Failed, 'the hubs 5-1, 7-2.1 .*--cascade'):
                COMMON.cascade_root(sysfs=sysfs)

    def test_a_relative_hub_is_placed_and_any_other_kept(self):
        self.assertEqual(COMMON.on_cascade('.3.3', '5-1'), '5-1.3.3')
        self.assertEqual(COMMON.on_cascade('.4', '5-1'), '5-1.4')
        self.assertEqual(COMMON.on_cascade('7-2.3.3', '5-1'), '7-2.3.3')
        for wrong in ('.', '.3.', '..3', '.0', '.x'):
            with self.assertRaises(COMMON.Failed):
                COMMON.on_cascade(wrong, '5-1')

    def parser(self):
        import argparse
        parser = argparse.ArgumentParser()
        parser.add_argument('--hub', default='.3.3')
        parser.add_argument('--console-hub', default='.4')
        COMMON.cascade_argument(parser)
        return parser

    def test_the_tools_options_find_the_root_unless_named(self):
        with tempfile.TemporaryDirectory() as tmp:
            sysfs = self.rig(tmp, '5-1')
            for argv, hub, console, cascade in (
                    ([], '5-1.3.3', '5-1.4', '5-1'),
                    (['--cascade', '7-2'], '7-2.3.3', '7-2.4', '7-2'),
                    (['--hub', '9-1.3.3'], '9-1.3.3', '5-1.4', '5-1'),
                    (['--hub', '.3.4', '--cascade', '5-1'], '5-1.3.4', '5-1.4', '5-1')):
                parser = self.parser()
                args = parser.parse_args(argv)
                COMMON.place_hubs(parser, args, 'hub', 'console_hub', sysfs=sysfs)
                self.assertEqual((args.hub, args.console_hub, args.cascade), (hub, console, cascade))

    def test_no_root_is_the_parsers_error(self):
        with tempfile.TemporaryDirectory() as tmp:
            parser = self.parser()
            args = parser.parse_args([])
            with mock.patch('sys.stderr'), self.assertRaises(SystemExit) as raised:
                COMMON.place_hubs(parser, args, 'hub', sysfs=Path(tmp))
            self.assertEqual(raised.exception.code, 2)

    def test_no_tool_writes_an_absolute_hub_into_its_defaults(self):
        """A move of the cascade needs no edit: every tool's hub defaults
        are relative to it, and its cascade is found."""
        boards = ROOT / 'environments/boards'
        for path in sorted(boards.glob('*.py')) + sorted(boards.glob('*/board.py')):
            text = path.read_text()
            self.assertNotRegex(text, r"default='[0-9]+-[0-9]", path)
            self.assertNotRegex(text, r"'--cascade', default", path)


class RamRuns(unittest.TestCase):
    def test_invalid_bundle_becomes_a_retained_board_failure(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            (directory / 'bundle.json').write_text('{"format_version": 0}')
            args = SimpleNamespace(bundle=directory, mode='ram')
            with self.assertRaisesRegex(COMMON.Failed, 'board bundle:'):
                COMMON.consume_board(mock.Mock(), args, 'rp2040')

    def image(self, path, address=0x20000000, physical=None, extra=()):
        sections = [('.isr_vector', address, struct.pack('<2I', 0x20041000, address + 9))]
        sections += list(extra)
        path.write_bytes(elf32(sections, [(address if physical is None else physical, '.isr_vector')]))
        return path

    def test_ram_layout_rejects_flash_lmas_boot_sections_and_oversized_bss(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'test.elf'
            self.assertEqual(COMMON.validate_ram_image(self.image(path), 'rp2040'), 0x20000000)
            for image in (
                    lambda: self.image(path, physical=0x10000000),
                    lambda: self.image(path, extra=[('.boot2', 0x20000100, bytes(256))])):
                image()
                with self.assertRaises(COMMON.Failed):
                    COMMON.validate_ram_image(path, 'rp2040')
            self.image(path)
            body = bytearray(path.read_bytes())
            struct.pack_into('<I', body, 52 + 20, 0x50000)
            path.write_bytes(body)
            with self.assertRaisesRegex(COMMON.Failed, 'memory exceeds SRAM'):
                COMMON.validate_ram_image(path, 'rp2040')

    def allocated_image(self, path, address=0x20000100, kind=8, load=False, symbols=()):
        names = b'\0' + b''.join(name.encode() + b'\0' for name, _ in symbols)
        entries, at = bytearray(bytes(16)), 1
        for name, value in symbols:
            entries += struct.pack('<IIIBBH', at, value, 0, 0x10, 0, 0xfff1)
            at += len(name) + 1
        sections = [('.isr_vector', 0x20000000, bytes(8)),
                    ('.extra', address, bytes(16)), ('.strtab', 0, names), ('.symtab', 0, entries)]
        loads = [(0x20000000, '.isr_vector')] + ([(address, '.extra')] if load else [])
        data = bytearray(elf32(sections, loads))
        shoff = struct.unpack_from('<I', data, 32)[0]
        struct.pack_into('<I', data, shoff + 80 + 4, kind)
        for index, section_kind in ((3, 3), (4, 2)):
            struct.pack_into('<II', data, shoff + index * 40 + 4, section_kind, 0)
        struct.pack_into('<I', data, shoff + 160 + 24, 3)
        struct.pack_into('<I', data, shoff + 160 + 36, 16)
        path.write_bytes(data)
        return path

    def test_allocated_noload_sections_must_stay_in_ram_and_outside_the_stack(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'allocated.elf'
            self.assertEqual(COMMON.validate_ram_image(self.allocated_image(path), 'rp2040'), 0x20000000)
            with self.assertRaisesRegex(COMMON.Failed, 'allocated section exceeds SRAM'):
                COMMON.validate_ram_image(self.allocated_image(path, address=0x10000100), 'rp2040')
            stack = [('_landin_firmware_stack_bottom', 0x20000100),
                     ('_landin_firmware_stack_top', 0x20000200)]
            with self.assertRaisesRegex(COMMON.Failed, 'allocated section overlaps reserved stack'):
                COMMON.validate_ram_image(self.allocated_image(path, symbols=stack), 'rp2040')

    def test_reserved_stack_symbols_must_be_a_complete_ram_range(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'allocated.elf'
            bottom, top = '_landin_firmware_stack_bottom', '_landin_firmware_stack_top'
            for symbols, message in (([(bottom, 0x20000300)], 'incomplete reserved stack'),
                    ([(bottom, 0x10000000), (top, 0x10000100)], 'stack is outside SRAM'),
                    ([(bottom, 0x20000300), (top, 0x20000200)], 'stack is outside SRAM'),
                    ([(bottom, 0x20000000), (top, 0x20000008)], 'segment overlaps reserved stack')):
                with self.subTest(symbols=symbols), self.assertRaisesRegex(COMMON.Failed, message):
                    COMMON.validate_ram_image(self.allocated_image(path, symbols=symbols), 'rp2040')

    def test_initialized_allocated_sections_need_matching_loaded_file_bytes(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'allocated.elf'
            with self.assertRaisesRegex(COMMON.Failed, 'matching PT_LOAD'):
                COMMON.validate_ram_image(self.allocated_image(path, kind=1), 'rp2040')
            self.allocated_image(path, kind=1, load=True)
            self.assertEqual(COMMON.validate_ram_image(path, 'rp2040'), 0x20000000)
            data = bytearray(path.read_bytes())
            # Still bounded, and the VMA is covered, but the load names other file bytes.
            offset = struct.unpack_from('<I', data, 52 + 32 + 4)[0]
            struct.pack_into('<I', data, 52 + 32 + 4, offset + 1)
            path.write_bytes(data)
            with self.assertRaisesRegex(COMMON.Failed, 'matching PT_LOAD'):
                COMMON.validate_ram_image(path, 'rp2040')

    def test_all_startup_bss_symbol_ranges_are_checked_even_without_sections(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'allocated.elf'
            for prefix in ('_landin_firmware_bss', '_landin_firmware_region_DTIM_bss'):
                for start, end, message in ((0x10000000, 0x10000010, 'BSS symbols exceed SRAM'),
                        (0x20000100, 0x20000110, 'BSS symbols overlap reserved stack'),
                        (0x200000f0, 0x200000e0, 'reversed BSS symbols')):
                    with self.subTest(prefix=prefix, start=start):
                        symbols = [(prefix + '_start', start), (prefix + '_end', end),
                            ('_landin_firmware_stack_bottom', 0x20000100),
                            ('_landin_firmware_stack_top', 0x20000200)]
                        with self.assertRaisesRegex(COMMON.Failed, message):
                            COMMON.validate_ram_image(self.allocated_image(path, address=0x20000080,
                                symbols=symbols), 'rp2040')
                with self.assertRaisesRegex(COMMON.Failed, 'incomplete BSS symbols'):
                    COMMON.validate_ram_image(self.allocated_image(path,
                        symbols=[(prefix + '_end', 0x20000100)]), 'rp2040')
                # An empty range writes nothing, including an unused description region.
                COMMON.validate_ram_image(self.allocated_image(path, symbols=[
                    (prefix + '_start', 0x10000000), (prefix + '_end', 0x10000000)]), 'rp2040')

    def test_loader_matches_the_bundle_identity_and_checks_usb_after_the_call(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            elf = self.image(out / 'board.elf')
            pace = mock.Mock()
            args = SimpleNamespace(probe='0000:0002:10.42.0.50/0', ram_loader='loader', pace=pace)
            report = dict(format_version=1, status='passed', mode='warm', flash_written=False,
                          board='rp2040', elf_sha256=COMMON.sha(elf),
                          helper_source_sha256=COMMON.helper_source_hash())
            run = mock.Mock(out=out)
            def command(name, argv, **kwargs):
                self.assertEqual(name, 'ram-load')
                self.assertEqual(argv[0], 'loader')
                (out / 'ram-load.json').write_text(json.dumps(report))
            run.command.side_effect = command
            self.assertEqual(COMMON.ram_load(run, args, 'rp2040', elf), report)
            self.assertEqual(pace.before.call_args_list,
                             [mock.call('RAM load'), mock.call('RAM load completion')])
            for field, value in (('flash_written', True), ('elf_sha256', 'stale'),
                                 ('helper_source_sha256', 'stale'),
                                 ('status', 'failed'), ('board', 'rp2350'), ('mode', 'boot')):
                wrong = dict(report, **{field: value})
                with mock.patch.object(json, 'loads', return_value=wrong), self.assertRaises(COMMON.Failed):
                    COMMON.ram_load(run, args, 'rp2040', elf)

    def test_ram_mode_refuses_boot_controls_and_boot_record_overwrite_before_hardware(self):
        parser = argparse.ArgumentParser()
        parser.add_argument('--refine', default='refine')
        parser.add_argument('--record', type=Path)
        parser.add_argument('--recover', action='store_true')
        COMMON.board_arguments(parser)
        for options in (['--recover'], ['--record=record.json']):
            args = parser.parse_args(['--ram-loader=loader', *options])
            with self.assertRaises(COMMON.Failed), mock.patch.object(COMMON, 'rig_lock') as lock:
                COMMON.board_preflight(args, 'rp2040')
            lock.assert_not_called()

    def test_usb_trouble_prevents_fixed_image_restoration(self):
        args = SimpleNamespace(mode='boot', pace=mock.Mock(), fixed_image=Path('fixed.elf'))
        args.pace.before.side_effect = COMMON.Failed('USB trouble: HC died')
        result = {'status': 'passed'}
        restore = mock.Mock()
        COMMON.finish_boot(args, result, restore)
        restore.assert_not_called()
        self.assertEqual(result['status'], 'failed')
        self.assertEqual(result['fixed_restore']['status'], 'pending')

    def test_controller_failures_are_usb_trouble_and_wifi_firmware_is_not(self):
        for text in ('xhci_hcd: HC died', 'host controller timeout', 'controller timed out',
                     'xHCI host controller not responding'):
            self.assertRegex(text, COMMON.USB_TROUBLE)
        journal = SimpleNamespace(returncode=0, stderr='',
            stdout='1.0 brcmfmac: firmware error -2\n2.0 xhci_hcd: HC died\n')
        with mock.patch.object(COMMON.subprocess, 'run', return_value=journal):
            self.assertEqual(COMMON.kernel_usb_lines(3), [(2.0, 'xhci_hcd: HC died')])

    def test_failed_kernel_reader_is_not_empty_usb_evidence(self):
        journal = SimpleNamespace(returncode=1, stderr='permission denied', stdout='')
        with mock.patch.object(COMMON.subprocess, 'run', return_value=journal), \
                self.assertRaisesRegex(COMMON.Failed, 'kernel USB journal.*permission denied'):
            COMMON.kernel_usb_lines(3)



class SharedState(unittest.TestCase):
    """The rig's state directory, shared by the maintainer and the gate's
    runner user through its group."""
    def test_the_environment_names_the_state_and_must_be_an_absolute_directory(self):
        with tempfile.TemporaryDirectory() as tmp:
            system, legacy = Path(tmp) / 'system', Path(tmp) / 'legacy'
            self.assertEqual(COMMON.rig_state(dict(LANDIN_RIG_STATE=tmp), system, legacy),
                             (Path(tmp), 'environment', None))
            for named in ('', 'relative/state', str(Path(tmp) / 'absent')):
                path, source, problem = COMMON.rig_state(dict(LANDIN_RIG_STATE=named), system, legacy)
                self.assertEqual(source, 'environment')
                self.assertIn('LANDIN_RIG_STATE', problem)
            self.assertEqual(COMMON.rig_state({}, system, legacy), (legacy, 'legacy', None))
            system.mkdir()
            self.assertEqual(COMMON.rig_state({}, system, legacy), (system, 'system', None))

    def test_a_lock_in_an_unusable_named_state_refuses_as_needs_setup(self):
        with tempfile.TemporaryDirectory() as tmp, \
                mock.patch.object(COMMON, 'RIG_LOCK', Path(tmp) / 'absent/rig.lock'), \
                mock.patch.object(COMMON, 'RIG_STATE', Path(tmp) / 'absent'), \
                mock.patch.object(COMMON, 'RIG_STATE_PROBLEM', 'LANDIN_RIG_STATE is wrong'):
            with self.assertRaisesRegex(COMMON.NeedsSetup, 'LANDIN_RIG_STATE is wrong'):
                COMMON.RigLock('board.py', report=self.fail).acquire()
            self.assertFalse((Path(tmp) / 'absent').exists())

    def umask(self, value):
        previous = os.umask(value)
        self.addCleanup(os.umask, previous)

    def test_state_files_are_group_shared_whatever_the_umask_and_never_world_writable(self):
        self.umask(0o022)
        with tempfile.TemporaryDirectory() as tmp:
            lock = Path(tmp) / 'rig.lock'
            with COMMON.RigLock('board.py', lock, report=self.fail):
                pass
            self.assertEqual(lock.stat().st_mode & 0o7777, 0o660)
            older = Path(tmp) / 'older.lock'
            older.write_text('')
            for before, after in ((0o644, 0o664), (0o666, 0o664), (0o600, 0o660)):
                os.chmod(older, before)
                with COMMON.RigLock('board.py', older, report=self.fail):
                    pass
                self.assertEqual(older.stat().st_mode & 0o7777, after, oct(before))
            inode = lock.stat().st_ino
            with COMMON.RigLock('board.py', lock, report=self.fail):
                pass
            self.assertEqual(lock.stat().st_ino, inode, 'the lock must keep its inode')
            pace = COMMON.Pace(state=Path(tmp) / 'rig.pace', kernel=lambda _: [])
            pace._save('download', 1000.0)
            first = (Path(tmp) / 'rig.pace').stat()
            self.assertEqual(first.st_mode & 0o7777, 0o660)
            pace.acknowledge('understood')
            second = (Path(tmp) / 'rig.pace').stat()
            self.assertEqual(second.st_mode & 0o7777, 0o660)
            self.assertNotEqual(first.st_ino, second.st_ino, 'state is replaced, not rewritten')
            self.assertEqual([p.name for p in Path(tmp).iterdir() if p.name.startswith('.')], [])

    def test_state_directories_made_inside_the_state_are_group_shared_and_setgid(self):
        self.umask(0o022)
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp) / 'state'
            base.mkdir(mode=0o755)
            COMMON.write_state(base / 'runs/rp2040.json', '{}\n', base)
            self.assertEqual((base / 'runs').stat().st_mode & 0o7777, 0o2770)
            self.assertEqual((base / 'runs/rp2040.json').stat().st_mode & 0o7777, 0o660)
            self.assertEqual(base.stat().st_mode & 0o7777, 0o755, 'the base is the deploy\'s')

    def test_another_user_s_lock_that_this_one_may_not_write_still_locks(self):
        with tempfile.TemporaryDirectory() as tmp:
            lock = Path(tmp) / 'rig.lock'
            lock.write_text('')
            said = []
            real = COMMON.os.open

            def refused(path, flags, *rest):
                if str(path) == str(lock) and flags & os.O_RDWR:
                    raise PermissionError(13, 'Permission denied')
                return real(path, flags, *rest)
            with mock.patch.object(COMMON.os, 'open', side_effect=refused):
                with COMMON.RigLock('board.py', lock, report=said.append) as held:
                    self.assertFalse(held.file.writable())
                    with lock.open() as contender, self.assertRaises(BlockingIOError):
                        COMMON.fcntl.flock(contender, COMMON.fcntl.LOCK_EX | COMMON.fcntl.LOCK_NB)
            self.assertEqual(len(said), 1)
            self.assertIn('group write', said[0])


class BoundedLock(unittest.TestCase):
    def held(self, tmp):
        path = Path(tmp) / 'rig.lock'
        holder = COMMON.RigLock('esp32 board.py', path, report=lambda _: None).acquire()
        self.addCleanup(holder.release)
        locks = Path(tmp) / 'locks'
        locks.write_text('1: FLOCK  ADVISORY  WRITE 31 00:22:%d 0 EOF\n' % os.stat(path).st_ino)
        stack = contextlib.ExitStack()
        self.addCleanup(stack.close)
        stack.enter_context(mock.patch.object(COMMON, 'ancestors', return_value=[1234, 5678]))
        return path, locks, holder

    def test_a_bounded_wait_names_the_holder_once_and_ends_rig_busy(self):
        with tempfile.TemporaryDirectory() as tmp:
            path, locks, _ = self.held(tmp)
            clock, slept, said = [100.0], [], []

            def sleep(seconds):
                slept.append(seconds)
                clock[0] += seconds
            lock = COMMON.RigLock('gate.py rp2040', path, report=said.append, locks=locks, timeout=3.5,
                                  clock=lambda: clock[0], sleep=sleep)
            with self.assertRaises(COMMON.RigBusy) as raised:
                lock.acquire()
            self.assertEqual(COMMON.outcome_of(raised.exception), 'rig-busy')
            self.assertIn('held by esp32 board.py, process %d' % os.getpid(), str(raised.exception))
            self.assertIn(str(path), str(raised.exception))
            self.assertEqual(len(said), 1)
            self.assertEqual(slept, [1.0, 1.0, 1.0, 0.5])
            self.assertIsNone(lock.file)

    def test_a_bounded_wait_takes_the_lock_once_it_is_released(self):
        with tempfile.TemporaryDirectory() as tmp:
            path, locks, holder = self.held(tmp)
            lock = COMMON.RigLock('gate.py rp2040', path, report=lambda _: None, locks=locks,
                                  timeout=60, sleep=lambda _: holder.release())
            with lock:
                self.assertTrue(path.read_text().startswith('gate.py rp2040, process'))

    def test_without_a_timeout_the_wait_has_no_end(self):
        lock = COMMON.RigLock('board.py', '/unused')
        lock.file = mock.Mock()
        with mock.patch.object(COMMON.fcntl, 'flock') as flock:
            lock.wait()
        flock.assert_called_once_with(lock.file, COMMON.fcntl.LOCK_EX)

    def test_a_held_legacy_lock_is_refused_while_the_system_state_is_used(self):
        with tempfile.TemporaryDirectory() as tmp:
            legacy = Path(tmp) / 'home/.cache/landin/rig.lock'
            legacy.parent.mkdir(parents=True)
            legacy.write_text('old tool, process 77\n')
            locks = Path(tmp) / 'locks'
            locks.write_text('1: FLOCK  ADVISORY  WRITE 77 00:22:%d 0 EOF\n' % os.stat(legacy).st_ino)
            system = Path(tmp) / 'system'
            system.mkdir()
            with mock.patch.object(COMMON, 'ancestors', return_value=[1234, 5678]), \
                    mock.patch.object(COMMON, 'RIG_STATE', system), \
                    mock.patch.object(COMMON, 'RIG_LOCK', system / 'rig.lock'), \
                    mock.patch.object(COMMON, 'LEGACY_STATE', legacy.parent):
                with self.assertRaises(COMMON.NeedsOperator) as raised:
                    COMMON.RigLock('board.py', report=self.fail, locks=locks).acquire()
                text = str(raised.exception)
                self.assertIn('two rig lock files', text)
                self.assertIn('retire %s' % legacy, text)
                self.assertFalse((system / 'rig.lock').exists())
                # The run's own parent holding it is the same run.
                with mock.patch.object(COMMON, 'ancestors', return_value=[1234, 77]):
                    with COMMON.RigLock('board.py', report=self.fail, locks=locks):
                        pass
                # The legacy state itself has no second file.
                with mock.patch.object(COMMON, 'RIG_STATE', legacy.parent), \
                        mock.patch.object(COMMON, 'RIG_LOCK', Path(tmp) / 'other.lock'):
                    self.assertIsNone(COMMON.RigLock('board.py').legacy)
            locks.write_text('')
            with mock.patch.object(COMMON, 'RIG_STATE', system), \
                    mock.patch.object(COMMON, 'RIG_LOCK', system / 'rig.lock'), \
                    mock.patch.object(COMMON, 'LEGACY_STATE', legacy.parent):
                with COMMON.RigLock('board.py', report=self.fail, locks=locks):
                    pass


class Outcomes(unittest.TestCase):
    def test_every_refusal_has_its_outcome(self):
        self.assertEqual(COMMON.OUTCOMES, ('passed', 'failed', 'usb-stopped', 'unavailable', 'rig-busy',
                                           'rig-tool-mismatch', 'needs-setup', 'needs-operator',
                                           'cancelled', 'incomplete'))
        for kind, outcome in ((COMMON.Failed, 'failed'), (COMMON.USBGuardError, 'usb-stopped'),
                              (COMMON.Unavailable, 'unavailable'), (COMMON.RigBusy, 'rig-busy'),
                              (COMMON.ToolMismatch, 'rig-tool-mismatch'),
                              (COMMON.NeedsSetup, 'needs-setup'),
                              (COMMON.NeedsOperator, 'needs-operator'),
                              (COMMON.Cancelled, 'cancelled'), (KeyboardInterrupt, 'cancelled'),
                              (OSError, 'failed'), (subprocess.TimeoutExpired, 'failed')):
            error = kind('cmd', 1) if kind is subprocess.TimeoutExpired else kind('x')
            self.assertEqual(COMMON.outcome_of(error), outcome, kind)
            self.assertIn(outcome, COMMON.OUTCOMES)
            if kind not in (COMMON.Cancelled, KeyboardInterrupt, OSError, subprocess.TimeoutExpired):
                self.assertTrue(issubclass(kind, COMMON.Failed))
        with self.assertRaises(COMMON.Unavailable):
            COMMON.require(False, 'gone', COMMON.Unavailable)

    def test_a_decisive_outcome_outranks_and_a_specific_one_is_kept(self):
        result = {}
        for outcome, kept in (('failed', 'failed'), ('unavailable', 'unavailable'),
                              ('failed', 'unavailable'), ('rig-tool-mismatch', 'unavailable'),
                              ('usb-stopped', 'usb-stopped'), ('failed', 'usb-stopped'),
                              ('cancelled', 'cancelled'), ('usb-stopped', 'cancelled')):
            COMMON.note_outcome(result, outcome)
            self.assertEqual(result['outcome'], kept, outcome)

    def test_settling_keeps_status_and_says_the_outcome(self):
        for result, outcome in ((dict(status='passed'), 'passed'), (dict(status='observed'), 'passed'),
                                (dict(status='failed'), 'failed'), (dict(status='pending'), 'failed'),
                                (dict(status='failed', outcome='unavailable'), 'unavailable'),
                                (dict(status='failed', outcome='passed'), 'failed')):
            status = result['status']
            self.assertEqual(COMMON.settle_result(result)['outcome'], outcome)
            self.assertEqual(result['status'], status)
            self.assertNotIn('cancelled', result)

    def test_a_result_written_while_a_cancellation_unwinds_is_cancelled_with_its_phase(self):
        run = SimpleNamespace(current='flash', commands=[dict(name='compile')],
                              pace=SimpleNamespace(last_action='download'))
        try:
            raise COMMON.Cancelled('SIGINT')
        except KeyboardInterrupt:
            result = COMMON.settle_result(dict(status='passed'), run)
        self.assertEqual(result['outcome'], 'cancelled')
        self.assertEqual(result['status'], 'failed')
        self.assertEqual(result['cancelled']['phase'],
                         dict(command='flash', command_state='running', action='download'))
        self.assertEqual(result['failure'], 'cancelled by SIGINT')
        with mock.patch.object(COMMON, 'CANCELLATION', dict(signal='SIGTERM', received=1.0)):
            result = COMMON.settle_result(dict(status='failed', failure='hub did not list'),
                                          SimpleNamespace(current=None, commands=[dict(name='hub-wait')]))
        self.assertEqual(result['cancelled'], dict(signal='SIGTERM', received=1.0,
                         phase=dict(command='hub-wait', command_state='completed')))
        self.assertEqual(result['failure'], 'hub did not list; cancelled by SIGTERM')

    def test_refusals_for_an_absent_rig_are_unavailable(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(COMMON.Unavailable):
                COMMON.cascade_root(sysfs=Path(tmp))
            with self.assertRaises(COMMON.Unavailable):
                COMMON.off_cascade('210319B3E738', '1-1.2', Path(tmp))
            self.assertIsInstance(COMMON.unopened(None, 'for USB serial X', 1), COMMON.Unavailable)
        hub = mock.Mock()
        hub.command.return_value = 'Current status for hub 1-1.2 [0bda:5411]\n  Port 1: 0100 power\n'
        with self.assertRaises(COMMON.Unavailable):
            COMMON.power_cycle(hub, '1-1.2', 1, 1.0, holds='A0:76')
        hub.command.assert_called_once()

    def test_a_missing_or_stale_helper_is_a_tool_mismatch(self):
        with self.assertRaises(COMMON.ToolMismatch):
            COMMON.verify_ram_helper(SimpleNamespace(ram_loader='/nonexistent/landin-ram-run'))
        stale = SimpleNamespace(returncode=0, stderr='', stdout=json.dumps(dict(
            protocol_version=1, source_sha256='0' * 64, probe_rs_revision=COMMON.HELPER_PROBE_REVISION)))
        with mock.patch.object(COMMON.subprocess, 'run', return_value=stale), \
                self.assertRaises(COMMON.ToolMismatch):
            COMMON.verify_ram_helper(SimpleNamespace(ram_loader='loader'))

    def test_a_pico_2_boot_check_on_the_cascade_needs_setup(self):
        import pico2
        with self.assertRaises(pico2.common.NeedsSetup):
            pico2.boot_location(SimpleNamespace(mode='boot', hub='1-1.2.3', cascade='1-1.2'))
        pico2.boot_location(SimpleNamespace(mode='ram', hub='1-1.2.3', cascade='1-1.2'))

    def test_a_power_only_pico_2_may_boot_on_the_cascade_but_never_by_uf2(self):
        import pico2
        pico2.boot_location(SimpleNamespace(mode='boot', hub='1-1.2.3', cascade='1-1.2',
                                            power_only=True))
        with self.assertRaisesRegex(pico2.common.Failed, 'cannot copy a UF2'):
            pico2.boot_location(SimpleNamespace(mode='boot', hub='1-1.2.3', cascade='1-1.2',
                                                power_only=True, boot_transport='manual-uf2'))

    def test_a_power_only_port_is_switched_only_while_it_shows_no_device(self):
        quiet = STATUS.replace('0103 power enable connect [0483:374e STMicroelectronics STLINK-V3'
                               ' 001900293137511339383538]', '0100 power')
        hub = Recorded(**{'hub-status': quiet})
        COMMON.power_cycle(hub, '7-2.3', 2, 1.0, holds_nothing=True)
        self.assertEqual([n for n, _ in hub.calls], ['hub-status', 'power-cycle'])
        hub = Recorded(**{'hub-status': STATUS})
        with self.assertRaisesRegex(COMMON.NeedsOperator, 'declared power-only'):
            COMMON.power_cycle(hub, '7-2.3', 2, 1.0, holds_nothing=True)
        self.assertEqual([n for n, _ in hub.calls], ['hub-status'])

    def test_an_action_s_own_refusal_survives_a_failed_completion(self):
        pace = mock.Mock()
        pace.after.side_effect = COMMON.Failed('journal unreadable')
        def action():
            raise COMMON.Unavailable('port 2 holds nothing')
        with self.assertRaises(COMMON.Unavailable) as raised:
            COMMON.paced(pace, 'power cycle', action)
        self.assertIn('action completion: journal unreadable', str(raised.exception))
        pace.after.side_effect = COMMON.USBGuardError('HC died')
        with self.assertRaises(COMMON.USBGuardError):
            COMMON.paced(pace, 'power cycle', action)

    def test_restoration_failures_and_usb_stops_keep_their_outcome(self):
        args = SimpleNamespace(mode='boot', pace=mock.Mock(), fixed_image=Path('fixed.elf'))
        args.pace.before.side_effect = COMMON.USBGuardError('HC died')
        result = dict(status='passed')
        COMMON.finish_boot(args, result, mock.Mock())
        self.assertEqual(COMMON.settle_result(result)['outcome'], 'usb-stopped')
        pace = mock.Mock()
        pace.check.side_effect = COMMON.USBGuardError('HC died')
        pace.evidence.return_value = {}
        result = dict(status='passed')
        COMMON.retain_kernel_usb(pace, result)
        self.assertEqual((result['status'], result['outcome']), ('failed', 'usb-stopped'))


class Cancellation(unittest.TestCase):
    def setUp(self):
        previous = {number: signal.getsignal(number) for number in (signal.SIGINT, signal.SIGTERM)}
        for number, handler in previous.items():
            self.addCleanup(signal.signal, number, handler)
        patcher = mock.patch.object(COMMON, 'CANCELLATION', None)
        patcher.start()
        self.addCleanup(patcher.stop)
        quiet = mock.patch('sys.stderr', new=io.StringIO())
        quiet.start()
        self.addCleanup(quiet.stop)
        COMMON.handle_cancellation()

    def test_the_first_signal_raises_once_and_later_ones_are_noted(self):
        with self.assertRaises(COMMON.Cancelled):
            os.kill(os.getpid(), signal.SIGINT)
            time.sleep(PATIENCE)
        self.assertTrue(COMMON.cancelled())
        os.kill(os.getpid(), signal.SIGTERM)
        self.assertEqual(COMMON.CANCELLATION['signal'], 'SIGINT')
        self.assertEqual(COMMON.CANCELLATION['repeated'], ['SIGTERM'])

    def test_an_action_that_disconnects_a_device_is_not_cut_short(self):
        events = []
        with self.assertRaises(COMMON.Cancelled):
            with COMMON.uninterrupted():
                os.kill(os.getpid(), signal.SIGTERM)
                events.append('the cycle completed')
            events.append('never')
        self.assertEqual(events, ['the cycle completed'])
        self.assertEqual(COMMON.CANCELLATION['signal'], 'SIGTERM')

    def test_a_deferred_cancellation_does_not_hide_the_action_s_own_failure(self):
        with self.assertRaises(COMMON.Unavailable):
            with COMMON.uninterrupted():
                os.kill(os.getpid(), signal.SIGINT)
                raise COMMON.Unavailable('the hub did not list')
        self.assertTrue(COMMON.cancelled())

    def test_a_cancelled_boot_check_does_not_begin_or_finish_restoration(self):
        args = SimpleNamespace(mode='boot', pace=mock.Mock(), fixed_image=Path('fixed.elf'))
        restore = mock.Mock()
        with mock.patch.object(COMMON, 'CANCELLATION', dict(signal='SIGINT')):
            result = dict(status='passed')
            COMMON.finish_boot(args, result, restore)
        restore.assert_not_called()
        self.assertEqual(result['fixed_restore'], dict(status='pending',
                         reason='cancelled before resident image restoration'))
        self.assertEqual(result['status'], 'failed')
        result = dict(status='passed')
        COMMON.finish_boot(args, result, mock.Mock(side_effect=COMMON.Cancelled('SIGINT')))
        self.assertEqual(result['fixed_restore']['reason'], 'cancelled during resident image restoration')
        self.assertEqual(result['outcome'], 'cancelled')
        args.manual_boot = mock.Mock()
        with self.assertRaises(KeyboardInterrupt):
            COMMON.finish_boot(args, dict(status='passed'), mock.Mock(side_effect=COMMON.Cancelled('SIGINT')))

    def test_a_tool_s_preflight_refusal_is_written_as_its_result(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / 'run'

            def main():
                raise COMMON.NeedsSetup('Pico 2 boot checks must be off the cascade')
            with mock.patch('sys.stderr'):
                self.assertEqual(COMMON.tool_main(main, ['--mode=boot', '--output', str(output)]), 1)
            result = json.loads((output / 'result.json').read_text())
            self.assertEqual((result['status'], result['outcome'], result['phase']),
                             ('failed', 'needs-setup', 'preflight'))
            # A tool that wrote its own result keeps it.
            (output / 'result.json').write_text('{"status": "failed", "outcome": "unavailable"}\n')
            with mock.patch('sys.stderr'):
                COMMON.tool_main(main, ['--output=' + str(output)])
            self.assertEqual(json.loads((output / 'result.json').read_text())['outcome'], 'unavailable')
        self.assertEqual(COMMON.tool_main(lambda: 0, []), 0)

    def test_a_cancelled_tool_exits_as_the_signal_says(self):
        def cancelled(name):
            def main():
                os.kill(os.getpid(), getattr(signal, name))
                time.sleep(PATIENCE)
            return main
        self.assertEqual(COMMON.tool_main(cancelled('SIGINT'), []), 130)
        COMMON.CANCELLATION = None
        self.assertEqual(COMMON.tool_main(cancelled('SIGTERM'), []), 143)


class Echo(unittest.TestCase):
    """The Pico 2 tools' probe check after a cycle: one ICMP echo through an
    unprivileged socket, summarised as ping's last line, with no host tool."""
    class Socket:
        def __init__(self, replies):
            self.replies, self.sent = replies, []

        def settimeout(self, _):
            pass

        def sendto(self, packet, address):
            self.sent.append((packet, address))

        def recvfrom(self, _):
            if not self.replies:
                raise COMMON.socket.timeout()
            reply = self.replies.pop(0)
            return reply(self.sent[-1][0][8:]), ('10.42.0.50', 0)

    def test_only_the_reply_carrying_this_request_s_payload_counts(self):
        sock = self.Socket([lambda payload: b'\x00\x00\x00\x00\x00\x00\x00\x01' + b'x' * 16,
                            lambda payload: b'\x08' + b'\x00' * 7 + payload,
                            lambda payload: b'\x00' + b'\x00' * 7 + payload])
        self.assertTrue(COMMON.icmp_echo('10.42.0.50', 1.0, sock))
        packet, address = sock.sent[0]
        self.assertEqual((packet[0], packet[1], address), (8, 0, ('10.42.0.50', 0)))
        self.assertFalse(COMMON.icmp_echo('10.42.0.50', 0.05, self.Socket([])))

    def test_the_command_prints_ping_s_summary_and_names_a_refused_socket(self):
        for answered, status, line in ((True, 0, ' 0% packet loss'), (False, 1, ' 100% packet loss')):
            with mock.patch.object(COMMON, 'icmp_echo', return_value=answered), \
                    contextlib.redirect_stdout(io.StringIO()) as out:
                self.assertEqual(COMMON.main(['echo', '10.42.0.50']), status)
            self.assertIn(line, out.getvalue())
        with mock.patch.object(COMMON, 'icmp_echo', side_effect=PermissionError('denied')), \
                contextlib.redirect_stderr(io.StringIO()) as err:
            self.assertEqual(COMMON.main(['echo', '10.42.0.50']), 2)
        self.assertIn('ping_group_range', err.getvalue())

class FakeLineBoard:
    """A board port's side of the line exchange, as the H753 app answers it
    with the H753 tool's own oracle: each byte echoed, a request answered
    with an `l` frame, the line changed after it, BACK answered with an `e`
    frame, and REPORT with a `t` frame counting what was handled.  A byte
    sent while the two ends' lines differ arrives as 0xff, as a framing
    error would; NOISE adds bytes the next time the host changes line.  The
    USART leaves a parity bit above seven data bits in what it receives, as
    RM0433's Table 408 says the STM32H753's RDR does; the port's read takes
    it off, unless KEEPS_PARITY, the fault a rig run found (D965)."""
    configurable = True

    def __init__(self, oracle, noise=b'', wrong=None, keeps_parity=False):
        self.oracle, self.noise, self.wrong = oracle, noise, wrong
        self.keeps_parity = keeps_parity
        self.received, self.sent = bytearray(), bytearray()
        self.host = self.board = COMMON.DEFAULT_LINE
        self.digits, self.handled, self.changed, self.counted = None, 0, False, b''

    def frame(self, tag, **fields):
        self.received += (b'\x02' + tag.encode() + b''.join(
            b' %s=%08x' % (k.encode(), v) for k, v in fields.items()) + b'\x03\n')

    def line(self, *setting):
        self.host = setting
        self.received += self.noise
        self.noise = b''

    def received_byte(self, byte):
        """BYTE as the application reads it on the board's line."""
        _, data_bits, parity, _ = self.board
        if parity == 'none' or data_bits >= 8 or not self.keeps_parity:
            return byte
        ones = bin(byte).count('1') % 2
        return byte | (ones if parity == 'even' else 1 - ones) << data_bits

    def send(self, data, pace=64):
        self.sent += data
        for byte in data:
            if self.host != self.board:
                byte = 0xff
            # The transmitter makes its own parity bit: the host reads the
            # data bits back, whatever the application kept.
            self.received.append(byte)
            byte = self.received_byte(byte)
            self.handled += 1
            if self.changed and byte != COMMON.BACK:
                self.counted += bytes([byte])
            if self.digits is not None:
                self.digits += chr(byte)
                if len(self.digits) == 11:
                    self.answer(self.digits)
                    self.digits = None
            elif byte == COMMON.LINE:
                self.digits = ''
            elif byte == COMMON.BACK and self.changed:
                self.frame('e', n=len(self.counted), h=COMMON.fnv1a(self.counted))
                self.board, self.changed = COMMON.DEFAULT_LINE, False
            elif byte == 0x11:
                self.frame('t', h=self.handled, c=0)

    def answer(self, digits):
        value = ''.join('%x' % (ord(d) - 97) for d in digits)
        rate, data, parity, stop = int(value[:8], 16), int(value[8], 16), int(value[9]), int(value[10])
        setting = (rate, data, COMMON.PARITIES[parity], stop)
        outcome, images = self.oracle(setting, 64000000)
        fields = dict(r=rate, d=data, p=parity, s=stop, k=64000000,
                      o={v: k for k, v in COMMON.LINE_OUTCOMES.items()}[outcome])
        if images:
            fields.update(images)
            if self.wrong:
                fields.update(self.wrong)
        self.frame('l', **fields)
        if outcome == 'accepted':
            self.board, self.changed, self.counted = setting, True, b''

    def wait(self, predicate, seconds, what):
        if predicate(bytes(self.received)):
            return bytes(self.received)
        raise COMMON.Failed('waited for %s' % what)


class LineExchange(unittest.TestCase):
    """The host's half of the line exchange (D962) against a fake board, with
    the H753 tool's own plan and oracle."""

    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location(
            'h753_board', ROOT / 'environments/boards/stm32h753/board.py')
        cls.board = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.board)

    def report(self, console):
        return COMMON.ask(console, 0x11, 't', len(COMMON.tagged(bytes(console.received), 't')))

    def run_plan(self, board, plan=None):
        import random
        with mock.patch.object(COMMON.time, 'sleep'):
            return COMMON.line_phase(board, plan or self.board.LINE_PLAN, self.board.line_oracle,
                                     self.report, random.Random(1))

    def test_every_setting_of_the_plan_is_exchanged_or_refused(self):
        board = FakeLineBoard(self.board.line_oracle)
        verdict, last = self.run_plan(board)
        self.assertEqual(verdict['status'], 'passed')
        self.assertEqual([(e['line'], e['outcome']) for e in verdict['settings']],
                         [('230400-8N1', 'accepted'), ('9600-8E1', 'accepted'),
                          ('57600-7O2', 'accepted'), ('300-8N1', 'unsupported_rate'),
                          ('115200-6N1', 'unsupported_format')])
        self.assertEqual(verdict['settings'][1]['registers'],
                         {'b': '0x1a0b', 'f': '0x1400', 'x': '0x0'})
        self.assertEqual(verdict['settings'][2]['registers'],
                         {'b': '0x457', 'f': '0x600', 'x': '0x2000'})
        self.assertEqual(last['h'], len(board.sent))
        self.assertEqual(board.host, COMMON.DEFAULT_LINE)

    def test_a_board_on_another_line_than_the_host_fails_the_echo(self):
        board = FakeLineBoard(self.board.line_oracle)
        board.line = lambda *setting: None
        with self.assertRaisesRegex(COMMON.Failed, 'waited for the exchange frame'):
            self.run_plan(board)

    def test_bytes_while_the_lines_change_fail_the_exchange(self):
        board = FakeLineBoard(self.board.line_oracle, noise=b'\x00')
        with self.assertRaisesRegex(COMMON.Failed, 'while the line changed'):
            self.run_plan(board)

    def test_wrong_register_images_fail_the_exchange(self):
        board = FakeLineBoard(self.board.line_oracle, wrong=dict(b=555))
        with self.assertRaisesRegex(COMMON.Failed, 'programs'):
            self.run_plan(board)

    def test_a_refusal_the_plan_does_not_expect_fails(self):
        board = FakeLineBoard(self.board.line_oracle)
        with self.assertRaisesRegex(COMMON.Failed, 'the plan expects'):
            self.run_plan(board, [((300, 8, 'none', 1), 'accepted')])

    def test_a_parity_bit_kept_above_the_data_loses_the_terminator(self):
        # 0x17 has four ones, so under odd parity its parity bit is one and
        # a read that kept it sees 0x97: the echo is right, as on the rig,
        # and no exchange frame comes.
        board = FakeLineBoard(self.board.line_oracle, keeps_parity=True)
        with self.assertRaisesRegex(COMMON.Failed, 'on 57600-7O2 the board echoed the payload'
                                    ' and 0x17 but sent no exchange frame'):
            self.run_plan(board)
        self.assertIn(((57600, 7, 'odd', 2), 'accepted'), self.board.LINE_PLAN)

    def test_a_fixed_console_is_not_run_and_says_why(self):
        verdict, last = COMMON.line_phase(mock.Mock(), [], None, None, None)
        self.assertEqual(verdict, {'status': 'not run: probehive bridge fixed at 115200 8N1'})
        self.assertIsNone(last)
        self.assertEqual(COMMON.TcpConsole.fixed, COMMON.FIXED_LINE)


if __name__ == '__main__':
    unittest.main()
