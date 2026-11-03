#!/usr/bin/env python3
"""Controls for the shared board tooling, without a board, a probe or a hub
(D646): every part environments/boards/common.py gives a board's tool, held
to fixed inputs on the standard library alone."""
import argparse
import importlib.util
import json
import os
import select
import socket
import struct
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
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


STATUS = """Current status for hub 7-2.3 [0bda:5411 Generic USB2.1 Hub, USB 2.10, 4 ports, ppps]
  Port 1: 0100 power
  Port 2: 0103 power enable connect [0483:374e STMicroelectronics STLINK-V3 001900293137511339383538]
  Port 3: 0100 power
  Port 4: 0503 power highspeed enable connect [0403:6010 Digilent Digilent USB Device 210319B3E738]
"""


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
            self.assertTrue((Path(out) / 'say.log').read_text().endswith('hi\n'))


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


class Probes(unittest.TestCase):
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
        try:
            console = COMMON.TtyConsole(os.ttyname(line))
            try:
                console.send(b'S1', pace=1)
                self.assertEqual(read_exactly(controller, 2),
                                 b'S1')
                os.write(controller, b'\x02b r=00fa0000\x03\nS')
                stream = console.wait(lambda s: s.endswith(b'S'), PATIENCE, 'the echo')
                self.assertEqual(COMMON.tagged(stream, 'b'), [{'r': 0x00fa0000}])
                self.assertEqual(bytes(console.sent), b'S1')
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
            said, done = [], threading.Event()
            first = COMMON.RigLock('rp2350 board.py', path).acquire()

            def second():
                with COMMON.RigLock('esp32c5 board.py', path, report=said.append):
                    done.set()
            waiter = threading.Thread(target=second)
            waiter.start()
            self.assertFalse(done.wait(0.3))
            self.assertEqual(len(said), 1)
            self.assertIn('esp32c5 board.py waits for the rig lock', said[0])
            self.assertIn('held by rp2350 board.py, process %d' % os.getpid(), said[0])
            first.release()
            self.assertTrue(done.wait(5))
            waiter.join(5)

    def test_a_run_under_its_parent_s_flock_goes_on(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'rig.lock'
            outer = COMMON.RigLock('flock by hand', path).acquire()
            locks = Path(tmp) / 'locks'
            locks.write_text('1: FLOCK  ADVISORY  WRITE %d 00:22:%d 0 EOF\n'
                             % (os.getppid(), os.stat(path).st_ino))
            inner = COMMON.RigLock('esp32c3 board.py', path, report=self.fail, locks=locks)
            inner.acquire()
            inner.release()
            outer.release()

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

    def test_ancestors_begin_with_this_process(self):
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
                           kernel=lambda seconds: [l for l in lines if l[0] >= clock[0] - seconds],
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

    def test_loader_matches_the_bundle_identity_and_checks_usb_after_the_call(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            elf = self.image(out / 'board.elf')
            pace = mock.Mock()
            args = SimpleNamespace(probe='0000:0002:10.42.0.50/0', ram_loader='loader', pace=pace)
            report = dict(format_version=1, status='passed', mode='warm', flash_written=False,
                          board='rp2040', elf_sha256=COMMON.sha(elf))
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
        journal = SimpleNamespace(stdout='1.0 brcmfmac: firmware error -2\n2.0 xhci_hcd: HC died\n')
        with mock.patch.object(COMMON.subprocess, 'run', return_value=journal):
            self.assertEqual(COMMON.kernel_usb_lines(3), [(2.0, 'xhci_hcd: HC died')])


if __name__ == '__main__':
    unittest.main()
