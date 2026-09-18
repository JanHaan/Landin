#!/usr/bin/env python3
"""R6.70 library consumers through compiler-owned startup and linking."""
import argparse
import json
from pathlib import Path
import re
import shutil

from backend import image_contract
from backend_corpus import inventory as corpus_inventory
from firmware import execute, dma_execute
from packed_native import PROFILES
from run import Run, require
from setup import DEFAULT, inventory, sha, supported_host

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
MODULES = ('mem', 'cpu', 'vec', 'pool', 'panic')


def imports(program):
    """The bounded probe inventory, not a package resolver."""
    result = set()
    for line in program.splitlines():
        if not line.startswith('import '):
            continue
        match = re.fullmatch(r'import core/(\w+)', line)
        require(match is not None and match[1] in MODULES,
                'undeclared freestanding module: '+line)
        result.add(match[1])
    return result


def linker_closure(mapping, helper):
    loads = re.findall(r'^LOAD (.+)$', mapping, re.MULTILINE)
    require(loads[:2] == ['core.elf.o', helper]
            and loads[2:] in ([], ['linker stubs']),
            'undeclared linker input: '+repr(loads))
    members = sorted(set(re.findall(re.escape(helper)+r'\(([^)]+)\)', mapping)))
    return loads, members


def build(run, refine, program, optimize, specialize, debug='none'):
    source = run.out / 'source'
    (source / 'app').mkdir(parents=True)
    (source / 'app/main.ldn').write_text(program)
    pending = imports(program)
    modules = set()
    while pending:
        module = min(pending)
        pending.remove(module)
        if module in modules:
            continue
        modules.add(module)
        shutil.copytree(ROOT / 'core' / module, source / 'core' / module)
        for path in sorted((source / 'core' / module).glob('*.ldn')):
            pending.update(imports(path.read_text()) - modules)
    inputs = {str(p.relative_to(source)): sha(p)
              for p in sorted(source.rglob('*.ldn'))}
    (run.out / 'inputs.json').write_text(json.dumps(inputs, indent=2)+'\n')
    elf = run.out / 'core.elf'
    run.command('compile', [refine, '--root=source', '--target=cortex-m0',
        '--firmware-entry=start', '--emit=exe', '--debug='+debug,
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
              'modules': ['app'] + ['core/'+m for m in sorted(modules)],
              'source_inputs': inputs, 'symbols': sorted(names),
              'linker_inputs': loads, 'runtime_members': members,
              'runtime_archive': helper, 'runtime_archive_sha256': sha(Path(helper))}
    (run.out / 'closure.json').write_text(json.dumps(record, indent=2)+'\n')
    return elf


def cpu(run, elf):
    execute(run, elf, [
        'set *(unsigned*)&initialized = 0xaaaaaaaa',
        'set *(unsigned*)&cleared = 0xbbbbbbbb',
        'break *start', 'continue', 'delete breakpoints', 'python',
        'assert v("$sp") == 0x20004000 and v("$r11") == 0',
        'assert v("*(unsigned*)&initialized") == 0x670',
        'assert v("*(unsigned*)&cleared") == 0',
        'gdb.selected_inferior().write_memory(0x20003000, bytes([0xa5])*4096)',
        'end', 'break *irq', 'continue', 'delete breakpoints', 'python',
        'assert v("$xpsr") & 511 == 16',
        'assert v("$lr") == 0xfffffff9 and v("$sp") % 8 == 0',
        'outersp = v("$sp")',
        'frame = [v("*(unsigned*)($sp+%d)" % (i*4)) for i in range(8)]',
        'callee = [v("$r%d" % i) for i in range(4,12)]',
        'gdb.execute("break *%d if ($xpsr & 511) == 0" % frame[6])', 'end',
        'continue', 'delete breakpoints', 'python',
        'assert [v("$r%d" % i) for i in (0,1,2,3,12)] == frame[:5]',
        'assert [v("$r%d" % i) for i in range(4,12)] == callee',
        'assert v("$xpsr") & 0xf00001ff == frame[7] & 0xf00001ff',
        'assert v("$sp") == outersp+32 and v("$lr") == frame[5]', 'end',
        'break _landin_firmware_returned', 'continue', 'python',
        'assert v("*(unsigned*)&observed") == 0x670',
        'assert v("*(unsigned*)&interrupts") == 1',
        'assert v("*(unsigned*)&handler_mask") == 1',
        'assert v("*(unsigned*)&discarded") == 73',
        'assert v("*(unsigned*)&evaluations") == 1',
        'assert v("$sp") == 0x20004000 and v("$r11") == 0',
        'assert v("$r9") == 0 and v("$r12") == 0',
        'assert bytes(gdb.selected_inferior().read_memory(0x20003000,256)) == bytes([0xa5])*256',
        'paint = bytes(gdb.selected_inferior().read_memory(0x20003000,4096))',
        'print("R670_STACK_OBSERVED", 4096-next(i for i,b in enumerate(paint) if b != 0xa5))',
        'print("R670_CORE_CPU_PASS")', 'end'], 'R670_CORE_CPU_PASS')


def memory(run, elf):
    execute(run, elf, [
        'break *start', 'continue', 'delete breakpoints', 'python',
        'assert v("$sp") == 0x20004000 and v("$r11") == 0',
        'gdb.selected_inferior().write_memory(0x20003000, bytes([0xa5])*4096)',
        'end', 'break _landin_firmware_returned', 'continue', 'python',
        'assert v("*(unsigned*)&observed") == 42',
        'assert v("$sp") == 0x20004000 and v("$r11") == 0',
        'assert v("$r9") == 0 and v("$r12") == 0',
        'paint = bytes(gdb.selected_inferior().read_memory(0x20003000,4096))',
        'assert paint[:256] == bytes([0xa5])*256',
        'print("R670_STACK_OBSERVED", 4096-next(i for i,b in enumerate(paint) if b != 0xa5))',
        'print("R670_CORE_MEMORY_PASS")', 'end'], 'R670_CORE_MEMORY_PASS')


def nonreturning(run, elf):
    # The same cold image selects six real call paths after initialization.
    # Stop at a callee reached only after the store; no source debugger or
    # instruction-text oracle is substituted for execution.
    for mode in range(6):
        lane = run.out / ('path-'+str(mode))
        lane.mkdir()
        execute(Run(lane, run.tools), elf, [
            'set *(unsigned*)&initialized = 0xaaaaaaaa',
            'set *(unsigned*)&cleared = 0xbbbbbbbb',
            'break *start', 'continue', 'delete breakpoints', 'python',
            'assert v("*(unsigned*)&initialized") == 0x670',
            'assert v("*(unsigned*)&cleared") == 0',
            'assert v("$sp") == 0x20004000 and v("$r11") == 0',
            'gdb.selected_inferior().write_memory(0x20003000, bytes([0xa5])*4096)',
            'end', 'set *(unsigned*)&mode = '+str(mode),
            'break *finished', 'continue', 'python',
            'assert v("*(unsigned*)&observed") == 42',
            'assert v("*(unsigned*)&later") == 0',
            'assert v("*(unsigned*)&cleanup_order") == '+str(7 if mode == 4 else 0),
            'assert v("$sp") % 8 == 0 and v("$sp") >= 0x20003000',
            'assert v("$r9") == 0',
            'frame = v("$r11")', 'depth = 0',
            'while frame:',
            '    assert frame % 8 == 0 and 0x20003000 <= frame < 0x20004000',
            '    prior = v("*(unsigned*)%d" % frame)',
            '    incoming = v("*(unsigned*)%d" % (frame+4))',
            '    assert incoming & 1 and incoming < 0x8000',
            '    assert prior == 0 or prior > frame',
            '    frame = prior', '    depth += 1', '    assert depth <= 16',
            'assert depth == '+str([2, 3, 4, 3, 3, 2][mode]),
            'paint = bytes(gdb.selected_inferior().read_memory(0x20003000,4096))',
            'assert paint[:256] == bytes([0xa5])*256',
            'print("R670_STACK_OBSERVED", 4096-next(i for i,b in enumerate(paint) if b != 0xa5))',
            'print("R670_NORETURN_PASS")', 'end'], 'R670_NORETURN_PASS')



def panic(run, elf):
    program = (run.out / 'source/app/main.ldn').read_bytes()
    names = json.loads((run.out / 'closure.json').read_text())['symbols']
    latches = [name for name in names if name.endswith('landin_panic_active')]
    require(len(latches) == 1, 'selected handler has no unique private latch')
    # Expected sites come from the input expression's byte position, never
    # the compiler map, generated instructions, or the observed panic value.
    tokens = [b'high += u8(input)', b'u8(input)', b'items[usize(input)]',
              b'42 / input', b'42 << input', b'bool(input)', b'never()',
              b'high += u8(input)', b'a / b', b'high += u8(input)', None,
              b'73 / input', b'compiler.volatile_load(port)', b'value.bits',
              b'ptr(usize(read_input()))', b'compiler.register_write(addr later',
              b'utf8(bytes[0..<1])']
    kinds = [2, 3, 1, 2, 1, 3, 4, 2, 2, 2, 4, 2, 3, 3, 3, 3, 3]
    values = [1, 256, 2, 0, -1, 2, 0, 1, 0, 1, 0, 0, 0, 0, 0, 0, 255]
    for mode, (token, kind, value) in enumerate(zip(tokens, kinds, values)):
        after = program.index(b'elsif mode == 1 then') if mode == 1 else 0
        site = 0 if token is None else 4 * program.index(token, after) + kind
        lane = run.out / ('panic-'+str(mode))
        lane.mkdir()
        prefix = [
            'set *(unsigned*)&'+latches[0]+' = 0xcccccccc',
            'set *(unsigned*)&initialized = 0xaaaaaaaa',
            'set *(unsigned*)&cleared = 0xbbbbbbbb',
            'break *start', 'continue', 'delete breakpoints', 'python',
            'assert v("*(unsigned*)&initialized") == 0x670',
            'assert v("*(unsigned*)&cleared") == 0',
            'assert v("$sp") == 0x20004000 and v("$r11") == 0',
            'gdb.selected_inferior().write_memory(0x20003000, bytes([0xa5])*4096)',
            'end', 'set *(unsigned*)&mode = '+str(mode),
            'set *(int*)&input = '+str(value)]
        if mode == 6:
            # Deliberately violate an ordinary noreturn promise at its ABI
            # boundary. This is debugger fault injection, not a C surface.
            prefix += ['break *never', 'continue', 'delete breakpoints',
                       'set $pc = $lr & ~1']
        target = '_landin_firmware_unhandled' if mode == 9 else 'finished'
        execute(Run(lane, run.tools), elf, prefix + [
            'break *'+target, 'continue', 'python',
            'assert v("*(unsigned*)&entries") == 1',
            'assert v("*(unsigned*)&observed_kind") == '+str(kind),
            'assert v("*(unsigned*)&observed_site") == '+str(site),
            'assert v("*(unsigned*)&later") == '+str(99 if mode == 10 else 0),
            'assert v("$xpsr") & 511 == '+str(3 if mode == 9 else 16 if mode == 11 else 0),
            'assert v("$sp") % 8 == 0 and v("$sp") >= 0x20003000',
            'assert v("$r9") == 0',
            'paint = bytes(gdb.selected_inferior().read_memory(0x20003000,4096))',
            'assert paint[:256] == bytes([0xa5])*256',
            'print("R670_STACK_OBSERVED", 4096-next(i for i,b in enumerate(paint) if b != 0xa5))',
            'print("R670_PANIC_PASS")', 'end'], 'R670_PANIC_PASS')
        if site:
            import sys
            output = run.command('site-'+str(mode), [sys.executable,
                ROOT / 'scripts/source-location.py', str(elf)+'.sources.json',
                '--panic-site', str(site), '--assembly', str(elf)+'.s'])
            offset = (site-kind)//4
            line = program[:offset].count(b'\n')+1
            column = offset-program.rfind(b'\n', 0, offset)
            reason = ('out_of_range', 'overflow', 'bad_conversion', 'unreachable')[kind-1]
            require(output.strip() == f'source/app/main.ldn:{line}:{column} ({reason})',
                    'panic source map disagrees with independent input coordinates')



def panic_default(run, elf):
    require(not Path(str(elf)+'.sources.json').exists(), 'mandatory panic map')
    require('panic_active' not in Path(str(elf)+'.s').read_text(),
            'default panic unexpectedly needs retained state')
    for mode, value in ((0, 1), (6, 0), (10, 0)):
        lane = run.out / ('default-'+str(mode))
        lane.mkdir()
        prefix = ['break *start', 'continue', 'delete breakpoints',
                  'set *(unsigned*)&mode = '+str(mode),
                  'set *(int*)&input = '+str(value)]
        if mode == 6:
            prefix += ['break *never', 'continue', 'delete breakpoints',
                       'set $pc = $lr & ~1']
        execute(Run(lane, run.tools), elf, prefix + [
            'break _landin_firmware_unhandled', 'continue', 'python',
            'assert v("$xpsr") & 511 == 3',
            'assert v("*(unsigned short*)*(unsigned*)($sp+24)") == 0xde01',
            'assert v("*(unsigned*)&later") == '+str(99 if mode == 10 else 0),
            'assert v("$sp") % 8 == 0 and v("$sp") >= 0x20003000',
            'assert v("$r9") == 0',
            'print("R670_PANIC_DEFAULT_PASS")', 'end'], 'R670_PANIC_DEFAULT_PASS')


def programs():
    corpus_inventory()
    result = {'cpu': (HERE / 'probes/core-cpu.ldn').read_text(),
              'pool': (HERE / 'probes/core-pool.ldn').read_text(),
              'zero': (HERE / 'probes/core-zero.ldn').read_text(),
              'vec': (HERE / 'probes/core-vec.ldn').read_text(),
              'noreturn': (HERE / 'probes/core-noreturn.ldn').read_text(),
              'panic': (HERE / 'probes/core-panic.ldn').read_text()}
    default = result['panic']
    first = default.index('public panic_handler:')
    last = default.index('end panic_handler', first)+len('end panic_handler')
    result['panic-default'] = (default[:first]+default[last:]).replace('import core/panic\n', '')
    dma = (HERE / 'probes/firmware-dma.ldn').read_text()
    changes = {
        'assembler.block("cpsid i")': 'saved_mask := cpu.disable_interrupts()',
        'assembler.block("cpsie i\\ndsb sy\\nisb sy")':
            'cpu.restore_interrupts(saved_mask)',
        'assembler.block("nop")': 'cpu.compiler_barrier()',
        'assembler.block("wfi")': 'cpu.wait_for_interrupt()',
        'compiler.device_barrier()': 'cpu.device_barrier()',
        'compiler.completion_barrier()': 'cpu.completion_barrier()',
    }
    for old, new in changes.items():
        require(old in dma, 'stale DMA library derivation: '+old)
        dma = dma.replace(old, new)
    result['dma'] = 'import core/cpu\n' + dma
    for name in ('core-mem-allocators', 'core-mem-arena-boundaries',
                 'core-mem-raw-storage'):
        fixture = ROOT / 'compiler/tests/fixtures/runtime' / name
        require('status: 42\n' in (fixture / 'fixture.meta').read_text(),
                'inherited fixture oracle changed')
        source = (ROOT / 'compiler/tests/cortex-m/cases' / name / 'main.ldn'
                  if name == 'core-mem-raw-storage' else fixture / 'main.ldn')
        result[name] = source.read_text() + '''
mut observed: u32 = 0
start: () -> none = observed = u32(main()) end start
'''
    return result


def execute_suite(parent, refine, profiles=PROFILES, cases=None):
    root = parent.out / 'freestanding'
    root.mkdir()
    refine = refine.resolve(strict=True)
    compiler_hash = sha(refine)
    parent.command('freestanding-refine-identity', [refine, '--identify'])
    controls = []
    selected = programs()
    if cases is not None:
        require(set(cases) <= selected.keys(), 'unknown freestanding case')
        selected = {name: selected[name] for name in cases}
    for optimize, specialize in profiles:
        profile = root / (optimize+'-'+specialize)
        profile.mkdir()
        for name, program in selected.items():
            out = profile / name
            out.mkdir()
            run = Run(out, parent.tools)
            elf = build(run, refine, program, optimize, specialize)
            (cpu if name == 'cpu' else dma_execute if name == 'dma' else
             nonreturning if name == 'noreturn' else
             panic if name == 'panic' else
             panic_default if name == 'panic-default' else memory)(run, elf)
            fresh = out / 'fresh'
            fresh.mkdir()
            build(Run(fresh, parent.tools), refine, program, optimize, specialize)
            suffixes = ('', '.o', '.s', '.ld', '.map')
            if name == 'panic':
                suffixes += ('.sources.json',)
            for suffix in suffixes:
                require((out / ('core.elf'+suffix)).read_bytes() ==
                        (fresh / ('core.elf'+suffix)).read_bytes(),
                        'nondeterministic freestanding artifact '+suffix)
            controls.append({'profile': profile.name, 'kind': name, 'status': 'passed',
                             'lane': 'renode' if name == 'dma' else 'qemu',
                             'artifact_comparisons': len(suffixes)})
            print('freestanding core: '+profile.name+'/'+name+' passed', flush=True)
    require(sha(refine) == compiler_hash, 'compiler changed')
    record = {'status': 'passed', 'compiler_sha256': compiler_hash,
              'controls': controls,
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
    tools_before = inventory(args.tools)
    args.output.mkdir(parents=True, exist_ok=False)
    record = {'status': 'failed', 'tools': tools_before,
              'scope': 'development freestanding library consumers; not acceptance'}
    try:
        record['freestanding'] = execute_suite(
            Run(args.output.resolve(), args.tools.resolve()), args.refine,
            PROFILES if args.all_profiles else PROFILES[:1], args.case)
        require(inventory(args.tools) == tools_before, 'embedded tool drift')
        record['status'] = 'passed'
    finally:
        record['files'] = {str(p.relative_to(args.output)): sha(p)
                          for p in sorted(args.output.rglob('*')) if p.is_file()}
        (args.output / 'result.json').write_text(json.dumps(record, indent=2)+'\n')
    print('DEVELOPMENT / NOT ACCEPTANCE: freestanding library controls passed')


if __name__ == '__main__':
    main()
