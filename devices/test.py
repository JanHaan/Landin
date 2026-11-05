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
import ast
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import struct
import tarfile
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
    """The lock's name for a policy's SVD: the one SVD it pins with the
    policy's hash.  Two policies may read one SVD, RP2350's two cores'."""
    names = [name for name, entry in fetch_inputs.read_lock().items()
             if name.endswith('.svd') and entry['sha256'] == policy['svd_sha256']]
    if len(names) != 1:
        raise AssertionError('the lock pins %d SVDs of the hash %s'
                             % (len(names), policy['svd_sha256']))
    return names[0]


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

    def test_the_evaluator_follows_a_copied_stage_to_its_exit(self):
        import struct
        import thumb

        class Flash:
            segments = [(0x10000000, struct.pack('<II', 0x20042000, 0x10000101), 8)]
            symbols = {}

        # ldr r0, =0x10000000; ldmia r0, {r0, r1}; msr msp, r0; bx r1;
        # then the literal, run from a copy at 0x20041f00.
        stage = struct.pack('<6HI', 0x4802, 0xc803, 0xf380, 0x8808, 0x4708,
                            0, 0x10000000)
        evaluation = thumb.Evaluation(
            Flash(), [], (0x20000000, 0x42000), special=True,
            start={'pc': 0x20041f00, 'sp': 0x20042000},
            until=lambda pc: not 0x20041f00 <= pc < 0x20042000)
        evaluation.place(0x20041f00, stage)
        self.assertEqual(evaluation.run(), [('msr', 'msp', 0x20042000)])
        self.assertEqual(evaluation.r[15], 0x10000100)
        self.assertEqual(evaluation.r[13], 0x20042000)

    def test_the_cores_are_the_compilers(self):
        """CORES is Landin.Targets.Firmware's table of each core's SVD
        cpu name, which refine svd reads, joined to the spelling a
        description names the core by: one table, and this a copy held
        to it, so render_d542 stays independent of refine's code."""
        firmware = ROOT / 'compiler/ada/src/stages/landin-targets-firmware'

        def table(text, function):
            #  A case expression's `when CORE => "TEXT"` arms, to its end.
            arms = text.split('function %s (Core : Core_Kind)' % function,
                              1)[1].split(');', 1)[0]
            return dict(re.findall(r'when (\w+) => "([^"]*)"', arms))

        svd = table(firmware.with_suffix('.ads').read_text(), 'Svd_Name')
        spelling = table(firmware.with_suffix('.adb').read_text(), 'Spelling')
        self.assertTrue(svd and spelling)
        self.assertEqual(CORES, {name: spelling[core]
                                 for core, name in svd.items() if name})

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


class PublicationSafety(unittest.TestCase):
    """Owned toy inputs exercise publication without fetching vendor data."""

    SVD = """<?xml version="1.0" encoding="utf-8"?>
<device schemaVersion="1.1">
  <name>TOY</name>
  <version>1.0</version>
  <addressUnitBits>8</addressUnitBits>
  <width>32</width>
  <size>32</size>
  <access>read-write</access>
  <resetValue>0</resetValue>
  <resetMask>0xFFFFFFFF</resetMask>
  <cpu><name>CM0</name><revision>r0p0</revision><endian>little</endian><mpuPresent>false</mpuPresent><fpuPresent>false</fpuPresent><nvicPrioBits>2</nvicPrioBits><vendorSystickConfig>false</vendorSystickConfig></cpu>
  <peripherals>
    <peripheral>
      <name>GPIO</name>
      <baseAddress>0x40000000</baseAddress>
      <interrupt><name>GPIO_IRQ</name><value>3</value></interrupt>
      <registers>
        <register>
          <name>CTRL</name>
          <addressOffset>0x0</addressOffset>
          <fields>
            <field><name>EN</name><bitOffset>0</bitOffset><bitWidth>1</bitWidth></field>
            <field><name>MODE</name><bitOffset>1</bitOffset><bitWidth>3</bitWidth></field>
          </fields>
        </register>
      </registers>
    </peripheral>
  </peripherals>
</device>
"""

    def make_tree(self, root):
        svd, policy, out = root / 'toy.svd', root / 'toy.json', root / 'out'
        svd.write_text(self.SVD)
        policy.write_text(json.dumps({
            'schema': 2, 'device': 'TOY', 'svd_version': '1.0',
            'svd_sha256': digest(self.SVD.encode()), 'notice': ['toy'],
            'selection': {'GPIO': ['CTRL']},
            'policies': {'GPIO.CTRL': {'read': 'normal', 'write': 'normal',
                                      'reserved': 'zero'}}}))
        out.mkdir()
        command = [str(REFINE), 'svd', '--policy=' + str(policy),
                   '--out-dir=' + str(out), str(svd)]
        return svd, policy, out, command

    def refused(self, command):
        process = subprocess.run(command, capture_output=True, text=True)
        self.assertIn(process.returncode, (1, 2), process.stderr)
        self.assertNotIn('internal compiler error', process.stderr)
        return process

    @requires_refine
    def test_inputs_and_stale_aliases_are_preserved(self):
        for kind in ('svd', 'policy', 'response', 'nested-response', 'stale'):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                svd, policy, out, command = self.make_tree(root)
                if kind == 'svd':
                    source = out / 'toy/gpio/device.ldn'
                    source.parent.mkdir(parents=True)
                    shutil.move(svd, source)
                    command[-1] = str(source)
                elif kind == 'policy':
                    source = out / 'toy/correspondence.json'
                    source.parent.mkdir(parents=True)
                    shutil.move(policy, source)
                    command[2] = '--policy=' + str(source)
                elif kind in ('response', 'nested-response'):
                    source = out / 'toy/correspondence.json'
                    source.parent.mkdir(parents=True)
                    source.write_text(shlex.join(command[1:]) + '\n')
                    if kind == 'nested-response':
                        outer = root / 'outer.rsp'
                        outer.write_text('@' + shlex.quote(str(source)) + '\n')
                        command = [str(REFINE), '@' + str(outer)]
                    else:
                        command = [str(REFINE), '@' + str(source)]
                else:
                    initial = subprocess.run(command, capture_output=True, text=True)
                    self.assertEqual(initial.returncode, 0, initial.stderr)
                    source = out / 'old.svd'
                    os.link(svd, source)
                    manifest = out / 'toy/outputs.json'
                    entries = json.loads(manifest.read_text())
                    entries['old.svd'] = '0' * 64
                    manifest.write_text(json.dumps(entries))
                control = root / 'control'
                control.mkdir()
                accepted_command = ([str(REFINE), 'svd', '--policy=' + str(policy),
                                     '--out-dir=' + str(control), str(svd)]
                                    if kind in ('response', 'nested-response')
                                    else list(command))
                accepted_command[3] = '--out-dir=' + str(control)
                accepted = subprocess.run(accepted_command, capture_output=True, text=True)
                self.assertEqual(accepted.returncode, 0, accepted.stderr)
                original = source.read_bytes()
                identity = (source.stat().st_dev, source.stat().st_ino)
                self.refused(command)
                self.assertEqual(source.read_bytes(), original)
                self.assertEqual((source.stat().st_dev, source.stat().st_ino), identity)

    @requires_refine
    def test_linked_outputs_parents_and_leftovers_are_preserved(self):
        for kind in ('root', 'root-trailing', 'parent', 'final', 'stage',
                     'recovery', 'stale', 'stale-final'):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                svd, policy, out, command = self.make_tree(root)
                outside = root / 'outside'
                outside.mkdir()
                sentinel = outside / 'device.ldn'
                sentinel.write_text('foreign bytes\n')
                if kind in ('root', 'root-trailing'):
                    if kind == 'root-trailing':
                        command[3] = '--out-dir=' + str(out) + '///'
                    out.rmdir()
                    out.symlink_to(outside, target_is_directory=True)
                    link = out
                elif kind == 'parent':
                    (out / 'toy').mkdir()
                    link = out / 'toy/gpio'
                    link.symlink_to(outside, target_is_directory=True)
                elif kind in ('stale', 'stale-final'):
                    initial = subprocess.run(command, capture_output=True, text=True)
                    self.assertEqual(initial.returncode, 0, initial.stderr)
                    link = out / 'linked'
                    if kind == 'stale-final':
                        link.symlink_to(outside / 'absent')
                    else:
                        link.symlink_to(outside, target_is_directory=True)
                    manifest = out / 'toy/outputs.json'
                    entries = json.loads(manifest.read_text())
                    entries['linked' if kind == 'stale-final'
                            else 'linked/device.ldn'] = '0' * 64
                    manifest.write_text(json.dumps(entries))
                else:
                    (out / 'toy/gpio').mkdir(parents=True)
                    suffix = {'final': '', 'stage': '.refine-new',
                              'recovery': '.refine-old'}[kind]
                    link = out / ('toy/gpio/device.ldn' + suffix)
                    link.symlink_to(outside / 'absent')
                original = sentinel.read_bytes()
                self.refused(command)
                self.assertTrue(link.is_symlink())
                self.assertEqual(sentinel.read_bytes(), original)
                self.assertFalse((outside / 'absent').exists())


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
            # A field whose enumerated values are not named as identifiers
            # is read as a number only when the policy says so; without that,
            # one refusal names every such field and the way out.
            unnumbered = dict(policy, numeric_enums=[
                name for name in policy['numeric_enums']
                if not name.startswith(('XOSC.', 'PADS_BANK0.'))])
            path = Path(root) / 'unnumbered.json'
            path.write_text(json.dumps(unnumbered))
            out = Path(root) / 'unnumbered'
            out.mkdir()
            result = run_svd(path, fetch_inputs.fetch(svd_input(policy)), out, expect=1)
            self.assertEqual(result.stderr.count('error[L0528]'), 1)
            for name in ('XOSC.CTRL.FREQ_RANGE ("1_15MHZ")', 'XOSC.STATUS.FREQ_RANGE',
                         'PADS_BANK0.GPIO0.DRIVE ("2mA")', 'PADS_BANK0.GPIO3.DRIVE'):
                self.assertIn(name, result.stderr)
            self.assertIn("the policy's numeric_enums reads such a field", result.stderr)
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
         'CM3': 'cortex-m3', 'CM4': 'cortex-m4', 'CM7': 'cortex-m7',
         'CM33': 'cortex-m33',
         'Xtensa LX6': 'xtensa-lx6', 'Xtensa LX7': 'xtensa-lx7'}

# D701: the two ESP cores' slots, which no interrupt-matrix source takes:
# a vectored mtvec's 32 mcause codes, and the C5's CLIC's 48 identities.
SOURCE_CORES = {'esp-rv32imc': 32, 'esp-rv32imac-clic': 48,
                'xtensa-lx6': 32, 'xtensa-lx7': 32}


def render_d542(raw, policy):
    """D542's generated half from an SVD's bytes and its policy's interrupt
    corrections, core and identity, with nothing of refine's; on an ESP
    core, also the module of its interrupt-matrix sources (D700, D701),
    which is None on the others."""
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
    for named_irq, correction in policy.get('interrupt_corrections', {}).items():
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
    core = policy.get('core') or CORES[text_of(cpu, 'name')]
    module = policy['prefix'] + '/sources'
    lines += ['-- Generated from the SVD; memory.ldn beside it is written'
              ' by hand.'] + notes
    if core in SOURCE_CORES:
        lines += ['-- Its interrupts are interrupt-matrix sources, not slots: '
                  + module + '.']
    lines += ['']
    declared = int(text_of(cpu, 'deviceNumInterrupts') or '0', 0)
    count = SOURCE_CORES.get(
        core, 16 + max(declared, max(value for value, _ in pairs) + 1))
    lines += ['compiler.device("%s")' % policy.get('identity', name.lower()),
              'compiler.core("%s")' % core,
              'compiler.vectors(%d)' % count]
    ordered = sorted(pairs, key=lambda pair: (pair[0], pair[1].encode()))
    if core not in SOURCE_CORES:
        lines += ['compiler.interrupt("%s", %d)' % (interrupt, value)
                  for value, interrupt in ordered]
        return '\n'.join(lines) + '\n', None
    sources = (['-- ' + line for line in policy['notice']]
               + ["-- The %s's interrupt-matrix sources: each is the number"
                  " of its map" % name,
                  '-- register, which routes it to a CPU interrupt line;'
                  ' none is a vector slot.'] + notes
               + ['public %s: u32 = %d' % (interrupt.lower(), value)
                  for value, interrupt in ordered])
    return '\n'.join(lines) + '\n', '\n'.join(sources) + '\n'


#  How pico-sdk's headers spell each field access, as the SVD gives it.
PICO_ACCESS = {
    'RW': ('read-write', None, None),
    'RO': ('read-only', None, None),
    'WO': ('write-only', None, None),
    'WC': ('read-write', None, 'oneToClear'),
    # A self-clearing command bit, CHAN_ABORT's, which the SVD writes as
    # one-to-clear.
    'SC': ('read-write', None, 'oneToClear'),
    'RWF': ('read-write', 'modify', None),
}


def compare_with_pico_sdk(case, rows, device, bases, requests, family_of):
    """Every selected register and field of ROWS against pico-sdk's own
    headers for DEVICE, which refine never reads: offset, address, width,
    masks, field positions, access, reset value and each encoding.
    BASES are each peripheral's base address; REQUESTS is DMA's TREQ_SEL
    request table, whose names the header does not give; FAMILY_OF names
    a peripheral's header and macro prefix."""
    for row in rows:
        peripheral, register = row['source'].split('.')
        family = family_of(peripheral)
        text = fetch_inputs.fetch(device + '/' + family.lower() + '.h').read_text()
        macros = dict(re.findall(r'^#define (\w+)\s+_u\((0x[0-9a-fA-F]+|[0-9]+)\)',
                                 text, re.MULTILINE))
        prefix = family + '_' + register
        with case.subTest(register=row['source']):
            case.assertEqual(row['offset'], int(macros[prefix + '_OFFSET'], 0))
            case.assertEqual(row['address'], bases[peripheral] + row['offset'])
            case.assertEqual(row['width'], 32)
            case.assertEqual(row['alignment'], 4)
            case.assertEqual(row['named_mask'], int(macros[prefix + '_BITS'], 0))
            reset_mask = 0
            reset_value = 0
            for field in row['fields']:
                # Single-field registers omit a second repeated suffix.
                field_prefix = (prefix if field['name'] == register
                                else prefix + '_' + field['name'])
                case.assertEqual(field['mask'], int(macros[field_prefix + '_BITS'], 0))
                case.assertEqual(field['low'], int(macros[field_prefix + '_LSB'], 0))
                case.assertEqual(field['high'], int(macros[field_prefix + '_MSB'], 0))
                access = re.search(r'^#define ' + field_prefix + r'_ACCESS\s+"(.*?)"',
                                   text, re.MULTILINE).group(1)
                case.assertEqual((field['access'], field['read_action'],
                                  field['modified_write']), PICO_ACCESS[access],
                                 field_prefix)
                reset = macros.get(field_prefix + '_RESET')
                if reset is not None:
                    reset_mask |= field['mask']
                    reset_value |= int(reset, 0) << field['low']
                else:
                    case.assertRegex(text, r'#define ' + field_prefix + r'_RESET\s+"-"')
                for name, value in field['encodings']:
                    if field['name'] == 'TREQ_SEL':
                        case.assertEqual(value, requests[name], name)
                    else:
                        case.assertEqual(value, int(macros[field_prefix + '_VALUE_'
                                                          + name.upper()], 0))
            case.assertEqual(row['known_reset_mask'], reset_mask)
            case.assertEqual(row['known_reset_value'], reset_value)


class D542Form(unittest.TestCase):
    """Each generated interrupts.ldn is D542's text, rendered apart from
    refine from the fetched SVD; this replaced the scripts test that read a
    vendored copy."""

    @requires_refine
    def test_each_interrupts_ldn_is_the_form(self):
        for name, policy in policies().items():
            with self.subTest(policy=name):
                raw = fetch_inputs.fetch(svd_input(policy)).read_bytes()
                description, sources = render_d542(raw, policy)
                self.assertEqual(
                    (HERE / policy['description'] / 'interrupts.ldn').read_bytes(),
                    description.encode('ascii'))
                module = (HERE / policy['modules'] / policy['prefix']
                          / 'sources' / 'device.ldn')
                if sources is None:
                    self.assertFalse(module.exists(), module)
                else:
                    self.assertEqual(module.read_bytes(), sources.encode('ascii'))


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
        # The header supplies TREQ_SEL's geometry but not its DREQ names;
        # this literal request table is independent of both.
        requests = ([f'PIO{p}_{d}{n}' for p in range(2)
                     for d in ('TX', 'RX') for n in range(4)] +
                    ['SPI0_TX', 'SPI0_RX', 'SPI1_TX', 'SPI1_RX',
                     'UART0_TX', 'UART0_RX', 'UART1_TX', 'UART1_RX'] +
                    ['PWM_WRAP' + str(n) for n in range(8)] +
                    ['I2C0_TX', 'I2C0_RX', 'I2C1_TX', 'I2C1_RX', 'ADC',
                     'XIP_STREAM', 'XIP_SSITX', 'XIP_SSIRX'])
        expected = dict(zip(requests, range(40)))
        expected.update(TIMER0=59, TIMER1=60, TIMER2=61, TIMER3=62, PERMANENT=63)
        compare_with_pico_sdk(
            self, self.rows(), 'rp2040', bases, expected,
            # The SVD's PPB is the core's private bus, which pico-sdk's
            # header calls by the core's name.
            lambda peripheral: ('UART' if peripheral.startswith('UART')
                                else 'M0PLUS' if peripheral == 'PPB' else peripheral))

    def test_literal_contract(self):
        rows = {r['source']: r for r in self.rows()}
        self.assertEqual(len(rows), 55)
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
                     'UART0.UARTRSR', 'UART0.UARTFR', 'UART0.UARTRIS', 'UART1.UARTFR', 'DMA.CH0_AL1_CTRL',
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



#  RP2350's DMA request table, RP2350 Datasheet release 8, 12.6.4.1,
#  Table 1254, pp. 1015 and 1016, each DREQ_ name without its prefix;
#  pico-sdk's dma.h names only the timers and PERMANENT.
RP2350_REQUESTS = dict(zip(
    [f'PIO{p}_{d}{n}' for p in range(3) for d in ('TX', 'RX') for n in range(4)]
    + ['SPI0_TX', 'SPI0_RX', 'SPI1_TX', 'SPI1_RX',
       'UART0_TX', 'UART0_RX', 'UART1_TX', 'UART1_RX']
    + ['PWM_WRAP' + str(n) for n in range(12)]
    + ['I2C0_TX', 'I2C0_RX', 'I2C1_TX', 'I2C1_RX', 'ADC', 'XIP_STREAM',
       'XIP_QMITX', 'XIP_QMIRX', 'HSTX', 'CORESIGHT', 'SHA256'],
    range(55)), TIMER0=59, TIMER1=60, TIMER2=61, TIMER3=62, PERMANENT=63)


class Rp2350Oracles(unittest.TestCase):
    """The RP2350's selection against pico-sdk's own headers and literals
    reviewed from the RP2350 datasheet (D635)."""

    @classmethod
    def rows(cls):
        policy = policies()['rp2350']
        return json.loads((HERE / policy['modules'] /
                           policy['correspondence']).read_text())

    @requires_refine
    def test_vendor_headers(self):
        # Each base is addressmap.h's PERIPHERAL_BASE; the M33's private
        # bus is PPB_BASE, whose registers m33.h gives as M33_.
        addresses = fetch_inputs.fetch('rp2350/addressmap.h').read_text()
        bases = {name: int(value, 0) for name, value in re.findall(
            r'^#define (\w+)_BASE _u\((0x[0-9a-fA-F]+)\)', addresses, re.MULTILINE)}
        compare_with_pico_sdk(
            self, self.rows(), 'rp2350', bases, RP2350_REQUESTS,
            lambda peripheral: {'UART0': 'UART', 'TIMER0': 'TIMER',
                                'PPB': 'M33'}.get(peripheral, peripheral))

    def test_literal_contract(self):
        rows = {r['source']: r for r in self.rows()}
        self.assertEqual(len(rows), 47)
        fields = {(key, f['name']): f for key, row in rows.items() for f in row['fields']}
        # RP2350 Datasheet release 8, 9.3, p. 539: a pad's isolation
        # latch resets latched and its input buffer disabled, so bring-up
        # clears ISO and sets IE; 9.11.3, Table 885, p. 705: GPIO0 resets
        # to 0x116, ISO bit 8 set, IE bit 6 clear.
        for pad in ('GPIO0', 'GPIO1', 'GPIO3'):
            row = rows['PADS_BANK0.' + pad]
            self.assertEqual((row['known_reset_mask'], row['known_reset_value']),
                             (0x1ff, 0x116), pad)
            self.assertEqual(fields[('PADS_BANK0.' + pad, 'ISO')]['mask'], 0x100)
            self.assertEqual(fields[('PADS_BANK0.' + pad, 'IE')]['mask'], 0x40)
        # 6.4, Table 521, p. 426: POWMAN's CHIP_RESET at offset 0x2c,
        # HAD_POR its bit 16, read-only.
        self.assertEqual(fields[('POWMAN.CHIP_RESET', 'HAD_POR')]['mask'], 1 << 16)
        self.assertEqual(rows['POWMAN.CHIP_RESET']['address'], 0x4010002c)
        # The M33's VTOR and NVIC, in its private peripheral bus.
        self.assertEqual([rows['PPB.' + r]['address'] for r in
                          ('NVIC_ISER0', 'NVIC_ICPR0', 'NVIC_ISPR0', 'VTOR')],
                         [0xe000e100, 0xe000e280, 0xe000e200, 0xe000ed08])
        # TICKS gives TIMER0 its tick, and DMA's control keeps RP2350's
        # status bits where they are: BUSY at 26, the errors at 29 to 31.
        self.assertEqual(rows['TICKS.TIMER0_CYCLES']['offset'], 0x1c)
        trigger = {f['name']: f for f in rows['DMA.CH0_CTRL_TRIG']['fields']}
        self.assertEqual(trigger['BUSY']['mask'], 1 << 26)
        self.assertEqual(trigger['RING_SIZE']['representation'], 'unsigned')
        # An independently reviewed access surface: no policy value builds
        # what is expected, nor the write masks.
        for key, row in rows.items():
            read = ('refused' if key in {'SIO.GPIO_OUT_SET', 'SIO.GPIO_OUT_CLR',
                                         'SIO.GPIO_OE_SET', 'UART0.UARTICR'}
                    else 'modify' if key == 'UART0.UARTDR' else 'normal')
            write = ('refused' if key in {
                'SIO.GPIO_IN', 'TIMER0.TIMERAWL', 'UART0.UARTFR', 'UART0.UARTRIS',
                'RESETS.RESET_DONE', 'CLOCKS.CLK_REF_SELECTED',
                'CLOCKS.CLK_SYS_SELECTED', 'POWMAN.CHIP_RESET', 'PPB.VTOR'}
                     else 'one_clears' if key in {'TIMER0.INTR', 'DMA.INTR',
                                                  'UART0.UARTICR', 'DMA.CHAN_ABORT',
                                                  'XOSC.STATUS'}
                     else 'normal')
            expected = {'read': read, 'write': write, 'reserved': 'zero'}
            if key == 'UART0.UARTDR':
                expected['write_mask'] = '0x000000ff'
            if key == 'DMA.CH0_CTRL_TRIG':
                # Bits 0 to 25 configure the channel; 26 and 31 are status
                # and 29 and 30 clear when written as one.
                expected['write_mask'] = '0x03ffffff'
            self.assertEqual(row['policy'], expected, key)

    @requires_refine
    def test_interrupts_against_the_header(self):
        header = fetch_inputs.fetch('rp2350/intctrl.h').read_text()
        numbers = {int(value): name for name, value in re.findall(
            r'^#define (\w+) (\d+)$', header, re.MULTILINE)}
        text = (DESCRIPTIONS / 'rp2350/interrupts.ldn').read_text()
        given = {int(value): name for name, value in re.findall(
            r'^compiler\.interrupt\("(\w+)", (\d+)\)$', text, re.MULTILINE)}
        # RP2350 Datasheet release 8, 3.2, Table 95, pp. 80 and 81: IRQs 0
        # to 51, of which the SVD omits 40 and 41, the cores' cross trigger
        # interrupts, and the policy adds them; the table spells the spares
        # SPAREIRQ_IRQ_n, where the SVD and the header have SPARE_IRQ_n.
        self.assertEqual(given, numbers)
        self.assertEqual(sorted(given), list(range(52)))
        self.assertIn('-- The policy adds PROC0_IRQ_CTI at 40: RP2350 Datasheet', text)
        self.assertIn('-- The policy adds PROC1_IRQ_CTI at 41: RP2350 Datasheet', text)
        self.assertIn('compiler.vectors(68)\n', text)
        self.assertIn('compiler.core("cortex-m33")\n', text)
        for name, value in (('TIMER0_IRQ_0', 0), ('DMA_IRQ_0', 10), ('USBCTRL_IRQ', 14),
                            ('UART0_IRQ', 33)):
            self.assertEqual(given[value], name)


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
    'RCC.CR': ('RCC_BASE', 'RCC_TypeDef', 'CR', 'RCC_CR'),
    'RCC.AHB1ENR': ('RCC_BASE', 'RCC_TypeDef', 'AHB1ENR', 'RCC_AHB1ENR'),
    'RCC.AHB4ENR': ('RCC_BASE', 'RCC_TypeDef', 'AHB4ENR', 'RCC_AHB4ENR'),
    'RCC.APB1LENR': ('RCC_BASE', 'RCC_TypeDef', 'APB1LENR', 'RCC_APB1LENR'),
    'RCC.RSR': ('RCC_BASE', 'RCC_TypeDef', 'RSR', 'RCC_RSR'),
    'PWR.CSR1': ('PWR_BASE', 'PWR_TypeDef', 'CSR1', 'PWR_CSR1'),
    'PWR.CR3': ('PWR_BASE', 'PWR_TypeDef', 'CR3', 'PWR_CR3'),
    'GPIOB.MODER': ('GPIOB_BASE', 'GPIO_TypeDef', 'MODER', 'GPIO_MODER'),
    'GPIOB.IDR': ('GPIOB_BASE', 'GPIO_TypeDef', 'IDR', 'GPIO_IDR'),
    'GPIOB.BSRR': ('GPIOB_BASE', 'GPIO_TypeDef', 'BSRR', 'GPIO_BSRR'),
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
    'RCC.CR.RC48ON': 'RCC_CR_HSI48ON',
    'RCC.CR.RC48RDY': 'RCC_CR_HSI48RDY',
    'RCC.CR.HSECSSON': 'RCC_CR_CSSHSEON',
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
        # to zero but these.
        expected = {
            # 11.4.1, p. 541: 0xFFFF FFFF for ports other than A and B;
            # 0xABFF FFFF is port A's, which the SVD gives ports B and D by
            # deriving them from port A, and port B's is 0xFFFF FEBF.
            'GPIOD.MODER': 0xffffffff,
            'GPIOB.MODER': 0xfffffebf,
            # 48.8.10, p. 2091, the FIFO-disabled view, which reset selects;
            # 48.8.9, p. 2085, the FIFO-enabled one, is 0x0X80 00C0.
            'USART3.ISR': 0x000000c0,
            # 8.7.39, p. 450, Table 65: 0x00FE 0000, by power-on reset
            # only, whose bit 18 the register's own diagram reserves; the
            # named bits are Table 56's power-on line, p. 333, PORRSTF,
            # PINRSTF, BORRSTF, D2RSTF, D1RSTF and CPURSTF.  The SVD gives 0.
            'RCC.RSR': 0x00fa0000,
            # 8.7.2, p. 383: 0x0000 0001, HSION alone; CSION and HSIKERON
            # are off after reset (p. 385), where the SVD gives 0x0000 0083.
            'RCC.CR': 0x00000001,
            # 6.8.2, p. 305: ACTVOS reads VOS3, and ACTVOSRDY is clear until
            # the supply configuration is written (6.4.1, p. 262).
            'PWR.CSR1': 0x00004000,
            # 6.8.4, p. 307: 0x0000 0006 on revision Y, LDOEN and SCUEN;
            # revision V's 0x0000 0046 differs in reserved bit 6 alone.
            'PWR.CR3': 0x00000006,
        }
        # 11.4.5, p. 543: GPIOx_IDR resets to 0x0000 XXXX, the pins' levels,
        # so no named bit of it has a known reset value.
        unknown = {'GPIOB.IDR': 0}
        # The zeros: RCC 8.7.41, p. 454, 8.7.43, p. 458, 8.7.45, p. 462;
        # GPIOx_AFRH 11.4.10, p. 546, GPIOx_BSRR 11.4.7, p. 544; USART
        # 48.8.1, p. 2067, 48.8.4, p. 2078, 48.8.5, p. 2082, 48.8.11,
        # p. 2096, 48.8.12 and 48.8.13, p. 2098; DMA 15.5.1, p. 659, 15.5.3,
        # p. 660, 15.5.5, p. 662, 15.5.6 and 15.5.7, p. 665, 15.5.8, p. 666;
        # DMAMUX1 17.6.1, p. 708; TIM2 39.4.7, p. 1688.
        for row in self.rows():
            with self.subTest(register=row['source']):
                self.assertEqual(row['known_reset_mask'],
                                 unknown.get(row['source'], row['named_mask']))
                self.assertEqual(row['known_reset_value'],
                                 expected.get(row['source'], 0))
        rows = {row['source']: row for row in self.rows()}
        for key, given in (('GPIOD.MODER', 0xabffffff), ('GPIOB.MODER', 0xabffffff),
                           ('RCC.RSR', 0), ('RCC.CR', 0x83)):
            self.assertEqual(rows[key]['svd_reset_value'], given, key)
            self.assertIn('RM0433', rows[key]['reset_correction']['source'], key)

    def test_access_policies(self):
        # Reviewed from RM0433 Rev 9's access types, never the policy: status
        # is read-only (USART_ISR 48.8.10, p. 2091; DMA_LISR 15.5.1,
        # p. 659; PWR_CSR1 6.8.2, p. 305; GPIOx_IDR 11.4.5, p. 543), a
        # clear register is write-only, written as one to clear (USART_ICR
        # 48.8.11, p. 2096; DMA_LIFCR 15.5.3, p. 660), a set and reset
        # register write-only, its zeros no action (GPIOx_BSRR 11.4.7,
        # p. 544), and the receive register is read-only and its read takes
        # a byte from its FIFO (USART_RDR 48.8.12, p. 2098).
        for row in self.rows():
            key = row['source']
            read = ('refused' if key in {'USART3.ICR', 'DMA1.LIFCR', 'GPIOB.BSRR'}
                    else 'modify' if key == 'USART3.RDR' else 'normal')
            write = ('refused' if key in {'USART3.ISR', 'USART3.RDR', 'DMA1.LISR',
                                          'PWR.CSR1', 'GPIOB.IDR'}
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
        # 15.5.5, p. 662: DMA_SxCR's bit 20 is TRBUFF, which must be set
        # for a stream serving a USART; the SVD lacks it and the policy adds
        # it (D652), as the header has it.
        trbuff = {f['name']: f for f in rows['DMA1.S0CR']['fields']}['TRBUFF']
        self.assertEqual((trbuff['low'], trbuff['high'], trbuff['access']),
                         (20, 20, 'read-write'))
        self.assertTrue(trbuff['correction']['added'])
        self.assertIn('RM0433 Rev 9, 15.5.5, p. 662', trbuff['correction']['source'])
        self.assertEqual(rows['TIM2.CCMR1_Input']['alternate_register'],
                         'CCMR1_Output')
        self.assertEqual(rows['USART3.CR1']['derived_from'], 'USART1')
        self.assertEqual(rows['GPIOD.MODER']['derived_from'], 'GPIOA')
        self.assertEqual(rows['GPIOB.MODER']['derived_from'], 'GPIOA')

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
    def test_the_consumer_links_cacheless(self):
        """The consumer links where the description places it, and nothing
        in its image can enable or maintain the M7's caches (D561, D562).

        Its device accesses are the board run's oracle's to check; what
        stays here is static: every address the code reaches that is not
        a small constant is a literal word in its flash, and none is SCB's
        CCR, whose IC and DC bits enable the caches, or the cache operations
        at 0xE000EF50 to 0xE000EF78.  CPACR's word, which reset writes for
        the float unit (D618), shows the scan reads reset's literals."""
        import struct
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
        self.assertEqual(image.symbols['_landin_firmware_data_start'], 0x24000000)
        self.assertEqual(image.symbols['_landin_firmware_stack_top'],
                         0x24000000 + 512 * 1024)
        self.assertEqual(image.symbols['_landin_firmware_vectors'], 0x08000000)
        self.assertTrue(0x08000000 <= image.symbols['message'] < 0x08200000)
        windows = [(0x58024400, 0x400), (0x58024800, 0x400), (0x58020c00, 0x400),
                   (0x40004800, 0x400), (0x40020000, 0x400), (0x40020800, 0x400),
                   (0xe000e000, 0x1000)]
        # PWR_CR3 reads its reset value, 0x0000 0006, and PWR_CSR1 VOS3 with
        # ACTVOSRDY set (6.8.4, p. 307; 6.8.2, p. 305).
        def reads(address, width):
            return {0x5802480c: 0x6, 0x58024804: 0x6000}.get(address, 0)
        # D653: the reset vector enters the description's stage, which
        # configures the supply, using no memory but the image's own bytes,
        # and ends in compiler-owned reset.
        flash = next(content for address, content, _ in image.segments
                     if address == 0x08000000)
        self.assertEqual(int.from_bytes(flash[4:8], 'little'),
                         image.symbols['_landin_firmware_reset_stage'] | 1)
        reset = image.symbols['_landin_firmware_reset'] & ~1
        before = thumb.Evaluation(image, windows, (0, 0), reads,
                                  until=lambda pc: pc == reset).run()
        self.assertEqual(before, [('r', 0x5802480c, 4, 0x6),   # PWR_CR3
                                  ('w', 0x5802480c, 4, 0x2),   # PWR_CR3: LDOEN
                                  ('r', 0x58024804, 4, 0x6000)])  # PWR_CSR1: ACTVOSRDY
        words = set()
        for address, content, _ in image.segments:
            if 0x08000000 <= address < 0x08200000:
                words.update(struct.unpack_from('<%dI' % (len(content) // 4), content))
        self.assertIn(0xe000ed88, words, 'reset writes no CPACR')
        self.assertNotIn(0xe000ed14, words, 'the image reaches SCB_CCR')
        self.assertFalse([w for w in words if 0xe000ef50 <= w <= 0xe000ef78],
                         'the image reaches a cache maintenance operation')

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


class IdfHeader:
    """ESP-IDF's register headers, read for their macros and the comment
    each field's macros follow: `NAME : ACCESS ;bitpos:[HIGH:LOW] ;default:
    VALUE ;`, in either of the two spellings IDF's generators have used."""

    FIELD = re.compile(r'(\w+)\s*:\s*([\w/]+)\s*;\s*bitpos:\s*\[(\d+)(?::(\d+))?\]'
                       r'\s*;\s*default:\s*([^;]*);')

    def __init__(self, *texts):
        self.lines = []
        self.macros = {}
        self.functions = {}
        for text in texts:
            for line in re.sub(r'\\\n', ' ', text).splitlines():
                self.lines.append(line)
                called = re.match(r'\s*#define\s+(\w+)\(([\w, ]+)\)\s+(.*?)\s*'
                                  r'(?://.*|/\*.*)?$', line)
                plain = re.match(r'\s*#define\s+(\w+)\s+(.*?)\s*(?://.*|/\*.*)?$', line)
                if called:
                    self.functions[called.group(1)] = (
                        [p.strip() for p in called.group(2).split(',')], called.group(3))
                elif plain:
                    self.macros.setdefault(plain.group(1), plain.group(2))

    def value(self, expression):
        def call(match):
            if match.group(1) not in self.functions:
                return match.group(0)
            params, body = self.functions[match.group(1)]
            for param, argument in zip(params, match.group(2).split(',')):
                body = re.sub(r'\b%s\b' % param, '(%s)' % argument.strip(), body)
            return '(' + body + ')'
        text = expression
        for _ in range(40):
            text = re.sub(r'\(\((\s*\w+\s*)\)\)', r'(\1)', text)
            expanded = re.sub(r'\b(\w+)\s*\(([^()]*)\)', call, text)
            expanded = re.sub(r'\bBIT\((\d+)\)', r'(1 << \1)', expanded)
            expanded = re.sub(r'\b([A-Za-z_]\w*)\b',
                              lambda m: '(' + self.macros[m.group(1)] + ')'
                              if m.group(1) in self.macros else m.group(0), expanded)
            if expanded == text:
                break
            text = expanded
        text = re.sub(r'\b(0x[0-9a-fA-F]+|\d+)[uUlL]+\b', r'\1', text)
        # REG_UART_BASE(i) selects UART2's irregular offset with a C
        # ternary. Its expanded arguments and both results are integers.
        text = re.sub(
            r'\(\s*\((\d+)\)\s*>\s*(\d+)\s*\?\s*(0x[0-9a-fA-F]+|\d+)'
            r'\s*:\s*(0x[0-9a-fA-F]+|\d+)\s*\)',
            lambda m: m.group(3) if int(m.group(1)) > int(m.group(2)) else m.group(4), text)
        if not re.fullmatch(r'[\s0-9a-fA-FxX()+\-*<>|&~]*', text):
            raise AssertionError('not evaluated: %s, %s' % (expression, text))
        return eval(text, {})

    def commented(self, register_macro):
        """Each field the comments in a register's block declare: its access,
        high and low bits and default."""
        lines = iter(self.lines)
        for line in lines:
            if re.match(r'\s*#define\s+%s\b' % register_macro, line):
                break
        else:
            raise AssertionError('no register ' + register_macro)
        found = {}
        for line in lines:
            if re.match(r'\s*#define\s+\w+_REG\b', line):
                break
            match = self.FIELD.search(line)
            if match:
                high = int(match.group(3))
                low = int(match.group(4)) if match.group(4) else high
                found[match.group(1)] = (match.group(2), high, low, match.group(5).strip())
        return found


def idf_default(text):
    """A field's default as IDF writes it: 0x1f, 31, or Verilog's 8'h1f."""
    match = re.fullmatch(r"(\d+)'([bdh])([0-9a-fA-F_]+)", text.strip())
    if match:
        return int(match.group(3).replace('_', ''),
                   {'b': 2, 'd': 10, 'h': 16}[match.group(2)])
    return int(text.strip().rstrip('uU'), 0)


#  How IDF's headers spell a register's macro and a field's, where neither
#  is the family's prefix, `_`, and the SVD's name.  The IO MUX's pins share
#  one set of field macros, which the C3 and C5 headers spell by their
#  sleep-mode and pull names.
IO_MUX_FIELDS = {'MCU_OE': 'SLP_OE', 'SLP_SEL': 'SLP_SEL', 'MCU_WPD': 'SLP_PD',
                 'MCU_WPU': 'SLP_PU', 'MCU_IE': 'SLP_IE', 'MCU_DRV': 'SLP_DRV',
                 'FUN_WPD': 'FUN_PD', 'FUN_WPU': 'FUN_PU', 'FUN_IE': 'FUN_IE',
                 'FUN_DRV': 'FUN_DRV', 'MCU_SEL': 'MCU_SEL', 'FILTER_EN': 'FILTER_EN'}


def compare_with_esp_idf(case, rows, chip, families, names, unshared, resets):
    """Every selected register and field of ROWS against ESP-IDF's headers
    for CHIP, which refine never reads: address, each field's position and
    width, the reset value it promises and the access its policy admits.

    FAMILIES gives each peripheral's header, macro prefix and instance;
    NAMES (register, field) the header's macro where it spells the field
    otherwise, a register's own in NAMES[(register, None)]; UNSHARED each
    (register, field, side) one of the two names and the other lacks,
    reviewed against the manual; RESETS each (register, field) whose
    default the manual says the header gives wrongly."""
    seen = set()
    for row in rows:
        key = row['source']
        peripheral, register = key.split('.')
        header_file, prefix, instance = families[peripheral]
        header = IdfHeader(*[fetch_inputs.fetch(chip + '/' + name).read_text()
                             for name in ('reg_base.h', 'soc.h', header_file)])
        macro = names.get((key, None), prefix + '_' + register + '_REG')
        call = re.match(r'(\w+)\((\d+)\)$', macro)
        with case.subTest(register=key):
            case.assertEqual(row['width'], 32)
            case.assertEqual(
                header.value(macro if call or instance is None
                             else '%s(%d)' % (macro, instance)), row['address'])
            commented = ({} if peripheral in ('IO_MUX', 'CLIC')
                         else header.commented(call.group(1) if call else macro))
            matched = set()
            reset_mask = 0
            reset_value = 0
            for field in row['fields']:
                name = names.get((key, field['name']), prefix + '_' + field['name'])
                if (key, field['name'], 'svd') in unshared:
                    seen.add((key, field['name'], 'svd'))
                    case.assertNotIn(name, commented)
                    continue
                if name + '_S' in header.macros and name + '_V' in header.macros:
                    case.assertEqual(header.value(name + '_S'), field['low'], name)
                    case.assertEqual(header.value(name + '_V'),
                                     (1 << field['high'] - field['low'] + 1) - 1, name)
                else:
                    # ESP32's older DPORT header gives clock/reset fields
                    # as shifted masks alone, without _S/_V companions.
                    case.assertEqual(header.value(name), field['mask'], name)
                if name not in commented:
                    continue
                matched.add(name)
                access, high, low, default = commented[name]
                case.assertEqual((high, low), (field['high'], field['low']), name)
                if (key, field['name']) in resets:
                    seen.add((key, field['name']))
                elif field['mask'] & row['known_reset_mask']:
                    reset_mask |= field['mask']
                    reset_value |= idf_default(default) << field['low']
            case.assertEqual(row['known_reset_value'] & reset_mask, reset_value)
            for name in sorted(set(commented) - matched):
                case.assertIn((key, name, 'header'), unshared,
                              'the header alone has ' + name)
                seen.add((key, name, 'header'))
            # A register of read-only fields takes no write, and one of
            # write-only fields or write triggers no read, but a FIFO.
            accesses = {commented[name][0] for name in matched}
            if accesses and accesses <= {'RO'} and register != 'FIFO':
                case.assertEqual(row['policy']['write'], 'refused')
            if accesses and accesses <= {'WO', 'WT'}:
                case.assertEqual(row['policy']['read'], 'refused')
    case.assertEqual(seen, set(unshared) | set(resets))


def sources_of(chip):
    """The interrupt-matrix sources IDF's interrupts.h numbers, by the
    name between ETS_ and its _INTR_SOURCE or _SOURCE."""
    text = fetch_inputs.fetch(chip + '/interrupts.h').read_text()
    body = text[text.index('typedef enum'):text.index('ETS_MAX_INTR_SOURCE')]
    found = {}
    number = -1
    for name, value in re.findall(r'^\s*ETS_(\w+?)\s*(?:=\s*(\w+))?\s*,', body,
                                  re.MULTILINE):
        if value and not value.isdigit():
            continue
        number = int(value) if value else number + 1
        found[re.sub(r'(_INTR)?_SOURCE$', '', name)] = number
    return found


def generated_sources(policy):
    text = (HERE / policy['modules'] / policy['prefix'] / 'sources'
            / 'device.ldn').read_text()
    return {name.upper(): int(value) for name, value in
            re.findall(r'^public (\w+): u32 = (\d+)$', text, re.MULTILINE)}


ESP32C3_FAMILIES = {
    'UART0': ('uart_reg.h', 'UART', 0), 'SYSTEM': ('system_reg.h', 'SYSTEM', None),
    'GPIO': ('gpio_reg.h', 'GPIO', None), 'IO_MUX': ('io_mux_reg.h', 'IO_MUX', None),
    'INTERRUPT_CORE0': ('interrupt_core0_reg.h', 'INTERRUPT_CORE0', None),
    'SYSTIMER': ('systimer_reg.h', 'SYSTIMER', None),
    'TIMG0': ('timer_group_reg.h', 'TIMG', 0), 'TIMG1': ('timer_group_reg.h', 'TIMG', 1),
    'RTC_CNTL': ('rtc_cntl_reg.h', 'RTC_CNTL', None)}


class Esp32c3Oracles(unittest.TestCase):
    """The ESP32-C3's selection against ESP-IDF v6.1's headers and literals
    reviewed from its Technical Reference Manual, v1.4 (D702)."""

    @classmethod
    def rows(cls):
        policy = policies()['esp32c3']
        return json.loads((HERE / policy['modules'] /
                           policy['correspondence']).read_text())

    @requires_refine
    def test_vendor_headers(self):
        names = {('GPIO.IN', 'DATA_NEXT'): 'GPIO_IN_DATA',
                 ('UART0.ID', 'REG_UPDATE'): 'UART_UPDATE',
                 ('UART0.CLKDIV', 'FRAG'): 'UART_CLKDIV_FRAG',
                 ('SYSTEM.PERIP_CLK_EN0', 'EXT1_CLK_EN'): 'SYSTEM_I2C_EXT1_CLK_EN',
                 ('SYSTEM.PERIP_RST_EN0', 'EXT1_RST'): 'SYSTEM_I2C_EXT1_RST'}
        for field, spelled in (('OUT_SEL', 'OUT_SEL'), ('INV_SEL', 'OUT_INV_SEL'),
                               ('OEN_SEL', 'OEN_SEL'), ('OEN_INV_SEL', 'OEN_INV_SEL')):
            names[('GPIO.FUNC10_OUT_SEL_CFG', field)] = 'GPIO_FUNC10_' + spelled
        for pin in ('GPIO10', 'GPIO20', 'GPIO21'):
            for field, spelled in IO_MUX_FIELDS.items():
                names[('IO_MUX.' + pin, field)] = spelled
        compare_with_esp_idf(
            self, self.rows(), 'esp32c3', ESP32C3_FAMILIES, names,
            unshared=set(),
            # 9.8, Registers 9.37 and 9.39, pp. 254 and 255: the RTC
            # watchdog's and the super watchdog's write protection reset to
            # zero, as the SVD says; the header gives each its key.
            resets={('RTC_CNTL.WDTWPROTECT', 'WDT_WKEY'),
                    ('RTC_CNTL.SWD_WPROTECT', 'SWD_WKEY')})

    @requires_refine
    def test_sources_against_the_header(self):
        given = generated_sources(policies()['esp32c3'])
        expected = dict(sources_of('esp32c3'))
        # The SVD and the header agree on every source's number; they
        # spell four otherwise.
        for svd_name, header_name in (('I2S0', 'I2S0'), ('TWAI0', 'TWAI'),
                                      ('USB_DEVICE', 'USB_SERIAL_JTAG'),
                                      ('I2C_MASTER', 'I2C_MASTER'),
                                      ('SYSTIMER_TARGET0', 'SYSTIMER_TARGET0')):
            expected[svd_name] = expected.pop(header_name)
        for name in list(expected):
            if name.endswith('_LEVEL_INTR'):
                expected[name[:-len('_INTR')]] = expected.pop(name)
        for name in ('SYSTIMER_TARGET0_EDGE', 'SYSTIMER_TARGET1_EDGE',
                     'SYSTIMER_TARGET2_EDGE'):
            expected.pop(name, None)
        self.assertEqual(given, expected)
        self.assertEqual(given['UART0'], 21)
        self.assertEqual(given['SYSTIMER_TARGET0'], 37)

    def test_literal_contract(self):
        rows = {r['source']: r for r in self.rows()}
        self.assertEqual(len(rows), 54)
        fields = {(key, f['name']): f for key, row in rows.items() for f in row['fields']}
        # TRM v1.4, 8.3, Table 8.3-1, pp. 204 and 205: UART0's source is 21
        # and SYSTIMER_TARGET0's 37, so their mapping registers are at 0x54
        # and 0x94 of the interrupt matrix at 0x600C_2000 (3.3, Table 3.3-3,
        # p. 99), each a CPU interrupt line in bits 4:0.
        self.assertEqual(rows['INTERRUPT_CORE0.UART_INTR_MAP']['address'], 0x600c2054)
        self.assertEqual(rows['INTERRUPT_CORE0.SYSTIMER_TARGET0_INT_MAP']['address'],
                         0x600c2094)
        self.assertEqual(fields[('INTERRUPT_CORE0.UART_INTR_MAP', 'UART_INTR_MAP')]['mask'],
                         0x1f)
        # 16.5, Registers 16.3 and 16.5, pp. 435 and 437: UART0's clock
        # enable and reset are bit 2, the system timer's bit 29, and the
        # one I2S's bit 21, which the policy moves there from bit 4.
        self.assertEqual(fields[('SYSTEM.PERIP_CLK_EN0', 'UART_CLK_EN')]['mask'], 1 << 2)
        self.assertEqual(fields[('SYSTEM.PERIP_CLK_EN0', 'SYSTIMER_CLK_EN')]['mask'],
                         1 << 29)
        self.assertEqual(fields[('SYSTEM.PERIP_CLK_EN0', 'I2S0_CLK_EN')]['mask'], 1 << 21)
        self.assertNotIn(('SYSTEM.PERIP_CLK_EN0', 'I2S1_CLK_EN'), fields)
        # 5.15.2, Register 5.21, p. 187: the IO MUX's pins from 0x0004, so
        # UART0's GPIO20 and GPIO21 at 0x54 and 0x58 and the indicator's
        # GPIO10 at 0x2c, MCU_SEL in bits 14:12 and MCU_DRV in 6:5.
        self.assertEqual([rows['IO_MUX.' + pin]['address'] for pin in
                          ('GPIO10', 'GPIO20', 'GPIO21')],
                         [0x6000902c, 0x60009054, 0x60009058])
        self.assertEqual(fields[('IO_MUX.GPIO20', 'MCU_SEL')]['mask'], 0x7000)
        self.assertEqual(fields[('IO_MUX.GPIO20', 'MCU_DRV')]['mask'], 0x60)
        self.assertEqual(rows['IO_MUX.GPIO20']['dim_element'],
                         {'array': 'GPIO%s', 'index': '20'})
        # The watchdogs: a flash boot leaves timer group 0's MWDT and the
        # RWDT running (12.1, p. 305), each enabled by bit 31 of its first
        # configuration word, as is timer group 1's; and the super watchdog
        # is fed automatically by bit 31 of SWD_CONF (12.3.2, p. 309;
        # Register 9.38, p. 255).
        for key in ('TIMG0.WDTCONFIG0', 'TIMG1.WDTCONFIG0', 'RTC_CNTL.WDTCONFIG0'):
            self.assertEqual(fields[(key, 'WDT_EN')]['mask'], 1 << 31, key)
        self.assertEqual([rows[k]['address'] for k in
                          ('TIMG0.WDTCONFIG0', 'TIMG0.WDTWPROTECT',
                           'TIMG1.WDTCONFIG0', 'TIMG1.WDTWPROTECT',
                           'RTC_CNTL.WDTCONFIG0', 'RTC_CNTL.WDTWPROTECT',
                           'RTC_CNTL.SWD_CONF', 'RTC_CNTL.SWD_WPROTECT')],
                         [0x6001f048, 0x6001f064, 0x60020048, 0x60020064,
                          0x60008090, 0x600080a8, 0x600080ac, 0x600080b0])
        self.assertEqual(fields[('RTC_CNTL.SWD_CONF', 'SWD_AUTO_FEED_EN')]['mask'],
                         1 << 31)
        # An independently reviewed access surface.
        for key, row in rows.items():
            read = ('refused' if key in {'UART0.INT_CLR', 'GPIO.OUT_W1TS',
                                         'GPIO.OUT_W1TC', 'GPIO.ENABLE_W1TS',
                                         'SYSTIMER.COMP0_LOAD', 'SYSTIMER.INT_CLR',
                                         'TIMG0.WDTFEED', 'TIMG1.WDTFEED',
                                         'RTC_CNTL.WDTFEED'}
                    else 'modify' if key == 'UART0.FIFO' else 'normal')
            write = ('refused' if key in {
                'UART0.INT_RAW', 'UART0.INT_ST', 'UART0.STATUS', 'GPIO.IN',
                'INTERRUPT_CORE0.CPU_INT_EIP_STATUS', 'SYSTIMER.UNIT0_VALUE_HI',
                'SYSTIMER.UNIT0_VALUE_LO', 'SYSTIMER.INT_RAW', 'SYSTIMER.INT_ST',
                'RTC_CNTL.RESET_STATE'}
                     else 'one_clears' if key in {'UART0.INT_CLR', 'SYSTIMER.INT_CLR'}
                     else 'normal')
            expected = {'read': read, 'write': write, 'reserved': 'zero'}
            mask = {'UART0.FIFO': '0x000000ff', 'SYSTIMER.UNIT0_OP': '0x40000000',
                    'RTC_CNTL.SWD_CONF': '0xfffe0000'}.get(key)
            if mask:
                expected['write_mask'] = mask
            self.assertEqual(row['policy'], expected, key)


ESP32C5_FAMILIES = {
    'UART0': ('uart_reg.h', 'UART', 0), 'PCR': ('pcr_reg.h', 'PCR', None),
    'GPIO': ('gpio_reg.h', 'GPIO', None), 'IO_MUX': ('io_mux_reg.h', 'IO_MUX', None),
    'INTERRUPT_CORE0': ('interrupt_matrix_reg.h', 'INTERRUPT_CORE0', None),
    'CLIC': ('clic_reg.h', 'CLIC', None),
    'SYSTIMER': ('systimer_reg.h', 'SYSTIMER', None),
    'TIMG0': ('timer_group_reg.h', 'TIMG', 0), 'TIMG1': ('timer_group_reg.h', 'TIMG', 1),
    'LP_WDT': ('lp_wdt_reg.h', 'LP_WDT', None),
    'LP_CLKRST': ('lp_clkrst_reg.h', 'LP_CLKRST', None)}


class Esp32c5Oracles(unittest.TestCase):
    """The ESP32-C5's selection against ESP-IDF v6.1's headers and literals
    reviewed from its Technical Reference Manual, v1.1 (D702, D704, D705)."""

    @classmethod
    def rows(cls):
        policy = policies()['esp32c5']
        return json.loads((HERE / policy['modules'] /
                           policy['correspondence']).read_text())

    @requires_refine
    def test_vendor_headers(self):
        names = {('GPIO.IN', 'DATA_NEXT'): 'GPIO_IN_DATA_NEXT',
                 ('CLIC.MCLICCFG', None): 'CLIC_INT_CONFIG_REG',
                 ('CLIC.CLICINFO', None): 'CLIC_INT_INFO_REG',
                 ('CLIC.MCLICCFG', 'MNLBITS'): 'CLIC_INT_CONFIG_MNLBITS',
                 ('CLIC.MCLICCFG', 'NMBITS'): 'CLIC_INT_CONFIG_NMBITS',
                 ('CLIC.CLICINFO', 'NUM_INTERRUPTS'): 'CLIC_INT_INFO_NUM_INT',
                 ('CLIC.CLICINFO', 'VERSION'): 'CLIC_INT_INFO_VERSION',
                 ('CLIC.CLICINFO', 'CLICINTCTLBITS'): 'CLIC_INT_INFO_CTLBITS'}
        for line in ('17', '18'):
            key = 'CLIC.CLICINT' + line
            names[(key, None)] = 'CLIC_INT_CTRL_REG(%s)' % line
            for field, spelled in (('IP', 'IP'), ('IE', 'IE'), ('SHV', 'ATTR_SHV'),
                                   ('TRIG', 'ATTR_TRIG'), ('MODE', 'ATTR_MODE')):
                names[(key, field)] = 'CLIC_INT_' + spelled
        for field, spelled in (('FUNC_OUT_SEL', 'OUT_SEL'),
                               ('FUNC_OUT_INV_SEL', 'OUT_INV_SEL'),
                               ('FUNC_OE_SEL', 'OE_SEL'), ('FUNC_OE_INV_SEL', 'OE_INV_SEL')):
            names[('GPIO.FUNC24_OUT_SEL_CFG', field)] = 'GPIO_FUNC24_' + spelled
        for source in ('UART0', 'SYSTIMER_TARGET0'):
            key = 'INTERRUPT_CORE0.%s_INTR_MAP' % source
            names[(key, 'PASS_IN_SEC')] = 'INTERRUPT_CORE0_%s_INTR_PASS_IN_SEC' % source
        unshared = set()
        for pin in ('GPIO11', 'GPIO12', 'GPIO24'):
            for field, spelled in IO_MUX_FIELDS.items():
                names[('IO_MUX.' + pin, field)] = spelled
            # TRM v1.1, 8.13, Register 8.25, p. 352: a pin's HYS_EN and
            # HYS_SEL are bits 16 and 17, as the SVD says; the header has no
            # macro for either.
            unshared |= {('IO_MUX.' + pin, 'HYS_EN', 'svd'),
                         ('IO_MUX.' + pin, 'HYS_SEL', 'svd')}
        # 2.8.2.7, Register 2.67, p. 90: clicintctl[i]'s level and priority
        # are its bits 7:5, its lower five hardwired to one, where the
        # header's CLIC_INT_CTL is the whole byte.
        unshared |= {('CLIC.CLICINT17', 'CTL', 'svd'), ('CLIC.CLICINT18', 'CTL', 'svd')}
        compare_with_esp_idf(self, self.rows(), 'esp32c5', ESP32C5_FAMILIES, names,
                             unshared=unshared, resets=set())

    @requires_refine
    def test_sources_against_the_header(self):
        given = generated_sources(policies()['esp32c5'])
        expected = dict(sources_of('esp32c5'))
        for svd_name, header_name in (('I2S', 'I2S0'), ('GPIO_EXT', 'GPIO_EXT'),
                                      ('I2C_MASTER', 'I2C_MASTER')):
            expected[svd_name] = expected.pop(header_name)
        for name in list(expected):
            if name.endswith('_LEVEL_INTR'):
                expected[name[:-len('_INTR')]] = expected.pop(name)
        # TRM v1.1, 11.5.1, Table 11.5-1, pp. 474 to 476, where the SVD and
        # the header disagree: source 27 is BUS_MONITOR, which the header
        # calls ASSIST_DEBUG, and 35 is reserved, which the header calls
        # MODEM_PERI_TIMEOUT.
        expected['BUS_MONITOR'] = expected.pop('ASSIST_DEBUG')
        del expected['MODEM_PERI_TIMEOUT']
        self.assertEqual(given, expected)
        self.assertEqual(given['UART0'], 47)
        self.assertEqual(given['SYSTIMER_TARGET0'], 61)

    def test_literal_contract(self):
        rows = {r['source']: r for r in self.rows()}
        self.assertEqual(len(rows), 53)
        fields = {(key, f['name']): f for key, row in rows.items() for f in row['fields']}
        # TRM v1.1, 11.6, p. 480: UART0's and SYSTIMER_TARGET0's mapping
        # registers are at 0x0BC and 0x0F4 of the matrix at 0x6001_0000,
        # four times their sources, 47 and 61, where the SVD gives 0xB4 and
        # 0xEC; and 11.5.3, p. 477: a source is routed by writing the CLIC
        # identity, 16 to 47, into its map register's bits 5:0.
        for key, offset, svd in (('INTERRUPT_CORE0.UART0_INTR_MAP', 0xbc, 0xb4),
                                 ('INTERRUPT_CORE0.SYSTIMER_TARGET0_INTR_MAP', 0xf4,
                                  0xec)):
            self.assertEqual(rows[key]['address'], 0x60010000 + offset, key)
            self.assertEqual(rows[key]['offset_correction']['svd_offset'], svd, key)
        self.assertEqual(fields[('INTERRUPT_CORE0.UART0_INTR_MAP',
                                 'UART0_INTR_MAP')]['mask'], 0x3f)
        self.assertTrue(fields[('INTERRUPT_CORE0.UART0_INTR_MAP',
                                'PASS_IN_SEC')]['correction']['added'])
        # 2.8.2.6 and 2.8.2.7, pp. 86 to 90: the CLIC's configuration and
        # information at 0x2080_0000 and 0x2080_0004, and each interrupt's
        # four bytes at 0x2080_1000 + 4 * i, so the CPU's peripheral lines
        # 1 and 2 are identities 17 and 18 at 0x2080_1044 and 0x2080_1048;
        # 48 interrupts, three bits of level and priority.
        self.assertEqual([rows['CLIC.' + r]['address'] for r in
                          ('MCLICCFG', 'CLICINFO', 'CLICINT17', 'CLICINT18')],
                         [0x20800000, 0x20800004, 0x20801044, 0x20801048])
        self.assertEqual((rows['CLIC.CLICINFO']['known_reset_value'],
                          rows['CLIC.CLICINT17']['known_reset_value']),
                         (0x00600030, 0x00c00000))
        self.assertEqual([fields[('CLIC.CLICINT17', f)]['mask'] for f in
                          ('IP', 'IE', 'SHV', 'TRIG', 'MODE', 'CTL')],
                         [0x1, 0x100, 0x10000, 0x60000, 0xc00000, 0xe0000000])
        self.assertIn('addition', rows['CLIC.CLICINT17'])
        # 8.13, Register 8.25, p. 352: UART0's GPIO11 and GPIO12 and the
        # indicator's GPIO24 from the IO MUX at 0x6009_0000.
        self.assertEqual([rows['IO_MUX.' + pin]['address'] for pin in
                          ('GPIO11', 'GPIO12', 'GPIO24')],
                         [0x6009002c, 0x60090030, 0x60090060])
        # The watchdogs: a flash boot leaves timer group 0's MWDT and the
        # RWDT running (16.1, p. 710), each enabled by bit 31 of its first
        # configuration word (Register 15.10, p. 701; Register 16.1, p. 717),
        # as is timer group 1's; and the super watchdog is fed automatically
        # by bit 18 of SWD_CONFIG (Register 16.8, p. 721), which the manual
        # calls RTC_WDT_ and the SVD and the header LP_WDT_.
        for key in ('TIMG0.WDTCONFIG0', 'TIMG1.WDTCONFIG0', 'LP_WDT.CONFIG0'):
            self.assertEqual(fields[(key, 'WDT_EN')]['mask'], 1 << 31, key)
        self.assertEqual(fields[('LP_WDT.SWD_CONFIG', 'SWD_AUTO_FEED_EN')]['mask'],
                         1 << 18)
        self.assertNotIn(('TIMG0.WDTCONFIG0', 'WDT_USE_XTAL'), fields)
        self.assertEqual([rows[k]['address'] for k in
                          ('TIMG0.WDTCONFIG0', 'TIMG0.WDTWPROTECT',
                           'TIMG1.WDTCONFIG0', 'TIMG1.WDTWPROTECT',
                           'LP_WDT.CONFIG0', 'LP_WDT.WPROTECT',
                           'LP_WDT.SWD_CONFIG', 'LP_WDT.SWD_WPROTECT')],
                         [0x60008048, 0x60008064, 0x60009048, 0x60009064,
                          0x600b1c00, 0x600b1c18, 0x600b1c1c, 0x600b1c20])
        for key, row in rows.items():
            read = ('refused' if key in {'UART0.INT_CLR', 'GPIO.OUT_W1TS',
                                         'GPIO.OUT_W1TC', 'GPIO.ENABLE_W1TS',
                                         'SYSTIMER.COMP0_LOAD', 'SYSTIMER.INT_CLR',
                                         'TIMG0.WDTFEED', 'TIMG1.WDTFEED',
                                         'LP_WDT.FEED'}
                    else 'modify' if key == 'UART0.FIFO' else 'normal')
            write = ('refused' if key in {
                'UART0.INT_RAW', 'UART0.INT_ST', 'UART0.STATUS', 'GPIO.IN',
                'CLIC.CLICINFO', 'SYSTIMER.UNIT0_VALUE_HI', 'SYSTIMER.UNIT0_VALUE_LO',
                'SYSTIMER.INT_RAW', 'SYSTIMER.INT_ST', 'LP_CLKRST.RESET_CAUSE'}
                     else 'one_clears' if key in {'UART0.INT_CLR', 'SYSTIMER.INT_CLR'}
                     else 'normal')
            expected = {'read': read, 'write': write, 'reserved': 'zero'}
            mask = {'UART0.FIFO': '0x000000ff', 'SYSTIMER.UNIT0_OP': '0x40000000',
                    'LP_WDT.SWD_CONFIG': '0xfffc0000',
                    'PCR.UART0_CONF': '0x00000003', 'PCR.SYSTIMER_CONF': '0x00000003',
                    'CLIC.MCLICCFG': '0x0000000f', 'CLIC.CLICINT17': '0xe0070101',
                    'CLIC.CLICINT18': '0xe0070101'}.get(key)
            if mask:
                expected['write_mask'] = mask
            self.assertEqual(row['policy'], expected, key)


class Rp2350Hazard3Oracles(unittest.TestCase):
    """RP2350's Hazard3 selection: the Arm cores' (D635) without the M33's
    private bus, from the same SVD, with the Hazard3 core and its own
    identity (D706)."""

    @requires_refine
    def test_vendor_headers(self):
        policy = policies()['rp2350_hazard3']
        rows = json.loads((HERE / policy['modules'] /
                           policy['correspondence']).read_text())
        addresses = fetch_inputs.fetch('rp2350/addressmap.h').read_text()
        bases = {name: int(value, 0) for name, value in re.findall(
            r'^#define (\w+)_BASE _u\((0x[0-9a-fA-F]+)\)', addresses, re.MULTILINE)}
        compare_with_pico_sdk(
            self, rows, 'rp2350', bases, RP2350_REQUESTS,
            lambda peripheral: {'UART0': 'UART', 'TIMER0': 'TIMER'}.get(peripheral,
                                                                       peripheral))

    def test_the_arm_selection_without_its_private_bus(self):
        arm = policies()['rp2350']
        hazard3 = policies()['rp2350_hazard3']
        self.assertEqual(hazard3['svd_sha256'], arm['svd_sha256'])
        self.assertEqual((hazard3['core'], hazard3['identity']),
                         ('hazard3', 'rp2350-hazard3'))
        expected = {k: v for k, v in arm['selection'].items() if k != 'PPB'}
        self.assertEqual(hazard3['selection'], expected)
        self.assertEqual(hazard3['policies'],
                         {k: v for k, v in arm['policies'].items()
                          if not k.startswith('PPB.')})
        # Every module the two share is the same text: the core does not
        # change a register, so the Hazard3 description's modules are the
        # chip's, named by the chip alone (D831), and its manifest names
        # every one the Arm cores' does, at the same hash, but the private
        # bus's.
        self.assertEqual((hazard3['modules'], hazard3['prefix']),
                         (arm['modules'], arm['prefix']))
        def modules(policy):
            recorded = json.loads((HERE / policy['modules'] / policy['manifest']).read_text())
            return {path: digest for path, digest in recorded.items()
                    if path.endswith('/device.ldn')}
        self.assertEqual(modules(hazard3),
                         {path: digest for path, digest in modules(arm).items()
                          if not path.startswith(arm['prefix'] + '/ppb/')})
        self.assertEqual(len(modules(hazard3)), len(expected))
        text = (DESCRIPTIONS / 'rp2350_hazard3/interrupts.ldn').read_text()
        # RP2350 Datasheet release 8, 3.2, p. 81: one IRQ table for both
        # cores' kinds, so Hazard3's IRQ n is the Arm cores' n, and the
        # Xh3irq core model takes it at slot 16 + n.
        arm_text = (DESCRIPTIONS / 'rp2350/interrupts.ldn').read_text()
        self.assertEqual(text.replace('"rp2350-hazard3"', '"rp2350"')
                         .replace('"hazard3"', '"cortex-m33"'), arm_text)

    def test_the_pico_2_map(self):
        # The Hazard3 description is the Arm one's map, regions, placements
        # and boot kind, line for line; only its comments differ.
        def directives(device):
            return [line for line in (DESCRIPTIONS / device / 'memory.ldn')
                    .read_text().splitlines() if line and not line.startswith('--')]
        self.assertEqual(directives('rp2350_hazard3'), directives('rp2350'))
        self.assertFalse((DESCRIPTIONS / 'rp2350_hazard3' / 'watchdogs.ldn').exists())


def stage_stores(text):
    """The device stores a boot stage written in RV32 assembly makes, in
    order, from its li, la, lw, or, sw, j and jr alone: (address, value), a
    value read back and modified being ('|', address, mask); and where it
    jumps.  It refuses any other instruction, so a stage this cannot read
    is not taken as checked."""
    body = re.search(r'assembler\.block\("""(.*?)"""\)', text, re.S).group(1)
    registers = {'zero': 0}
    stores = []
    for line in body.splitlines():
        line = line.split('#')[0].strip()
        if not line:
            continue
        op, _, rest = line.partition(' ')
        args = [a.strip() for a in rest.split(',')]
        if op == 'li':
            registers[args[0]] = int(args[1], 0)
        elif op == 'la':
            registers[args[0]] = ('symbol', args[1])
        elif op in ('sw', 'lw'):
            offset, base = re.fullmatch(r'(0x[0-9a-f]+|\d+)\((\w+)\)', args[1]).groups()
            address = registers[base] + int(offset, 0)
            if op == 'sw':
                stores.append((address, registers[args[0]]))
            else:
                registers[args[0]] = ('read', address)
        elif op == 'or':
            registers[args[0]] = ('|', registers[args[1]][1], registers[args[2]])
        elif op == 'jr':
            return stores, registers[args[0]]
        elif op == 'j':
            return stores, ('symbol', args[0])
        else:
            raise AssertionError('the stage has %s, which this does not read' % op)
    raise AssertionError('the stage does not jump')


def check_watchdog_stage(case, device, expected):
    """A description's watchdog stage: one naked boot-stage routine that
    makes EXPECTED's stores and nothing else, reaches neither the stack
    nor RAM, and ends in compiler-owned reset (D653, D708)."""
    text = (DESCRIPTIONS / device / 'watchdogs.ldn').read_text()
    case.assertEqual(len(re.findall(r'^link\(boot_stage\) extern\(naked\) \w+: '
                                    r'\(\) -> none =$', text, re.M)), 1)
    body = re.search(r'assembler\.block\("""(.*?)"""\)', text, re.S).group(1)
    code = '\n'.join(line.split('#')[0] for line in body.splitlines())
    case.assertFalse(re.search(r'\b(sp|x2|fp|s0|gp|tp|ra|call|ret)\b', code), code)
    case.assertEqual(set(re.findall(r'\b(t\d|a\d|s\d+|x\d+)\b', code)), {'t0', 't1', 't2'})
    stores, target = stage_stores(text)
    case.assertEqual(target, ('symbol', '_landin_firmware_reset'))
    case.assertEqual(stores, expected)


class EspDescriptions(unittest.TestCase):
    """The two ESP descriptions' hand-written halves: their memory against
    the TRMs' maps and the ROM's reservations, and their watchdog stages
    against the generated addresses and the TRMs' keys (D707, D708)."""

    @staticmethod
    def described(device):
        text = (DESCRIPTIONS / device / 'memory.ldn').read_text()

        def number(expression):
            value = 1
            for factor in expression.split('*'):
                value *= int(factor.strip().replace('_', ''), 0)
            return value

        regions = {name: (number(origin), number(length), access)
                   for name, origin, length, access in re.findall(
                       r'^linker\.region\("(\w+)", ([^,]+), ([^,]+), "(\w+)"\)$',
                       text, re.MULTILINE)}
        places = dict(re.findall(r'^linker\.place\("(\w+)", "(\w+)"', text, re.M))
        return text, regions, places

    def test_the_c3_memory(self):
        text, regions, places = self.described('esp32c3')
        kib = 1024
        self.assertEqual(regions, {'IRAM': (0x40380000, 128 * kib, 'rx'),
                                   'DRAM': (0x3fca0000, 160 * kib, 'rw')})
        self.assertIn('compiler.boot("esp-app-image")\n', text)
        # esp_app_format.h's chip id 5; ESP-IDF's default revisions, v0.3
        # to v1.99; the ROM reads the image at flash offset 0.
        self.assertIn('compiler.esp_image(5, 3, 199, 0x0)\n', text)
        self.assertEqual(places, {'vectors': 'IRAM', 'text': 'IRAM', 'rodata': 'IRAM',
                                  'data': 'DRAM', 'bss': 'DRAM', 'stack': 'DRAM'})
        # TRM v1.4, 3.3.2, Table 3.3-1, pp. 93 and 94: SRAM1 is 384 KiB at
        # 0x4038_0000 on the instruction bus and 0x3FC8_0000 on the data bus.
        # Read as data-bus addresses, the two regions are inside it and
        # apart, and end below 0x3FCC_AE00, where ESP-IDF v6.1's
        # bootloader.memory.ld.in says the ROM's buffers, stack and data
        # begin.
        alias = 0x40380000 - 0x3fc80000
        iram, dram = regions['IRAM'], regions['DRAM']
        spans = sorted([(iram[0] - alias, iram[0] - alias + iram[1]),
                        (dram[0], dram[0] + dram[1])])
        self.assertLessEqual(spans[0][1], spans[1][0])
        self.assertGreaterEqual(spans[0][0], 0x3fc80000)
        self.assertLessEqual(spans[1][1], 0x3fccae00)

    def test_the_c5_memory(self):
        text, regions, places = self.described('esp32c5')
        # TRM v1.1, 6.3, Table 6.3-1, p. 239: the HP SRAM is 384 KiB from
        # 0x4080_0000, one address space; the ROM's begin at 0x4084_E5A0.
        self.assertEqual(regions, {'SRAM': (0x40800000, 312 * 1024, 'rwx')})
        self.assertLessEqual(0x40800000 + 312 * 1024, 0x4084e5a0)
        self.assertIn('compiler.boot("esp-app-image")\n', text)
        # Chip id 23; revisions v1.0 to v1.99; flash offset 0x2000.
        self.assertIn('compiler.esp_image(23, 100, 199, 0x2000)\n', text)
        self.assertEqual(set(places.values()), {'SRAM'})

    def test_the_watchdog_stages(self):
        def rows(name):
            policy = policies()[name]
            return {r['source']: r['address'] for r in json.loads(
                (HERE / policy['modules'] / policy['correspondence']).read_text())}

        # TRM v1.4, 12.2.2.3, p. 308, and v1.1, 16.2.2.3, p. 714: the
        # watchdogs' write key; v1.4, 12.3.2.2, p. 310, the C3's super
        # watchdog's own, and v1.1, 16.3.2.2, p. 715, the C5's, which is the
        # same key as its other watchdogs'.  Bit 22 of an MWDT's first
        # configuration word takes the configuration (Registers 11.10,
        # p. 298, and 15.10, p. 701).
        key, update = 0x50d83aa1, 1 << 22
        for device, rwdt, swd, swd_protect, swd_key, auto_feed in (
                ('esp32c3', 'RTC_CNTL.WDT', 'RTC_CNTL.SWD_CONF',
                 'RTC_CNTL.SWD_WPROTECT', 0x8f1d312a, 1 << 31),
                ('esp32c5', 'LP_WDT.', 'LP_WDT.SWD_CONFIG',
                 'LP_WDT.SWD_WPROTECT', 0x50d83aa1, 1 << 18)):
            with self.subTest(device=device):
                at = rows(device)
                expected = []
                for group in ('TIMG0', 'TIMG1'):
                    expected += [(at[group + '.WDTWPROTECT'], key),
                                 (at[group + '.WDTCONFIG0'], update),
                                 (at[group + '.WDTWPROTECT'], 0)]
                protect, config = at[rwdt + 'WPROTECT'], at[rwdt + 'CONFIG0']
                expected += [(protect, key), (config, 0), (protect, 0),
                             (at[swd_protect], swd_key),
                             (at[swd], ('|', at[swd], auto_feed)),
                             (at[swd_protect], 0)]
                check_watchdog_stage(self, device, expected)

    def test_the_recorded_facts(self):
        # environments/cortex-m/descriptions.json records each description
        # apart from the compiler, from the manuals; its regions, its
        # placements and its stage's stores are the descriptions' own.
        recorded = json.loads((ROOT / 'environments/cortex-m/descriptions.json')
                              .read_text())['devices']
        for device, identity in (('esp32c3', 'esp32-c3'), ('esp32c5', 'esp32-c5')):
            with self.subTest(device=device):
                want = recorded[identity]
                _, regions, places = self.described(device)
                self.assertEqual({r['name']: (r['origin'], r['length'], r['access'])
                                  for r in want['regions']}, regions)
                self.assertEqual(want['placed'], places)
                stores, _ = stage_stores(
                    (DESCRIPTIONS / device / 'watchdogs.ldn').read_text())
                answers = dict(want['reset_stage']['reads'])
                written = [(address, value if not isinstance(value, tuple)
                            else answers[value[1]] | value[2])
                           for address, value in stores]
                self.assertEqual(written, [(a[1], a[3]) for a in
                                           want['reset_stage']['accesses'] if a[0] == 'w'])


XTENSA_FAMILIES = {
    'DPORT': ('dport_reg.h', 'DPORT', None),
    'APB_CTRL': ('apb_ctrl_reg.h', 'APB_CTRL', None),
    'SYSTEM': ('system_reg.h', 'SYSTEM', None),
    'EXTMEM': ('extmem_reg.h', 'EXTMEM', None),
    'UART0': ('uart_reg.h', 'UART', 0),
    'GPIO': ('gpio_reg.h', 'GPIO', None),
    'IO_MUX': ('io_mux_reg.h', 'IO_MUX', None),
    'RTC_CNTL': ('rtc_cntl_reg.h', 'RTC_CNTL', None),
    'TIMG0': ('timer_group_reg.h', 'TIMG', 0),
    'TIMG1': ('timer_group_reg.h', 'TIMG', 1),
    'INTERRUPT_CORE0': ('interrupt_core0_reg.h', 'INTERRUPT_CORE0', None),
    'SYSTIMER': ('systimer_reg.h', 'SYSTIMER', None)}


def xtensa_header_names(chip, rows):
    """The reviewed spelling differences between the SVD and IDF headers."""
    names = {('GPIO.IN', 'DATA_NEXT'): 'GPIO_IN_DATA',
             ('GPIO.IN1', 'DATA_NEXT'): 'GPIO_IN1_DATA',
             ('UART0.CLKDIV', 'FRAG'): 'UART_CLKDIV_FRAG'}
    for row in rows:
        key = row['source']
        peripheral, register = key.split('.')
        if peripheral == 'IO_MUX':
            if chip == 'esp32':
                names[(key, None)] = 'PERIPHS_IO_MUX_' + {
                    'GPIO1': 'U0TXD_U', 'GPIO3': 'U0RXD_U',
                    'GPIO22': 'GPIO22_U'}[register]
            for field, spelled in IO_MUX_FIELDS.items():
                names[(key, field)] = spelled
        if peripheral == 'GPIO' and register.startswith('FUNC'):
            for field in row['fields']:
                spelled = {'INV_SEL': 'OUT_INV_SEL'}.get(field['name'], field['name'])
                names[(key, field['name'])] = 'GPIO_' + register.split('_OUT')[0] + '_' + spelled
        if peripheral == 'DPORT' and register.startswith('PERIP_'):
            for field in row['fields']:
                spelled = field['name'].replace('I2C0_EXT0', 'I2C_EXT0')
                names[(key, field['name'])] = 'DPORT_' + spelled
        if peripheral.startswith('TIMG') and register.startswith('T0'):
            for field in row['fields']:
                names[(key, field['name'])] = 'TIMG_T0_' + field['name']
    return names


def xtensa_stage(text, memory, calls=None, special=None, prepared=False, rom_effects=True):
    """Execute the stage's assembly against explicit MMIO and ROM words.

    Unknown instructions, unknown memory and nonterminating paths fail.
    ROM calls model only their contract; the pinned vendor ELF supplies
    the independent implementation and calling-convention oracle.
    """
    instructions = []
    labels = {}
    functions = re.finditer(
        r'link\(([^)]*)\) extern\(naked\) \w+:.*?assembler\.block\("""(.*?)"""\)',
        text, re.S)
    for function in functions:
        symbol = re.search(r'symbol: "([^"]+)"', function.group(1))
        if symbol:
            labels[symbol.group(1)] = len(instructions)
        for line in function.group(2).splitlines():
            line = line.split('#')[0].strip()
            if not line:
                continue
            if line.endswith(':'):
                labels[line[:-1]] = len(instructions)
            else:
                instructions.append(line)
    registers = {}
    stores = []
    calls = [] if calls is None else calls
    special = {} if special is None else special
    if prepared:
        # The compiler-owned entry prelude is the cold stage's ABI root.
        top = 0x3ffd0000 if prepared == 'esp32' else 0x3fcd0000
        registers['a1'] = top - 32
        memory[top - 44] = top
        special.update({'PS': 0x4002f, 'INTENABLE': 0, 'WINDOWBASE': 0,
                        'WINDOWSTART': 1,
                        'VECBASE': 0x40080000 if prepared == 'esp32' else 0x40378000})
    pc = 0
    for _ in range(4096):
        op, _, rest = instructions[pc].partition(' ')
        args = [a.strip() for a in rest.split(',')]
        pc += 1
        if op == 'movi':
            registers[args[0]] = int(args[1], 0) & 0xffffffff
        elif op == 'addi':
            registers[args[0]] = registers[args[1]] + int(args[2], 0)
        elif op in ('l32i', 's32i'):
            address = registers[args[1]] + int(args[2], 0)
            if op == 'l32i':
                registers[args[0]] = memory[address]
            else:
                value = registers[args[0]]
                memory[address] = value
                stores.append((address, value))
        elif op in ('and', 'or'):
            a, b = registers[args[1]], registers[args[2]]
            registers[args[0]] = a & b if op == 'and' else a | b
        elif op in ('bbsi', 'bbci'):
            taken = bool(registers[args[0]] & (1 << int(args[1], 0)))
            if taken == (op == 'bbsi'):
                pc = labels[args[2]]
        elif op in ('bne', 'bnez'):
            taken = (registers[args[0]] != registers[args[1]] if op == 'bne'
                     else registers[args[0]] != 0)
            if taken:
                pc = labels[args[-1]]
        elif op == 'callx8':
            # Model only the specified API effects; actual vendor bodies
            # and ABI are independently checked by the ROM ELF oracle.
            address = registers[args[0]]
            classic = address in (0x40009ab8, 0x40009a14)
            rtc, stall, top, vectors = ((0x3ff48000, 0xac, 0x3ffd0000, 0x40080000)
                                        if classic else
                                        (0x60008000, 0xbc, 0x3fcd0000, 0x40378000))
            assert memory[rtc] & 3 == 2
            assert memory[rtc + stall] & 0x03f00000 == 0x02100000
            assert special == {'PS': 0x4002f, 'INTENABLE': 0,
                               'WINDOWBASE': 0, 'WINDOWSTART': 1,
                               'VECBASE': vectors}
            assert registers['a1'] == top - 32
            assert memory[top - 44] == top
            if classic:
                assert all(memory[base + off] == 0
                           for base in (0x3ff5f000, 0x3ff60000)
                           for off in (0x48, 0x64))
                assert memory[rtc + 0x8c] == memory[rtc + 0xa4] == 0
                cpu = registers['a10']  # CALL8 outgoing a10 becomes callee a2.
                assert cpu in (0, 1)
                calls.append((address, cpu))
                if rom_effects and address == 0x40009ab8:
                    memory[0x3ff00040 + cpu * 0x18] &= ~8
            elif address not in (0x400016f8, 0x4000186c, 0x40001884):
                raise AssertionError('unexamined ROM call')
            else:
                calls.append(address)
            if rom_effects and address == 0x4000186c:
                memory[0x600c4060] &= ~1
            elif rom_effects and address == 0x40001884:
                memory[0x600c4000] &= ~1
            # Exercise the caller-clobbered register contract explicitly.
            for reg in range(2, 16):
                registers.pop('a' + str(reg), None)
        elif op in ('memw', 'isync'):
            pass
        elif op == 'j':
            if args[0] == '_landin_firmware_reset' or labels[args[0]] == pc - 1:
                return args[0], stores
            pc = labels[args[0]]
        else:
            raise AssertionError('unexamined stage instruction: ' + op)
    raise AssertionError('stage did not exit')


class XtensaDescriptions(unittest.TestCase):
    def test_memory_and_aliases(self):
        for chip, code, data, data_size, identity, maximum, offset in (
                ('esp32', 0x40080000, 0x3ffb0000, 128, 0, 399, '0x1000'),
                ('esp32s3', 0x40378000, 0x3fca8000, 160, 9, 99, '0x0')):
            with self.subTest(chip=chip):
                text, regions, places = EspDescriptions.described(chip)
                self.assertEqual(regions, {'IRAM': (code, 128 * 1024, 'rx'),
                                          'DRAM': (data, data_size * 1024, 'rw')})
                self.assertEqual(places, {'vectors': 'IRAM', 'text': 'IRAM',
                                          'rodata': 'DRAM', 'data': 'DRAM',
                                          'bss': 'DRAM', 'stack': 'DRAM'})
                self.assertIn('compiler.boot("esp-app-image")', text)
                self.assertIn('compiler.esp_image(%d, 0, %d, %s)' % (identity, maximum, offset), text)
                if chip == 'esp32s3':
                    # IDF's bootloader script fixes the I/D alias offset
                    # and reserves ROM shared buffers from 0x3fcd7e00.
                    self.assertEqual(code + 128 * 1024 - 0x6f0000, data)
                    self.assertLess(data + data_size * 1024, 0x3fcd7e00)
                else:
                    self.assertLess(data + data_size * 1024, 0x3ffdc200)

    def test_stack_free_stage_and_cache_refusals(self):
        for chip, rtc, stall, config, protect, t0, t1, cache, bit in (
                ('esp32', 0x3ff48000, 0xac, 0x8c, 0xa4, 0x3ff5f000, 0x3ff60000,
                 (0x3ff00040, 0x3ff00058), 3),
                ('esp32s3', 0x60008000, 0xbc, 0x98, 0xb0, 0x6001f000, 0x60020000,
                 (0x600c4000, 0x600c4060), 0)):
            text = (DESCRIPTIONS / chip / 'prepare.ldn').read_text()
            body = re.search(r'assembler\.block\("""(.*?)"""\)', text, re.S).group(1)
            instructions = '\n'.join(line.split('#')[0] for line in body.splitlines())
            self.assertNotRegex(instructions, r'\b(a0|a1|sp|entry|retw?)\b')
            expected = [(base + off, value) for base in (t0, t1)
                        for off, value in ((0x64, 0x50d83aa1), (0x48, 0), (0x64, 0))]
            expected += [(rtc + protect, 0x50d83aa1), (rtc + config, 0), (rtc + protect, 0)]
            if chip == 'esp32s3':
                expected += [(rtc + 0xb8, 0x8f1d312a), (rtc + 0xb4, 0xc0000000), (rtc + 0xb8, 0)]
            # Exercise preservation of unrelated control bits, rather
            # than accepting a stage that succeeds only from all-zero RAM.
            initial = {rtc: 0x1c00a009, rtc + stall: 0x45800000,
                       cache[0]: 0, cache[1]: 0,
                       rtc + (0x34 if chip == 'esp32' else 0x38): 2}
            expected += [(rtc, (initial[rtc] & ~3) | 2),
                         (rtc + stall, (initial[rtc + stall] & ~0x03f00000) | 0x02100000)]
            with self.subTest(chip=chip, state='cacheless'):
                calls, special = [], {}
                self.assertEqual(xtensa_stage(text, dict(initial), calls, special),
                                 ('_landin_firmware_reset', expected))
                self.assertEqual(calls, [])
                self.assertEqual(special, {})
            for address in cache:
                memory = dict(initial)
                memory[address] = 1 << bit
                with self.subTest(chip=chip, forbidden_cache=hex(address)):
                    self.assertEqual(xtensa_stage(text, memory), ('_landin_device_cache_refused', []))

    @staticmethod
    def classic_cold_memory(pro=8, app=8):
        contract = json.loads((HERE / 'esp32-rom.json').read_text())
        memory = {0x3ff48000: 0x1c00a009, 0x3ff480ac: 0x45800000,
                  0x3ff48034: 0x3301, 0x3ff00040: pro, 0x3ff00058: app}
        for region in contract['word_ranges']:
            address = int(region['address'], 0)
            for index, word in enumerate(region['words']):
                memory[address + 4 * index] = int(word, 0)
        for literal in contract['literal_words']:
            memory[int(literal['address'], 0)] = int(literal['word'], 0)
        return memory

    def test_classic_cold_rom_normalization(self):
        text = (DESCRIPTIONS / 'esp32/prepare.ldn').read_text()
        expected = [(0x40009ab8, 0), (0x40009ab8, 1),
                    (0x40009a14, 0), (0x40009a14, 1)]
        for pro, app in ((0x28, 0x30), (0x20, 0x38), (0x28, 0x38)):
            with self.subTest(pro=pro, app=app):
                memory = self.classic_cold_memory(pro, app)
                calls = []
                exit_at, stores = xtensa_stage(text, memory, calls, prepared='esp32')
                self.assertEqual(exit_at, '_landin_firmware_reset')
                self.assertEqual(calls, expected)
                self.assertEqual((memory[0x3ff00040], memory[0x3ff00058]),
                                 (pro & ~8, app & ~8))
                self.assertTrue(all(address >= 0x3ff00000 for address, _ in stores))
                self.assertTrue(all(address not in (0x3ff00040, 0x3ff00058)
                                    for address, _ in stores))
        with self.assertRaises(AssertionError):
            xtensa_stage(text, self.classic_cold_memory())  # No compiler ABI prelude.
        calls = []
        exit_at, stores = xtensa_stage(text, self.classic_cold_memory(), calls,
                                      prepared='esp32', rom_effects=False)
        self.assertEqual(exit_at, '_landin_device_cache_refused')
        self.assertEqual(calls, expected)
        self.assertTrue(stores)
        # A sticky POWERON cause is only a precondition of direct ROM entry.
        for cause in range(64):
            if cause == 1:
                continue
            memory = self.classic_cold_memory()
            memory[0x3ff48034] = 0x3300 | cause
            self.assertEqual(xtensa_stage(text, memory),
                             ('_landin_device_cache_refused', []))
        initial = self.classic_cold_memory()
        rom_words = [address for address in initial if 0x40000000 <= address < 0x40080000]
        self.assertEqual(len(rom_words), 55)
        for address in rom_words:
            with self.subTest(changed_rom_word=hex(address)):
                memory = dict(initial)
                memory[address] ^= 1
                self.assertEqual(xtensa_stage(text, memory),
                                 ('_landin_device_rom_refused', []))

    @staticmethod
    def cold_memory(dcache=1, icache=1):
        contract = json.loads((HERE / 'esp32s3-rom.json').read_text())
        memory = {0x60008000: 0x1c00a009, 0x600080bc: 0x45800000,
                  0x60008038: 1, 0x600c4000: dcache, 0x600c4060: icache,
                  int(contract['table_pointer'], 0): int(contract['table_address'], 0)}
        for offset, value in contract['callbacks'].items():
            memory[int(contract['table_address'], 0) + int(offset)] = int(value, 0)
        for function in contract['functions']:
            entry, body = int(function['entry'], 0), int(function['body'], 0)
            memory.update({entry - 4: body, entry: 0xa0ffff91, entry + 4: 9,
                           body: int(function['first_word'], 0)})
        for region in contract['word_ranges']:
            address = int(region['address'], 0)
            for index, word in enumerate(region['words']):
                memory[address + 4 * index] = int(word, 0)
        for literal in contract['literal_words']:
            memory[int(literal['address'], 0)] = int(literal['word'], 0)
        return memory

    def test_s3_cold_rom_normalization(self):
        text = (DESCRIPTIONS / 'esp32s3/prepare.ldn').read_text()
        for dcache, icache in ((1, 1), (1, 0), (0, 1)):
            with self.subTest(dcache=dcache, icache=icache):
                memory = self.cold_memory(dcache, icache)
                calls, special = [], {}
                exit_at, stores = xtensa_stage(text, memory, calls, special, prepared=True)
                self.assertEqual(exit_at, '_landin_firmware_reset')
                self.assertEqual(calls, ([0x400016f8] if dcache else [])
                                 + [0x4000186c, 0x40001884])
                self.assertEqual((memory[0x600c4000], memory[0x600c4060]), (0, 0))
                self.assertTrue(all(address >= 0x60000000 for address, _ in stores))
                self.assertTrue(all(address not in (0x600c4000, 0x600c4060)
                                    for address, value in stores))
        with self.assertRaises(AssertionError):
            xtensa_stage(text, self.cold_memory())  # missing compiler ABI prelude
        calls = []
        exit_at, stores = xtensa_stage(text, self.cold_memory(), calls,
                                      prepared=True, rom_effects=False)
        self.assertEqual(exit_at, '_landin_device_cache_refused')
        self.assertEqual(calls, [0x400016f8, 0x4000186c, 0x40001884])
        self.assertTrue(stores)  # failed postcondition parks after normalization
        # A sticky cold cause is only a precondition: the documented caller
        # must still be the direct ROM loader. Every other cause is refused.
        for cause in range(64):
            if cause == 1:
                continue
            memory = self.cold_memory()
            memory[0x60008038] = cause
            self.assertEqual(xtensa_stage(text, memory),
                             ('_landin_device_cache_refused', []))
        initial = self.cold_memory()
        rom_words = [address for address in initial
                     if address not in (0x60008000, 0x600080bc, 0x60008038,
                                        0x600c4000, 0x600c4060)]
        for address in rom_words:
            with self.subTest(changed_rom_word=hex(address)):
                memory = dict(initial)
                memory[address] ^= 1
                self.assertEqual(xtensa_stage(text, memory),
                                 ('_landin_device_rom_refused', []))

    def test_board_uart_drain_before_reconfiguration(self):
        # Evaluate the source condition with independent register snapshots:
        # a FIFO-empty UART can still be transmitting its final byte.
        def evaluate(node, images):
            if isinstance(node, ast.BoolOp) and isinstance(node.op, ast.Or):
                return any(evaluate(value, images) for value in node.values)
            if isinstance(node, ast.Compare) and len(node.ops) == 1 and isinstance(node.ops[0], ast.NotEq):
                return evaluate(node.left, images) != evaluate(node.comparators[0], images)
            if isinstance(node, ast.Attribute) and isinstance(node.value, ast.Name):
                return images[node.value.id][node.attr]
            if isinstance(node, ast.Constant) and node.value == 0:
                return 0
            raise AssertionError('unexamined UART drain condition')

        for chip in ('esp32', 'esp32s3'):
            text = (ROOT / 'compiler/tests/board' / chip / 'bringup/bringup.ldn').read_text()
            body = text.split('public clocks_and_uart: () -> none =', 1)[1].split('end clocks_and_uart', 1)[0]
            before, after = body.split('end while', 1)
            self.assertNotIn('_write(', before)
            self.assertIn('_write(', after)
            self.assertIn('tx = uart0.status_decode(uart0.status_read(uart0.base))', before)
            if chip == 'esp32s3':
                self.assertIn('state = uart0.fsm_status_decode(uart0.fsm_status_read(uart0.base))', before)
            condition = ast.parse(re.search(r'while (.*?) do', before).group(1).replace('<>', '!='), mode='eval').body
            rows = {row['source']: row for row in XtensaOracles.rows(chip)}

            def image(register, raw):
                return {'f_' + field['name'].lower(): (raw & field['mask']) >> field['low']
                        for field in rows['UART0.' + register]['fields']}

            for fifo, transmitter, pending in ((2, 0, True), (0, 3, True),
                                               (1, 2, True), (0, 0, False)):
                with self.subTest(chip=chip, fifo=fifo, transmitter=transmitter):
                    # Unrelated RX count and pin status must not delay TX.
                    status = (fifo << 16) | 0x80000001
                    if chip == 'esp32':
                        status |= transmitter << 24
                    images = {'tx': image('STATUS', status)}
                    if chip == 'esp32s3':
                        images['state'] = image('FSM_STATUS', (transmitter << 4) | 5)
                    self.assertEqual(evaluate(condition, images), pending)

    def test_idf_uart_address_ternary(self):
        header = IdfHeader('#define BASE 0x60000000\n'
                           '#define REG_UART_BASE(i) (BASE + (i) * 0x10000 + ((i) > 1 ? 0xe000 : 0))\n')
        self.assertEqual([header.value('REG_UART_BASE(%d)' % i) for i in (0, 1, 2)],
                         [0x60000000, 0x60010000, 0x6002e000])


class XtensaOracles(unittest.TestCase):
    @staticmethod
    def rows(chip):
        return json.loads((GENERATED / chip / 'correspondence.json').read_text())

    @requires_refine
    def test_vendor_headers(self):
        for chip in ('esp32', 'esp32s3'):
            with self.subTest(chip=chip):
                rows = self.rows(chip)
                # The old DPORT header documents whole-register fields
                # above its individual clock/reset masks. The S3 GPIO
                # header's IN1 comment misnames its DATA field IN_DATA;
                # its actual macros correctly say IN1_DATA and match the
                # SVD's 22-bit field. Neither discrepancy adds an accessor.
                unshared = ({('DPORT.PERIP_CLK_EN', 'DPORT_PERIP_CLK_EN', 'header'),
                             ('DPORT.PERIP_RST_EN', 'DPORT_PERIP_RST', 'header'),
                             ('UART0.MEM_RX_STATUS', 'UART_MEM_RX_STATUS', 'header')}
                            if chip == 'esp32' else
                            {('GPIO.IN1', 'GPIO_IN_DATA', 'header')})
                compare_with_esp_idf(self, rows, chip, XTENSA_FAMILIES,
                                    xtensa_header_names(chip, rows), unshared, set())

    @requires_refine
    def test_memory_scripts_and_stall_contract(self):
        for chip, prefix, maximum in (('esp32', 'ESP32', 399),
                                      ('esp32s3', 'ESP32S3', 99)):
            with self.subTest(chip=chip):
                memory = fetch_inputs.fetch(chip + '/memory.ld.in').read_text()
                boot = fetch_inputs.fetch(chip + '/bootloader.memory.ld.in').read_text()
                config = fetch_inputs.fetch(chip + '/Kconfig.hw_support').read_text()
                stall = fetch_inputs.fetch(chip + '/cpu_utility_ll.h').read_text()
                self.assertRegex(config, r'config ' + prefix
                                 + r'_REV_MAX_FULL\s+int\s+default ' + str(maximum))
                self.assertIn('0x86', stall)
                self.assertRegex(stall, r'2\s*<<\s*rtc_cntl_c0_s')
                self.assertRegex(stall, r'0x21\s*<<\s*rtc_cntl_c1_s')
                if chip == 'esp32s3':
                    self.assertRegex(memory, r'SRAM_DIRAM_I_START\s+0x40378000')
                    self.assertRegex(memory, r'SRAM_DRAM_START\s+0x3FC88000')
                    self.assertIn('iram_dram_offset = 0x6f0000;', boot)
                    self.assertIn('0x3fcd7e00 - 0x3fce9704: Shared buffers', boot)
                else:
                    self.assertIn('org = 0x40080000, len = 0x20000', memory)
                    self.assertIn('org = 0x3FFB0000 + CONFIG_BTDM_RESERVE_DRAM', memory)
                    self.assertIn('#define DRAM0_0_SEG_LEN 0x2c200', memory)

    def test_selected_access_contract(self):
        for chip, count in (('esp32', 51), ('esp32s3', 52)):
            with self.subTest(chip=chip):
                rows = {row['source']: row for row in self.rows(chip)}
                self.assertEqual(len(rows), count)
                self.assertEqual(rows['UART0.FIFO']['policy'],
                                 {'read': 'modify', 'write': 'normal', 'reserved': 'zero', 'write_mask': '0xff'})
                self.assertEqual(rows['UART0.INT_CLR']['policy']['read'], 'refused')
                self.assertEqual(rows['UART0.INT_CLR']['policy']['write'], 'one_clears')
                self.assertEqual(rows['UART0.STATUS']['policy']['write'], 'refused')
                self.assertEqual(rows['RTC_CNTL.RESET_STATE']['known_reset_mask'], 0)
                self.assertEqual(rows['RTC_CNTL.OPTIONS0']['policy']['write_mask'],
                                 '0x7fffffcf' if chip == 'esp32' else '0x7f83ffcf')
                for key in (('DPORT.PRO_CACHE_CTRL', 'DPORT.APP_CACHE_CTRL') if chip == 'esp32'
                            else ('EXTMEM.ICACHE_CTRL', 'EXTMEM.DCACHE_CTRL')):
                    self.assertEqual(rows[key]['policy']['write'], 'refused')

    @requires_refine
    def test_uart_idle_contract(self):
        for chip in ('esp32', 'esp32s3'):
            with self.subTest(chip=chip):
                header = fetch_inputs.fetch(chip + '/uart_ll.h').read_text()
                idle = header.split('bool uart_ll_is_tx_idle', 1)[1].split('}', 1)[0]
                self.assertRegex(idle, r'(?s)txfifo_cnt.*== 0.*&&.*st_utx_out == 0')
                rows = {row['source']: row for row in self.rows(chip)}
                register = rows['UART0.STATUS' if chip == 'esp32' else 'UART0.FSM_STATUS']
                self.assertEqual(register['offset'], 0x1c if chip == 'esp32' else 0x6c)
                field = next(field for field in register['fields'] if field['name'] == 'ST_UTX_OUT')
                self.assertEqual((field['low'], field['high']), (24, 27) if chip == 'esp32' else (4, 7))
                self.assertEqual(register['policy']['write'], 'refused')
                self.assertEqual(register['known_reset_mask'], 0)

    @requires_refine
    def test_classic_cold_rom_abi(self):
        contract = json.loads((HERE / 'esp32-rom.json').read_text())
        with tarfile.open(fetch_inputs.fetch(contract['elf_archive'])) as archive:
            elf = archive.extractfile(contract['elf_member']).read()
        self.assertEqual(digest(elf), contract['elf_sha256'])
        self.assertEqual(contract['elf_member'], 'esp32_rev300_rom.elf')
        self.assertEqual(elf[:7], b'\x7fELF\x01\x01\x01')
        phoff = struct.unpack_from('<I', elf, 28)[0]
        phsize, phnum = struct.unpack_from('<HH', elf, 42)
        segments = [struct.unpack_from('<8I', elf, phoff + index * phsize)
                    for index in range(phnum)]

        def read(address, size):
            matches = [elf[offset + address - start:offset + address - start + size]
                       for kind, offset, start, _, length, _, _, _ in segments
                       if kind == 1 and start <= address and address + size <= start + length]
            self.assertEqual(len(matches), 1, hex(address))
            return matches[0]

        symbols = fetch_inputs.fetch('esp32/rom.ld').read_text()
        header = fetch_inputs.fetch('esp32/rom-cache.h').read_text()
        self.assertEqual({function['name'] for function in contract['functions']},
                         {'Cache_Read_Disable', 'Cache_Flush'})
        ranges = {int(region['address'], 0): region for region in contract['word_ranges']}
        for function in contract['functions']:
            entry = int(function['entry'], 0)
            self.assertIn(function['name'] + '_rom = ' + function['entry'], symbols)
            self.assertIn(function['name'] + '(int cpu_no)', header)
            implementation = read(entry, function['size'])
            self.assertEqual(digest(implementation), function['sha256'])
            self.assertEqual(implementation[:3], bytes.fromhex('364100'))  # ENTRY32
            self.assertEqual(implementation[-2:], bytes.fromhex('1df0'))  # RETW.N
            self.assertTrue(function['leaf'])  # Reviewed complete bodies call no further code.
            self.assertEqual(function['frame_bytes'], 32)
            words = ranges[entry]['words']
            self.assertEqual(len(words), (function['size'] + 3) // 4)
            expected = b''.join(struct.pack('<I', int(word, 0)) for word in words)
            self.assertEqual(read(entry, len(expected)), expected)
        self.assertEqual({int(word['address'], 0) for word in contract['literal_words']},
                         {0x40009944, 0x40009948, 0x4000994c, 0x40009ab4})
        for literal in contract['literal_words']:
            self.assertEqual(read(int(literal['address'], 0), 4),
                             struct.pack('<I', int(literal['word'], 0)))
        self.assertEqual(contract['call_order'],
                         [{'name': name, 'cpu': cpu}
                          for name in ('Cache_Read_Disable', 'Cache_Flush') for cpu in (0, 1)])

    @requires_refine
    def test_s3_cold_rom_abi(self):
        contract = json.loads((HERE / 'esp32s3-rom.json').read_text())
        with tarfile.open(fetch_inputs.fetch(contract['elf_archive'])) as archive:
            elf = archive.extractfile(contract['elf_member']).read()
        self.assertEqual(elf[:7], b'\x7fELF\x01\x01\x01')
        phoff = struct.unpack_from('<I', elf, 28)[0]
        phsize, phnum = struct.unpack_from('<HH', elf, 42)
        segments = [struct.unpack_from('<8I', elf, phoff + index * phsize)
                    for index in range(phnum)]

        def read(address, size):
            matches = [elf[offset + address - start:offset + address - start + size]
                       for kind, offset, start, _, length, _, _, _ in segments
                       if kind == 1 and start <= address and address + size <= start + length]
            self.assertEqual(len(matches), 1, hex(address))
            return matches[0]

        symbols = fetch_inputs.fetch('esp32s3/rom.ld').read_text()
        header = fetch_inputs.fetch('esp32s3/rom-cache.h').read_text()
        self.assertIn('rom_cache_internal_table_ptr = 0x3fceffc4', symbols)
        for function in contract['functions']:
            entry, body = int(function['entry'], 0), int(function['body'], 0)
            self.assertIn(function['name'] + ' = ' + function['entry'], symbols)
            self.assertIn(function['name'] + '(void)', header)
            self.assertEqual(read(entry - 4, 12), struct.pack('<I', body)
                             + bytes.fromhex('91ffffa009000000'))
            implementation = read(body, function['size'])
            self.assertEqual(digest(implementation), function['sha256'])
            self.assertEqual(implementation[:3], bytes.fromhex('364100'))  # ENTRY32
            self.assertEqual(implementation[-2:], bytes.fromhex('1df0'))  # RETW.N
        for region in contract['word_ranges']:
            expected = b''.join(struct.pack('<I', int(word, 0)) for word in region['words'])
            self.assertEqual(read(int(region['address'], 0), len(expected)), expected)
        self.assertEqual(len(contract['literal_words']), 16)
        for literal in contract['literal_words']:
            self.assertEqual(read(int(literal['address'], 0), 4),
                             struct.pack('<I', int(literal['word'], 0)))
        for callback in contract['callback_bodies']:
            implementation = read(int(callback['address'], 0), callback['size'])
            self.assertEqual(digest(implementation), callback['sha256'])
            self.assertEqual(implementation[:3], bytes.fromhex('364100'))
            self.assertEqual(implementation[-2:], bytes.fromhex('1df0'))
        for offset, value in contract['callbacks'].items():
            self.assertEqual(read(int(contract['table_address'], 0) + int(offset), 4),
                             struct.pack('<I', int(value, 0)))

    @requires_refine
    def test_interrupt_sources(self):
        renames = {'WIFI_NMI': 'WIFI_MAC_NMI', 'MCPWM0': 'PWM0',
                   'MCPWM1': 'PWM1', 'TWAI0': 'TWAI'}
        for chip in ('esp32', 'esp32s3'):
            with self.subTest(chip=chip):
                expected = dict(sources_of(chip))
                aliases = dict(renames)
                if chip == 'esp32s3':
                    aliases.update({'GPIO_INTR_2': 'GPIO_INTR_SOURCE2',
                                    'GPIO_NMI_2': 'GPIO_NMI_SOURCE2',
                                    'USB_DEVICE': 'USB_SERIAL_JTAG'})
                for svd, header in aliases.items():
                    expected[svd] = expected.pop(header)
                self.assertEqual(generated_sources(policies()[chip]), expected)


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
