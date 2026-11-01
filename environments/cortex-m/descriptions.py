#!/usr/bin/env python3
"""Device descriptions select their profiles: link-only Cortex-M controls.

Each device of descriptions.json is selected by its identity, RP2040,
RP2350 and the STM32H753 by importing devices/descriptions/rp2040,
devices/descriptions/rp2350 and devices/descriptions/stm32h753 and the
constrained reference by importing none (D543), and every fact the linked
image and its build report
carry is compared with the expectation recorded there, apart from the
compiler and the description, so a wrong or absent fact fails.  The slot-21
controls (D544), the region placement (D547) and the developer linker
script's contract (D546), each clause broken once, are here too.

RP2040's second stage (D587, D588) is held to pico-sdk's own: the linked
`.boot2`'s CRC is recomputed here, no relocation may reach it, and
devices/thumb.py follows it from its first instruction in the copy the boot
ROM makes, recording the device stores it makes and the stack pointer and
branch it ends with, which must be what pico-sdk's boot2_generic_03h.S and
its exit_from_boot2.S do, read from the fetched files and their headers'
macros rather than from the port.  An oversize stage and one with a
relocation are each refused naming the problem.

RP2350's image block (D637, D638) is held to pico-sdk's own: the linked
block's address, directly after the vector table and inside the first
4 KiB of flash, and its bytes, which must be those the pinned GCC assembles
from the fetched embedded_start_block.inc.S with its end block off; no
relocation is in it, the build report gives it, and a developer's script
that moves it past 4 KiB or changes its words is refused naming clause 1.

Nothing here runs an image on a chip: RP2040 and the STM32H753 are chips,
and emulators cover cores only, so their evidence is compile-and-link and a
reading of the linked instructions.
"""
import argparse
import ast
import binascii
import json
import operator
from pathlib import Path
import re
import shutil
import struct
import sys

from run import CommandFailed, Run, require
from setup import DEFAULT, installed_tools, inventory, sha, supported_host

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(ROOT / 'devices'))
sys.path.insert(0, str(ROOT / 'scripts'))
import fetch_inputs  # noqa: E402
import thumb  # noqa: E402
EXPECTED = json.loads((HERE / 'descriptions.json').read_text())['devices']

PROGRAMS = {
    'rp2040': ('import descriptions/rp2040\n'
               'link(vector: 21) extern(interrupt) usb: () -> none = end usb\n'
               'link(region: "SCRATCH_X") mut scratch: u32 = 7\n'
               'mut counted: u32 = 1\n'
               'start: () -> none = counted += scratch end start\n'),
    'rp2350': ('import descriptions/rp2350\n'
               'link(vector: 56) extern(interrupt) cti: () -> none = end cti\n'
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


def compile_firmware(run, refine, program, extra=(), name='core.elf', check=True,
                     devices=ROOT / 'devices'):
    (run.out / 'app').mkdir(exist_ok=True)
    (run.out / 'app/main.ldn').write_text(program)
    argv = [refine, '--root=' + str(devices), '--target=cortex-m0',
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
    for key in ('core', 'float_unit', 'boot', 'regions', 'placed', 'vector_address',
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
    if 'boot2' in want:
        boot_stage(run, image, report, want)
    else:
        require('_landin_firmware_boot2' not in image.symbols, device + ' has a second stage')
    if 'image_block' in want:
        image_block(run, image, report, want)
    else:
        require('_landin_firmware_image_block' not in image.symbols,
                device + ' has an image block')
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


def crc32_mpeg2(data):
    """The RP2040 boot ROM's CRC-32 as pico-sdk 2.2.0's
    boot_stage2/pad_checksum computes it when its CMakeLists.txt calls it
    with `-s 0xffffffff`: zlib's reflected CRC-32 over bit-reversed bytes,
    reversed, which is polynomial 0x04c11db7, initial value all ones,
    nothing reflected and no final exclusive or."""
    seed = 0xffffffff

    def reverse(value, width):
        return int(format(value, '0%db' % width)[::-1], 2)
    return reverse((binascii.crc32(bytes(reverse(b, 8) for b in data), seed ^ 0xffffffff)
                    ^ 0xffffffff) & 0xffffffff, 32)


class Elf:
    """The sections, symbols and relocations of a 32-bit little-endian ELF."""

    def __init__(self, data):
        require(data[:6] == b'\x7fELF\x01\x01', 'not an ELF32 LE file')
        shoff = struct.unpack_from('<I', data, 32)[0]
        shentsize, shnum, shstrndx = struct.unpack_from('<HHH', data, 46)
        self.data = data
        self.sections = [struct.unpack_from('<IIIIIIIIII', data, shoff + shentsize * i)
                         for i in range(shnum)]
        names = self.sections[shstrndx][4]
        self.names = [self.text(names + header[0]) for header in self.sections]

    def text(self, at):
        return self.data[at:self.data.index(b'\0', at)].decode()

    def index(self, name):
        return self.names.index(name)

    def symbols(self, table):
        header = self.sections[table]
        strings = self.sections[header[6]][4]
        for at in range(header[4], header[4] + header[5], 16):
            name, value, size, info, _, shndx = struct.unpack_from('<IIIBBH', self.data, at)
            yield self.text(strings + name) if name else '', value, size, info, shndx

    def reaching(self, target, into_only=False):
        """Every relocation in section TARGET, or, unless INTO_ONLY, in an
        allocated section against a symbol defined in TARGET: (section,
        offset, symbol).  A linked image gives a symbol its script defines
        whatever section is beside it, so only an object says which
        symbols are the stage's."""
        found = []
        for header, name in zip(self.sections, self.names):
            if header[1] not in (4, 9):
                continue
            symbols = list(self.symbols(header[6]))
            into = header[7]
            size = 8 if header[1] == 9 else 12
            for at in range(header[4], header[4] + header[5], size):
                offset, info = struct.unpack_from('<II', self.data, at)
                symbol = symbols[info >> 8]
                if into == target or (not into_only and self.sections[into][2] & 2
                                      and info >> 8 and symbol[4] == target):
                    found.append((self.names[into], offset, symbol[0] or name))
        return found


def defines(*texts):
    """The C preprocessor's object-like #defines of TEXTS, continuation
    lines joined and comments removed, `_u(x)` read as x."""
    found = {}
    for text in texts:
        text = re.sub(r'/\*.*?\*/', ' ', text.replace('\\\n', ' '), flags=re.S)
        for line in text.splitlines():
            line = line.split('//')[0]
            match = re.match(r'\s*#define\s+(\w+)\s+(.+)', line)
            if match:
                found.setdefault(match.group(1), match.group(2).strip())
    return found


OPERATORS = {ast.BitOr: operator.or_, ast.LShift: operator.lshift, ast.Add: operator.add,
             ast.Sub: operator.sub, ast.BitAnd: operator.and_, ast.RShift: operator.rshift}


def evaluate(expression, macros, depth=0):
    """A C integer constant expression of MACROS' names, with nothing but
    numbers, parentheses, names and | << >> & + -."""
    require(depth < 20, 'the macros of %r do not end' % expression)
    expression = re.sub(r'_u\(([^()]*)\)', r'(\1)', expression)

    def value(node):
        if isinstance(node, ast.Expression):
            return value(node.body)
        if isinstance(node, ast.Constant) and isinstance(node.value, int):
            return node.value
        if isinstance(node, ast.Name):
            require(node.id in macros, 'pico-sdk defines no %s' % node.id)
            return evaluate(macros[node.id], macros, depth + 1)
        if isinstance(node, ast.BinOp) and type(node.op) in OPERATORS:
            return OPERATORS[type(node.op)](value(node.left), value(node.right))
        raise RuntimeError('not a constant expression the oracle reads: %r' % expression)
    return value(ast.parse(expression.strip(), mode='eval')) & 0xffffffff


def pico_sdk_stage(word, lr):
    """What pico-sdk 2.2.0's boot2_generic_03h.S, with exit_from_boot2.S at
    its #include, does when entered with LR: its device stores, then
    ('msr', 'msp', value) and the address it branches to, or the address it
    returns to.  It is read from the fetched files: each instruction of the
    two is one of the few forms below, any other line is refused, and each
    operand is evaluated from the files' and their headers' #defines.  WORD
    reads the linked image, for the vector table the stage loads."""
    inputs = fetch_inputs.read_lock()
    read = {name: fetch_inputs.fetch('rp2040/' + name, inputs).read_text()
            for name in ('boot2_generic_03h.S', 'exit_from_boot2.S', 'ssi.h',
                         'addressmap.h', 'm0plus.h')}
    macros = defines(*read.values())
    body = read['boot2_generic_03h.S'].split('regular_func _stage2_boot', 1)[1]
    body = body.replace('#include "boot2_helpers/exit_from_boot2.S"',
                        read['exit_from_boot2.S'].split('#include "hardware/regs/m0plus.h"', 1)[1])
    lines = [re.sub(r'//.*|/\*.*?\*/', '', line).strip() for line in body.splitlines()]
    lines = [line for line in lines if line and not line.startswith(('#', '.global', '.ltorg',
                                                                       '.end', 'literals:'))]
    labels = {line[:-1]: index for index, line in enumerate(lines) if line.endswith(':')}
    r = {'lr': lr}
    stack, effects, at = [], [], 0
    while at < len(lines):
        line, at = lines[at], at + 1
        if line.endswith(':'):
            continue
        op, _, rest = line.partition(' ')
        args = [a.strip() for a in re.split(r',(?![^{]*})', rest)]
        if op == 'push' and args == ['{lr}']:
            stack.append(r['lr'])
        elif op == 'pop' and len(args) == 1:
            r[args[0].strip('{}')] = stack.pop()
        elif op == 'ldr' and args[1].startswith('='):
            r[args[0]] = evaluate(args[1][1:], macros)
        elif op == 'movs' and args[1].startswith('#'):
            r[args[0]] = evaluate(args[1][1:], macros)
        elif op == 'str':
            base = re.fullmatch(r'\[(\w+)(?:,\s*#(.+))?\]', ', '.join(args[1:]))
            require(base, 'the oracle does not read %r' % line)
            address = r[base.group(1)] + (evaluate(base.group(2), macros) if base.group(2) else 0)
            effects.append(('w', address & 0xffffffff, 4, r[args[0]]))
        elif op == 'cmp' and args[1].startswith('#'):
            r['flags'] = r[args[0]] - evaluate(args[1][1:], macros)
        elif op == 'beq':
            if r['flags'] == 0:
                at = labels[args[0]]
        elif op == 'ldmia' and args[1] == '{r0, r1}':
            base = r[args[0]]
            r['r0'], r['r1'] = word(base), word(base + 4)
        elif op == 'msr' and args[0] == 'msp':
            effects.append(('msr', 'msp', r[args[1]]))
        elif op == 'bx':
            return effects, r[args[0]] & ~1
        else:
            raise RuntimeError('the oracle does not read pico-sdk\'s %r' % line)
    raise RuntimeError('pico-sdk\'s stage does not end in a branch')


def boot_stage(run, image, report, want):
    """D587/D588: RP2040's second stage in the linked image and its object."""
    boot2 = want['boot2']
    at, slot, limit = boot2['address'], boot2['slot'], boot2['limit']
    require(image.symbols['_landin_firmware_boot2'] == at,
            'the second stage is not at the start of flash')
    stage = image.read(at, slot)
    checksum = struct.unpack_from('<I', stage, limit)[0]
    require(checksum == crc32_mpeg2(stage[:limit]),
            'the second stage\'s checksum %#x is not the CRC-32 of its %d bytes, %#x'
            % (checksum, limit, crc32_mpeg2(stage[:limit])))
    linked, assembled = Elf(image.data), Elf((run.out / 'core.elf.o').read_bytes())
    for elf, which in ((linked, 'linked image'), (assembled, 'object')):
        reached = elf.reaching(elf.index('.boot2'), into_only=elf is linked)
        require(not reached, 'a relocation reaches the %s\'s .boot2: %r' % (which, reached))
    length = next(size for name, _, size, _, _ in linked.symbols(linked.names.index('.symtab'))
                  if name == '_landin_firmware_boot2')
    require(0 < length <= limit and not any(stage[length:limit]),
            'the stage is %d bytes and the slot past it is not zeros' % length)
    said = report['boot_stage']
    wanted = {'routine': boot2['routine'], 'address': at, 'bytes': length, 'slot': slot,
              'checksum': checksum, 'checksum_address': at + limit}
    require(said == wanted, 'the build report says the stage is %r, not %r' % (said, wanted))
    vectors = want['vector_address']
    copy, top = boot2['copy'], boot2['copy'] + slot
    windows = [(base, size) for base, size in boot2['devices']]
    for lr in (0, 0x20000101):
        evaluation = thumb.Evaluation(
            thumb.Image(image.data), windows, (0x20000000, 0x42000), special=True,
            start={'pc': copy, 'sp': boot2['rom_stack'], 'lr': lr},
            until=lambda pc: not copy <= pc < top, limit=10_000)
        evaluation.place(copy, stage)
        effects = evaluation.run()
        expected, branch = pico_sdk_stage(image.word, lr)
        require(effects == expected, 'entered with lr %#x, the stage makes %r, and pico-sdk\'s'
                ' makes %r' % (lr, effects, expected))
        require(evaluation.r[15] == branch, 'entered with lr %#x, the stage leaves for %#x,'
                ' and pico-sdk\'s for %#x' % (lr, evaluation.r[15], branch))
    require(branch == lr & ~1, 'called, the stage does not return')
    entered, branch = pico_sdk_stage(image.word, 0)
    require(branch == image.symbols['_landin_firmware_reset'] & ~1
            and entered[-1] == ('msr', 'msp', want['stack_top'])
            and entered[-2] == ('w', boot2['vtor'], 4, vectors),
            'from the ROM the stage does not point VTOR at the table, load its stack and'
            ' enter reset: %r' % entered)


def pico_sdk_block(run):
    """The bytes of pico-sdk 2.2.0's embedded_start_block.inc.S for an
    RP2350 Arm image with its end block off, a block loop of one block,
    as the pinned GCC assembles it with the fetched picobin.h: the oracle
    the linked block is compared with, read from the files rather than
    from refine or the datasheet."""
    inputs = fetch_inputs.read_lock()
    where = run.out / 'pico-sdk-block'
    (where / 'boot').mkdir(parents=True, exist_ok=True)
    shutil.copyfile(fetch_inputs.fetch('rp2350/picobin.h', inputs), where / 'boot/picobin.h')
    shutil.copyfile(fetch_inputs.fetch('rp2350/embedded_start_block.inc.S', inputs),
                    where / 'embedded_start_block.inc.S')
    (where / 'block.S').write_text('#include "boot/picobin.h"\n'
                                   '#include "embedded_start_block.inc.S"\n')
    run.command('assemble-pico-sdk-block', [
        run.arm / 'arm-eabi-gcc', '-mcpu=cortex-m33', '-mthumb', '-DNO_PICO_PLATFORM=1',
        '-DPICO_CRT0_INCLUDE_PICOBIN_END_BLOCK=0', '-I', where, '-c', where / 'block.S',
        '-o', where / 'block.o'])
    elf = Elf((where / 'block.o').read_bytes())
    at = elf.index('.embedded_block')
    require(not elf.reaching(at, into_only=True), 'pico-sdk\'s block is relocated')
    header = elf.sections[at]
    return elf.data[header[4]:header[4] + header[5]]


def image_block(run, image, report, want):
    """D637/D638: RP2350's image block in the linked image and its object."""
    block = want['image_block']
    at, size = block['address'], block['bytes']
    flash = next(r for r in want['regions'] if r['name'] == want['placed']['vectors'])
    require(image.symbols.get('_landin_firmware_image_block') == at,
            'the image block is not at %#x' % at)
    require(at == want['vector_address'] + 4 * want['vector_words'],
            'the image block does not follow the vector table directly')
    require(at + size <= flash['origin'] + block['window'],
            'the image block does not end in the first %d bytes of %s'
            % (block['window'], flash['name']))
    expected = pico_sdk_block(run)
    linked = image.read(at, size)
    require(linked == expected, 'the linked image block is %s, and pico-sdk\'s is %s'
            % (linked.hex(), expected.hex()))
    elf, assembled = Elf(image.data), Elf((run.out / 'core.elf.o').read_bytes())
    require('.embedded_block' in elf.names, 'the image block has no section of its own')
    reached = assembled.reaching(assembled.index('.embedded_block'), into_only=True)
    require(not reached, 'a relocation is in the object\'s image block: %r' % reached)
    wanted = {'address': at, 'bytes': size,
              'words': list(struct.unpack('<%dI' % (size // 4), expected))}
    require(report['image_block'] == wanted, 'the build report says the image block is %r,'
            ' not %r' % (report['image_block'], wanted))


def block_contract(run, refine):
    """D546/D638: a developer's script must keep the block refine checked
    in the first 4 KiB; one that moves it or changes its words is refused
    naming clause 1."""
    level = ['--level=' + EXPECTED['rp2350']['level']]
    compile_firmware(run, refine, PROGRAMS['rp2350'], level, name='derived.elf')
    derived = (run.out / 'derived.elf.ld').read_text()
    (run.out / 'copy.ld').write_text(derived)
    compile_firmware(run, refine, PROGRAMS['rp2350'], level + ['--linker-script=copy.ld'],
                     name='copy.elf')
    placed = '  .embedded_block : { KEEP(*(.embedded_block)) } > FLASH\n'
    window = ('ASSERT(ADDR(.embedded_block) + SIZEOF(.embedded_block) <= ORIGIN(FLASH) + 4096,\n'
              '       "the image block must end in the first 4 KiB of the image")\n')
    broken = {
        'late': ([(placed, placed.replace(' : {', ' ORIGIN(FLASH) + 4096 : {')),
                  (window, '')], 'ends past the first 4 KiB of FLASH'),
        'words': ([(placed, '  .embedded_block : { _landin_firmware_image_block = .;'
                    ' LONG(0xffffded3) LONG(0x10210142) LONG(0x1ff) LONG(4)'
                    ' LONG(0xab123579) } > FLASH\n  /DISCARD/ : { *(.embedded_block) }\n')],
                  'is not the one refine assembled: the image block links to offset'
                  ' 0x00000004'),
    }
    for name, (edits, said) in broken.items():
        text = derived
        for old, new in edits:
            require(old in text, 'the derived script lacks %r' % old)
            text = text.replace(old, new)
        (run.out / ('block-%s.ld' % name)).write_text(text)
        refused = compile_firmware(run, refine, PROGRAMS['rp2350'],
                                   level + ['--linker-script=block-%s.ld' % name],
                                   name='block-%s.elf' % name, check=False)
        require('error[L0519]' in refused and 'clause 1,' in refused and said in refused,
                'a script whose image block is %s is not refused naming it: %s'
                % (name, refused))
        require(not (run.out / ('block-%s.elf' % name)).exists(),
                'a refused image is left behind for the %s block' % name)


def stage_refusals(run, refine):
    """D588: an oversize stage and a stage with a relocation are refused
    before the link, each naming its problem, and leave no image."""
    devices = run.out / 'devices'
    shutil.copytree(ROOT / 'devices/descriptions/rp2040', devices / 'descriptions/rp2040')
    port = (devices / 'descriptions/rp2040/boot2.ldn').read_text()
    cases = {
        'oversize': (port.replace('        push {lr}\n', '        push {lr}\n' + '        nop\n' * 120),
                     'the second stage and its literals are '),
        'relocated': (port.replace('ldr r3, =0x18000000', 'ldr r3, =_landin_firmware_reset'),
                      'the second stage holds a relocation at offset '),
    }
    for name, (text, said) in cases.items():
        require(text != port, 'the port no longer has the line the %s control edits' % name)
        (devices / 'descriptions/rp2040/boot2.ldn').write_text(text)
        refused = compile_firmware(run, refine, PROGRAMS['rp2040'], name=name + '.elf',
                                   check=False, devices=devices)
        require('error[L0538]' in refused and said in refused,
                'the %s stage is not refused naming its problem: %s' % (name, refused))
        require(not (run.out / (name + '.elf')).exists(),
                'a refused %s stage leaves an image' % name)


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
        #  D588: the slot holds what the script fills it with, not the
        #  stage refine sealed, so its checksum is wrong.
        'checksum': [('  .boot2 ORIGIN(FLASH) : { KEEP(*(.boot2)) } > FLASH\n',
                      '  .boot2 ORIGIN(FLASH) : { _landin_firmware_boot2 = .; LONG(1)'
                      ' . = ORIGIN(FLASH) + 256; } > FLASH\n'
                      '  /DISCARD/ : { *(.boot2) }\n')],
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
        (run.out / ('clause%s.ld' % clause)).write_text(text)
        said = compile_firmware(run, refine, PROGRAMS['rp2040'],
                                ['--linker-script=clause%s.ld' % clause],
                                name='clause%s.elf' % clause, check=False)
        named = 'clause 1,' if clause == 'checksum' else 'clause %d,' % clause
        require('error[L0519]' in said and named in said
                and (clause != 'checksum' or 'checksum is not the CRC-32' in said),
                'a script breaking clause %s is not refused naming it: %s' % (clause, said))
        require(not (run.out / ('clause%s.elf' % clause)).exists(),
                'a refused image is left behind for clause %s' % clause)
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
    controls.append({'contract': 'four clauses, the stage\'s checksum and an unknown region',
                     'status': 'passed'})
    out = root / 'block-contract'
    out.mkdir()
    block_contract(Run(out, parent.tools), refine)
    controls.append({'contract': 'the image block moved past 4 KiB and its words changed',
                     'status': 'passed'})
    out = root / 'stage-refusals'
    out.mkdir()
    stage_refusals(Run(out, parent.tools), refine)
    controls.append({'stage': 'an oversize and a relocated stage refused', 'status': 'passed'})
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
