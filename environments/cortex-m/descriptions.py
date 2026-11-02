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
import hashlib
import json
import operator
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import time

from run import CommandFailed, Run, gdb_listener, oracle, require, stop
from setup import DEFAULT, installed_tools, inventory, sha, supported_host

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(ROOT / 'devices'))
sys.path.insert(0, str(ROOT / 'scripts'))
import fetch_inputs  # noqa: E402
import thumb  # noqa: E402
#  The Cortex-M devices, and the RV32 ones, which link with the RV32
#  toolchain and take their own checks (D680-D686).
DEVICES = json.loads((HERE / 'descriptions.json').read_text())['devices']
EXPECTED = {name: record for name, record in DEVICES.items()
            if record.get('target', 'cortex-m0') == 'cortex-m0'}
RV32_EXPECTED = {name: record for name, record in DEVICES.items()
                 if record.get('target') == 'rv32'}

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
    'riscv-reference': (
        'link(vector: 7) extern(interrupt) mtimer: () -> none = end mtimer\n'
        'mut counted: u32 = 1\n'
        'start: () -> none = counted += 1 end start\n'),
    #  D688: its RAM code runs in IRAM, with its text; it says so on
    #  UART0's FIFO once the ROM has entered it (D685).
    'esp32-c3': ('import descriptions/esp32c3\n'
                 'link(vector: 1) extern(interrupt) uart0: () -> none = end uart0\n'
                 'mut counted: u32 = 1\n'
                 'link(section: ".ramtext.say") say: (byte: u32) -> none =\n'
                 '    fifo: ptr mut u32 = ptr(0x6000_0000)\n'
                 '    compiler.volatile_store(fifo, byte)\n'
                 'end say\n'
                 'start: () -> none =\n'
                 '    say(82)\n    say(86)\n    say(51)\n    say(50)\n    say(10)\n'
                 '    counted += 1\n'
                 'end start\n'),
    'esp32-c5': ('import descriptions/esp32c5\n'
                 'link(vector: 17) extern(interrupt) uart0: () -> none = end uart0\n'
                 'mut counted: u32 = 1\n'
                 'start: () -> none = counted += 1 end start\n'),
    'rp2350-hazard3': ('import descriptions/rp2350_hazard3\n'
                       'link(vector: 56) extern(interrupt) cti: () -> none = end cti\n'
                       'mut counted: u32 = 1\n'
                       'start: () -> none = counted += 1 end start\n'),
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
        self.executable = []
        names = sections[struct.unpack_from('<H', data, 50)[0]][4] if shnum else 0
        for header in sections:
            if header[2] & 4 and header[2] & 2 and header[5]:
                end = data.index(b'\0', names + header[0])
                self.executable.append((data[names + header[0]:end].decode(),
                                        header[3], header[5]))
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
                     devices=ROOT / 'devices', rv32=False):
    (run.out / 'app').mkdir(exist_ok=True)
    (run.out / 'app/main.ldn').write_text(program)
    argv = [refine, '--root=' + str(devices),
            '--target=' + ('rv32' if rv32 else 'cortex-m0'),
            '--firmware-entry=start', '--emit=exe',
            '--toolchain=' + str(run.riscv / 'riscv64-elf-gcc' if rv32
                                 else run.arm / 'arm-eabi-gcc'),
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
                'vector_words', 'boot_prefix', 'boot_suffix', 'stack_reserved'):
        require(report[key] == want[key], '%s: the build report says %s %r, and %r is'
                ' recorded' % (device, key, report[key], want[key]))
    require(report['device'] == device, 'the build report names device %r' % report['device'])
    vectors = want['vector_address']
    require(image.symbols['_landin_firmware_vectors'] == vectors,
            '%s: the vector table is at %#x' % (device, image.symbols['_landin_firmware_vectors']))
    require(image.symbols['_landin_firmware_stack_top'] == want['stack_top'],
            '%s: the stack top is %#x' % (device, image.symbols['_landin_firmware_stack_top']))
    require(image.word(vectors) == want['stack_top'], device + ': word 0 is not the stack top')
    if 'reset_stage' in want:
        reset_stage(image, want, device, vectors)
    else:
        require(image.word(vectors + 4) == image.symbols['_landin_firmware_reset'] | 1,
                device + ': word 1 is not reset')
        require('_landin_firmware_reset_stage' not in image.symbols,
                device + ' has a stage before reset')
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


def jump_target(word, at):
    """Where WORD at AT jumps when it is `jal x0`, RISC-V's `j`; else None."""
    if word & 0x7f != 0x6f or (word >> 7) & 0x1f:
        return None
    offset = (((word >> 31) & 1) << 20 | ((word >> 12) & 0xff) << 12
              | ((word >> 20) & 1) << 11 | ((word >> 21) & 0x3ff) << 1)
    return (at + offset - ((word >> 31) << 21)) & 0xffffffff


def esp_image(run, image, report, want, device):
    """D683/D685: OUT.bin read here as ESP-IDF's esp_image_header_t,
    esp_image_segment_header_t, checksum and hash declare it, against the
    linked ELF's loaded segments and the record's chip facts."""
    data = (run.out / 'core.elf.bin').read_bytes()
    facts = want['esp_image']
    magic, count, mode, size_freq, entry = struct.unpack_from('<BBBBI', data, 0)
    require(magic == 0xe9, device + ': OUT.bin does not begin with 0xe9')
    require(entry == image.symbols['_landin_firmware_entry'],
            '%s: OUT.bin enters at %#x' % (device, entry))
    wp, chip, legacy, minimum, maximum = struct.unpack_from('<B3xHBHH', data, 8)
    require((chip, minimum, maximum) == (facts['chip'], facts['min_revision'],
                                         facts['max_revision']) and data[23] == 1,
            '%s: OUT.bin names chip %d, revisions %d to %d' % (device, chip, minimum, maximum))
    loads = [(paddr, image.data[offset:offset + size])
             for paddr, offset, size in image.segments if size]
    require(count == len(loads), '%s: OUT.bin holds %d segments, the ELF loads %d'
            % (device, count, len(loads)))
    at, checksum = 24, 0xef
    for address, payload in loads:
        got_address, length = struct.unpack_from('<II', data, at)
        padded = payload + b'\0' * (-len(payload) % 4)
        require((got_address, data[at + 8:at + 8 + length]) == (address, padded),
                '%s: OUT.bin\'s segment at %#x is not the ELF\'s' % (device, got_address))
        for byte in padded:
            checksum ^= byte
        at += 8 + length
    at += 15 - at % 16
    require(data[at] == checksum, device + ': OUT.bin\'s checksum is not its segments\'')
    require(data[at + 1:] == hashlib.sha256(data[:at + 1]).digest(),
            device + ': OUT.bin does not end with its SHA-256')
    require(report['esp_image']['offset'] == facts['offset']
            and report['esp_image']['sha256'] == hashlib.sha256(data[:at + 1]).hexdigest(),
            '%s: the build report\'s esp_image is %r' % (device, report['esp_image']))


def flash_image(run, want, name='core.elf'):
    """NAME's OUT.bin at its offset of a flash image of the size the
    machine reads, erased elsewhere, written as flash.bin; its bytes."""
    data = (run.out / (name + '.bin')).read_bytes()
    flash = bytearray(b'\xff' * want['rom_boot']['flash_bytes'])
    offset = want['esp_image']['offset']
    flash[offset:offset + len(data)] = data
    (run.out / 'flash.bin').write_bytes(bytes(flash))
    return data


def rom_boot(run, want, device):
    """D685: OUT.bin at its offset of a flash image the machine's real boot
    ROM reads, as on the board: the ROM's log names each segment it loads
    and the entry, which must be the image's, and the program then speaks
    on the same UART."""
    boot = want['rom_boot']
    data = flash_image(run, want)
    count, entry = data[1], struct.unpack_from('<I', data, 4)[0]
    wanted, at = [], 24
    for _ in range(count):
        address, length = struct.unpack_from('<II', data, at)
        wanted.append('load:0x%08x,len:0x%x' % (address, length))
        at += 8 + length
    wanted.append('entry 0x%08x' % entry)
    uart = run.out / 'uart.log'
    argv = [str(run.espressif / 'qemu-system-riscv32'), '-M', boot['machine'],
            '-display', 'none', '-monitor', 'none', '-serial', 'file:' + str(uart),
            '-drive', 'file=flash.bin,if=mtd,format=raw']
    run.commands.append({'name': 'qemu-rom-boot', 'argv': argv,
                         'timeout_seconds': boot['seconds']})
    process = subprocess.Popen(argv, cwd=run.out, env=run.env, stdout=subprocess.DEVNULL,
                               stderr=(run.out / 'qemu-rom-boot.log').open('wb'),
                               start_new_session=True)
    try:
        deadline = time.monotonic() + boot['seconds']
        while time.monotonic() < deadline and process.poll() is None:
            if uart.exists() and boot['says'] in uart.read_text(errors='replace'):
                break
            time.sleep(0.1)
    finally:
        stop(process)
    said = uart.read_text(errors='replace') if uart.exists() else ''
    lines = [line.strip() for line in said.splitlines()]
    loaded = [line for line in lines if line.startswith(('load:', 'entry '))]
    require(loaded == wanted, '%s: the ROM logged %r, and OUT.bin holds %r'
            % (device, loaded, wanted))
    require(boot['says'] in lines[lines.index(wanted[-1]) + 1:],
            '%s: the program did not say %r after the ROM entered it' % (device, boot['says']))


def select_rv32(run, refine, device):
    """D662, D680-D686: an RV32 device linked by its own toolchain, its
    entry word, table, slots, block and image held to its record."""
    want = RV32_EXPECTED[device]
    image = compile_firmware(run, refine, PROGRAMS[device], ['--level=' + want['level']]
                             if 'level' in want else ['--level=rv32imac'], rv32=True)
    report = json.loads((run.out / 'core.elf.json').read_text())['firmware']
    for key in ('core', 'float_unit', 'boot', 'regions', 'placed', 'vector_address',
                'vector_words', 'boot_prefix', 'boot_suffix', 'stack_reserved'):
        require(report[key] == want[key], '%s: the build report says %s %r, and %r is'
                ' recorded' % (device, key, report[key], want[key]))
    symbols = image.symbols
    vectors = want['vector_address']
    origin = next(r['origin'] for r in want['regions']
                  if r['name'] == want['placed']['vectors']) + want['boot_prefix']
    require(symbols['_landin_firmware_entry'] == origin,
            '%s: the entry word is at %#x' % (device, symbols['_landin_firmware_entry']))
    stage = '_landin_firmware_reset_stage' if 'reset_stage' in want else '_landin_firmware_reset'
    require(jump_target(image.word(origin), origin) == symbols[stage],
            '%s: the entry word does not jump to %s' % (device, stage))
    require(symbols['_landin_firmware_vectors'] == vectors,
            '%s: the table is at %#x' % (device, symbols['_landin_firmware_vectors']))
    require(symbols['_landin_firmware_stack_top'] == want['stack_top'],
            '%s: the stack top is %#x' % (device, symbols['_landin_firmware_stack_top']))
    targets = [jump_target(image.word(vectors + 4 * slot), vectors + 4 * slot)
               for slot in range(want['vector_words'])]
    unhandled = symbols['_landin_firmware_unhandled']
    for slot in want.get('reserved_slots', ()):
        require(targets[slot] == unhandled,
                '%s: reserved slot %d does not jump to the unhandled loop' % (device, slot))
    slot = want['handler_slot']
    handler = symbols[want.get('handler_symbol', 'mtimer')]
    dispatched = want['core'] == 'esp-rv32imac-clic' or (want['core'] == 'hazard3' and slot >= 16)
    require(targets[slot] == (handler if dispatched
                              else symbols['_landin_firmware_slot_%d' % slot]),
            '%s: slot %d does not reach its handler as its interrupt model enters it'
            % (device, slot))
    if want['core'] == 'hazard3':
        require(targets[11] == symbols['_landin_firmware_external'],
                device + ': code 11 is not meinext\'s dispatch')
    if 'image_block' in want:
        block = want['image_block']
        require(symbols['_landin_firmware_image_block'] == block['address']
                and block['address'] + block['bytes'] <= origin + block['window'],
                device + ': the image block is not where it is recorded')
        words = [image.word(block['address'] + 4 * i) for i in range(5)]
        require(words == [0xffffded3, 0x11010142, 0x000001ff, 0, 0xab123579],
                '%s: the image block is %s, not RISC-V\'s IMAGE_DEF (D682)'
                % (device, [hex(w) for w in words]))
    for name, address, size in image.executable:
        require(any(r['origin'] <= address and address + size <= r['origin'] + r['length']
                    and 'x' in r['access'] for r in want['regions']),
                '%s: %s at %#x, which holds code, lies in no region code runs in'
                ' (D688)' % (device, name, address))
    if want['boot'] == 'esp-app-image':
        esp_image(run, image, report, want, device)
        if 'rom_boot' in want:
            rom_boot(run, want, device)
    else:
        require(not (run.out / 'core.elf.bin').exists(), device + ' wrote an ESP image')
    return image


#  D656: the RV32 devices whose unhandled entry is run on an emulator, and
#  its machine: the reference's image on sifive_e, and the C3's OUT.bin
#  through the chip's ROM.
TRAP_MACHINES = {'riscv-reference': 'sifive_e', 'esp32-c3': 'esp32c3'}
#  A write to the read-only cycle CSR, an illegal instruction that is not
#  the compiler's own trap, whose compressed form would leave mtval zero.
TRAP_PROGRAM = ('start: () -> none =\n'
                '    assembler.block("csrw cycle, {value}", in value: u32 at general = 0)\n'
                'end start\n')
WFI = 0x10500073


def trap_record(run, refine, device):
    """D656: a program that executes an illegal instruction, run on an
    emulator, leaves mcause 2, its address, its encoding, the interrupted
    sp and a count of one in the unhandled entry's cells, read as memory
    once the entry waits, and every register as the trap left it."""
    want = RV32_EXPECTED[device]
    machine = TRAP_MACHINES[device]
    importing = 'import descriptions/esp32c3\n' if device == 'esp32-c3' else ''
    image = compile_firmware(run, refine, importing + TRAP_PROGRAM,
                             ['--level=' + want.get('level', 'rv32imac')], name='trap.elf',
                             rv32=True)
    listing = run.command('trap-disassembly', [run.riscv / 'riscv64-elf-objdump', '-d',
                                               run.out / 'trap.elf'])
    found = re.search(r'^\s*([0-9a-f]+):\s+([0-9a-f]{8})\s+csrw\s+cycle,', listing, re.M)
    require(found is not None, device + ': the trap program holds no csrw cycle')
    at, encoding = int(found.group(1), 16), int(found.group(2), 16)
    cells = ('cause', 'pc', 'value', 'sp', 'count')
    for offset, cell in enumerate(cells):
        require(image.symbols['_landin_firmware_trap_' + cell]
                == image.symbols['_landin_firmware_bss_start'] + 4 * offset,
                '%s: _landin_firmware_trap_%s is not word %d of .bss' % (device, cell, offset))
    if machine == 'esp32c3':
        flash_image(run, want, 'trap.elf')
        load = ['-drive', 'file=flash.bin,if=mtd,format=raw']
    else:
        load = ['-kernel', str(run.out / 'trap.elf')]
    seen = run.out / 'trap-record.json'
    script = run.out / 'trap.gdb'
    listener, port, stub = gdb_listener()
    #  A hardware breakpoint, since the C3's ROM writes the image after
    #  the session sets it.
    script.write_text('\n'.join([
        'set pagination off', 'set confirm off', 'set architecture riscv:rv32',
        'target remote 127.0.0.1:%d' % port,
        'hbreak *_landin_firmware_unhandled', 'continue',
        'python', 'import gdb, json',
        'def value(expr): return int(gdb.parse_and_eval(expr)) & 0xffffffff',
        'names = ["$x%d" % i for i in range(1, 32)]',
        'entered = [value(n) for n in names]',
        'for _ in range(64):',
        '    if value("*(unsigned int*)$pc") == %d: break' % WFI,
        '    gdb.execute("stepi", to_string=True)',
        'cells = [value("*(unsigned int*)&_landin_firmware_trap_" + c) for c in %r]'
        % (cells,),
        'waiting = [value(n) for n in names]',
        'with open(%r, "w") as f: json.dump({"entered": entered, "waiting": waiting,'
        ' "pc": value("$pc"), "cells": cells}, f)' % str(seen),
        'print("LANDIN_TRAP_RECORD_READ")', 'end', 'quit', '']))
    argv = [str(run.espressif / 'qemu-system-riscv32'), '-M', machine, '-accel',
            'tcg,thread=single', '-display', 'none', '-monitor', 'none', '-serial', 'none',
            *load, '-S', *stub]
    run.commands.append({'name': 'qemu-trap-record', 'argv': argv})
    with (run.out / 'qemu-trap-record.log').open('wb') as log:
        with listener:
            process = subprocess.Popen(argv, cwd=run.out, env=run.env, stdout=log,
                                       stderr=log, start_new_session=True,
                                       pass_fds=(listener.fileno(),))
        try:
            require(process.poll() is None, 'QEMU exited before connection')
            oracle(run.debug('gdb-trap-record', run.out / 'trap.elf', script, timeout=30),
                   'LANDIN_TRAP_RECORD_READ')
        finally:
            stop(process)
    record = json.loads(seen.read_text())
    got = dict(zip(cells, record['cells']))
    require(image.word(record['pc']) == WFI
            and record['pc'] > image.symbols['_landin_firmware_unhandled'],
            '%s: the unhandled entry did not reach its wait at wfi: pc %#x'
            % (device, record['pc']))
    require(got == {'cause': 2, 'pc': at, 'value': encoding, 'sp': record['entered'][1],
                    'count': 1},
            '%s: the trap record is %s, and mcause 2 at %#x, mtval %#x, sp %#x and a count'
            ' of 1 were made' % (device, {k: hex(v) for k, v in got.items()}, at, encoding,
                                 record['entered'][1]))
    require(record['waiting'] == record['entered'],
            '%s: the unhandled entry changed %s' % (device, ', '.join(
                'x%d' % (i + 1) for i, (a, b) in enumerate(zip(record['entered'],
                                                                record['waiting'])) if a != b)))
    return got


def reset_stage(image, want, device, vectors):
    """D653: the reset vector enters the description's stage, which makes
    the device accesses recorded from the manual with no memory but the
    image's own bytes, no RAM and no stack, and then enters reset."""
    stage = want['reset_stage']
    require(image.word(vectors + 4) == image.symbols['_landin_firmware_reset_stage'] | 1,
            device + ': word 1 is not the stage before reset')
    reset = image.symbols['_landin_firmware_reset'] & ~1
    answers = dict(stage['reads'])
    windows = [(address & ~0x3ff, 0x400) for address, _ in stage['reads']]
    try:
        made = thumb.Evaluation(thumb.Image(image.data), windows, (0, 0),
                                lambda address, width: answers.get(address, 0),
                                limit=10_000, until=lambda pc: pc == reset).run()
    except thumb.Refused as refused:
        raise AssertionError('%s: the stage before reset: %s' % (device, refused))
    require([list(a) for a in made] == stage['accesses'],
            '%s: the stage before reset makes %r, and %r is recorded'
            % (device, made, stage['accesses']))


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
    for device in RV32_EXPECTED:
        out = root / device
        out.mkdir()
        select_rv32(Run(out, parent.tools), refine, device)
        controls.append({'device': device, 'target': 'rv32', 'status': 'passed'})
        print('description: ' + device + ' linked for rv32 and compared', flush=True)
        if device in TRAP_MACHINES:
            out = root / (device + '-trap')
            out.mkdir()
            cells = trap_record(Run(out, parent.tools), refine, device)
            controls.append({'device': device, 'trap_record': cells,
                             'machine': TRAP_MACHINES[device], 'status': 'passed'})
            print('description: %s recorded its trap on %s'
                  % (device, TRAP_MACHINES[device]), flush=True)
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
              'scope': 'compile and link; the C3\'s ROM boot and the RV32 trap records'
                       ' on Espressif\'s QEMU'}
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
