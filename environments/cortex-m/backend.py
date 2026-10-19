#!/usr/bin/env python3
"""Compiler-generated ARMv6-M execution through the external test harness.

This development selector is not the complete applicability/acceptance gate.
"""
import argparse
import json
import re
from pathlib import Path
import struct
import subprocess
import time

from run import FLAGS, CommandFailed, Run, gdb_listener, oracle, require, stop
from setup import DEFAULT, HERE, installed_tools, inventory, sha, supported_host

ROOT = HERE.parent.parent
COUNTERPARTS = ROOT / 'compiler/tests/cortex-m'

#  The CPU feature levels (D255) the corpus executes beyond Armv6-M, each
#  with the processor arguments the external harness assembles and links
#  with, the libgcc multilib that selects, the ELF attributes the image must
#  carry and the QEMU machine that executes it.  QEMU's micro:bit is a
#  Cortex-M0 whatever -cpu says, so a higher level runs on the MPS2 AN385's
#  Cortex-M3, from the same locked binary; its RAM sits where the selected
#  map puts it, and only the corpus runs there, because the synthetic
#  peripheral windows are real devices on that board.
LEVELS = {
    'armv6-m': {'flags': ['-mcpu=cortex-m0'], 'multilib': '/thumb/v6-m/nofp/',
                'attributes': ['Tag_CPU_arch: v6S-M', 'Tag_THUMB_ISA_use: Thumb-1'],
                'machine': 'microbit'},
    'armv7-m': {'flags': ['-march=armv7-m'], 'multilib': '/thumb/v7-m/nofp/',
                'attributes': ['Tag_CPU_arch: v7', 'Tag_CPU_arch_profile: Microcontroller',
                               'Tag_THUMB_ISA_use: Thumb-2'],
                'machine': 'mps2-an385'},
}


def level_flags(level):
    """FLAGS with the processor argument the level selects."""
    require(level in LEVELS, 'unknown Cortex level: ' + level)
    return LEVELS[level]['flags'] + [f for f in FLAGS if not f.startswith('-mcpu=')]


def metadata(path):
    result = {}
    for line in path.read_text().splitlines():
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        key, value = line.split(':', 1)
        require(key not in result, 'duplicate fixture key ' + key)
        result[key] = value.strip()
    return result


def execute(run, elf, expected, traps, before=(), level='armv6-m'):
    listener, port, stub = gdb_listener()
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
         'import json, struct',
        #  One 4 KiB read rather than 1,024 one-word round trips to the stub.
        'words=list(struct.unpack("<1024I", bytes(gdb.selected_inferior().read_memory(0x20003000, 4096))))',
        'assert words[:4] == [0xa55ac33c]*4',
        'assert value("$sp") >= 0x20003000',
        'first=next((i for i,w in enumerate(words) if w != 0xa55ac33c), len(words))',
        f'with open({str(run.out / "stack-observation.json")!r}, "w") as f: json.dump({{"lowest_changed_word":0x20003000+4*first,"reserved_bytes":4096,"is_stack_bound":False}},f)',
        'print("R650_GENERATED_QEMU_PASS")', 'end', 'quit', '']))
    argv = [str(run.bin / 'qemu-system-arm'), '-M', LEVELS[level]['machine'], '-accel',
            'tcg,thread=single', '-display', 'none', '-monitor', 'none',
            '-serial', 'none', '-kernel', str(elf), '-S', *stub]
    record = {'name': 'qemu-backend', 'argv': argv, 'timeout_seconds': 25}
    run.commands.append(record)
    tick = time.monotonic()
    with (run.out / 'qemu.log').open('wb') as log:
        with listener:
            process = subprocess.Popen(argv, cwd=run.out, env=run.env, stdout=log,
                                       stderr=log, start_new_session=True,
                                       pass_fds=(listener.fileno(),))
        try:
            #  The stub's socket is listening before QEMU starts, so GDB's
            #  connection waits in its backlog rather than racing the start.
            require(process.poll() is None, 'QEMU exited before connection')
            try:
                text = run.debug('gdb-backend', elf, script, timeout=SESSION_LIMIT)
            except CommandFailed as error:
                if error.ended.startswith('timed out'):
                    raise timed_out(error, process, time.monotonic() - tick) from None
                raise
            oracle(text, 'R650_GENERATED_QEMU_PASS')
        finally:
            stop(process)
            record['seconds'] = time.monotonic() - tick
            record['exit'] = process.returncode
            (run.out / 'commands.json').write_text(json.dumps(run.commands, indent=2)+'\n')


#  How long one program may take, from GDB connecting to its result
#  breakpoint, under single-threaded QEMU.
SESSION_LIMIT = 20


def timed_out(error, process, elapsed):
    """A debugger session's timeout, saying whose time ran out.

    QEMU still running when the session ends means the program never
    reached either result breakpoint: the fixture, not the debugger, took
    longer than the limit.  An emulator that had already exited is the
    other case, and says so.
    """
    if process.poll() is None:
        return RuntimeError(
            'the program ran for %.1f s under QEMU and reached neither backend_done nor '
            'backend_fault_done within the debugger\'s %d-second session limit: the fixture '
            'takes longer than a corpus program may; inspect %s'
            % (elapsed, SESSION_LIMIT, error.log))
    return RuntimeError(
        'QEMU exited with status %s %.1f s after it started, before the program reached a '
        'result breakpoint, and the %d-second debugger session ran out waiting; inspect %s'
        % (process.returncode, elapsed, SESSION_LIMIT, error.log))


#  The regions the external harness's map gives a program: 32 KiB of
#  flash, and 16 KiB of RAM of which the top 4 KiB is the stack.
REGIONS = {'FLASH': 32768, 'RAM': 12288}


def load_extents(path):
    """Flash and static RAM a linked image occupies, read from its LOAD headers.

    Unlike image_contract this holds the image to no bound, so it measures
    an image linked with the enlarged map as well as a fitting one.
    """
    data = path.read_bytes()
    header = struct.unpack_from('<16sHHIIIIIHHHHHH', data)
    flash, ram = 0, 0
    for index in range(header[10]):
        kind, _, virtual, physical, file_size, memory_size, _, _ = struct.unpack_from(
            '<8I', data, header[5] + index * 32)
        if kind != 1:
            continue
        if file_size:
            flash = max(flash, physical + file_size)
        if virtual >= 0x20000000:
            ram = max(ram, virtual + memory_size - 0x20000000)
    return {'FLASH': flash, 'RAM': ram}


def routine_sizes(listing):
    """Each routine's bytes, largest first, from `nm -S --defined-only`.

    A routine is a sized symbol in a code section, `T` or `t`; Thumb
    addresses and the vector table's words are not routines and have no
    size there.  Equal sizes keep the order of their names.
    """
    sizes = {}
    for line in listing.splitlines():
        parts = line.split()
        if len(parts) == 4 and parts[2] in ('T', 't'):
            sizes[parts[3]] = int(parts[1], 16)
    return dict(sorted(sizes.items(), key=lambda item: (-item[1], item[0])))


def image_sizes(run, elf, name='sections'):
    """Each region's use against its limit, each allocated section's size
    and each routine's, so where an image's bytes go is read from the
    corpus rather than from hand-run tools, overflowing or not."""
    listing = run.command(name, [run.bin / 'arm-none-eabi-size', '-A', elf])
    sections = {}
    for line in listing.splitlines():
        parts = line.split()
        if len(parts) == 3 and parts[0].startswith('.') and parts[1].isdigit():
            if parts[0] in ('.isr_vector', '.text', '.data', '.bss') and int(parts[1]):
                sections[parts[0]] = int(parts[1])
    routines = routine_sizes(run.command(
        name + '-routines', [run.bin / 'arm-none-eabi-nm', '-S', '--defined-only', elf]))
    used = load_extents(elf)
    return {'regions': {region: {'used': used[region], 'limit': limit}
                        for region, limit in REGIONS.items()},
            'sections': sections, 'routines': routines}


def describe_routines(sizes, count=3):
    """The largest routines of an image, for a corpus line; "" without any."""
    routines = list(sizes.get('routines', {}).items())[:count]
    if not routines:
        return ''
    return 'largest routines ' + ', '.join('%s %d' % item for item in routines)


def describe_sizes(sizes):
    """One corpus-line clause: every region against its limit, and its sections."""
    members = {'FLASH': ('.isr_vector', '.text', '.data'), 'RAM': ('.data', '.bss')}
    parts = []
    for region, record in sizes['regions'].items():
        text = '%s %d of %d' % (region, record['used'], record['limit'])
        if record['used'] > record['limit']:
            text += ', over by %d' % (record['used'] - record['limit'])
        inside = ['%s %d' % (section, sizes['sections'][section])
                  for section in members[region] if section in sizes['sections']]
        if inside:
            text += ' (' + ', '.join(inside) + ')'
        parts.append(text)
    return '; '.join(parts)


def measure_overflow(run, level='armv6-m'):
    """The sizes an image that overflowed the map would have had.

    The objects the failed link left are relinked against a copy of the
    probe's map with both regions enlarged and the stack reservation's
    assertion removed.  The result is a measurement and never runs.
    """
    text = (HERE / 'probes/backend-memory.ld').read_text()
    for old, new in (('LENGTH = 32K', 'LENGTH = 256M'), ('LENGTH = 16K', 'LENGTH = 256M')):
        require(old in text, 'the probe map no longer says ' + old)
        text = text.replace(old, new)
    text = '\n'.join(line for line in text.splitlines()
                     if not line.startswith('ASSERT(__bss_end'))
    script = run.out / 'measure-memory.ld'
    script.write_text('/* Measurement only: never executed. */\n' + text + '\n')
    objects = sorted(run.out.glob('input-*.o'), key=lambda p: int(p.stem.split('-')[1]))
    elf = run.out / 'measure.elf'
    run.command('measure-link', [run.bin / 'arm-none-eabi-gcc', *level_flags(level),
                '-Wl,-T,' + str(script) + ',--gc-sections', *objects, '-lgcc', '-o', elf])
    return image_sizes(run, elf, 'measure-sections')


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


def build(run, refine, inputs, optimize, specialize, extra=(), linker=None,
          level='armv6-m'):
    flags = level_flags(level)
    selected = [] if level == 'armv6-m' else ['--level=' + level]
    assembly = run.out / 'program.s'
    run.command('compile', [refine, *inputs, '--target=cortex-m0', *selected, '--emit=asm',
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
        run.command('assemble-' + str(index), [run.bin / 'arm-none-eabi-gcc', *flags,
                    '-c', source, '-o', obj])
        objects.append(obj)
    run.command('object-disassembly', [run.bin / 'arm-none-eabi-objdump', '-dr', objects[1]])
    run.command('assemble-link', [run.bin / 'arm-none-eabi-gcc', *flags,
                '-Wl,-T,' + str(linker or HERE / 'probes/backend-memory.ld') +
                ',--gc-sections,-Map,program.map', *objects, '-lgcc', '-o', elf])
    image = image_contract(elf)
    image.update(image_sizes(run, elf))
    (run.out / 'image.json').write_text(json.dumps(image, indent=2)+'\n')
    attributes = run.command('elf', [run.bin / 'arm-none-eabi-readelf', '-h', '-A', '-S', elf])
    require(all(tag in attributes for tag in LEVELS[level]['attributes']),
            'ELF does not describe the selected ' + level + ' profile')
    require('Tag_ARM_ISA_use: Yes' not in attributes and 'VFP registers' not in attributes,
            'ELF requires an unsupported instruction or floating ABI')
    run.command('disassembly', [run.bin / 'arm-none-eabi-objdump', '-dr', elf])
    run.command('size', [run.bin / 'arm-none-eabi-size', elf])
    require(not run.command('undefined', [run.bin / 'arm-none-eabi-nm', '-u', elf]).strip(),
            'freestanding test image has unresolved dependencies')
    library = Path(run.command('libgcc-path', [run.bin / 'arm-none-eabi-gcc',
                   *LEVELS[level]['flags'], '-mthumb', '-mfloat-abi=soft',
                   '-print-libgcc-file-name']).strip()).resolve(strict=True)
    require(LEVELS[level]['multilib'] in str(library), 'wrong Arm runtime multilib')
    (run.out / 'helpers.json').write_text(json.dumps({
        'library': str(library), 'sha256': sha(library),
        'requested': sorted(set(re.findall(r'\bbl (__aeabi_\w+)', assembly.read_text()))),
        'unresolved': [], 'provenance': 'pinned gcc-arm-none-eabi_14.2.rel1-1',
    }, indent=2) + '\n')
    return elf


def fixture(run, refine, name, optimize, specialize, level='armv6-m',
            include_compiler_sha256=True):
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
    require(not meta.get('run_args') and not meta.get('run_expect')
            and not meta.get('stdin'),
            'fixture requires hosted input/output')
    elf = build(run, refine, inputs, optimize, specialize, level=level)
    execute(run, elf, 1 if name == 'runtime/fixed-conditional-runtime' else
            int(meta.get('status', '0')), meta.get('traps') == 'yes', level=level)
    result = {'fixture': name, 'optimize': optimize, 'specialize': specialize,
              'status': 'passed'}
    if include_compiler_sha256:
        result['compiler_sha256'] = sha(refine)
    return result


def levels_of(meta):
    """The M-profile levels a fixture's `levels:` names beyond the default."""
    named = [one.strip() for one in meta.get('levels', '').split(',') if one.strip()]
    return [one for one in named if one in LEVELS]


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
    args.tools = installed_tools(args.tools)
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
