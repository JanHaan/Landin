#!/usr/bin/env python3
"""The device fixtures, checked offline and, where refine and the inputs are
at hand, regenerated and held to independent vendor oracles (D555-D559).

Offline, which check.py runs: the lock and the policies agree on each SVD's
hash, every generated file is the one its manifest hashes, every module
carries its policy's notice, and every notice it names is in the tree.

Regeneration, which needs a built refine and the fetched inputs and which
the gate's cortex-m job runs: `refine svd` regenerates every file under
devices/generated and devices/descriptions byte for byte from each policy
and its pinned SVD, twice into fresh directories; a changed output is put
back and a stale one removed; each SVD form refine does not read is refused
with its code; and every selected register and field is compared with the
vendor's own C headers, which refine never reads.

    python3 devices/test.py                       # offline only
    python3 devices/test.py --refine PATH         # everything; fetches
    python3 devices/test.py --refine PATH --require-inputs

Without --refine, $LANDIN_REFINE names the compiler.  The regeneration
tests are skipped, and say so, when there is none, unless --require-inputs
is given, which the gate gives.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(ROOT / 'scripts'))
import fetch_inputs  # noqa: E402

POLICIES = HERE / 'policies'
GENERATED = HERE / 'generated'
DESCRIPTIONS = HERE / 'descriptions'
REFINE = None
REQUIRE = False


def digest(data):
    return hashlib.sha256(data).hexdigest()


def policies():
    return {path.stem: json.loads(path.read_text())
            for path in sorted(POLICIES.glob('*.json'))}


def svd_input(policy):
    """The lock's name for a policy's SVD."""
    return policy['prefix'] + '/' + policy['device'] + '.svd'


def tree(directory):
    return {str(p.relative_to(directory)): p.read_bytes()
            for p in sorted(Path(directory).rglob('*')) if p.is_file()}


class Offline(unittest.TestCase):
    def test_policies_name_locked_svds(self):
        lock = fetch_inputs.read_lock()
        for name, policy in policies().items():
            with self.subTest(policy=name):
                self.assertEqual(policy['schema'], 2)
                self.assertEqual(lock[svd_input(policy)]['sha256'],
                                 policy['svd_sha256'])

    def test_manifests_hash_the_generated_files(self):
        owned = set()
        for name, policy in policies().items():
            modules = HERE / policy['modules']
            manifest = modules / policy['manifest']
            recorded = json.loads(manifest.read_text())
            with self.subTest(policy=name):
                self.assertEqual(list(recorded), sorted(recorded))
                for path, expected in recorded.items():
                    self.assertEqual(digest((modules / path).read_bytes()),
                                     expected, path)
                    owned.add(modules / path)
            owned.add(manifest)
            owned.add(HERE / policy['description'] / 'interrupts.ldn')
        present = {p for p in GENERATED.rglob('*') if p.is_file()}
        self.assertEqual(present - owned, set(),
                         'a generated file no manifest names')

    def test_modules_carry_their_notice(self):
        for name, policy in policies().items():
            notice = ''.join('-- ' + line + '\n' for line in policy['notice'])
            prefix = HERE / policy['modules'] / policy['prefix']
            for module in sorted(prefix.glob('*/device.ldn')):
                with self.subTest(module=str(module.relative_to(HERE))):
                    self.assertTrue(module.read_text().startswith(notice))
            for line in policy['notice']:
                for named in re.findall(r'devices/notices/[\w.-]+', line):
                    self.assertTrue((ROOT / named).is_file(), named)

    def test_no_vendor_input_is_vendored(self):
        self.assertFalse((HERE / 'inputs').exists())
        for path in HERE.rglob('*'):
            self.assertFalse(path.suffix.lower() in ('.svd', '.h'), path)


def requires_refine(case):
    def guarded(self):
        if REFINE is None:
            if REQUIRE:
                self.fail('--require-inputs needs --refine or $LANDIN_REFINE')
            self.skipTest('no refine named: pass --refine or set LANDIN_REFINE')
        case(self)
    guarded.__name__ = case.__name__
    guarded.__doc__ = case.__doc__
    return guarded


def run_svd(policy_path, svd, out, expect=0):
    result = subprocess.run(
        [str(REFINE), 'svd', '--policy=' + str(policy_path),
         '--out-dir=' + str(out), str(svd)],
        capture_output=True, text=True, timeout=120)
    if result.returncode != expect:
        raise AssertionError('refine svd exited %d, not %d:\n%s%s' % (
            result.returncode, expect, result.stdout, result.stderr))
    return result


def generate(name, policy, root):
    """Every file refine writes for a policy, into a fresh directory."""
    out = Path(root) / name
    out.mkdir()
    run_svd(POLICIES / (name + '.json'),
            fetch_inputs.fetch(svd_input(policy)), out)
    return tree(out)


def checked_in(policy):
    files = {}
    modules = HERE / policy['modules']
    manifest = json.loads((modules / policy['manifest']).read_text())
    for path in list(manifest) + [policy['manifest']]:
        files[str(Path(policy['modules']) / path)] = (modules / path).read_bytes()
    interrupts = Path(policy['description']) / 'interrupts.ldn'
    files[str(interrupts)] = (HERE / interrupts).read_bytes()
    return files


class Regeneration(unittest.TestCase):
    @requires_refine
    def test_every_file_is_regenerated_byte_for_byte(self):
        for name, policy in policies().items():
            with self.subTest(policy=name), \
                    tempfile.TemporaryDirectory() as root:
                first = generate(name, policy, root)
                second = generate(name, policy, tempfile.mkdtemp(dir=root))
                self.assertEqual(first, second)
                self.assertEqual(first, checked_in(policy))

    @requires_refine
    def test_a_changed_output_is_put_back_and_a_stale_one_removed(self):
        policy = policies()['rp2040']
        with tempfile.TemporaryDirectory() as root:
            out = Path(root) / 'out'
            out.mkdir()
            svd = fetch_inputs.fetch(svd_input(policy))
            run_svd(POLICIES / 'rp2040.json', svd, out)
            expected = tree(out)
            changed = out / 'generated/rp2040/uart0/device.ldn'
            changed.write_bytes(changed.read_bytes() + b'-- stale\n')
            result = run_svd(POLICIES / 'rp2040.json', svd, out)
            self.assertIn('1 of them written', result.stdout)
            self.assertEqual(tree(out), expected)
            # A peripheral no longer selected leaves with its manifest entry.
            smaller = json.loads((POLICIES / 'rp2040.json').read_text())
            del smaller['selection']['UART1']
            del smaller['policies']['UART1.UARTFR']
            del smaller['reset_mask_overrides']['UART1.UARTFR']
            narrowed = Path(root) / 'narrowed.json'
            narrowed.write_text(json.dumps(smaller))
            result = run_svd(narrowed, svd, out)
            self.assertIn('1 no longer made removed', result.stdout)
            self.assertFalse((out / 'generated/rp2040/uart1').joinpath(
                'device.ldn').exists())
            # A leftover of an interrupted run stops the next one.
            (out / 'generated/outputs.json.refine-new').write_text('')
            result = run_svd(POLICIES / 'rp2040.json', svd, out, expect=1)
            self.assertIn('error[L0531]', result.stderr)

    @requires_refine
    def test_unsupported_forms_are_refused(self):
        policy = json.loads((POLICIES / 'rp2040.json').read_text())
        original = fetch_inputs.fetch(svd_input(policy)).read_bytes()
        register = b'<register>\n                <name>GPIO0_CTRL</name>'
        anchor = b'<name>GPIO0_CTRL</name>'

        def after(data, old, new, at=anchor):
            start = data.index(at)
            found = data.index(old, start)
            return data[:found] + new + data[found + len(old):]

        def clustered(data):
            data = data.replace(register, b'<cluster><name>C</name>'
                                b'<addressOffset>0</addressOffset>' + register, 1)
            return after(data, b'</register>', b'</register></cluster>')

        cases = (
            (after(original, anchor, anchor + b'<dim>2</dim>'),
             'L0528', 'an array'),
            (original.replace(b'<size>32</size>', b'<size>64</size>', 1),
             'L0528', 'bits wide'),
            (after(original, anchor, anchor + b'<size>16</size>'),
             'L0528', 'bits wide'),
            (after(original, anchor,
                   anchor + b'<alternateGroup>A</alternateGroup>'),
             'L0528', 'alternateGroup'),
            (original.replace(b'<baseAddress>0x40038000</baseAddress>',
                              b'<baseAddress>0x40038000</baseAddress>'
                              b'<registers/>', 1),
             'L0528', 'registers of its own'),
            (original.replace(register, register.replace(
                b'<register>', b'<register derivedFrom="GPIO1_CTRL">'), 1),
             'L0528', 'derived from another'),
            (clustered(original), 'L0528', 'in a cluster'),
            (after(original, b'<enumeratedValue>',
                   b'<enumeratedValue><isDefault>true</isDefault>'),
             'L0528', 'default enumerated value'),
            (after(original, b'<addressOffset>', b'<addressOffset>4k#'),
             'L0528', 'not a number'),
            (after(original, b'[29:28]', b'[29:16]'), 'L0529', 'overlaps'),
            (original.replace(b'<!--', b'<!DOCTYPE device>\n<!--', 1),
             'L0525', 'document type declaration'),
            (original.replace(b'</device>', b'</devices>', 1),
             'L0525', 'does not close'),
        )
        with tempfile.TemporaryDirectory() as root:
            for index, (data, code, words) in enumerate(cases):
                with self.subTest(code=code, words=words):
                    self.assertNotEqual(data, original)
                    svd = Path(root) / ('case%d.svd' % index)
                    svd.write_bytes(data)
                    rehashed = dict(policy, svd_sha256=digest(data))
                    path = Path(root) / ('case%d.json' % index)
                    path.write_text(json.dumps(rehashed))
                    out = Path(root) / ('out%d' % index)
                    out.mkdir()
                    result = run_svd(path, svd, out, expect=1)
                    self.assertIn('error[' + code + ']', result.stderr)
                    self.assertIn(words, result.stderr)
                    self.assertEqual(tree(out), {})
            # Rehashing alone is what admits a changed SVD; without it the
            # policy's review does not cover the file.
            svd = Path(root) / 'unreviewed.svd'
            svd.write_bytes(original + b'\n')
            out = Path(root) / 'unreviewed'
            out.mkdir()
            result = run_svd(POLICIES / 'rp2040.json', svd, out, expect=1)
            self.assertIn('error[L0527]', result.stderr)
            # A selection the SVD does not have.
            missing = dict(policy, selection=dict(policy['selection'],
                                                  SIO=['GPIO_NOWHERE']))
            missing['policies'] = dict(policy['policies'])
            missing['policies']['SIO.GPIO_NOWHERE'] = {
                'read': 'normal', 'write': 'normal', 'reserved': 'zero'}
            for key in ('SIO.GPIO_IN', 'SIO.GPIO_OUT', 'SIO.GPIO_OUT_SET',
                        'SIO.GPIO_OUT_CLR'):
                del missing['policies'][key]
            path = Path(root) / 'missing.json'
            path.write_text(json.dumps(missing))
            result = run_svd(path, fetch_inputs.fetch(svd_input(policy)),
                             out, expect=1)
            self.assertIn('error[L0530]', result.stderr)


class Rp2040Oracles(unittest.TestCase):
    """The RP2040's selection against pico-sdk's own headers and literals."""

    @classmethod
    def rows(cls):
        policy = policies()['rp2040']
        return json.loads((HERE / policy['modules'] /
                           policy['correspondence']).read_text())

    @requires_refine
    def test_vendor_headers(self):
        # These separately shipped official C headers are not read by
        # refine. Every selected register and field is compared.
        bases = {'IO_BANK0': 0x40014000, 'SIO': 0xd0000000,
                 'TIMER': 0x40054000, 'UART0': 0x40034000,
                 'UART1': 0x40038000, 'DMA': 0x50000000}
        for row in self.rows():
            peripheral, register = row['source'].split('.')
            family = 'UART' if peripheral.startswith('UART') else peripheral
            text = fetch_inputs.fetch('rp2040/' + family.lower() + '.h').read_text()
            macros = dict(re.findall(r'^#define (\w+)\s+_u\((0x[0-9a-fA-F]+|[0-9]+)\)',
                                     text, re.MULTILINE))
            prefix = family + '_' + register
            with self.subTest(register=row['source']):
                self.assertEqual(row['offset'], int(macros[prefix + '_OFFSET'], 0))
                self.assertEqual(row['address'], bases[peripheral] + row['offset'])
                self.assertEqual(row['width'], 32)
                self.assertEqual(row['alignment'], 4)
                self.assertEqual(row['named_mask'], int(macros[prefix + '_BITS'], 0))
                reset_mask = 0
                reset_value = 0
                for field in row['fields']:
                    # Single-field registers omit a second repeated suffix.
                    field_prefix = (prefix if field['name'] == register
                                    else prefix + '_' + field['name'])
                    self.assertEqual(field['mask'], int(macros[field_prefix + '_BITS'], 0))
                    self.assertEqual(field['low'], int(macros[field_prefix + '_LSB'], 0))
                    self.assertEqual(field['high'], int(macros[field_prefix + '_MSB'], 0))
                    access = re.search(r'^#define ' + field_prefix + r'_ACCESS\s+"(.*?)"',
                                       text, re.MULTILINE).group(1)
                    self.assertEqual((field['access'], field['read_action'],
                                      field['modified_write']), {
                        'RW': ('read-write', None, None),
                        'RO': ('read-only', None, None),
                        'WO': ('write-only', None, None),
                        'WC': ('read-write', None, 'oneToClear'),
                        'RWF': ('read-write', 'modify', None),
                    }[access])
                    reset = macros.get(field_prefix + '_RESET')
                    if reset is not None:
                        reset_mask |= field['mask']
                        reset_value |= int(reset, 0) << field['low']
                    else:
                        self.assertRegex(text, r'#define ' + field_prefix + r'_RESET\s+"-"')
                    for name, value in field['encodings']:
                        if field['name'] == 'TREQ_SEL':
                            # Header supplies geometry but not DREQ names.
                            # The literal request table below is independent.
                            requests = ([f'PIO{p}_{d}{n}' for p in range(2)
                                         for d in ('TX', 'RX') for n in range(4)] +
                                        ['SPI0_TX', 'SPI0_RX', 'SPI1_TX', 'SPI1_RX',
                                         'UART0_TX', 'UART0_RX', 'UART1_TX', 'UART1_RX'] +
                                        ['PWM_WRAP' + str(n) for n in range(8)] +
                                        ['I2C0_TX', 'I2C0_RX', 'I2C1_TX', 'I2C1_RX', 'ADC',
                                         'XIP_STREAM', 'XIP_SSITX', 'XIP_SSIRX'])
                            expected = dict(zip(requests, range(40)))
                            expected.update(TIMER0=59, TIMER1=60, TIMER2=61,
                                            TIMER3=62, PERMANENT=63)
                            self.assertEqual(value, expected[name])
                        else:
                            self.assertEqual(value, int(macros[field_prefix + '_VALUE_'
                                                              + name.upper()], 0))
                self.assertEqual(row['known_reset_mask'], reset_mask)
                self.assertEqual(row['known_reset_value'], reset_value)

    def test_literal_contract(self):
        rows = {r['source']: r for r in self.rows()}
        self.assertEqual(len(rows), 30)
        self.assertEqual(rows['UART1.UARTFR']['derived_from'], 'UART0')
        self.assertEqual(rows['DMA.CH1_CTRL_TRIG']['offset']
                         - rows['DMA.CH0_CTRL_TRIG']['offset'], 64)
        self.assertEqual(rows['IO_BANK0.GPIO1_CTRL']['offset']
                         - rows['IO_BANK0.GPIO0_CTRL']['offset'], 8)
        self.assertEqual([rows['TIMER.ALARM' + str(i)]['offset'] for i in range(4)],
                         [16, 20, 24, 28])
        self.assertEqual(rows['DMA.CH0_AL1_CTRL']['svd_reset_mask'], 0)
        self.assertEqual(rows['DMA.CH0_AL1_CTRL']['known_reset_mask'], 0)
        self.assertEqual(rows['UART0.UARTDR']['known_reset_mask'], 0)
        self.assertEqual(rows['UART0.UARTFR']['known_reset_value'], 0x90)
        self.assertEqual(rows['IO_BANK0.GPIO0_CTRL']['named_mask'], 0x3003331f)
        for key in ('DMA.CH0_CTRL_TRIG', 'DMA.CH1_CTRL_TRIG'):
            fields = {f['name']: f for f in rows[key]['fields']}
            self.assertEqual(fields['DATA_SIZE']['encodings'],
                             [['SIZE_BYTE', 0], ['SIZE_HALFWORD', 1], ['SIZE_WORD', 2]])
            self.assertEqual(fields['RING_SIZE']['representation'], 'unsigned')
            self.assertEqual(fields['RING_SIZE']['mask'], 0x3c0)
        # Independent reviewed policy oracle: no policy values are used to
        # construct the expected access surface or restricted write masks.
        for key, row in rows.items():
            read = ('refused' if key in {'SIO.GPIO_OUT_SET', 'SIO.GPIO_OUT_CLR',
                    'UART0.UARTICR'} else 'modify' if key == 'UART0.UARTDR' else 'normal')
            write = ('refused' if key in {'SIO.GPIO_IN', 'TIMER.TIMERAWL',
                     'UART0.UARTRSR', 'UART0.UARTFR', 'UART1.UARTFR', 'DMA.CH0_AL1_CTRL'}
                     else 'one_clears' if key in {'TIMER.INTR', 'DMA.INTR', 'UART0.UARTICR'}
                     else 'normal')
            expected = {'read': read, 'write': write,
                        'reserved': 'preserve' if key == 'SIO.GPIO_OUT' else 'zero'}
            if key == 'UART0.UARTDR':
                expected['write_mask'] = '0x000000ff'
            if key in {'DMA.CH0_CTRL_TRIG', 'DMA.CH1_CTRL_TRIG'}:
                expected['write_mask'] = '0x00ffffff'
            self.assertEqual(row['policy'], expected, key)

    def test_interrupt_five_is_usbctrl(self):
        text = (DESCRIPTIONS / 'rp2040/interrupts.ldn').read_text()
        self.assertIn('compiler.interrupt("USBCTRL_IRQ", 5)\n', text)
        self.assertIn('compiler.vectors(48)\n', text)


def main():
    global REFINE, REQUIRE
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--refine', type=Path,
                        default=os.environ.get('LANDIN_REFINE'))
    parser.add_argument('--require-inputs', action='store_true',
                        help='fail, rather than skip, without refine or inputs')
    args, rest = parser.parse_known_args()
    REFINE = Path(args.refine).resolve() if args.refine else None
    REQUIRE = args.require_inputs
    unittest.main(argv=[sys.argv[0]] + rest)


if __name__ == '__main__':
    main()
