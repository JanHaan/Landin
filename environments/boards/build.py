#!/usr/bin/env python3
"""Build board images and compare hardware records, without accessing the rig.

    python3 environments/boards/build.py --refine REFINE --output NEW_DIRECTORY

The default builds all eight boot ports. --mode=both also prepares RAM images,
and the STM32H753's cached profile, which runs from SRAM alone, its RAM
image only (D975).
--records=report reports drift but fails only builds, for continuous coverage.
"""
import argparse
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
from types import SimpleNamespace

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))
import bundle  # noqa: E402
import common  # noqa: E402

BOARDS = ('rp2040', 'rp2350', 'rp2350_hazard3', 'stm32h753', 'stm32h753_cached', 'esp32c3',
          'esp32c5', 'esp32', 'esp32s3')
TARGETS = dict(rp2040=('cortex-m0', None), rp2350=('cortex-m0', 'armv8-m.main'),
               stm32h753=('cortex-m0', 'armv7e-m'), stm32h753_cached=('cortex-m0', 'armv7e-m'),
               rp2350_hazard3=('rv32', 'rv32imac'),
               esp32c3=('rv32', 'rv32imc'), esp32c5=('rv32', 'rv32imac'),
               esp32=('xtensa', 'xtensa-esp32'), esp32s3=('xtensa', 'xtensa-esp32s3'))
# The modes a board is built in, both but where this says: the cached
# profile has no boot check of its own, the cacheless port's being the
# board's, so it has no boot image and no resident image to restore.
MODES = dict(stm32h753_cached=('ram',))


def load(board):
    spec = importlib.util.spec_from_file_location('offline_' + board, HERE / board / 'board.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def tool(*names):
    for name in names:
        found = shutil.which(name)
        if found:
            return found
    raise common.Failed('no %s on PATH: enter the pinned Landin environment' % ' or '.join(names))


def image_name(board, mode):
    record = HERE / board / ('record.json' if mode == 'boot' else 'ram-record.json')
    name = json.loads(record.read_text()).get('image_name', 'board.elf') if record.is_file() else 'board.elf'
    if not isinstance(name, str) or not name or name in ('.', '..') or Path(name).name != name:
        raise bundle.Invalid('record image_name must be a filename: %s' % record)
    return name[:-4] if board.startswith('esp32') and name.endswith('.bin') else name


def prepare(board, mode, refine, output, source=None):
    """Call board-owned build checks and retain their host-independent inputs."""
    output = Path(output).resolve()
    bundle.check_output(output, ROOT)
    output.mkdir(parents=True, exist_ok=False)
    before = source if source is not None else bundle.source_identity(ROOT)
    compiler = dict(sha256=bundle.sha(refine), name=Path(refine).name)
    run = common.Run(output)
    arm = board in ('rp2040', 'rp2350', 'stm32h753', 'stm32h753_cached')
    prefix = ('arm-eabi-', 'arm-none-eabi-') if arm else ('riscv64-elf-', 'riscv64-unknown-elf-')
    if board in ('esp32', 'esp32s3'):
        prefix = ('xtensa-%s-elf-' % board,)
    args = SimpleNamespace(refine=Path(refine).resolve(), mode=mode, image_name=image_name(board, mode),
                           nm=tool(*(p + 'nm' for p in prefix)))
    if board in ('rp2350_hazard3', 'stm32h753', 'stm32h753_cached', 'esp32c3', 'esp32c5', 'esp32',
                 'esp32s3'):
        args.objdump = tool(*(p + 'objdump' for p in prefix))
    if board == 'stm32h753':
        args.readelf = tool(*(p + 'readelf' for p in prefix))
    module = load(board)
    files = {}
    if board.startswith('esp32'):
        import esp
        chip = module.CHIP() if hasattr(module, 'CHIP') else (
            module.C3() if board == 'esp32c3' else module.C5())
        elf, image, report = esp.build(run, args, chip)
        names = common.symbols(run, args.nm, elf)
        listing = esp.objdump(run, args, elf)
        (output / 'disassembly.txt').write_text(listing)
        checked = esp.check_image(chip, image.read_bytes(), elf, report) if image is not None else None
        metadata = dict(instructions=esp.instructions(chip, listing), image={})
        if checked is not None:
            metadata['image'] = {key: value.hex() if isinstance(value, bytes) else value
                                 for key, value in checked.items() if key != 'segments'}
            metadata['image']['segments'] = ['%#x+%#x' % (a, len(body)) for a, body in checked['segments']]
            files['image'] = image
    else:
        made = module.build(run, args)
        elf = made[0]
        if board == 'rp2040':
            _, stage, crc, names = made
            metadata = dict(stage=stage.hex(), crc=crc)
        elif board == 'rp2350':
            _, head, names = made
            metadata = dict(head=head.hex())
        elif board == 'rp2350_hazard3':
            _, head, names, adds = made
            metadata = dict(head=head.hex(), adds=adds)
        else:
            _, table, names, image = made
            metadata = dict(table=table.hex(), image=image)
    files.update(elf=elf, report=output / 'build.json')
    if 'boot' in MODES.get(board, ('boot', 'ram')):
        fixed_image(board, args, output, run, files)
    for name, filename in (('disassembly', 'disassembly.txt'),
                           ('disassembly_log', 'disassembly.log'),
                           ('attributes', 'attributes.log')):
        if (output / filename).is_file():
            files[name] = output / filename
    changed = changed_inputs(before, bundle.source_identity(ROOT), refine,
                             compiler['sha256'], bundle.sha(refine))
    if changed:
        raise bundle.Invalid(changed)
    return bundle.write(output, board, mode, files, metadata, names, compiler, before)


def changed_inputs(before, after, refine, compiler_before, compiler_after, shown=8):
    """What changed between a preparation's start and its end, as the
    refusal's text, or None: each source path that was changed, added or
    removed, the first SHOWN of them, with both source identities, and the
    compiler with both of its hashes."""
    said = []
    if after != before:
        was, now = before['files'], after['files']
        paths = ['%s %s' % ('added' if name not in was else
                            'removed' if name not in now else 'changed', name)
                 for name in sorted(set(was) | set(now)) if was.get(name) != now.get(name)]
        more = len(paths) - shown
        said.append('the source changed while building: %s%s (source identity %s when it began,'
                    ' %s now)' % (', '.join(paths[:shown]) or 'its identity alone',
                                  ' and %d more' % more if more > 0 else '',
                                  before['sha256'], after['sha256']))
    if compiler_after != compiler_before:
        said.append('the compiler %s changed while building (sha256 %s when it began, %s now)'
                    % (refine, compiler_before, compiler_after))
    return '; '.join(said) + '; prepare again' if said else None


def fixed_image(board, args, output, run, files):
    """The quiet resident image a boot check restores, never the
    application's, and the board's recovery images of it."""
    fixed = output / 'fixed.elf'
    target, level = TARGETS[board]
    roots = [ROOT / 'devices', ROOT / 'devices/generated', ROOT / 'compiler/tests/driver',
             ROOT / 'compiler/tests/board/fixed' / board]
    command = [args.refine] + ['--root=' + str(root) for root in roots]
    command += ['--target=' + target]
    if level:
        command.append('--level=' + level)
    command += ['--firmware-entry=start', '--emit=exe',
                '--build-report=' + str(output / 'fixed-build.json'),
                str(roots[-1] / 'app'), '-o', str(fixed)]
    run.command('compile-fixed', command)
    files.update(fixed_elf=fixed, fixed_image=fixed, fixed_report=output / 'fixed-build.json')
    if board.startswith('esp32'):
        files['fixed_image'] = fixed.with_name('fixed.elf.bin')
    if board in ('rp2350', 'rp2350_hazard3'):
        import uf2
        architecture = 'arm' if board == 'rp2350' else 'hazard3'
        recovery = output / 'fixed.uf2'
        recovery.write_bytes(uf2.convert(fixed, architecture))
        files['fixed_uf2'] = recovery
        if args.mode == 'boot':
            boot_uf2 = output / 'board.uf2'
            boot_uf2.write_bytes(uf2.convert(files['elf'], architecture))
            files['uf2'] = boot_uf2


def compare(manifest, directory, record):
    """Compare artifact hashes only; a source revision is not an image hash."""
    if not record.is_file():
        return ['no hardware record: %s' % record]
    kept = json.loads(record.read_text())
    artifact_name = 'image' if 'image' in manifest['files'] else 'elf'
    checks = [('image_sha256', artifact_name)]
    if artifact_name == 'image':
        checks.append(('elf_sha256', 'elf'))
    differences = []
    expected_name = kept.get('image_name', 'board.elf')
    actual_name = Path(manifest['files'][artifact_name]['path']).name
    if expected_name != actual_name:
        differences.append('image_name: record=%s built=%s' % (expected_name, actual_name))
    for field, name in checks:
        expected, actual = kept.get(field), manifest['files'][name]['sha256']
        if expected != actual:
            differences.append('%s: record=%s built=%s (%s)' % (field, expected, actual, directory / manifest['files'][name]['path']))
    return differences


def build_all(boards, modes, refine, output, records='strict'):
    output = Path(output).resolve()
    bundle.check_output(output, ROOT)
    output.mkdir(parents=True, exist_ok=False)
    source = bundle.source_identity(ROOT)
    results = []
    for board in boards:
        for mode in (m for m in modes if m in MODES.get(board, ('boot', 'ram'))):
            directory = output / board / mode
            try:
                manifest = prepare(board, mode, refine, directory, source)
                record = HERE / board / ('record.json' if mode == 'boot' else 'ram-record.json')
                differences = compare(manifest, directory, record)
                row = dict(board=board, mode=mode, status='mismatch' if differences else 'matches',
                           differences=differences, bundle=str(directory))
            except (common.Failed, bundle.Invalid, OSError, ValueError, subprocess.TimeoutExpired) as error:
                row = dict(board=board, mode=mode, status='failed', failure=str(error), bundle=str(directory))
            results.append(row)
            print('%s %s: %s' % (board, mode, row['status']))
            for detail in row.get('differences', [row['failure']] if 'failure' in row else []):
                print('  ' + detail)
    (output / 'summary.json').write_text(json.dumps(results, indent=2) + '\n')
    return int(any(row['status'] == 'failed' or (records == 'strict' and row['status'] == 'mismatch') for row in results))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--refine', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--board', choices=BOARDS, action='append', help='repeat to select boards; default all of them')
    parser.add_argument('--mode', choices=('boot', 'ram', 'both'), default='boot')
    parser.add_argument('--records', choices=('strict', 'report'), default='strict')
    args = parser.parse_args(argv)
    sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))
    import refine_revision
    refine_revision.warn(args.refine)  # is it this checkout's?
    try:
        return build_all(args.board or BOARDS, ('boot', 'ram') if args.mode == 'both' else (args.mode,),
                         args.refine, args.output, args.records)
    except (OSError, bundle.Invalid) as error:
        parser.error(str(error))


if __name__ == '__main__':
    sys.exit(main())
