#!/usr/bin/env python3
"""Offline controls of environments/boards/timing.py: what a timing bundle
calls one image, what it refuses before the rig, how a clock and a run are
read, and how a run is held to its oracle.  No probe, rig or compiler."""
import io
import json
from contextlib import redirect_stdout
from pathlib import Path
import struct
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'environments/boards'))
import build  # noqa: E402
import common  # noqa: E402
import timing  # noqa: E402


def elf(segments, entry=0x20000000, tail=b''):
    """An ELF32 with SEGMENTS, [(address, bytes, memory size)], as PT_LOADs,
    and TAIL after them: bytes no segment loads, as line tables are."""
    at = 52 + 32 * len(segments)
    body, programs = bytearray(), bytearray()
    for address, data, memory in segments:
        programs += struct.pack('<8I', 1, at + len(body), address, address, len(data), memory, 5, 4)
        body += data
    header = bytearray(b'\x7fELF\x01\x01\x01' + bytes(9))
    header += struct.pack('<HHIIIIIHHHHHH', 2, 40, 1, entry, 52, 0, 0, 52, 32,
                          len(segments), 40, 0, 0)
    return bytes(header + programs + body + tail)


class Images(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def write(self, name, data):
        path = self.root / name
        path.write_bytes(data)
        return path

    def test_an_image_is_what_the_board_loads_not_the_elf_file(self):
        """Profiles whose ELF files differ only in what is not loaded, their
        line and frame tables, are one image; a different BSS size, entry or
        byte is another."""
        code = [(0x20000000, b'\x01\x02\x03\x04', 4), (0x20000100, b'', 64)]
        one = timing.loaded_digest(self.write('a.elf', elf(code, tail=b'debug one')))
        self.assertEqual(one, timing.loaded_digest(self.write('b.elf', elf(code, tail=b'other'))))
        for changed in (elf([code[0], (0x20000100, b'', 68)]),
                        elf(code, entry=0x20000002),
                        elf([(0x20000000, b'\x01\x02\x03\x05', 4), code[1]])):
            self.assertNotEqual(one, timing.loaded_digest(self.write('c.elf', changed)))

    def test_instruction_sram_that_is_not_whole_words_is_refused_before_the_rig(self):
        self.assertIsNone(timing.refused('esp32c3', self.write(
            'ok.elf', elf([(0x40380000, bytes(8), 8), (0x3fca0000, bytes(3), 3)]))))
        reason = timing.refused('esp32c3', self.write(
            'odd.elf', elf([(0x40380180, bytes(0x201), 0x201)])))
        self.assertRegex(reason, r'instruction SRAM segment at 0x40380180 holds 513 bytes')
        self.assertIsNone(timing.refused('rp2040', self.write(
            'arm.elf', elf([(0x20000000, bytes(3), 3)]))))

    def test_every_board_is_a_port_with_a_counter_file_a_probe_and_its_ram(self):
        self.assertEqual({b: build.TARGETS[b] for b in timing.BOARDS}, timing.BOARDS)
        self.assertEqual(set(build.TARGETS) - set(timing.BOARDS), {'stm32h753_cached'})
        for board in timing.BOARDS:
            text = (ROOT / timing.COUNTERS / (board + '.ldn')).read_text()
            self.assertIn('import descriptions/%s\n' % board, text)
            self.assertIn('counted: () -> (count: u32) =', text)
            self.assertIn(board, timing.PROBES)
            self.assertEqual({(lo, hi) for lo, hi, _ in timing.REGIONS[board]},
                             set(common.RAM_REGIONS[board]))
        entry = (ROOT / timing.ENTRY).read_text()
        for word in (timing.STATUS, timing.BEFORE, timing.AFTER):
            self.assertIn('mut %s:' % word, entry)

    def test_the_firmware_set_names_fixtures_with_a_status(self):
        workloads = timing.firmware_workloads()
        self.assertTrue(workloads)
        for workload in workloads:
            self.assertIsNotNone(workload['meta'].status, workload['name'])
        with self.assertRaisesRegex(common.Failed, 'no firmware workload named nothing'):
            timing.firmware_workloads(['nothing'])

    def test_a_rooted_workload_is_named_by_its_files_so_the_entry_can_join(self):
        rooted = dict(meta={'root': '../../../../..'}, directory=ROOT / 'compiler/tests/fixtures/runtime/cmp-siphash-vectors')
        named = timing.sources(rooted)
        self.assertEqual(named[0], '--root=' + str(ROOT))
        self.assertTrue(all(p.endswith('.ldn') for p in named[1:]) and named[1:])


class Clocks(unittest.TestCase):
    def test_known_states_decode_and_others_keep_their_registers(self):
        stm = lambda cr, cfgr, d1: dict(registers={'0x58024400': cr, '0x58024410': cfgr,
                                                    '0x58024418': d1})
        self.assertEqual(timing.decode_clock('stm32h753', stm(0x25, 0, 0)), dict(source='hsi', hz=64000000))
        self.assertEqual(timing.decode_clock('stm32h753', stm(0x25 | 1 << 3, 0, 0))['hz'], 32000000)
        self.assertEqual(timing.decode_clock('stm32h753', stm(0x25, 0, 8 << 8))['hz'], 32000000)
        self.assertEqual(timing.decode_clock('stm32h753', stm(0x25, 3 << 3, 0))['source'], 'registers')
        c3 = lambda sysclk: dict(registers={'0x600c0008': 12, '0x600c0058': sysclk})
        self.assertEqual(timing.decode_clock('esp32c3', c3(0xa8001)), dict(source='xtal', hz=20000000))
        self.assertEqual(timing.decode_clock('esp32c3', c3(0xa8000))['hz'], 40000000)
        self.assertEqual(timing.decode_clock('esp32c3', c3(0xa8400))['source'], 'registers')
        c5 = lambda sysclk, cpu: dict(registers={'0x60096110': sysclk, '0x60096114': 0xd,
                                                 '0x60096118': cpu, '0x6009611c': 0})
        self.assertEqual(timing.decode_clock('esp32c5', c5(0xb0000200, 0)), dict(source='xtal', hz=48000000))
        self.assertEqual(timing.decode_clock('esp32c5', c5(0xa8000200, 1))['hz'], 20000000)
        self.assertEqual(timing.decode_clock('esp32c5', c5(0xb0020200, 0))['source'], 'registers')
        self.assertEqual(timing.decode_clock('rp2040', dict(source='xosc', hz=12000000, x=1)),
                         dict(source='xosc', hz=12000000))
        self.assertEqual(timing.clock_key(dict(source='xtal', hz=40000000)), 'xtal-40000000hz')
        self.assertEqual(timing.clock_key(timing.decode_clock('esp32c3', c3(0xa8400))),
                         'registers-0x600c0008=0xc-0x600c0058=0xa8400')


class Runs(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.out = Path(self.temporary.name)

    def run_with(self, timed, image=None, board='esp32', reported=None):
        """time_load's verdict on a helper that reports TIMED, its report's
        other fields changed by REPORTED."""
        image = image or dict(workload='w', digest='d' * 64, elf_sha256='e' * 64, status=42)
        report = dict(format_version=1, status='passed', mode='time', flash_written=False,
                      board=board, elf_sha256=image['elf_sha256'],
                      helper_source_sha256=common.helper_source_hash(), timing=timed)
        report.update(reported or {})
        args = SimpleNamespace(probe='p', seconds=5, ram_loader='helper',
                               pace=mock.Mock())
        plans = []

        def helper(run, name, argv, **_):
            plans.append(json.loads(Path(argv[argv.index('--plan') + 1]).read_text()))
            Path(argv[argv.index('--output') + 1]).write_text(json.dumps(report))
        with mock.patch.object(common, 'probe_command', helper):
            return timing.time_load(SimpleNamespace(out=self.out), args, board, image,
                                    self.out / 'x.elf', 1), plans

    def timed(self, before, after, **more):
        timed = dict(status=42, count=999, unit='cycles', host_seconds=0.01,
                     clock=dict(source='xtal', hz=40000000),
                     words={timing.BEFORE: [before], timing.AFTER: [after]})
        timed.update(more)
        return timed

    def test_the_figure_is_what_the_program_read_around_main(self):
        got, (plan,) = self.run_with(self.timed(0xfffffff0, 0x10))
        self.assertEqual((got['count'], got['probe_count']), (0x20, 999))
        self.assertEqual(plan['mode'], 'time')
        self.assertEqual(plan['status'], timing.STATUS)
        self.assertEqual([w['symbol'] for w in plan['words']], [timing.BEFORE, timing.AFTER])

    def test_a_wrong_status_or_a_long_count_fails_and_a_checksum_is_kept(self):
        with self.assertRaisesRegex(common.Failed, 'returned 7, expected 42'):
            self.run_with(self.timed(0, 1, status=7))
        with self.assertRaisesRegex(common.Failed, r'past 2\^31'):
            self.run_with(self.timed(0, 1 << 31))
        with self.assertRaisesRegex(common.Failed, 'long enough for its counter to pass'):
            self.run_with(self.timed(0, 1, host_seconds=60.0))
        # The program holds its checksum to the expected one before it
        # returns 42; the run reads the word and keeps it.
        image = dict(workload='w', digest='d' * 64, elf_sha256='e' * 64, status=42,
                     checksum='checksum')
        timed = self.timed(0, 1)
        timed['words']['checksum'] = [0x1234]
        got, (plan,) = self.run_with(timed, image)
        self.assertEqual(plan['words'][-1], dict(symbol='checksum', count=1))
        self.assertEqual(got['checksum'], 0x1234)

    def test_a_report_for_another_image_is_not_evidence(self):
        with self.assertRaisesRegex(common.Failed, 'did not return matching timing evidence'):
            self.run_with(self.timed(0, 1), reported=dict(elf_sha256='f' * 64))
        with self.assertRaisesRegex(common.Failed, 'did not return matching timing evidence'):
            self.run_with(self.timed(0, 1), reported=dict(mode='warm'))


def figure(cycles, clock='xtal-40000000hz', placement='text:iram0,data:dram0,stack:dram0', **more):
    return dict(dict(figure=cycles, unit='cycles', counter='CCOUNT', clock=clock, placement=placement,
                     runs=3, spread=0, image='i' * 64, compiler='c' * 64), **more)


class Baselines(unittest.TestCase):
    """compare and record against baselines in a temporary directory: the
    base commit's are what read_baseline gives for a revision, the
    candidate's what the directory holds."""
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.base = {}
        noise = self.root / 'noise.json'
        noise.write_text(json.dumps(dict(tolerance=dict(esp32=dict(relative=0.002, absolute=8)))))
        real = timing.read_baseline
        for name, value in (('BASELINES', self.root / 'baselines'), ('NOISE', noise)):
            patcher = mock.patch.object(timing, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)
        patcher = mock.patch.object(timing, 'read_baseline', lambda board, rev=None: (
            self.base.get(board, {}) if rev else real(board)))
        patcher.start()
        self.addCleanup(patcher.stop)

    def figures(self, found):
        path = self.root / ('figures-%d.json' % len(list(self.root.glob('figures-*'))))
        path.write_text(json.dumps(dict(schema=1, kind='cycles', figures=found)))
        return path

    def compare(self, found):
        printed = io.StringIO()
        with redirect_stdout(printed), mock.patch.object(sys, 'stderr', io.StringIO()):
            code = timing.compare(SimpleNamespace(figures=self.figures(found), base='BASE'))
        return code, printed.getvalue()

    def record(self, found, **more):
        with redirect_stdout(io.StringIO()):
            timing.record(SimpleNamespace(figures=self.figures(found), board=None, key=None, **more))

    def recorded_base(self, found):
        self.record(found)
        self.base['esp32'] = json.loads(timing.baseline_path('esp32').read_text())

    def test_a_figure_within_tolerance_passes_and_beyond_it_fails_either_way(self):
        key = 'esp32/xtensa-esp32/size-auto/sieve'
        self.recorded_base({key: figure(10000)})
        self.assertEqual(self.compare({key: figure(10020)})[0], 0)
        for changed in (10021, 9979, 20000):
            code, said = self.compare({key: figure(changed)})
            self.assertEqual(code, 1, changed)
            self.assertIn('UNDECLARED', said)
            self.assertIn(key, said)
        # The absolute floor holds a small figure.
        small = 'esp32/xtensa-esp32/size-auto/search'
        self.recorded_base({small: figure(100)})
        self.assertEqual(self.compare({small: figure(108)})[0], 0)
        self.assertEqual(self.compare({small: figure(109)})[0], 1)

    def test_a_change_the_candidate_records_is_declared(self):
        key = 'esp32/xtensa-esp32/size-auto/sieve'
        self.recorded_base({key: figure(10000)})
        self.record({key: figure(12000)})
        code, said = self.compare({key: figure(12001)})
        self.assertEqual(code, 0, said)
        self.assertIn("declared by the candidate's baselines: 1", said)
        self.assertIn('10000 -> 12001 (+20.01%)', said)

    def test_a_configuration_without_a_baseline_or_with_a_new_placement_fails(self):
        key = 'esp32/xtensa-esp32/size-auto/sieve'
        code, said = self.compare({key: figure(10000)})
        self.assertEqual(code, 1)
        self.assertIn('UNRECORDED: 1 configurations', said)
        self.recorded_base({key: figure(10000)})
        code, said = self.compare({key: figure(10000, placement='text:iram0,data:iram0,stack:dram0')})
        self.assertEqual(code, 1)
        self.assertIn('placement text:iram0,data:dram0,stack:dram0 -> text:iram0', said)

    def test_another_clock_is_the_runner_s_and_is_recorded_rather_than_failed(self):
        key = 'esp32/xtensa-esp32/size-auto/sieve'
        self.recorded_base({key: figure(10000)})
        code, said = self.compare({key: figure(15000, clock='xtal-20000000hz')})
        self.assertEqual(code, 0, said)
        self.assertIn('the base ran at xtal-40000000hz, this at xtal-20000000hz', said)

    def test_a_limit_is_compared_as_its_reason(self):
        key = 'esp32/xtensa-esp32/size-auto/siphash'
        self.recorded_base({key: dict(limit='not whole words')})
        self.assertEqual(self.compare({key: dict(limit='not whole words')})[0], 0)
        self.assertEqual(self.compare({key: figure(5)})[0], 1)

    def test_record_writes_one_file_per_board_keyed_by_level_profile_and_workload(self):
        self.record({'esp32/xtensa-esp32/size-auto/sieve': figure(10, checksum='0x00000001'),
                     'rp2040/armv6-m/none-off/sieve': figure(7, clock='xosc-12000000hz')})
        esp32 = json.loads(timing.baseline_path('esp32').read_text())
        self.assertEqual((esp32['board'], esp32['target'], esp32['level']), ('esp32', 'xtensa', 'xtensa-esp32'))
        self.assertEqual(esp32['entries']['xtensa-esp32/size-auto/sieve'],
                         dict(cycles=10, unit='cycles', counter='CCOUNT', clock='xtal-40000000hz',
                              placement='text:iram0,data:dram0,stack:dram0', image='i' * 64, runs=3,
                              checksum='0x00000001'))
        self.assertEqual(json.loads(timing.baseline_path('rp2040').read_text())['level'], 'armv6-m')
        # A whole record replaces the board's baseline; --key adds to it.
        self.record({'esp32/xtensa-esp32/size-auto/other': figure(11)})
        self.assertEqual(list(json.loads(timing.baseline_path('esp32').read_text())['entries']),
                         ['xtensa-esp32/size-auto/other'])
        self.record({'esp32/xtensa-esp32/none-off/x': figure(12)}, )
        with redirect_stdout(io.StringIO()):
            timing.record(SimpleNamespace(figures=self.figures({
                'esp32/xtensa-esp32/none-off/y': figure(13)}), board=None,
                key=['esp32/xtensa-esp32/none-off/y']))
        self.assertEqual(sorted(json.loads(timing.baseline_path('esp32').read_text())['entries']),
                         ['xtensa-esp32/none-off/x', 'xtensa-esp32/none-off/y'])

    def test_the_committed_baselines_cover_every_board_with_a_tolerance(self):
        noise = json.loads((ROOT / 'compiler/tests/measure/noise/cycles.json').read_text())
        self.assertEqual(set(noise['tolerance']), set(timing.BOARDS))
        for board in timing.BOARDS:
            path = ROOT / 'compiler/tests/measure/baselines' / ('%s.cycles.json' % board)
            if not path.exists():
                continue
            kept = json.loads(path.read_text())
            self.assertEqual((kept['board'], kept['target']), (board, timing.BOARDS[board][0]))


class Evidence(unittest.TestCase):
    def test_each_port_s_latest_attempt_is_read(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for attempt, port, boards in ((1, 'pico2', ('rp2350', 'rp2350_hazard3')),
                                          (2, 'pico2', ('rp2350_hazard3',)), (1, 'esp32', ('esp32',))):
                leg = root / ('board-evidence-%s-%d' % (port, attempt)) / port
                leg.mkdir(parents=True)
                (leg / 'transfer.json').write_text(json.dumps(dict(port=port, run_attempt=str(attempt))))
                for board in boards:
                    (leg / 'evidence' / (board + '-time')).mkdir(parents=True)
                    (leg / 'evidence' / (board + '-time') / 'result.json').write_text('{}')
                (leg / 'evidence' / 'esp32-ram').mkdir(parents=True)
            found = [path.relative_to(root).as_posix() for path in timing.latest_legs(root)]
            self.assertEqual(found, ['board-evidence-esp32-1/esp32/evidence/esp32-time/result.json',
                                     'board-evidence-pico2-2/pico2/evidence/rp2350_hazard3-time/result.json'])


if __name__ == '__main__':
    unittest.main()
