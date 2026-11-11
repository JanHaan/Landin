#!/usr/bin/env python3
"""Prove the two assembler configurations and the bounded shared instruction path."""
import argparse
import json
from pathlib import Path
import re
import sys

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(ROOT))
from environments.xtensa.backend import (Run, build, sha, symbols, stage)  # noqa: E402
from environments.xtensa.remote import observe  # noqa: E402
from environments.xtensa.tools import Tools  # noqa: E402
from environments.xtensa.helpers import audit  # noqa: E402


def assemblers(output, refine):
    results = []
    instructions = {'integer-divide': 'quos a2, a3, a4',
                    'salt': 'salt a2, a3, a4',
                    'dfp-accelerator': 'rur.f64r_lo a2',
                    'optional-const16': 'const16 a2, 0'}
    selections = (('esp32', False), ('esp32s3', False), ('esp32', True))
    for chip, default in selections:
        label = chip + ('-default' if default else '')
        level = [] if default else ['--level=xtensa-' + chip]
        for name, instruction in instructions.items():
            accepts = (name == 'integer-divide' or
                       name == 'salt' and chip == 'esp32s3' or
                       name == 'dfp-accelerator' and chip == 'esp32')
            run = Run(output / (label + '--' + name))
            source = run.out / 'case.ldn'
            source.write_text('main: () -> (status: i32) =\n'
                              '    assembler.block("' + instruction + '")\n'
                              '    status = 0\nend main\n')
            assembly = run.out / 'program.s'
            staged = stage(run, [source], chip)
            run.command('compile', [refine, *staged, '--target=xtensa',
                        *level, '--emit=asm', '-o', assembly])
            tool = 'xtensa-' + chip + '-elf-'
            run.command('assemble', [tool + 'as', '--abi-windowed',
                        '--auto-litpools', '--longcalls', '-o', run.out / 'program.o',
                        assembly], expected=0 if accepts else 1)
            if not accepts and 'Error:' not in (run.out / 'assemble.log').read_text():
                raise RuntimeError('negative assembler control has no instruction error')
            results.append({'chip': chip, 'default_level': default, 'instruction': instruction,
                            'accepted': accepts, 'source_sha256': sha(source),
                            'assembly_sha256': sha(assembly)})
    for chip, default in selections:
        label = chip + ('-default' if default else '')
        level = [] if default else ['--level=xtensa-' + chip]
        run = Run(output / (label + '--generated-divide'))
        source = run.out / 'case.ldn'
        source.write_text('divide: (a: i32, b: i32) -> (r: i32) =\n'
                          '    r = a / b\nend divide\n'
                          'main: () -> (r: i32) =\n'
                          '    r = divide(42, 2) - 21\nend main\n')
        assembly = run.out / 'program.s'
        run.command('compile', [refine, *stage(run, [source], chip), '--target=xtensa',
                    *level, '--emit=asm', '-o', assembly])
        if not re.search(r'^\s*quos ', assembly.read_text(), re.M):
            raise RuntimeError('generated integer division has no native QUOS instruction')
        run.command('assemble', ['xtensa-' + chip + '-elf-as', '--abi-windowed',
                    '--auto-litpools', '--longcalls', '-o', run.out / 'program.o', assembly])
        results.append({'chip': chip, 'default_level': default,
                        'generated': 'checked signed integer division',
                        'accepted': True, 'assembly_sha256': sha(assembly)})
        absent = {'optional-const16': 'const16 a2, 0',
                  'other-configuration': ('salt a2, a3, a4' if chip == 'esp32'
                                          else 'rur.f64r_lo a2')}
        for name, instruction in absent.items():
            # Keep the accepted compiler artifact intact. This separate
            # negative control appends one valid but unavailable native
            # instruction to that exact generated source, without running it.
            negative = run.out / (name + '.s')
            negative.write_text(assembly.read_text() +
                                '\n.text\n.balign 4\n' + instruction + '\n')
            run.command('absent-' + name, ['xtensa-' + chip + '-elf-as',
                        '--abi-windowed', '--auto-litpools', '--longcalls', '-o',
                        run.out / (name + '.o'), negative], expected=1)
            if 'Error:' not in (run.out / ('absent-' + name + '.log')).read_text():
                raise RuntimeError('generated absence control has no instruction error')
            results.append({'chip': chip, 'default_level': default,
                            'generated': 'checked signed integer division',
                            'appended_instruction': instruction, 'accepted': False,
                            'accepted_source_sha256': sha(assembly),
                            'negative_source_sha256': sha(negative)})
    return results


def baseline(output, refine, qemu, control):
    source = ROOT / 'compiler/tests/xtensa' / (control + '.ldn')
    original = Run(output / (control + '--esp32'))
    elf, named = build(original, refine, [source], 'esp32')
    first = observe(qemu, 'esp32', elf, named, original.out)
    if first['values']['_landin_firmware_trap_count'] or first['values'][
            '_landin_xtensa_fixture_status']:
        raise RuntimeError('LX6 baseline control failed')
    other = Run(output / (control + '--esp32s3-map'))
    # Derive the S3 memory map from the identical source and compiler, then
    # link the actual original LX6 object into it. The S3 compilation's
    # object is retained for comparison but is not the object being run.
    build(other, refine, [source], 'esp32s3')
    other.command('strict-common-assemble', ['xtensa-esp32s3-elf-as',
        '--abi-windowed', '--auto-litpools', '--longcalls', '-o',
        other.out / 'common-check.o', original.out / 'program.s'])
    common = other.out / 'common-lx6.elf'
    other.command('link-common', ['xtensa-esp32s3-elf-gcc', '-mabi=windowed',
        '-nostdlib', '-Wl,-T,' + str(other.out / 'program.ld') + ',--gc-sections',
        '-o', common, original.out / 'program.o', '-lgcc'])
    other.command('common-disassembly', ['xtensa-esp32s3-elf-objdump', '-dr', common])
    # Audit instruction source, since objdump also decodes literal pool
    # data as instructions. The whole source passed both strict assemblers;
    # helpers come from the S3-specific library, not the LX6 library.
    if re.search(r'^\s*(?:(?:rur|wur)\.f64|ee\.)',
                 (original.out / 'program.s').read_text(), re.M):
        raise RuntimeError('common control contains a configuration-specific instruction')
    observed = observe(qemu, 'esp32s3', common,
                       symbols(other, 'xtensa-esp32s3-elf-', common), other.out)
    if observed['values']['_landin_firmware_trap_count'] or observed['values'][
            '_landin_xtensa_fixture_status']:
        raise RuntimeError('unchanged LX6 object failed on S3')
    return {'control': control, 'original_object_sha256': sha(original.out / 'program.o'),
            'shared_assembly_sha256': sha(original.out / 'program.s'),
            'esp32': first, 'esp32_object_on_esp32s3': observed,
            'helpers': json.loads((other.out / 'helpers.json').read_text()),
            'scope': 'only this emitted instruction path and the S3-selected helper library'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--refine', type=Path, required=True)
    parser.add_argument('--qemu', type=Path)
    parser.add_argument('--tools', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))
    import refine_revision
    refine_revision.warn(args.refine)  # is it this checkout's?
    tools = Tools(args.tools, args.qemu)
    args.output.mkdir(parents=True, exist_ok=False)
    result = {'status': 'passed', 'scope': 'FILTERED configuration controls',
              'assemblers': assemblers(args.output, args.refine.resolve()),
              'baseline': [baseline(args.output, args.refine.resolve(), tools.qemu, c)
                           for c in ('window-depth', 'scalars')],
              'helper_state': [audit(args.output / ('helper-state--' + chip),
                  args.output / ('window-depth--esp32' if chip == 'esp32' else
                                 'window-depth--esp32s3-map'), chip)
                  for chip in ('esp32', 'esp32s3')]}
    tools.finish(args.output)
    (args.output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print('FILTERED Xtensa strict assembler and shared-object controls passed')


if __name__ == '__main__':
    main()
