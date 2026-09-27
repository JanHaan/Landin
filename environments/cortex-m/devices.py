#!/usr/bin/env python3
"""Generated device fixture consumers; separate from all inherited lanes."""
import argparse
import json
from pathlib import Path
import re
import shutil
import sys

from backend import image_contract
from firmware import execute
from freestanding import linker_closure
from machine import Machine, Refused
from models import FixturePeripheral
from packed_native import PROFILES
from run import Run, require, FLAGS
from setup import DEFAULT, inventory, sha, supported_host

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
DEVICES = ROOT / 'devices'


def build(run, refine, program, optimize, specialize):
    source = run.out / 'source'
    (source / 'app').mkdir(parents=True)
    (source / 'app/main.ldn').write_text(program)
    modules = set()
    for line in program.splitlines():
        if not line.startswith('import '):
            continue
        module = line[7:]
        require(module in ('core/cpu', 'core/panic') or module in
                ('rp2040/io_bank0', 'rp2040/sio', 'rp2040/timer',
                 'rp2040/uart0', 'rp2040/uart1', 'rp2040/dma'),
                'undeclared device consumer module: '+module)
        modules.add(module)
        origin = ROOT / module if module.startswith('core/') else DEVICES / 'generated' / module
        shutil.copytree(origin, source / module)
    inputs = {str(p.relative_to(source)): sha(p)
              for p in sorted(source.rglob('*.ldn'))}
    (run.out / 'inputs.json').write_text(json.dumps(inputs, indent=2)+'\n')
    elf = run.out / 'core.elf'
    run.command('compile', [refine, '--root=source', '--target=cortex-m0',
        '--firmware-entry=start', '--emit=exe',
        '--toolchain=' + str(run.bin / 'arm-none-eabi-gcc'),
        '--optimize='+optimize, '--specialize='+specialize,
        *(['--panic-map'] if 'import core/panic' in program else []),
        'source/app', '-o', elf.name], timeout=60)
    run.command('elf', [run.bin / 'arm-none-eabi-readelf', '-h', '-A', '-S', '-l', '-r', elf])
    run.command('disassembly', [run.bin / 'arm-none-eabi-objdump', '-dr', elf])
    symbols = run.command('symbols', [run.bin / 'arm-none-eabi-nm', '-n', elf])
    require(not run.command('undefined', [run.bin / 'arm-none-eabi-nm', '-u', elf]).strip(),
            'unresolved freestanding symbols')
    names = {line.split()[-1] for line in symbols.splitlines() if line.split()}
    require(not names & {'malloc', 'calloc', 'realloc', 'free', 'exit', '_exit',
                         '__libc_init_array', '__libc_start_main', '_sbrk'},
            'hosted runtime in freestanding closure')
    mapping = (run.out / 'core.elf.map').read_text()
    require('libc.a' not in mapping and 'crt0.o' not in mapping,
            'hosted archive in freestanding closure')
    helper = run.command('runtime-archive', [run.bin / 'arm-none-eabi-gcc',
        '-mcpu=cortex-m0', '-mthumb', '-mfloat-abi=soft',
        '-print-libgcc-file-name']).strip()
    require(helper.endswith('/thumb/v6-m/nofp/libgcc.a'), 'wrong private runtime')
    loads, members = linker_closure(mapping, helper)
    record = {'image': image_contract(elf),
              'modules': ['app'] + sorted(modules),
              'source_inputs': inputs, 'symbols': sorted(names),
              'linker_inputs': loads, 'runtime_members': members,
              'runtime_archive': helper, 'runtime_archive_sha256': sha(Path(helper))}
    (run.out / 'closure.json').write_text(json.dumps(record, indent=2)+'\n')
    return elf


def images(run, elf):
    execute(run, elf, [
        'set *(unsigned*)&initialized = 0xaaaaaaaa',
        'set *(unsigned*)&cleared = 0xbbbbbbbb',
        'break *start', 'continue', 'delete breakpoints', 'python',
        'assert v("*(unsigned*)&initialized") == 0x680',
        'assert v("*(unsigned*)&cleared") == 0',
        'assert v("$sp") == 0x20004000 and v("$r11") == 0',
        'assert v("&immutable") < 0x8000',
        'assert v("*(unsigned*)&immutable") == 0x40014004',
        'assert v("*(unsigned*)((char*)&immutable+4)") == 0x5000004c',
        'low=v("&_landin_firmware_ramtext_start")',
        'high=v("&_landin_firmware_ramtext_end")',
        'load=v("&_landin_firmware_ramtext_load")',
        'assert 0x20000000 <= low < high < 0x20003000 and load < 0x8000',
        'mem=gdb.selected_inferior()',
        'assert bytes(mem.read_memory(low,high-low)) == bytes(mem.read_memory(load,high-low))',
        'mem.write_memory(0x20003000, bytes([0xa5])*4096)', 'end',
        'break _landin_firmware_returned', 'continue', 'python',
        'assert v("*(unsigned*)&observed") == 0x680',
        'assert v("$sp") == 0x20004000 and v("$r11") == 0',
        'assert v("$r9") == 0 and v("$r12") == 0',
        'paint=bytes(mem.read_memory(0x20003000,4096))',
        'assert paint[:256] == bytes([0xa5])*256',
        'print("R680_STACK_OBSERVED",4096-next(i for i,b in enumerate(paint) if b != 0xa5))',
        'print("R680_IMAGES_PASS")', 'end'], 'R680_IMAGES_PASS')


# Literal oracle, transcribed independently of projection code and outputs.
PREFIX = ('r32:4:0000001f;w32:4:00000002;w32:114:00000012;'
          'w32:118:00000002;r32:110:00000010;r32:200:00000041;'
          'r32:200:00000042;w32:200:00000055;w32:244:00000010;'
          'r32:218:00000090;w32:310:00000007;w32:334:00000001;'
          'w32:334:00000000;r32:334:00000002;w32:1000:40070200;')
TAIL = (';w32:1008:00000004;w32:100c:000a8020;w32:1404:00000001;'
        'w32:100c:000a8021;dma8:0:2a;dma8:1:2b;r32:1400:00000001;'
        'r32:1008:00000002;w32:1400:00000001;dma8:2:2c;dma8:3:2d;'
        'r32:1400:00000001;r32:1008:00000000;w32:1400:00000001')


def peripheral(run, elf, model=None, name='device'):
    text = run.command('device-symbols', [run.bin / 'arm-none-eabi-nm', elf])
    symbols = {s[2]: int(s[0], 16) for line in text.splitlines()
               if len(s := line.split()) == 3}
    stage = symbols['stage']
    model = model or FixturePeripheral()
    with Machine(run, elf, name, poll=[stage]) as m:
        m.map(0x40070000, 0x2000, model)
        m.trap(symbols['hardfault' if 'hardfault' in symbols else
                       '_landin_firmware_unhandled'], 'unhandled exception')
        u32 = m.u32
        m.until(lambda: u32(stage) == 1)
        require(model.configuration == 0xa8021 and model.remaining == 4, 'ready: descriptor')
        require(model.output == 16 and model.transmitted == 0x55 and model.alarm == 7,
                'ready: device images')
        require(model.transfers == 0, 'ready: transfers')
        model.feed(42)
        model.feed(43)
        m.settle()
        require(u32(symbols['notifications']) == 1, 'half: notifications')
        require(u32(symbols['completed']) == 0 and u32(symbols['result']) == 0, 'half: state')
        require(model.transfers == 2 and model.remaining == 2, 'half: model')
        m.write_u32(stage, 2)
        m.until(lambda: u32(stage) == 3)
        model.feed(44)
        model.feed(45)
        m.settle()
        require(u32(symbols['notifications']) == 1, 'masked: delivered while masked')
        require(u32(symbols['completed']) == 0, 'masked: completed while masked')
        require(model.transfers == 4 and model.remaining == 0, 'masked: model')
        require(u32(symbols['buffer']) == 0x2d2c2b2a, 'masked: buffer')
        m.write_u32(stage, 4)
        m.until(lambda: u32(stage) == 5)
        m.settle()
        require(u32(symbols['result']) == 174, 'done: result')
        require(u32(symbols['notifications']) == 2 and u32(symbols['completed']) == 1,
                'done: notifications')
        require(model.pending == 0 and model.configuration == 0xa8020, 'done: model')
    trace = PREFIX + 'w32:1004:'+format(symbols['buffer'], '08x') + TAIL
    require(model.trace == trace, 'device trace differs: ' + model.trace)
    refused = 0
    for action in [lambda: model.read(0x114, 4), lambda: model.write(0x218, 4, 0),
                   lambda: model.read(0x1008, 2), lambda: model.write(0x200, 1, 1),
                   lambda: model.write(0x334, 4, 16), lambda: model.read(0x204, 4),
                   lambda: model.write(0x100c, 4, 12)]:
        try:
            action()
        except Refused:
            refused += 1
    require(refused == 7 and model.trace == trace, 'model accepted a refused access')
    (run.out / 'device-trace.txt').write_text(model.trace + '\n')


def faults(run, elf):
    """The harness fails, naming the cause, on each fault it exists to catch.

    The independent C consumer runs three times with one fault injected into
    its otherwise passing lane: a register the contract refuses, a device
    whose interrupt line never reaches the NVIC, and a reply one bit wrong.
    Each must fail the way it says; a lane that passed would mean the
    harness could not see that fault.
    """
    class Refusing(FixturePeripheral):
        def read(self, offset, width):
            if offset == 0x218:
                raise Refused('forbidden read or unknown fixture register')
            return super().read(offset, width)

    class Silent(FixturePeripheral):
        LINES = {}

    class Lying(FixturePeripheral):
        def read(self, offset, width):
            value = super().read(offset, width)
            return value ^ 1 if offset == 0x218 else value

    outcomes = {}
    # An interrupt never delivered leaves the handler's count at zero once
    # the firmware is idle; a wrong status reply makes it stop configuring.
    for name, model, expected in (('refused', Refusing, 'forbidden read'),
                                  ('undelivered', Silent, '^half: notifications$'),
                                  ('wrong-reply', Lying, '^firmware idle at 0x[0-9a-f]+ before')):
        try:
            peripheral(run, elf, model(), 'fault-' + name)
        except (Refused, RuntimeError) as failure:
            require(re.search(expected, str(failure)), 'fault %s failed for another reason: %s'
                    % (name, failure))
            outcomes[name] = str(failure)
            continue
        raise RuntimeError('fault %s passed: the harness cannot see it' % name)
    (run.out / 'faults.json').write_text(json.dumps(outcomes, indent=2) + '\n')


def independent(run):
    elf = run.out / 'control.elf'
    run.command('independent-build', [run.bin / 'arm-none-eabi-gcc', *FLAGS,
        '-Wl,-T,'+str(HERE / 'probes/memory.ld')+',--gc-sections,-Map,control.map',
        HERE / 'probes/start.S', HERE / 'probes/device-control.c', '-o', elf])
    run.command('independent-elf', [run.bin / 'arm-none-eabi-readelf', '-h', '-A', '-S', '-l', '-r', elf])
    run.command('independent-disassembly', [run.bin / 'arm-none-eabi-objdump', '-dr', elf])
    require(not run.command('independent-undefined', [run.bin / 'arm-none-eabi-nm', '-u', elf]).strip(),
            'independent control unresolved symbols')
    (run.out / 'image.json').write_text(json.dumps(image_contract(elf), indent=2)+'\n')
    peripheral(run, elf)
    faults(run, elf)


def refusal_programs():
    source = (DEVICES / 'consumers/refusals/main.ldn').read_text()
    old = '''    image := io_bank0.gpio0_ctrl_decode(io_bank0.gpio0_ctrl_read(0x40070000))
    unchecked begin
        _ = image.f_funcsel
    end unchecked'''
    require(old in source, 'stale refusal consumer derivation')
    return {'hole': source,
            'reserved': source.replace(old, '''    raw := io_bank0.gpio0_ctrl_read(0x40070000)
    uart0.uarticr_write(0x40070200, raw)'''),
            'alignment': source.replace(old, '    _ = io_bank0.gpio0_ctrl_read(0x40070001)')}


def refusal(run, elf, name):
    # Compute D232 coordinates from source bytes in D150 FIFO import order,
    # independently of compiler maps and the handler's observed site.
    filename, token = {
        'hole': ('app/main.ldn', b'image.f_funcsel'),
        'reserved': ('rp2040/uart0/device.ldn', b'compiler.register_write(port, raw, compiler.one_clears'),
        'alignment': ('rp2040/io_bank0/device.ldn', b'compiler.register_read(port, compiler.normal_read)'),
    }[name]
    paths = [run.out / 'source' / p for p in (
        'app/main.ldn', 'rp2040/io_bank0/device.ldn',
        'rp2040/uart0/device.ldn', 'core/cpu/cpu.ldn', 'core/panic/panic.ldn')]
    require(set(paths) == set((run.out / 'source').rglob('*.ldn')),
            'panic oracle source inventory changed')
    offset = 0
    for path in paths:
        data = path.read_bytes()
        if str(path.relative_to(run.out / 'source')) == filename:
            # First UART one-clears call is UARTICR; UARTRSR has no write.
            offset += data.index(token)
            break
        offset += len(data)+1
    else:
        raise RuntimeError('missing panic oracle input')
    site = offset*4+3
    text = run.command('refusal-symbols', [run.bin / 'arm-none-eabi-nm', elf])
    symbols = {s[2]: int(s[0], 16) for line in text.splitlines() if len(s := line.split()) == 3}
    trace = {'hole':'r32:4:00000008','reserved':'r32:4:00000800','alignment':''}[name]
    model = FixturePeripheral()
    model.gpio = 8 if name == 'hole' else 0x800
    with Machine(run, elf, 'refusal') as m:
        m.map(0x40070000, 0x2000, model)
        m.settle()
        require(m.u32(symbols['entries']) == 1, 'refusal: entries')
        require(m.u32(symbols['observed_kind']) == 3, 'refusal: kind')
        require(m.u32(symbols['observed_site']) == site, 'refusal: site')
        require(m.u32(symbols['later']) == 0, 'refusal: continued past the trap')
    require(model.trace == trace, 'refusal trace differs: ' + model.trace)
    (run.out / 'refusal-trace.txt').write_text(model.trace + '\n')


def execute_suite(parent, refine, profiles=PROFILES, cases=None):
    root = parent.out / 'devices'
    root.mkdir()
    parent.command('device-regeneration', [sys.executable, DEVICES / 'generate.py'])
    parent.command('device-oracles', [sys.executable, DEVICES / 'test.py'])
    refine = refine.resolve(strict=True)
    compiler_hash = sha(refine)
    parent.command('device-refine-identity', [refine, '--identify'])
    parent.command('device-source-refusals', [sys.executable, DEVICES / 'check_sources.py',
                   '--refine', refine, '--output', root / 'source-refusals'])
    controls = []
    programs = {n: (DEVICES / 'consumers' / n / 'main.ldn').read_text()
                for n in ('images', 'peripheral')}
    programs.update(refusal_programs())
    if cases is not None:
        require(set(cases) <= programs.keys(), 'unknown device case')
        programs = {n: programs[n] for n in cases}
    for optimize, specialize in profiles:
        for name, program in programs.items():
            out = root / (optimize+'-'+specialize) / name
            out.mkdir(parents=True)
            run = Run(out, parent.tools)
            elf = build(run, refine, program, optimize, specialize)
            if name in ('hole', 'reserved', 'alignment'):
                refusal(run, elf, name)
            else:
                (images if name == 'images' else peripheral)(run, elf)
            fresh = out / 'fresh'
            fresh.mkdir()
            build(Run(fresh, parent.tools), refine, program, optimize, specialize)
            suffixes = ('', '.o', '.s', '.ld', '.map')
            if name in ('hole', 'reserved', 'alignment'):
                suffixes += ('.sources.json',)
            for suffix in suffixes:
                require((out / ('core.elf'+suffix)).read_bytes() ==
                        (fresh / ('core.elf'+suffix)).read_bytes(),
                        'nondeterministic device artifact '+suffix)
            controls.append({'profile': optimize+'-'+specialize, 'kind': name,
                             'status': 'passed', 'artifact_comparisons': len(suffixes)})
            print('device fixture: '+optimize+'-'+specialize+'/'+name+' passed', flush=True)
    if cases is None:
        out = root / 'independent-c-assembly'
        out.mkdir()
        independent(Run(out, parent.tools))
    require(sha(refine) == compiler_hash, 'compiler changed')
    record = {'status': 'passed', 'compiler_sha256': compiler_hash, 'controls': controls,
              'artifacts': {str(p.relative_to(root)): sha(p)
                            for p in sorted(root.rglob('*')) if p.is_file()}}
    (root / 'result.json').write_text(json.dumps(record, indent=2)+'\n')
    return record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--refine', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--tools', type=Path, default=DEFAULT)
    parser.add_argument('--all-profiles', action='store_true')
    parser.add_argument('--case', action='append')
    args = parser.parse_args()
    supported_host()
    before = inventory(args.tools)
    args.output.mkdir(parents=True, exist_ok=False)
    record = {'status': 'failed', 'tools': before, 'scope': 'development; not acceptance'}
    try:
        record['devices'] = execute_suite(Run(args.output.resolve(), args.tools.resolve()),
            args.refine, PROFILES if args.all_profiles else PROFILES[:1], args.case)
        require(inventory(args.tools) == before, 'embedded tool drift')
        record['status'] = 'passed'
    finally:
        record['files'] = {str(p.relative_to(args.output)): sha(p)
                          for p in sorted(args.output.rglob('*')) if p.is_file()}
        (args.output / 'result.json').write_text(json.dumps(record, indent=2)+'\n')
    print('DEVELOPMENT / NOT ACCEPTANCE: device fixtures passed')


if __name__ == '__main__':
    main()
