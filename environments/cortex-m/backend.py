#!/usr/bin/env python3
"""Compiler-generated ARMv6-M execution through the external R6.50 harness.

This development selector is not the complete applicability/acceptance gate.
"""
import argparse
import json
import re
from pathlib import Path
import socket
import struct
import subprocess
import time

from run import FLAGS, Run, oracle, require, stop
from setup import DEFAULT, HERE, inventory, sha, supported_host

ROOT = HERE.parent.parent
COUNTERPARTS = ROOT / 'compiler/tests/cortex-m'


def metadata(path):
    result = {}
    for line in path.read_text().splitlines():
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        key, value = line.split(':', 1)
        require(key not in result, 'duplicate fixture key ' + key)
        result[key] = value.strip()
    return result


def execute(run, elf, expected, traps, before=()):
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    script = run.out / 'backend.gdb'
    script.write_text('\n'.join([
        'set pagination off', 'set confirm off',
        f'target remote 127.0.0.1:{port}', *before,
        'break backend_done', 'break backend_fault_done', 'continue',
        'python', 'import gdb',
        'def value(expr): return int(gdb.parse_and_eval(expr))',
        'assert value("*(unsigned int*)&backend_fault") == ' + ('3' if traps else '0'),
        ('assert value("$pc") == value("&backend_fault_done")' if traps else
         'assert value("$pc") == value("&backend_done")'),
        *(['assert value("*(unsigned short*)*(unsigned int*)($sp+24)") == 0xde01'] if traps else [
            f'assert value("*(unsigned int*)&backend_result") & 255 == {expected}',
            'assert value("*((unsigned int*)&backend_result+1)") == 0',
            'assert value("$sp") == 0x20004000', 'assert value("$r11") == 0',
            'assert [value("$r%d" % i) for i in range(4, 11)] == [44,55,66,77,88,99,100]']),
         'import json',
        'words=[value("*(unsigned int*)%d" % a) for a in range(0x20003000,0x20004000,4)]',
        'assert words[:4] == [0xa55ac33c]*4',
        'assert value("$sp") >= 0x20003000',
        'first=next((i for i,w in enumerate(words) if w != 0xa55ac33c), len(words))',
        f'with open({str(run.out / "stack-observation.json")!r}, "w") as f: json.dump({{"lowest_changed_word":0x20003000+4*first,"reserved_bytes":4096,"is_stack_bound":False}},f)',
        'print("R650_GENERATED_QEMU_PASS")', 'end', 'quit', '']))
    argv = [str(run.bin / 'qemu-system-arm'), '-M', 'microbit', '-accel',
            'tcg,thread=single', '-display', 'none', '-monitor', 'none',
            '-serial', 'none', '-kernel', str(elf), '-S', '-gdb',
            f'tcp:127.0.0.1:{port}']
    record = {'name': 'qemu-backend', 'argv': argv, 'timeout_seconds': 25}
    run.commands.append(record)
    tick = time.monotonic()
    with (run.out / 'qemu.log').open('wb') as log:
        process = subprocess.Popen(argv, cwd=run.out, env=run.env, stdout=log,
                                   stderr=log, start_new_session=True)
        try:
            deadline = time.monotonic() + 3
            while True:
                require(process.poll() is None, 'QEMU exited before connection')
                try:
                    with socket.create_connection(('127.0.0.1', port), timeout=.1):
                        break
                except OSError:
                    require(time.monotonic() < deadline, 'QEMU startup timeout')
                    time.sleep(.02)
            text = run.command('gdb-backend', [run.bin / 'gdb-multiarch', '-q',
                               '-nx', '-batch', elf, '-x', script], timeout=20)
            oracle(text, 'R650_GENERATED_QEMU_PASS')
        finally:
            stop(process)
            record['seconds'] = time.monotonic() - tick
            record['exit'] = process.returncode
            (run.out / 'commands.json').write_text(json.dumps(run.commands, indent=2)+'\n')


def preflight(assembly):
    """Bound materialization before invoking as, even for giant .rept images.

    This is a resource guard, not an encoding or physical-image verdict.
    The linker remains authoritative for the selected flash/RAM map.
    """
    total = 0
    nesting = []
    factor = 1
    for line in assembly.read_text().splitlines():
        text = line.strip()
        if text.startswith('.rept '):
            count = int(text.split()[1])
            nesting.append(factor)
            factor *= count
        elif text == '.endr':
            require(bool(nesting), 'unbalanced assembly repetition')
            factor = nesting.pop()
        elif text.startswith(('.zero ', '.space ')):
            total += factor * int(text.split()[1].split(',')[0])
        elif text.startswith(('.byte ', '.short ', '.long ', '.quad ', '.word ')):
            width = {'.byte': 1, '.short': 2, '.long': 4, '.quad': 8, '.word': 4}
            directive, values = text.split(None, 1)
            total += factor * width[directive] * len(values.split(','))
        elif text and not text.startswith(('.', '@')) and not text.endswith(':'):
            total += factor * 4
        require(total <= 8 * 1024 * 1024,
                'bounded assembly materialization exceeds 8 MiB')
    require(not nesting, 'unclosed assembly repetition')
    return total


def image_contract(path):
    """Independently read actual ELF LOAD extents, rather than trust a map label."""
    data = path.read_bytes()
    require(len(data) >= 52 and data[:6] == b'\x7fELF\x01\x01', 'expected little-endian ELF32')
    header = struct.unpack_from('<16sHHIIIIIHHHHHH', data)
    require(header[1:4] == (2, 40, 1) and header[8] == 52 and header[9] == 32,
            'unexpected ELF identity or program header')
    require(header[4] & 1 and header[4] < 32768, 'entry loses Thumb identity or flash bound')
    flash_end, ram_end, vectors = 0, 0x20000000, False
    for index in range(header[10]):
        offset = header[5] + index * 32
        require(offset + 32 <= len(data), 'truncated ELF program header')
        kind, file_at, virtual, physical, file_size, memory_size, _, _ = struct.unpack_from('<8I', data, offset)
        if kind != 1:
            continue
        require(file_size <= memory_size and file_at + file_size <= len(data), 'invalid ELF load extent')
        if virtual < 32768:
            require(virtual + memory_size <= 32768, 'ELF exceeds selected flash')
        else:
            require(0x20000000 <= virtual and virtual + memory_size <= 0x20003000,
                    'ELF intrudes on selected RAM/stack boundary')
            ram_end = max(ram_end, virtual + memory_size)
        if file_size:
            require(physical + file_size <= 32768, 'ELF load image exceeds selected flash')
            flash_end = max(flash_end, physical + file_size)
        if virtual == 0 and physical == 0:
            require(file_size >= 192, 'missing external vectors')
            require(struct.unpack_from('<II', data, file_at) == (0x20004000, header[4]),
                    'external initial SP/reset words disagree')
            vectors = True
    require(vectors, 'no external vector load segment')
    return {'flash_load_extent': flash_end, 'ram_static_extent': ram_end - 0x20000000,
            'stack_reserved': 4096, 'entry': header[4]}


def build(run, refine, inputs, optimize, specialize, extra=(), linker=None):
    assembly = run.out / 'program.s'
    run.command('compile', [refine, *inputs, '--target=cortex-m0', '--emit=asm',
                '--optimize=' + optimize, '--specialize=' + specialize,
                '-o', assembly, '--build-report=' + str(run.out / 'build.json')], timeout=60)
    preflight(assembly)
    report = json.loads((run.out / 'build.json').read_text())['build']
    require(all(r['frame_bytes'] <= 4096 for r in report['routines']),
            'routine frame exceeds selected 4 KiB test stack reservation')
    elf = run.out / 'program.elf'
    objects = []
    for index, source in enumerate([HERE / 'probes/backend-start.S', assembly, *extra]):
        obj = run.out / ('input-' + str(index) + '.o')
        run.command('assemble-' + str(index), [run.bin / 'arm-none-eabi-gcc', *FLAGS,
                    '-c', source, '-o', obj])
        objects.append(obj)
    run.command('object-disassembly', [run.bin / 'arm-none-eabi-objdump', '-dr', objects[1]])
    run.command('assemble-link', [run.bin / 'arm-none-eabi-gcc', *FLAGS,
                '-Wl,-T,' + str(linker or HERE / 'probes/backend-memory.ld') +
                ',--gc-sections,-Map,program.map', *objects, '-lgcc', '-o', elf])
    (run.out / 'image.json').write_text(json.dumps(image_contract(elf), indent=2)+'\n')
    attributes = run.command('elf', [run.bin / 'arm-none-eabi-readelf', '-h', '-A', '-S', elf])
    require('Tag_CPU_arch: v6S-M' in attributes and 'Tag_THUMB_ISA_use: Thumb-1' in attributes,
            'ELF does not describe the selected ARMv6-M profile')
    require('Tag_ARM_ISA_use: Yes' not in attributes and 'VFP registers' not in attributes,
            'ELF requires an unsupported instruction or floating ABI')
    run.command('disassembly', [run.bin / 'arm-none-eabi-objdump', '-dr', elf])
    run.command('size', [run.bin / 'arm-none-eabi-size', elf])
    require(not run.command('undefined', [run.bin / 'arm-none-eabi-nm', '-u', elf]).strip(),
            'freestanding test image has unresolved dependencies')
    library = Path(run.command('libgcc-path', [run.bin / 'arm-none-eabi-gcc',
                   '-mcpu=cortex-m0', '-mthumb', '-mfloat-abi=soft',
                   '-print-libgcc-file-name']).strip()).resolve(strict=True)
    require('/thumb/v6-m/nofp/' in str(library), 'wrong Arm runtime multilib')
    (run.out / 'helpers.json').write_text(json.dumps({
        'library': str(library), 'sha256': sha(library),
        'requested': sorted(set(re.findall(r'\bbl (__aeabi_\w+)', assembly.read_text()))),
        'unresolved': [], 'provenance': 'pinned gcc-arm-none-eabi_14.2.rel1-1',
    }, indent=2) + '\n')
    return elf


def fixture(run, refine, name, optimize, specialize):
    source = ROOT / 'compiler/tests/fixtures' / name
    meta = metadata(source / 'fixture.meta')
    require(meta['class'] == 'runtime', 'development selector requires runtime fixture')
    if meta.get('root'):
        inputs = ['--root=' + str((source / meta['root']).resolve()), str(source)]
    else:
        inputs = [str(source / meta['program'])]
        inputs += [str(source / p.strip()) for p in meta.get('with', '').split(',') if p.strip()]
    counterparts = json.loads((COUNTERPARTS / 'counterparts.json').read_text())['replacements']
    if source.name in counterparts:
        inputs = ['--root=' + str(ROOT), str(COUNTERPARTS / 'cases' / source.name)]
    require(not meta.get('args'), 'fixture has explicit compiler arguments')
    require(not meta.get('run_args') and not meta.get('run_expect'),
            'fixture requires hosted input/output')
    elf = build(run, refine, inputs, optimize, specialize)
    execute(run, elf, 1 if name == 'runtime/fixed-conditional-runtime' else
            int(meta.get('status', '0')), meta.get('traps') == 'yes')
    return {'fixture': name, 'optimize': optimize, 'specialize': specialize,
            'compiler_sha256': sha(refine), 'status': 'passed'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--refine', type=Path, required=True)
    parser.add_argument('--tools', type=Path, default=DEFAULT)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--fixture', action='append', required=True)
    parser.add_argument('--optimize', default='none', choices=['none', 'size', 'speed'])
    parser.add_argument('--specialize', default='off', choices=['off', 'auto', 'all'])
    args = parser.parse_args()
    supported_host()
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=False)
    tools_before = inventory(args.tools.resolve())
    results = []
    for name in args.fixture:
        output = args.output / name.replace('/', '--')
        output.mkdir(exist_ok=False)
        run = Run(output, args.tools.resolve())
        try:
            result = fixture(run, args.refine.resolve(), name,
                             args.optimize, args.specialize)
            result['artifacts'] = {str(p.relative_to(run.out)): sha(p)
                                   for p in sorted(run.out.rglob('*')) if p.is_file()}
            (run.out / 'result.json').write_text(json.dumps(result, indent=2)+'\n')
            print('DEVELOPMENT / FILTERED / NOT ACCEPTANCE: ' + name + ' passed', flush=True)
        except Exception as error:
            result = {'fixture': name, 'status': 'failed', 'error': str(error)}
            (run.out / 'failure.json').write_text(json.dumps(result, indent=2)+'\n')
            print('FAILED: ' + name + ': ' + str(error), flush=True)
        results.append(result)
    require(inventory(args.tools.resolve()) == tools_before, 'embedded tools changed')
    (args.output / 'result.json').write_text(json.dumps(
        {'scope': 'development-filtered', 'tools': tools_before, 'results': results},
        indent=2)+'\n')
    require(all(r['status'] == 'passed' for r in results), 'one or more fixtures failed')


if __name__ == '__main__':
    main()
