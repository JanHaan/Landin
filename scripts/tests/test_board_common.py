#!/usr/bin/env python3
"""Controls for the shared board tooling, without a board, a probe or a hub
(D646): every part environments/boards/common.py gives a board's tool, held
to fixed inputs on the standard library alone."""
import importlib.util
import os
import socket
import struct
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('common', ROOT / 'environments/boards/common.py')
COMMON = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(COMMON)


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

    def test_a_tty_console_keeps_every_byte_each_way(self):
        controller, line = os.openpty()
        try:
            console = COMMON.TtyConsole(os.ttyname(line))
            try:
                console.send(b'S1', pace=1)
                self.assertEqual(os.read(controller, 2), b'S1')
                os.write(controller, b'\x02b r=00fa0000\x03\nS')
                stream = console.wait(lambda s: s.endswith(b'S'), 5, 'the echo')
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
            thread.join(5)
            peer = accepted[0]
            console.send(b'1A0')
            self.assertEqual(peer.recv(3), b'1A0')
            peer.sendall(b'1A0')
            self.assertEqual(console.wait(lambda s: len(s) == 3, 5, 'the echo'), b'1A0')
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


if __name__ == '__main__':
    unittest.main()
