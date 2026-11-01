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
sys.path.insert(0, str(HERE))
import fetch_inputs  # noqa: E402

POLICIES = HERE / 'policies'
GENERATED = HERE / 'generated'
DESCRIPTIONS = HERE / 'descriptions'
REFINE = None
TOOLCHAIN = None
REQUIRE = False


def digest(data):
    return hashlib.sha256(data).hexdigest()


def policies():
    """Each policy, its layout's defaults filled in as refine fills them."""
    found = {}
    for path in sorted(POLICIES.glob('*.json')):
        policy = json.loads(path.read_text())
        prefix = policy.setdefault('prefix', policy['device'].lower())
        policy.setdefault('modules', '.')
        policy.setdefault('correspondence', prefix + '/correspondence.json')
        policy.setdefault('manifest', prefix + '/outputs.json')
        policy.setdefault('description', 'descriptions/' + policy['device'].lower())
        found[path.stem] = policy
    return found


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

    def test_the_evaluator_reads_stores_and_their_widths(self):
        import struct
        import thumb

        class Built:
            code = struct.pack('<II', 0x20001000, 0x9) + struct.pack(
                '<6H', 0x4802, 0x2105, 0x6041, 0x8101, 0xbf30, 0) \
                + struct.pack('<I', 0x40000000)
            segments = [(0, code, len(code))]
            symbols = {'_landin_firmware_vectors': 0}

        # ldr r0, =0x40000000; movs r1, #5; str r1, [r0, #4];
        # strh r1, [r0, #8]; wfi
        evaluation = thumb.Evaluation(Built(), [(0x40000000, 0x100)],
                                      (0x20000000, 0x1000))
        self.assertEqual(evaluation.run(), [('w', 0x40000004, 4, 5),
                                            ('w', 0x40000008, 2, 5)])
        broken = thumb.Evaluation(Built(), [], (0x20000000, 0x1000))
        with self.assertRaisesRegex(thumb.Refused, 'outside the image'):
            broken.run()

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
            for key in [k for k in missing['policies'] if k.startswith('SIO.')
                        and k != 'SIO.GPIO_NOWHERE']:
                del missing['policies'][key]
            path = Path(root) / 'missing.json'
            path.write_text(json.dumps(missing))
            result = run_svd(path, fetch_inputs.fetch(svd_input(policy)),
                             out, expect=1)
            self.assertIn('error[L0530]', result.stderr)


CORES = {'CM0': 'cortex-m0', 'CM0PLUS': 'cortex-m0plus',
         'CM3': 'cortex-m3', 'CM4': 'cortex-m4', 'CM7': 'cortex-m7'}


def render_d542(raw, corrections=()):
    """D542's generated half from an SVD's bytes and a policy's interrupt
    corrections, with nothing of refine's."""
    import xml.etree.ElementTree as ElementTree

    def text_of(element, name):
        found = element.find(name)
        return None if found is None or found.text is None else found.text.strip()

    device = ElementTree.fromstring(raw)
    name = text_of(device, 'name')
    clauses = [label + ' ' + value for label, value in
               (('vendor', text_of(device, 'vendor')),
                ('version', text_of(device, 'version'))) if value]
    lines = ['-- Interrupts of the ' + name + ', from its SVD'
             + (': ' + ', '.join(clauses) if clauses else '') + '.',
             '-- SVD SHA-256 ' + hashlib.sha256(raw).hexdigest() + '.']
    licence = device.find('licenseText')
    if licence is not None and licence.text:
        lines += ['-- ' + line.strip() for line in licence.text.splitlines()
                  if line.strip()]
    cpu = device.find('cpu')
    pairs = set()
    for peripheral in device.iter('peripheral'):
        for interrupt in peripheral.findall('interrupt'):
            pairs.add((int(text_of(interrupt, 'value'), 0),
                       text_of(interrupt, 'name')))
    notes = []
    for named_irq, correction in dict(corrections).items():
        old = sorted(value for value, named in pairs if named == named_irq)
        pairs = {pair for pair in pairs if pair[1] != named_irq}
        olds = ' and '.join(str(value) for value in old)
        if correction.get('omit'):
            notes.append('-- The policy removes %s at %s: %s.'
                         % (named_irq, olds, correction['source']))
        else:
            pairs.add((correction['value'], named_irq))
            notes.append('-- The policy %s %d: %s.' % (
                ('adds %s at' % named_irq) if not old else
                ('moves %s from %s to' % (named_irq, olds)),
                correction['value'], correction['source']))
    lines += ['-- Generated from the SVD; memory.ldn beside it is written'
              ' by hand.'] + notes + ['']
    declared = int(text_of(cpu, 'deviceNumInterrupts') or '0', 0)
    count = 16 + max(declared, max(value for value, _ in pairs) + 1)
    lines += ['compiler.device("%s")' % name.lower(),
              'compiler.core("%s")' % CORES[text_of(cpu, 'name')],
              'compiler.vectors(%d)' % count]
    lines += ['compiler.interrupt("%s", %d)' % (interrupt, value)
              for value, interrupt in
              sorted(pairs, key=lambda pair: (pair[0], pair[1].encode()))]
    return '\n'.join(lines) + '\n'


class D542Form(unittest.TestCase):
    """Each generated interrupts.ldn is D542's text, rendered apart from
    refine from the fetched SVD; this replaced the scripts test that read a
    vendored copy."""

    @requires_refine
    def test_each_interrupts_ldn_is_the_form(self):
        for name, policy in policies().items():
            with self.subTest(policy=name):
                raw = fetch_inputs.fetch(svd_input(policy)).read_bytes()
                self.assertEqual(
                    (HERE / policy['description'] / 'interrupts.ldn').read_bytes(),
                    render_d542(raw, policy.get('interrupt_corrections', {}))
                    .encode('ascii'))


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
                 'UART1': 0x40038000, 'DMA': 0x50000000,
                 'RESETS': 0x4000c000, 'CLOCKS': 0x40008000,
                 'XOSC': 0x40024000, 'PADS_BANK0': 0x4001c000,
                 'VREG_AND_CHIP_RESET': 0x40064000, 'PPB': 0xe0000000,
                 'WATCHDOG': 0x40058000}
        for row in self.rows():
            peripheral, register = row['source'].split('.')
            # The SVD's PPB is the core's private bus, which pico-sdk's
            # header calls by the core's name.
            family = ('UART' if peripheral.startswith('UART')
                      else 'M0PLUS' if peripheral == 'PPB' else peripheral)
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
                        # A self-clearing command bit, CHAN_ABORT's, which
                        # the SVD writes as one-to-clear.
                        'SC': ('read-write', None, 'oneToClear'),
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
        self.assertEqual(len(rows), 53)
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
                    'SIO.GPIO_OE_SET', 'UART0.UARTICR'} else 'modify' if key == 'UART0.UARTDR' else 'normal')
            write = ('refused' if key in {'SIO.GPIO_IN', 'TIMER.TIMERAWL',
                     'UART0.UARTRSR', 'UART0.UARTFR', 'UART1.UARTFR', 'DMA.CH0_AL1_CTRL',
                     'RESETS.RESET_DONE', 'CLOCKS.CLK_REF_SELECTED',
                     'CLOCKS.CLK_SYS_SELECTED', 'VREG_AND_CHIP_RESET.CHIP_RESET',
                     'PPB.VTOR'}
                     else 'one_clears' if key in {'TIMER.INTR', 'DMA.INTR', 'UART0.UARTICR',
                                                  'DMA.CHAN_ABORT', 'XOSC.STATUS'}
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



class CmsisHeader:
    """ST's stm32h753xx.h, read for its macros and register structures."""

    def __init__(self, text):
        self.text = text
        self.defines = {}
        for m in re.finditer(r'^#define\s+(\w+)[ \t]+([^\n]*?)\s*(?:/\*.*)?$',
                             text, re.MULTILINE):
            self.defines.setdefault(m.group(1), m.group(2).strip())

    def value(self, expression):
        expression = expression.strip()
        while expression.startswith('(') and expression.endswith(')') \
                and self.balanced(expression[1:-1]):
            expression = expression[1:-1].strip()
        literal = re.fullmatch(r'(0x[0-9A-Fa-f]+|\d+)U?L?', expression)
        if literal:
            return int(literal.group(1), 0)
        for operator in ('+', '<<'):
            depth = 0
            for at in range(len(expression)):
                c = expression[at]
                depth += (c == '(') - (c == ')')
                if depth == 0 and expression.startswith(operator, at):
                    left = self.value(expression[:at])
                    right = self.value(expression[at + len(operator):])
                    return left + right if operator == '+' else left << right
        if expression in self.defines:
            return self.value(self.defines[expression])
        raise KeyError(expression)

    @staticmethod
    def balanced(text):
        depth = 0
        for c in text:
            depth += (c == '(') - (c == ')')
            if depth < 0:
                return False
        return depth == 0

    def offsets(self, structure):
        end = re.search(r'\}\s*' + structure + ';', self.text).start()
        body = self.text[self.text.rindex('typedef struct', 0, end):end]
        offsets, at = {}, 0
        for member in re.finditer(r'(uint32_t|uint16_t|uint8_t)\s+(\w+)'
                                  r'(?:\[(\w+)\])?\s*;', body):
            size = {'uint32_t': 4, 'uint16_t': 2, 'uint8_t': 1}[member.group(1)]
            count = int(member.group(3), 0) if member.group(3) else 1
            at = (at + size - 1) // size * size
            for i in range(count):
                name = member.group(2) + ('[%d]' % i if member.group(3) else '')
                offsets[name] = (at + i * size, size)
            at += size * count
        return offsets

    def mask(self, *names):
        for name in names:
            for spelling in (name + '_Msk', name):
                if spelling in self.defines:
                    return self.value(spelling)
        raise KeyError(' or '.join(names))


#  Where each selected STM32H753 register is in ST's header: the base
#  macro, the structure and its member, and the prefix its fields' macros
#  take.  Reviewed by reading stm32h753xx.h, never the SVD.
H753_REGISTERS = {
    'RCC.AHB1ENR': ('RCC_BASE', 'RCC_TypeDef', 'AHB1ENR', 'RCC_AHB1ENR'),
    'RCC.AHB4ENR': ('RCC_BASE', 'RCC_TypeDef', 'AHB4ENR', 'RCC_AHB4ENR'),
    'RCC.APB1LENR': ('RCC_BASE', 'RCC_TypeDef', 'APB1LENR', 'RCC_APB1LENR'),
    'GPIOD.MODER': ('GPIOD_BASE', 'GPIO_TypeDef', 'MODER', 'GPIO_MODER'),
    'GPIOD.AFRH': ('GPIOD_BASE', 'GPIO_TypeDef', 'AFR[1]', 'GPIO_AFRH'),
    'USART3.CR1': ('USART3_BASE', 'USART_TypeDef', 'CR1', 'USART_CR1'),
    'USART3.CR3': ('USART3_BASE', 'USART_TypeDef', 'CR3', 'USART_CR3'),
    'USART3.BRR': ('USART3_BASE', 'USART_TypeDef', 'BRR', 'USART_BRR'),
    'USART3.ISR': ('USART3_BASE', 'USART_TypeDef', 'ISR', 'USART_ISR'),
    'USART3.ICR': ('USART3_BASE', 'USART_TypeDef', 'ICR', 'USART_ICR'),
    'USART3.RDR': ('USART3_BASE', 'USART_TypeDef', 'RDR', 'USART_RDR'),
    'USART3.TDR': ('USART3_BASE', 'USART_TypeDef', 'TDR', 'USART_TDR'),
    'DMA1.LISR': ('DMA1_BASE', 'DMA_TypeDef', 'LISR', 'DMA_LISR'),
    'DMA1.LIFCR': ('DMA1_BASE', 'DMA_TypeDef', 'LIFCR', 'DMA_LIFCR'),
    'DMA1.S0CR': ('DMA1_Stream0_BASE', 'DMA_Stream_TypeDef', 'CR', 'DMA_SxCR'),
    'DMA1.S0NDTR': ('DMA1_Stream0_BASE', 'DMA_Stream_TypeDef', 'NDTR', 'DMA_SxNDT'),
    'DMA1.S0PAR': ('DMA1_Stream0_BASE', 'DMA_Stream_TypeDef', 'PAR', 'DMA_SxPAR'),
    'DMA1.S0M0AR': ('DMA1_Stream0_BASE', 'DMA_Stream_TypeDef', 'M0AR', 'DMA_SxM0AR'),
    'DMAMUX1.DMAMUX_C0CR': ('DMAMUX1_Channel0_BASE', 'DMAMUX_Channel_TypeDef',
                            'CCR', 'DMAMUX_CxCR'),
    'TIM2.CCMR1_Input': ('TIM2_BASE', 'TIM_TypeDef', 'CCMR1', 'TIM_CCMR1'),
}

#  Fields the header spells otherwise, reviewed one by one.
H753_FIELD_SPELLINGS = {
    'USART3.BRR.BRR_4_15': 'USART_BRR_DIV_MANTISSA',
    'USART3.BRR.BRR_0_3': 'USART_BRR_DIV_FRACTION',
    'DMA1.S0NDTR.NDT': 'DMA_SxNDT',
    'DMA1.S0PAR.PA': 'DMA_SxPAR_PA',
    'DMA1.S0M0AR.M0A': 'DMA_SxM0AR_M0A',
    'RCC.AHB1ENR.USB1OTGEN': 'RCC_AHB1ENR_USB1OTGHSEN',
    'RCC.AHB1ENR.USB1ULPIEN': 'RCC_AHB1ENR_USB1OTGHSULPIEN',
    'RCC.AHB1ENR.USB2OTGEN': 'RCC_AHB1ENR_USB2OTGFSEN',
    'RCC.AHB1ENR.USB2ULPIEN': 'RCC_AHB1ENR_USB2OTGFSULPIEN',
    'RCC.APB1LENR.USART7EN': 'RCC_APB1LENR_UART7EN',
    'RCC.APB1LENR.USART8EN': 'RCC_APB1LENR_UART8EN',
    'USART3.ISR.TXE': 'USART_ISR_TXE_TXFNF',
    'USART3.ISR.RXNE': 'USART_ISR_RXNE_RXFNE',
    'USART3.ISR.NF': 'USART_ISR_NE',
    'USART3.ICR.NCF': 'USART_ICR_NECF',
    'USART3.ICR.TCBGTC': 'USART_ICR_TCBGTCF',
    'TIM2.CCMR1_Input.IC2PCS': 'TIM_CCMR1_IC2PSC',
    'TIM2.CCMR1_Input.ICPCS': 'TIM_CCMR1_IC1PSC',
    'USART3.CR1.TXEIE': 'USART_CR1_TXEIE_TXFNFIE',
    'USART3.CR1.RXNEIE': 'USART_CR1_RXNEIE_RXFNEIE',
}


#  Where the header's mask is not the field's, and RM0433 Rev 9 says the
#  SVD is right: 17.6.1, p. 708, gives DMAMUX1_CxCR's DMAREQ_ID[6:0] and
#  SYNC_ID[2:0]; the header's masks are DMAMUX2's wider ones, 17.6.2, p. 709.
H753_HEADER_DISAGREEMENTS = {
    'DMAMUX1.DMAMUX_C0CR.DMAREQ_ID': 0x000000ff,
    'DMAMUX1.DMAMUX_C0CR.SYNC_ID': 0x1f000000,
}


class Stm32h753Oracles(unittest.TestCase):
    """The STM32H753's selection against ST's CMSIS header and reviewed
    literals, neither of them the SVD or the generator."""

    @classmethod
    def rows(cls):
        policy = policies()['stm32h753']
        return json.loads((HERE / policy['modules'] /
                           policy['correspondence']).read_text())

    @requires_refine
    def test_cmsis_header(self):
        header = CmsisHeader(fetch_inputs.fetch('stm32h753/stm32h753xx.h')
                             .read_text())
        rows = {row['source']: row for row in self.rows()}
        self.assertEqual(set(rows), set(H753_REGISTERS))
        for key, (base, structure, member, prefix) in H753_REGISTERS.items():
            row = rows[key]
            offset, size = header.offsets(structure)[member]
            with self.subTest(register=key):
                self.assertEqual(row['address'], header.value(base) + offset)
                self.assertEqual((row['width'], row['alignment']), (8 * size, size))
                for field in row['fields']:
                    name = key + '.' + field['name']
                    spelled = H753_FIELD_SPELLINGS.get(name, prefix + '_' + field['name'])
                    digits = re.fullmatch(r'(.*?)(\d)$', field['name'])
                    candidates = [spelled]
                    if digits:
                        candidates.append(prefix + '_' + digits.group(1) + '_'
                                          + digits.group(2))
                    mask = header.mask(*candidates)
                    if name in H753_HEADER_DISAGREEMENTS:
                        self.assertEqual(mask, H753_HEADER_DISAGREEMENTS[name])
                        self.assertNotEqual(field['mask'], mask)
                        continue
                    with self.subTest(field=name):
                        self.assertEqual(field['mask'], mask)
                        self.assertEqual(field['low'], (mask & -mask).bit_length() - 1)
                        self.assertEqual(field['high'], mask.bit_length() - 1)

    def test_reset_values(self):
        # Reviewed from RM0433 Rev 9, pinned by its SHA-256 in
        # devices/inputs.json, never the SVD: every selected register resets
        # to zero but these two.
        expected = {
            # 11.4.1, p. 541: 0xFFFF FFFF for ports other than A and B;
            # 0xABFF FFFF is port A's, which the SVD gives port D by
            # deriving it from port A.
            'GPIOD.MODER': 0xffffffff,
            # 48.8.10, p. 2091, the FIFO-disabled view, which reset selects;
            # 48.8.9, p. 2085, the FIFO-enabled one, is 0x0X80 00C0.
            'USART3.ISR': 0x000000c0,
        }
        # The zeros: RCC 8.7.41, p. 454, 8.7.43, p. 458, 8.7.45, p. 462;
        # GPIOx_AFRH 11.4.10, p. 546; USART 48.8.1, p. 2067, 48.8.4,
        # p. 2078, 48.8.5, p. 2082, 48.8.11, p. 2096, 48.8.12 and 48.8.13,
        # p. 2098; DMA 15.5.1, p. 659, 15.5.3, p. 660, 15.5.5, p. 662,
        # 15.5.6 and 15.5.7, p. 665, 15.5.8, p. 666; DMAMUX1 17.6.1,
        # p. 708; TIM2 39.4.7, p. 1688.
        for row in self.rows():
            with self.subTest(register=row['source']):
                self.assertEqual(row['known_reset_mask'], row['named_mask'])
                self.assertEqual(row['known_reset_value'],
                                 expected.get(row['source'], 0))
        rows = {row['source']: row for row in self.rows()}
        self.assertEqual(rows['GPIOD.MODER']['svd_reset_value'], 0xabffffff)
        self.assertIn('RM0433', rows['GPIOD.MODER']['reset_correction']['source'])

    def test_access_policies(self):
        # Reviewed from RM0433 Rev 9's access types, never the policy: status
        # is read-only (USART_ISR 48.8.10, p. 2091; DMA_LISR 15.5.1,
        # p. 659), a clear register is write-only, written as one to clear
        # (USART_ICR 48.8.11, p. 2096; DMA_LIFCR 15.5.3, p. 660), and the
        # receive register is read-only and its read takes a byte from its
        # FIFO (USART_RDR 48.8.12, p. 2098).
        for row in self.rows():
            key = row['source']
            read = ('refused' if key in {'USART3.ICR', 'DMA1.LIFCR'}
                    else 'modify' if key == 'USART3.RDR' else 'normal')
            write = ('refused' if key in {'USART3.ISR', 'USART3.RDR', 'DMA1.LISR'}
                     else 'one_clears' if key in {'USART3.ICR', 'DMA1.LIFCR'}
                     else 'normal')
            self.assertEqual(row['policy'], {'read': read, 'write': write,
                                             'reserved': 'zero'}, key)

    def test_reviewed_field_corrections(self):
        rows = {row['source']: row for row in self.rows()}
        fields = {f['name']: f for f in rows['DMAMUX1.DMAMUX_C0CR']['fields']}
        # RM0433 Rev 9, 17.6.1, p. 708: DMAMUX1_CxCR's DMAREQ_ID is bits 6:0
        # and SYNC_ID bits 26:24, as the SVD says; the header's wider masks
        # are DMAMUX2's (17.6.2, p. 709), and nothing corrects them.
        self.assertEqual((fields['DMAREQ_ID']['mask'], fields['SYNC_ID']['mask']),
                         (0x7f, 0x07000000))
        self.assertNotIn('correction', fields['DMAREQ_ID'])
        # 8.7.41, p. 454: RCC_AHB1ENR's bit 18 is reserved.
        self.assertEqual([f['name'] for f in rows['RCC.AHB1ENR']['omitted_fields']],
                         ['USB2OTGHSULPIEN'])
        self.assertEqual(rows['TIM2.CCMR1_Input']['alternate_register'],
                         'CCMR1_Output')
        self.assertEqual(rows['USART3.CR1']['derived_from'], 'USART1')
        self.assertEqual(rows['GPIOD.MODER']['derived_from'], 'GPIOA')

    @requires_refine
    def test_interrupts_against_the_header(self):
        header = fetch_inputs.fetch('stm32h753/stm32h753xx.h').read_text()
        numbers = {int(m.group(2)): m.group(1) for m in re.finditer(
            r'^\s*(\w+)_IRQn\s*=\s*(-?\d+)', header, re.MULTILINE)}
        text = (DESCRIPTIONS / 'stm32h753/interrupts.ldn').read_text()
        given = {int(value): name for name, value in re.findall(
            r'^compiler\.interrupt\("(\w+)", (\d+)\)$', text, re.MULTILINE)}
        external = {n for n in numbers if n >= 0}
        # The two the SVD and the header disagree on, as RM0433 Rev 9's
        # vector table, Table 147, p. 759, settles them: position 143 is
        # WWDG1_RST, which the SVD has and the header lacks, and position
        # 145 the RAMECC diagnostic interrupt, which the header has as
        # ECC_IRQn and the policy adds to the SVD's.
        self.assertEqual(set(given) - external, {143})
        self.assertEqual(external - set(given), set())
        self.assertEqual((given[143], given[145]), ('WWDG1_RST', 'ECC'))
        self.assertIn('-- The policy adds ECC at 145: RM0433 Rev 9, Table 147,'
                      ' p. 759,', text)
        self.assertIn('compiler.vectors(%d)\n' % (16 + max(external) + 1), text)
        self.assertIn('compiler.core("cortex-m7")\n', text)
        # Table 147: TIM2 28 and DMA_STR0 11 on p. 754, USART3 39 on p. 755,
        # DMAMUX1_OV 102 on p. 758.
        for name, value in (('USART3', 39), ('DMA_STR0', 11), ('DMAMUX1_OV', 102),
                            ('TIM2', 28)):
            self.assertEqual(given[value], name)
        self.assertEqual((numbers[39], numbers[11], numbers[102], numbers[28]),
                         ('USART3', 'DMA1_Stream0', 'DMAMUX1_OVR', 'TIM2'))

    @requires_refine
    def test_the_consumer_s_linked_accesses(self):
        """The consumer's every device store, read from its linked image."""
        import thumb
        if TOOLCHAIN is None and not shutil.which('arm-eabi-gcc') \
                and not shutil.which('arm-none-eabi-gcc'):
            if REQUIRE:
                self.fail('--require-inputs needs --toolchain or a Cortex-M driver')
            self.skipTest('no Cortex-M driver: pass --toolchain')
        with tempfile.TemporaryDirectory() as root:
            elf = Path(root) / 'consumer.elf'
            command = [str(REFINE), 'compile', '--root=' + str(HERE),
                       '--root=' + str(GENERATED),
                       '--target=cortex-m0', '--level=armv7e-m',
                       '--firmware-entry=start', str(HERE / 'consumers/stm32h753'),
                       '-o', str(elf)]
            if TOOLCHAIN is not None:
                command.insert(2, '--toolchain=' + str(TOOLCHAIN))
            result = subprocess.run(command, capture_output=True, text=True,
                                    timeout=120)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            data = elf.read_bytes()
        image = thumb.Image(data)
        # The description places data, BSS and the stack in the AXI SRAM,
        # 512 KiB from 0x2400_0000, which is the image's RAM.
        ram = (0x24000000, 512 * 1024)
        self.assertEqual(image.symbols['_landin_firmware_data_start'], 0x24000000)
        self.assertEqual(image.symbols['_landin_firmware_stack_top'],
                         0x24000000 + 512 * 1024)
        self.assertEqual(image.symbols['_landin_firmware_vectors'], 0x08000000)
        self.assertTrue(0x08000000 <= image.symbols['message'] < 0x08200000)
        windows = [(0x58024400, 0x400), (0x58020c00, 0x400), (0x40004800, 0x400),
                   (0x40020000, 0x400), (0x40020800, 0x400), (0xe000e000, 0x1000)]
        stores = [a for a in thumb.accesses(data, windows, ram) if a[0] != 'barrier']
        # The cacheless profile: nothing enables the M7's caches, through
        # SCB_CCR's IC and DC bits, or maintains them, through SCB's cache
        # operations at 0xE000EF50 to 0xE000EF78.
        system = [a for a in stores if a[1] >= 0xe000e000]
        self.assertFalse([a for a in system if a[1] == 0xe000ed14 and a[3] & 0x30000
                          or 0xe000ef50 <= a[1] <= 0xe000ef78], system)
        stores = [a for a in stores if a[1] < 0xe000e000]
        message = image.symbols['message']
        # Reviewed from RM0433 Rev 9, never the generator: each base from
        # Table 8's register boundary addresses, pp. 132 to 135, each offset
        # and bit from the register's section, cited at test_reset_values,
        # and the request from Table 124, p. 697, usart3_tx_dma being
        # dmamux1_req_in46; the address, the width and the value of every
        # store, in order.
        self.assertEqual(stores, [
            ('w', 0x580244e0, 4, 0x00000008),   # RCC_AHB4ENR: GPIODEN
            ('w', 0x580244e8, 4, 0x00040000),   # RCC_APB1LENR: USART3EN
            ('w', 0x580244d8, 4, 0x00000001),   # RCC_AHB1ENR: DMA1EN
            ('w', 0x58020c00, 4, 0xfffaffff),   # GPIOD_MODER: PD8, PD9 alternate
            ('w', 0x58020c24, 4, 0x00000077),   # GPIOD_AFRH: PD8, PD9 AF7
            ('w', 0x4000480c, 4, 556),          # USART3_BRR: 64 MHz / 115200
            ('w', 0x40004808, 4, 0x00000080),   # USART3_CR3: DMAT
            ('w', 0x40020800, 4, 46),           # DMAMUX1_C0CR: usart3_tx_dma
            ('w', 0x40020018, 4, 0x40004828),   # DMA_S0PAR: USART3_TDR
            ('w', 0x4002001c, 4, message),      # DMA_S0M0AR: the message
            ('w', 0x40020014, 4, 4),            # DMA_S0NDTR: four bytes
            ('w', 0x40020010, 4, 0x00000440),   # DMA_S0CR: MINC, memory to peripheral
            ('w', 0x40004800, 4, 0x00000009),   # USART3_CR1: TE, UE
            ('w', 0x40020010, 4, 0x00000441),   # DMA_S0CR: EN
        ])

    @requires_refine
    def test_the_hand_written_memory_against_the_header(self):
        header = CmsisHeader(fetch_inputs.fetch('stm32h753/stm32h753xx.h')
                             .read_text())
        text = (DESCRIPTIONS / 'stm32h753/memory.ldn').read_text()

        def number(expression):
            value = 1
            for factor in expression.split('*'):
                value *= int(factor.strip().replace('_', ''), 0)
            return value

        regions = {name: (number(origin), number(length), access)
                   for name, origin, length, access in re.findall(
                       r'^linker\.region\("(\w+)", ([^,]+), ([^,]+), "(\w+)"\)$',
                       text, re.MULTILINE)}
        places = dict(re.findall(r'^linker\.place\("(\w+)", "(\w+)"', text,
                                 re.MULTILINE))
        kib = 1024
        d2 = header.value('D2_AHBSRAM_BASE')
        # Bases from the header's macros, sizes from its own comments on
        # them and from RM0433 Rev 9: 2.4, p. 136, the SRAMs and TCMs and
        # which masters reach them; Table 7, pp. 130 and 131, the memory
        # map; p. 153, the flash's two 1 MiB banks from 0x0800 0000; 2.6,
        # p. 138, the boot address 0x0800 0000.  FLASH_END bounds the flash.
        self.assertEqual(regions, {
            'FLASH': (header.value('D1_AXIFLASH_BASE'),
                      header.value('FLASH_END') + 1 - header.value('FLASH_BASE'), 'rx'),
            'ITCM': (header.value('D1_ITCMRAM_BASE'), 64 * kib, 'rwx'),
            'DTCM': (header.value('D1_DTCMRAM_BASE'), 128 * kib, 'rw'),
            'AXI_SRAM': (header.value('D1_AXISRAM_BASE'), 512 * kib, 'rwx'),
            'SRAM1': (d2, 128 * kib, 'rw'),
            'SRAM2': (d2 + 128 * kib, 128 * kib, 'rw'),
            'SRAM3': (d2 + 256 * kib, 32 * kib, 'rw'),
            'SRAM4': (header.value('D3_SRAM_BASE'), 64 * kib, 'rw'),
        })
        for macro, size in (('D1_ITCMRAM_BASE', '64KB'), ('D1_DTCMRAM_BASE', '128KB'),
                            ('D1_AXISRAM_BASE', '512KB'), ('D2_AHBSRAM_BASE', '288KB'),
                            ('D3_SRAM_BASE', '64 KB')):
            self.assertRegex(header.text, r'#define %s\s.*%s' % (macro, size))
        self.assertIn('compiler.boot("vector-table")\n', text)
        self.assertEqual(places['vectors'], 'FLASH')
        # DMA1 and DMA2 reach neither tightly coupled memory (2.4, p. 136;
        # Table 3, p. 104), so nothing a stream may read or write is placed
        # in one.
        for kind in ('data', 'bss', 'stack'):
            self.assertNotIn(places[kind], ('DTCM', 'ITCM'), kind)


def main():
    global REFINE, REQUIRE, TOOLCHAIN
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--refine', type=Path,
                        default=os.environ.get('LANDIN_REFINE'))
    parser.add_argument('--toolchain', type=Path,
                        help='the Cortex-M C driver the consumer links with')
    parser.add_argument('--require-inputs', action='store_true',
                        help='fail, rather than skip, without refine or inputs')
    args, rest = parser.parse_known_args()
    REFINE = Path(args.refine).resolve() if args.refine else None
    REQUIRE = args.require_inputs
    TOOLCHAIN = args.toolchain
    unittest.main(argv=[sys.argv[0]] + rest)


if __name__ == '__main__':
    main()
