#!/usr/bin/env python3
"""Device descriptions select their profiles: link-only Cortex-M controls.

Each device of descriptions.json is selected by its identity, RP2040 and
the STM32H753 by importing devices/descriptions/rp2040 and
devices/descriptions/stm32h753 and the constrained reference by importing
none (D543), and every fact the linked image and its build report
carry is compared with the expectation recorded there, apart from the
compiler and the description, so a wrong or absent fact fails.  The slot-21
controls (D544), the region placement (D547) and the developer linker
script's contract (D546), each clause broken once, are here too.

Nothing here runs an image: RP2040 and the STM32H753 are chips, and
emulators cover cores only, so their evidence is compile-and-link.
"""
import argparse
import json
from pathlib import Path
import struct
import sys

from run import CommandFailed, Run, require
from setup import DEFAULT, installed_tools, inventory, sha, supported_host

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
EXPECTED = json.loads((HERE / 'descriptions.json').read_text())['devices']

PROGRAMS = {
    'rp2040': ('import descriptions/rp2040\n'
               'link(vector: 21) extern(interrupt) usb: () -> none = end usb\n'
               'link(region: "SCRATCH_X") mut scratch: u32 = 7\n'
               'mut counted: u32 = 1\n'
               'start: () -> none = counted += scratch end start\n'),
    'stm32h753': ('import descriptions/stm32h753\n'
                  'link(vector: 55) extern(interrupt) usart3: () -> none = end usart3\n'
                  'link(region: "DTCM") mut fast: u32 = 7\n'
                  'mut counted: u32 = 1\n'
                  'start: () -> none = counted += fast end start\n'),
    'constrained-reference': (
        'link(vector: 20) extern(interrupt) irq4: () -> none = end irq4\n'
        'mut counted: u32 = 1\n'
        'start: () -> none = counted += 1 end start\n'),
}


class Image:
    """The loadable bytes and symbols of a 32-bit little-endian Arm ELF."""

    def __init__(self, path):
        data = path.read_bytes()
        require(data[:6] == b'\x7fELF\x01\x01', 'not an ELF32 LE image: %s' % path)
        self.data = data
        phoff, shoff = struct.unpack_from('<II', data, 28)
        phnum = struct.unpack_from('<H', data, 44)[0]
        shentsize, shnum = struct.unpack_from('<HH', data, 46)
        self.segments = []
        for index in range(phnum):
            kind, offset, _, paddr, filesz, _ = struct.unpack_from('<IIIIII', data, phoff + 32 * index)
            if kind == 1:
                self.segments.append((paddr, offset, filesz))
        self.symbols = {}
        sections = [struct.unpack_from('<IIIIIIIIII', data, shoff + shentsize * i)
                    for i in range(shnum)]
        for header in sections:
            if header[1] == 2:
                strings = sections[header[6]][4]
                for at in range(header[4], header[4] + header[5], 16):
                    name, value = struct.unpack_from('<II', data, at)
                    end = data.index(b'\0', strings + name)
                    self.symbols.setdefault(data[strings + name:end].decode(), value)

    def read(self, address, size):
        for paddr, offset, filesz in self.segments:
            if paddr <= address and address + size <= paddr + filesz:
                return self.data[offset + address - paddr:offset + address - paddr + size]
        raise RuntimeError('no loaded bytes at %#x' % address)

    def word(self, address):
        return struct.unpack('<I', self.read(address, 4))[0]


def compile_firmware(run, refine, program, extra=(), name='core.elf', check=True):
    (run.out / 'app').mkdir(exist_ok=True)
    (run.out / 'app/main.ldn').write_text(program)
    argv = [refine, '--root=' + str(ROOT / 'devices'), '--target=cortex-m0',
            '--firmware-entry=start', '--emit=exe',
            '--toolchain=' + str(run.arm / 'arm-eabi-gcc'),
            '--build-report=' + name + '.json', *extra, 'app', '-o', name]
    if check:
        run.command('compile-' + name, argv, timeout=60)
        return Image(run.out / name)
    try:
        run.command('compile-' + name, argv, timeout=60)
    except CommandFailed as failed:
        return failed.log.read_text()
    raise RuntimeError(name + ' was not refused')


def select(run, refine, device):
    """D543/D544/D545: one device by its identity, every fact compared."""
    want = EXPECTED[device]
    image = compile_firmware(run, refine, PROGRAMS[device],
                             ['--level=' + want['level']] if 'level' in want else ())
    report = json.loads((run.out / 'core.elf.json').read_text())['firmware']
    for key in ('core', 'boot', 'regions', 'placed', 'vector_address',
                'vector_words', 'stack_reserved'):
        require(report[key] == want[key], '%s: the build report says %s %r, and %r is'
                ' recorded' % (device, key, report[key], want[key]))
    require(report['device'] == device, 'the build report names device %r' % report['device'])
    vectors = want['vector_address']
    require(image.symbols['_landin_firmware_vectors'] == vectors,
            '%s: the vector table is at %#x' % (device, image.symbols['_landin_firmware_vectors']))
    require(image.symbols['_landin_firmware_stack_top'] == want['stack_top'],
            '%s: the stack top is %#x' % (device, image.symbols['_landin_firmware_stack_top']))
    require(image.word(vectors) == want['stack_top'], device + ': word 0 is not the stack top')
    require(image.word(vectors + 4) == image.symbols['_landin_firmware_reset'] | 1,
            device + ': word 1 is not reset')
    words = [image.word(vectors + 4 * slot) for slot in range(want['vector_words'])]
    for slot in want['reserved_slots']:
        require(words[slot] == 0, '%s: reserved slot %d holds %#x' % (device, slot, words[slot]))
    handler = want.get('handler_symbol', 'usb' if device == 'rp2040' else 'irq4')
    require(words[want['handler_slot']] == image.symbols[handler] | 1,
            '%s: slot %d is not its handler' % (device, want['handler_slot']))
    if 'boot2_address' in want:
        require(image.symbols['_landin_firmware_boot2'] == want['boot2_address'],
                device + ': the second stage is not at the start of flash')
        require(image.read(want['boot2_address'], want['boot2_bytes'])
                == bytes(want['boot2_bytes']), device + ': the second-stage slot is not zero')
    else:
        require('_landin_firmware_boot2' not in image.symbols, device + ' has a second stage')
    if device == 'rp2040':
        scratch = next(r for r in want['regions'] if r['name'] == 'SCRATCH_X')
        require(scratch['origin'] <= image.symbols.get('scratch', -1)
                < scratch['origin'] + scratch['length'],
                'the datum placed in SCRATCH_X is not in it')
    elif 'placed_datum' in want:
        datum = want['placed_datum']
        region = next(r for r in want['regions'] if r['name'] == datum['region'])
        require(region['origin'] <= image.symbols.get(datum['symbol'], -1)
                < region['origin'] + region['length'],
                '%s: the datum placed in %s is not in it' % (device, datum['region']))
    else:
        refused = compile_firmware(run, refine, PROGRAMS[device].replace(
            'vector: 20', 'vector: %d' % want['refused_slot']), name='refused.elf', check=False)
        require('error[L0347]' in refused and 'reserved in constrained-reference' in refused,
                'the reference does not refuse slot %d' % want['refused_slot'])
    return image


def contract(run, refine):
    """D546: a copy of the derived script links; each broken clause is named."""
    compile_firmware(run, refine, PROGRAMS['rp2040'], name='derived.elf')
    derived = (run.out / 'derived.elf.ld').read_text()
    (run.out / 'copy.ld').write_text(derived)
    compile_firmware(run, refine, PROGRAMS['rp2040'], ['--linker-script=copy.ld'],
                     name='copy.elf')
    broken = {
        1: [('ORIGIN(FLASH) + 256 :', 'ORIGIN(FLASH) + 512 :'),
            ('ASSERT(ADDR(.isr_vector) == 268435712, "vectors must start at 0x10000100")\n', '')],
        2: [('_landin_firmware_stack_bottom = _landin_firmware_stack_top - 4096;\n', '')],
        3: [('_landin_firmware_stack_top - 4096', '_landin_firmware_stack_top - 2048')],
        4: [('} > RAM AT> FLASH', '} > RAM AT> RAM'),
            ('ASSERT(LOADADDR(', 'ASSERT(1 || LOADADDR(')],
    }
    for clause, edits in broken.items():
        text = derived
        for old, new in edits:
            require(old in text, 'the derived script lacks %r' % old)
            text = text.replace(old, new)
        (run.out / ('clause%d.ld' % clause)).write_text(text)
        said = compile_firmware(run, refine, PROGRAMS['rp2040'],
                                ['--linker-script=clause%d.ld' % clause],
                                name='clause%d.elf' % clause, check=False)
        require('error[L0519]' in said and 'clause %d,' % clause in said,
                'a script breaking clause %d is not refused naming it' % clause)
        require(not (run.out / ('clause%d.elf' % clause)).exists(),
                'a refused image is left behind for clause %d' % clause)
    said = compile_firmware(run, refine, 'import descriptions/rp2040\n'
                            'link(region: "NOWHERE") table: u32 = 1\n'
                            'start: () -> none = end start\n',
                            name='nowhere.elf', check=False)
    require('error[L0517]' in said and 'rp2040 has no region named NOWHERE' in said,
            'an unknown region is not refused')


def larger_than_the_reference(run, refine):
    """D537/D543: RP2040's budget is its own, so an image the reference's
    16 KiB RAM cannot hold links for it, inside its RAM region."""
    body = ('mut table: [100000]u8 = zeroed\n'
            'mut out: u8 = 0\n'
            'start: () -> none =\n    table[5] = 3\n    out = table[99999]\nend start\n')
    image = compile_firmware(run, refine, 'import descriptions/rp2040\n' + body, name='large.elf')
    report = json.loads((run.out / 'large.elf.json').read_text())['firmware']
    ram = next(r for r in EXPECTED['rp2040']['regions'] if r['name'] == 'RAM')
    require(report['static_ram_used'] > 100000 and report['static_ram_limit'] == ram['length'],
            'RP2040 does not hold a 100,000-byte image in its RAM: %r' % report)
    require(ram['origin'] <= image.symbols.get('_landin_firmware_bss_end', 0)
            <= ram['origin'] + ram['length'], 'the image is not in RP2040\'s RAM')
    said = compile_firmware(run, refine, body, name='reference-large.elf', check=False)
    require("region `RAM' overflowed" in said, 'the reference holds a 100,000-byte image')


def execute_suite(parent, refine):
    root = parent.out / 'descriptions'
    root.mkdir()
    refine = refine.resolve(strict=True)
    compiler_hash = sha(refine)
    controls = []
    for device in EXPECTED:
        out = root / device
        out.mkdir()
        select(Run(out, parent.tools), refine, device)
        controls.append({'device': device, 'status': 'passed'})
        print('description: ' + device + ' selected and compared', flush=True)
    out = root / 'contract'
    out.mkdir()
    contract(Run(out, parent.tools), refine)
    controls.append({'contract': 'four clauses and an unknown region', 'status': 'passed'})
    out = root / 'larger-than-the-reference'
    out.mkdir()
    larger_than_the_reference(Run(out, parent.tools), refine)
    controls.append({'image': 'RP2040 holds what the reference cannot', 'status': 'passed'})
    print('description: linker script contract held', flush=True)
    require(sha(refine) == compiler_hash, 'compiler changed')
    record = {'status': 'passed', 'compiler_sha256': compiler_hash, 'controls': controls,
              'scope': 'compile and link; no image is executed'}
    (root / 'result.json').write_text(json.dumps(record, indent=2) + '\n')
    return record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--refine', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--tools', type=Path, default=DEFAULT)
    args = parser.parse_args()
    supported_host(args.output)
    args.tools = installed_tools(args.tools)
    before = inventory(args.tools)
    args.output.mkdir(parents=True, exist_ok=False)
    record = {'status': 'failed', 'scope': 'development; not acceptance'}
    try:
        record['descriptions'] = execute_suite(
            Run(args.output.resolve(), args.tools.resolve()), args.refine)
        require(inventory(args.tools) == before, 'embedded tool drift')
        record['status'] = 'passed'
    finally:
        (args.output / 'result.json').write_text(json.dumps(record, indent=2) + '\n')
    print('descriptions ' + record['status'])
    return 0 if record['status'] == 'passed' else 1


if __name__ == '__main__':
    sys.exit(main())
