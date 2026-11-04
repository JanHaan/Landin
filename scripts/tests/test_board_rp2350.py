#!/usr/bin/env python3
"""Controls for the RP2350 board tool's oracle, without a board (D655): the
IMAGE_DEF block it expects, the corrupted copy of its negative control and
that control's reading of the hub, the hub's guard while the Pico 2 does
not enumerate, the pace and the wait for the hub around each download and
cycle, every download as RP235x followed at once by a cycle (D712,
D832), and the
framing and accounting it shares with the RP2040's."""
import argparse
import importlib.util
import struct
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


BOARD = load('board_rp2350', 'environments/boards/rp2350/board.py')
ELF = load('test_board_common', 'scripts/tests/test_board_common.py').elf32
HANDSHAKE = load('test_rp_startup', 'scripts/tests/test_board_rp2040.py')

SERIAL = 'E661A4D4171B5D2E'
GUARD = '  Port 4: 0503 power highspeed enable connect [0403:6010 Digilent Digilent USB Device 210319B3E738]\n'
QUIET = ('Current status for hub 7-2.3.3 [0bda:5411 Generic USB2.1 Hub, USB 2.10, 4 ports, ppps]\n'
         '  Port 1: 0100 power\n  Port 2: 0101 power connect\n  Port 3: 0100 power\n' + GUARD)
BOOTSEL = QUIET.replace('  Port 2: 0101 power connect\n',
                        '  Port 2: 0103 power enable connect [2e8a:000f Raspberry Pi RP2350 %s]\n' % SERIAL)


class Startup(unittest.TestCase):
    def test_uart_opens_after_ram_loading_and_before_boot_power(self):
        for mode in ('ram', 'boot'):
            with self.subTest(mode=mode):
                HANDSHAKE.console_order(self, BOARD, (b'', {}), mode=mode)

    def test_startup_ack_precedes_boot_frame_and_application_traffic(self):
        HANDSHAKE.startup_order(self, BOARD)

    def test_startup_retries_a_lost_ack_with_a_bounded_wait(self):
        HANDSHAKE.startup_retry(self, BOARD)


class Paced:
    """A pace that records each action it spaces."""
    def __init__(self, calls):
        self.calls = calls

    def before(self, what):
        self.calls.append('before ' + what)

    def after(self, what):
        self.calls.append('after ' + what)


class Recorded:
    """A tool's commands: every call kept, each name answered, and each
    status recorded as Run records it."""
    def __init__(self, statuses=None, **answers):
        self.answers, self.statuses, self.calls, self.commands = answers, statuses or {}, [], []

    def command(self, name, argv, **_):
        self.calls.append(name)
        self.commands.append(dict(name=name, status=self.statuses.get(name, 0)))
        answer = self.answers.get(name, bytes(4) if name.startswith(('attach-', 'reattach-')) else '')
        if isinstance(answer, list):
            answer = answer.pop(0) if len(answer) > 1 else answer[0]
        return HANDSHAKE.helper_fixture_command(self, name, argv, answer,
            board='rp2350', probe=ARGS['probe'])


def image(block):
    vectors = struct.pack('<%dI' % BOARD.VECTOR_WORDS, *([0x20082000] + [0x10000201] * 67))
    words = struct.pack('<5I', *block)
    return ELF([('.isr_vector', BOARD.VECTORS, vectors),
                ('.embedded_block', BOARD.VECTORS + len(vectors), words)],
               [(BOARD.VECTORS, '.isr_vector'), (BOARD.VECTORS + len(vectors), '.embedded_block')])


class Block(unittest.TestCase):
    def test_the_expected_block_is_the_datasheet_s_minimum_arm_image_def(self):
        # 5.9.5.1, Table 503: IMAGE_TYPE is item type 0x42, one word, its
        # flags 0x1021 above; LAST is type 0x7f with the size flag, 0xff,
        # then the other items' one word; the link to itself is zero.
        image_type = 0x42 | 1 << 8 | 0x1021 << 16
        last = 0xff | 1 << 8
        self.assertEqual(BOARD.IMAGE_DEF, (0xffffded3, image_type, last, 0, 0xab123579))

    def test_the_corrupted_copy_differs_in_its_end_marker_alone(self):
        with tempfile.TemporaryDirectory() as out:
            path = Path(out) / 'board.elf'
            path.write_bytes(image(BOARD.IMAGE_DEF))
            run = SimpleNamespace(out=Path(out))
            bad = BOARD.corrupted(run, path)
            good_bytes, bad_bytes = path.read_bytes(), bad.read_bytes()
            self.assertEqual(len(good_bytes), len(bad_bytes))
            differ = [i for i, (a, b) in enumerate(zip(good_bytes, bad_bytes)) if a != b]
            self.assertEqual(len(differ), 4)
            data, sections = BOARD.elf_sections(bad)
            self.assertEqual(BOARD.block_of(data, sections)[2][-1], 0xab123579 ^ 0xffffffff)
            self.assertEqual(BOARD.block_of(data, sections)[2][:-1], BOARD.IMAGE_DEF[:-1])

    def test_a_block_of_another_size_is_refused(self):
        with tempfile.TemporaryDirectory() as out:
            path = Path(out) / 'board.elf'
            path.write_bytes(ELF([('.embedded_block', 0x10000110, bytes(16))],
                                 [(0x10000110, '.embedded_block')]))
            data, sections = BOARD.elf_sections(path)
            with self.assertRaises(BOARD.Failed):
                BOARD.block_of(data, sections)


ARGS = dict(hub='7-2.3.3', port=2, guard_serial='210319B3E738', cascade='7-2', off_seconds=0,
            pico_serial=SERIAL, hub_group=None, enumerate_seconds=1.0, probe_rs='probe-rs',
            probe='0000:0002:10.42.0.50/1', guard_seconds=0, boot_seconds=0,
            bootsel_attach=False, probe_host='10.42.0.50', ram_loader='ram-loader')
PING = '1 packets transmitted, 1 received, 0% packet loss, time 0ms\n'


def paced_args(run, **more):
    """ARGS with a pace that records into RUN's calls."""
    return SimpleNamespace(**dict(ARGS, pace=Paced(run.calls), **more))


def answers(**more):
    """The answers a clean guarded cycle gets."""
    found = {'hub-status': QUIET, 'hub-wait': QUIET, 'probe-ping': PING,
             'hub-before-attach': QUIET}
    found.update(more)
    return found


class RamGuard(unittest.TestCase):
    """Read-only USB topology controls, including failures ordinary root-run
    fixture permissions cannot reproduce with chmod alone."""
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.sysfs = Path(directory.name)
        self.hub = self.sysfs / '1-1'
        self.child = self.sysfs / '1-1.2'
        self.device(self.hub, idVendor='0424', idProduct='2514',
                    bDeviceClass='09', maxchild='4')
        patcher = mock.patch.object(BOARD.pico2, 'USB_SYSFS', self.sysfs)
        patcher.start()
        self.addCleanup(patcher.stop)

    def device(self, path, **attributes):
        path.mkdir(exist_ok=True)
        for name, value in attributes.items():
            (path / name).write_text(value + '\n')

    def guard(self, **more):
        run = Recorded()
        args = SimpleNamespace(**dict(dict(mode='ram', hub='1-1', port=2,
            bootsel_attach=True, cascade='9-9'), **more))
        try:
            return BOARD.pico2.refuse_bootsel(run, args, allowed=True)
        finally:
            self.assertEqual(run.calls, [], 'RAM guard must issue no USB or probe commands')

    def test_silent_selected_port_needs_no_uhubctl_or_cascade(self):
        # BOOTSEL at a different port must not be mistaken for our Pico.
        self.device(self.sysfs / '1-1.3', idVendor='2e8a', idProduct='000f')
        self.assertIsNone(self.guard())

    def test_present_non_bootsel_identity_is_accepted_without_commands(self):
        self.device(self.child, idVendor='2e8a', idProduct='000a')
        self.assertIsNone(self.guard())

    def test_bootsel_is_refused_even_with_both_legacy_overrides(self):
        self.device(self.child, idVendor='2E8A', idProduct='000F')
        with self.assertRaisesRegex(BOARD.Failed, 'enumerates as BOOTSEL 2e8a:000f'):
            self.guard()

    def test_missing_parent_is_not_a_silent_port(self):
        with self.assertRaisesRegex(BOARD.Failed, 'cannot inspect USB hub'):
            self.guard(hub='1-9')

    def test_parent_must_be_a_valid_hub_with_a_valid_port_count(self):
        controls = [('idVendor', 'garbled', 'malformed'),
                    ('idProduct', '', 'malformed'),
                    ('bDeviceClass', '00', 'not a hub'),
                    ('bDeviceClass', '9', 'malformed'),
                    ('maxchild', 'zero', 'malformed'),
                    ('maxchild', '9' * 5000, 'malformed'),
                    ('maxchild', '0', 'invalid physical port count'),
                    ('maxchild', '256', 'invalid physical port count')]
        for attribute, value, message in controls:
            with self.subTest(attribute=attribute, value=value):
                path = self.hub / attribute
                original = path.read_bytes()
                path.write_text(value)
                try:
                    with self.assertRaisesRegex(BOARD.Failed, message):
                        self.guard()
                finally:
                    path.write_bytes(original)

    def test_requested_port_must_exist_on_the_selected_hub(self):
        for port in (0, -1, True, '2', 5):
            with self.subTest(port=port), self.assertRaisesRegex(BOARD.Failed, 'port'):
                self.guard(port=port)

    def test_hub_name_cannot_escape_or_select_an_interface(self):
        for hub in ('../1-1', '1-1/..', '1-1:1.0', '.1', '1-1.0'):
            with self.subTest(hub=hub), self.assertRaisesRegex(BOARD.Failed, 'concrete USB hub'):
                self.guard(hub=hub)

    def test_missing_or_malformed_child_identity_is_not_silent(self):
        self.device(self.child, idVendor='2e8a')
        with self.assertRaisesRegex(BOARD.Failed, 'cannot read .*idProduct'):
            self.guard()
        for value in ('000f extra', '00f', 'not-a-product'):
            with self.subTest(value=value):
                (self.child / 'idProduct').write_text(value)
                with self.assertRaisesRegex(BOARD.Failed, 'malformed .*idProduct'):
                    self.guard()

    def test_non_ascii_attribute_fails_with_its_path(self):
        self.device(self.child, idVendor='2e8a', idProduct='000f')
        (self.child / 'idProduct').write_bytes(b'\xff\n')
        with self.assertRaisesRegex(BOARD.Failed, 'cannot read .*idProduct'):
            self.guard()

    def test_unreadable_parent_and_child_attributes_fail_closed(self):
        self.device(self.child, idVendor='2e8a', idProduct='000f')
        read_text = Path.read_text
        for path in (self.hub / 'idVendor', self.hub / 'maxchild', self.child / 'idProduct'):
            def unreadable(at, *args, **kwargs):
                if at == path:
                    raise PermissionError('synthetic read denial')
                return read_text(at, *args, **kwargs)
            with self.subTest(path=path), mock.patch.object(Path, 'read_text', unreadable), \
                    self.assertRaisesRegex(BOARD.Failed, 'cannot read .*synthetic read denial'):
                self.guard()

    def test_unreadable_child_lookup_is_not_silent(self):
        lstat = Path.lstat
        def unreadable(at, *args, **kwargs):
            if at == self.child:
                raise PermissionError('synthetic lookup denial')
            return lstat(at, *args, **kwargs)
        with mock.patch.object(Path, 'lstat', unreadable), \
                self.assertRaisesRegex(BOARD.Failed, 'cannot inspect USB child .*lookup denial'):
            self.guard()

    def test_disappearing_parent_is_not_a_silent_port(self):
        lstat = Path.lstat
        def disconnected(at, *args, **kwargs):
            if at == self.child:
                (self.hub / 'maxchild').unlink()
                raise FileNotFoundError('synthetic disconnect')
            return lstat(at, *args, **kwargs)
        with mock.patch.object(Path, 'lstat', disconnected), \
                self.assertRaisesRegex(BOARD.Failed, 'cannot read .*maxchild'):
            self.guard()

    def test_dangling_child_link_is_not_a_silent_port(self):
        self.child.symlink_to(self.sysfs / 'gone')
        with self.assertRaisesRegex(BOARD.Failed, 'cannot read .*idVendor'):
            self.guard()

    def test_root_hub_uses_its_linux_directory_and_physical_child(self):
        self.hub.rename(self.sysfs / 'usb1')
        self.assertIsNone(self.guard(hub='1-0'))
        self.device(self.sysfs / '1-2', idVendor='2e8a', idProduct='000f')
        with self.assertRaisesRegex(BOARD.Failed, 'enumerates as BOOTSEL'):
            self.guard(hub='1-0')

    def test_explicit_cascade_override_does_not_require_a_connected_cascade(self):
        args = SimpleNamespace(cascade='9-9', hub='1-1')
        with mock.patch.object(BOARD.common, 'cascade_root', side_effect=AssertionError('scan')):
            BOARD.common.place_hubs(argparse.ArgumentParser(), args, 'hub', sysfs=self.sysfs)
        self.assertEqual((args.cascade, args.hub), ('9-9', '1-1'))
        self.assertIsNone(self.guard(cascade=args.cascade, hub=args.hub))

    def test_explicit_boot_mode_still_uses_the_existing_listing(self):
        run = Recorded(**answers(**{'hub-before-attach': BOOTSEL}))
        with mock.patch.object(BOARD.pico2, 'ram_port_device', side_effect=AssertionError('sysfs')), \
                self.assertRaisesRegex(BOARD.Failed, 'enumerates as BOOTSEL'):
            BOARD.pico2.refuse_bootsel(run, paced_args(run, mode='boot'), allowed=True)
        self.assertEqual(run.calls, ['hub-before-attach'])


class Hub(unittest.TestCase):
    def setUp(self):
        patcher = mock.patch.object(BOARD.common, 'device_location', return_value='7-1.4')
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_a_port_holding_no_device_or_the_pico_2_is_switched(self):
        for status in (QUIET, BOOTSEL):
            hub = Recorded(**answers(**{'hub-status': status}))
            BOARD.power_cycle(hub, paced_args(hub))
            self.assertEqual(hub.calls, ['before power cycle', 'hub-status', 'power-cycle',
                                         'after power cycle', 'hub-wait', 'probe-ping'])

    def test_a_port_holding_another_device_is_not(self):
        hub = Recorded(**answers(**{'hub-status': BOOTSEL.replace(SERIAL, 'SOMEONE-ELSE')}))
        with self.assertRaises(BOARD.Failed):
            BOARD.power_cycle(hub, paced_args(hub))
        self.assertEqual(hub.calls, ['before power cycle', 'hub-status', 'after power cycle'])

    def test_nothing_is_switched_while_the_arty_is_on_the_cascade_or_absent(self):
        for where in ('7-2.3.3.4', None):
            hub = Recorded(**answers())
            with mock.patch.object(BOARD.common, 'device_location', return_value=where), \
                    self.assertRaises(BOARD.Failed):
                BOARD.power_cycle(hub, paced_args(hub))
            self.assertEqual(hub.calls, [])

    def test_the_cycle_waits_for_the_hub_to_list_again(self):
        hub = Recorded(**answers(**{'hub-wait': ['', QUIET]}))
        with mock.patch.object(BOARD.common.time, 'sleep'):
            BOARD.power_cycle(hub, paced_args(hub, guard_seconds=5))
        self.assertEqual(hub.calls.count('hub-wait'), 2)


class Control(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.output = Path(directory.name)
        output = mock.patch.object(Recorded, 'out', self.output, create=True)
        output.start()
        self.addCleanup(output.stop)
        patcher = mock.patch.object(BOARD.common, 'device_location', return_value='7-1.4')
        patcher.start()
        self.addCleanup(patcher.stop)

    def head(self):
        return struct.pack('<%dI' % (BOARD.VECTOR_WORDS + 5),
                           *([0x20082000] + [0x10000201] * 67 + list(BOARD.IMAGE_DEF)))

    def readback(self, head):
        return head

    def test_malformed_block_controls_refuse_before_any_file_or_hardware_action(self):
        for allowed in (False, True):
            with self.subTest(bootsel_attach=allowed):
                run = Recorded()
                args = SimpleNamespace(bootsel_attach=allowed)
                with mock.patch.object(BOARD, 'corrupted') as corrupt:
                    with self.assertRaisesRegex(BOARD.Failed, 'disabled pending an off-cascade UF2'):
                        BOARD.block_control(run, args, 'missing.elf', b'')
                    corrupt.assert_not_called()
                with self.assertRaisesRegex(BOARD.Failed, 'BOOTSEL attachment is always refused'):
                    BOARD.pico2.corrupt(run, args, 'missing.elf', b'', 'bad image')
                self.assertEqual(run.calls, [])

    def test_even_explicit_bootsel_attach_is_refused_before_any_probe_command(self):
        run = Recorded(**answers(**{'hub-before-attach': BOOTSEL}))
        with self.assertRaisesRegex(BOARD.Failed, 'enumerates as BOOTSEL'):
            BOARD.flash(run, paced_args(run, bootsel_attach=True), 'board.elf', b'')
        self.assertEqual(run.calls, ['hub-before-attach'])

    def test_every_download_as_rp235x_is_cycled_at_once_before_the_head_is_read(self):
        # D832: the download's own reset left BOOTSEL's USB device halted on
        # the bus; the cycle precedes any wait for the hub and any attach,
        # and the head is read back from the booted image.
        head = self.head()
        run = Recorded(**answers(**{'flash-readback': self.readback(head)}))
        run.out = self.output
        with mock.patch.object(BOARD.time, 'sleep'):
            self.assertEqual(BOARD.flash(run, paced_args(run), 'board.elf', head), 'RP235x')
        self.assertEqual(run.calls, ['hub-before-attach', 'attach-RP235x', 'before download',
                                     'flash', 'after download', 'hub-status', 'power-cycle',
                                     'after power cycle at once', 'hub-wait', 'probe-ping',
                                     'hub-before-attach', 'reattach-RP235x', 'flash-readback'])

    def test_a_board_left_running_a_risc_v_image_is_flashed_through_its_side(self):
        # D712: a RISC-V image gates the Arm access ports, so RP235x meets a
        # FAULT; the Arm image is flashed as RP235x_riscv, booted by a paced
        # cycle and read back from the Arm cores.
        head = self.head()
        run = Recorded(statuses={'attach-RP235x': 1},
                       **answers(**{'flash-readback': self.readback(head)}))
        run.out = self.output
        with mock.patch.object(BOARD.time, 'sleep'):
            self.assertEqual(BOARD.flash(run, paced_args(run), 'board.elf', head),
                             'RP235x_riscv')
        self.assertEqual(run.calls, ['hub-before-attach', 'attach-RP235x', 'attach-RP235x_riscv',
                                     'before download', 'flash', 'after download',
                                     'before power cycle', 'hub-status', 'power-cycle',
                                     'after power cycle', 'hub-wait', 'probe-ping',
                                     'hub-before-attach', 'reattach-RP235x', 'flash-readback'])

    def test_nothing_attaches_while_the_pico_2_is_in_bootsel(self):
        run = Recorded(**answers(**{'hub-before-attach': BOOTSEL}))
        with self.assertRaisesRegex(BOARD.Failed, 'enumerates as BOOTSEL'):
            BOARD.flash(run, paced_args(run), 'board.elf', self.head())
        self.assertEqual(run.calls, ['hub-before-attach'])
        # The obsolete override cannot bypass the BOOTSEL guard.
        run = Recorded(**answers(**{'hub-before-attach': BOOTSEL}))
        with mock.patch.object(BOARD.time, 'sleep'), \
                self.assertRaisesRegex(BOARD.Failed, 'enumerates as BOOTSEL'):
            BOARD.flash(run, paced_args(run, bootsel_attach=True), 'board.elf', self.head())
        self.assertNotIn('flash-readback', run.calls)


class Framing(unittest.TestCase):
    def test_frames_and_echo_are_the_shared_reading(self):
        stream = b'1\x02t h=00000001 p=0000001e\x03\n'
        self.assertEqual(BOARD.frames_safe(stream), [('t', {'h': 1, 'p': 30})])
        self.assertEqual(BOARD.echo_of(stream), b'1')
        self.assertEqual(BOARD.USBCTRL_SLOT, 30)
        self.assertEqual(BOARD.CHIP_RESET_HAD_POR, 1 << 16)


if __name__ == '__main__':
    unittest.main()
