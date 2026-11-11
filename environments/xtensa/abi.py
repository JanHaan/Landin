#!/usr/bin/env python3
"""Independent vendor-C layout and windowed carrier checks on both chips.

Only scalar Landin routines cross the C boundary. Native assembly peers
pin C aggregate transport; they do not admit Landin by-value C aggregates.
"""
import argparse
import json
from pathlib import Path
import re
import shutil
import sys

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(ROOT))
from environments.xtensa.backend import Run, description, sha, symbols, verify  # noqa: E402
from environments.xtensa.remote import observe  # noqa: E402
from environments.xtensa.tools import Tools  # noqa: E402

PEERS = ('abi_peer.c', 'abi_peer.S', 'abi_peer.ldn')
C_FLAGS = ('-mabi=windowed', '-std=c11', '-O2', '-ffreestanding',
           '-fno-builtin', '-fno-optimize-sibling-calls', '-Wall', '-Wextra', '-Werror')


def check_observation(result, expected):
    """Use the shared status/trap oracle; prove nonzero is rejected as zero."""
    verify(result, expected=expected)
    if expected:
        try:
            verify(result)
        except RuntimeError:
            return 'nonzero control rejected when zero was required'
        raise RuntimeError('the negative ABI control was accepted as zero')
    return 'zero status with no trap'


def build(run, refine, chip, failure=0):
    prefix = 'xtensa-' + chip + '-elf-'
    app = run.out / 'source/app'
    app.mkdir(parents=True)
    for name in PEERS:
        shutil.copy2(HERE / name, run.out / name)
    shutil.copy2(HERE / 'abi_peer.ldn', app / 'main.ldn')
    desc = run.out / 'source/descriptions/abi'
    desc.mkdir(parents=True)
    (desc / 'core.ldn').write_text(description(chip))
    (app / 'description.ldn').write_text('import descriptions/abi\n')
    base = [refine, '--root=' + str(run.out / 'source'), app,
            '--target=xtensa', '--level=xtensa-' + chip, '--firmware-layout=ram',
            '--firmware-entry=abi_entry', '--optimize=none', '--specialize=off']
    assembly = run.out / 'program.s'
    script = run.out / 'program.ld'
    run.command('landin', [*base, '--emit=asm', '-o', assembly])
    run.command('script', [*base, '--emit=linker-script', '-o', script])
    flags = [prefix + 'gcc', *C_FLAGS, '-DABI_FAILURE=' + str(failure)]
    c_source = run.out / 'abi_peer.c'
    c_asm = run.out / 'peer.s'
    run.command('vendor-c', [*flags, '-S', c_source, '-o', c_asm])
    # Record the compiler's supported scalar modes rather than pretending
    # that generic 128-bit vector storage is an unsigned __int128 integer.
    macros = run.command('vendor-macros', [prefix + 'gcc', '-mabi=windowed',
                                          '-dM', '-E', '-x', 'c', '/dev/null'])
    int128 = bool(re.search(r'^#define __SIZEOF_INT128__ 16$', macros, re.M))
    int128_source = run.out / 'int128.c'
    int128_source.write_text('typedef unsigned __int128 u128;\n'
        '_Static_assert(sizeof(u128) == 16 && _Alignof(u128) == 16, "u128 layout");\n')
    run.command('vendor-int128', [*flags, '-c', int128_source, '-o', run.out / 'int128.o'],
                expected=0 if int128 else 1)
    if not int128 and '__int128' not in (run.out / 'vendor-int128.log').read_text():
        raise RuntimeError('the unavailable int128 control has no type diagnostic')
    objects = []
    for name, source in (('landin', assembly), ('vendor', c_asm),
                         ('native', run.out / 'abi_peer.S')):
        obj = run.out / (name + '.o')
        run.command('assemble-' + name, [prefix + 'as', '--abi-windowed',
                    '--auto-litpools', '--longcalls', source, '-o', obj])
        objects.append(obj)
    elf = run.out / 'program.elf'
    run.command('link', [prefix + 'gcc', '-mabi=windowed', '-nostdlib',
                '-Wl,-T,' + str(script) + ',--gc-sections,-Map,program.map',
                '-o', elf, *objects, '-lgcc'])
    run.command('disassembly', [prefix + 'objdump', '-dr', elf])
    library = Path(run.command('libgcc', [prefix + 'gcc', '-mabi=windowed',
                                        '-print-libgcc-file-name']).strip())
    return elf, symbols(run, prefix, elf), {
        'unsigned_int128': '16-byte integer supported' if int128 else
            'vendor C refuses unsigned __int128; no such C integer ABI claimed',
        'unsigned_vector128': 'size and alignment are both 16 bytes',
        'library_sha256': sha(library), 'library': str(library)}


def execute(output, refine, qemu, chip, failure=0):
    run = Run(output)
    elf, named, facts = build(run, refine, chip, failure)
    observation = observe(qemu, chip, elf, named, run.out)
    (run.out / 'observation.json').write_text(json.dumps(observation, indent=2) + '\n')
    oracle = check_observation(observation, failure)
    result = {'status': 'passed', 'chip': chip, 'expected': failure,
              'oracle': oracle, 'facts': facts, 'observation': observation,
              'compiler_sha256': sha(refine), 'image_sha256': sha(elf),
              'peer_sha256': {name: sha(run.out / name) for name in PEERS},
              'runner_sha256': {name: sha(HERE / name) for name in
                                ('abi.py', 'backend.py', 'remote.py', 'tools.py')},
              'scope': 'C layout; C/native aggregate carriers and returns; '
                       'C to emitted Landin scalar integer/float calls only'}
    (run.out / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--refine', type=Path, required=True)
    parser.add_argument('--tools', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))
    import refine_revision
    refine_revision.warn(args.refine)  # is it this checkout's?
    tools = Tools(args.tools)
    args.output.mkdir(parents=True, exist_ok=False)
    try:
        results = [execute(args.output / (chip + ('--nonzero' if failure else '--zero')),
                           args.refine.resolve(), tools.qemu, chip, failure)
                   for chip in ('esp32', 'esp32s3') for failure in (0, 37)]
    finally:
        tools.finish(args.output)
    result = {'status': 'passed', 'scope': 'FILTERED independent C ABI probes',
              'results': results}
    (args.output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print('FILTERED Xtensa independent C ABI probes passed on both chips')


if __name__ == '__main__':
    main()
