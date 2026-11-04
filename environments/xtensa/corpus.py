#!/usr/bin/env python3
"""Execute the existing freestanding inventory on one pinned Xtensa configuration."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import re
import sys

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(HERE))
from environments.xtensa.backend import (COUNTERPARTS, INVENTORY, PROFILES,
    SPECIALIZATION_PROFILES, Run, disposition, execute, inventory, metadata, sha)  # noqa: E402


def rows():
    """Validate both the shared inventory and each explicit target override."""
    result = inventory()
    for name, row in result.items():
        for target, own in row.get('targets', {}).items():
            if target != 'xtensa' or own.get('mode', row['mode']) not in (
                    'execute', 'refuse', 'restriction'):
                raise RuntimeError('invalid target disposition: ' + name)
            selected = disposition(row, target)
            if selected['mode'] == 'refuse' and not selected.get('codes'):
                raise RuntimeError('target refusal has no diagnostic codes: ' + name)
            if not own.get('reason'):
                raise RuntimeError('target disposition has no explanation: ' + name)
    return result


def inputs_of(name, row):
    source = ROOT / 'compiler/tests/fixtures' / name
    meta = metadata(source / 'fixture.meta')
    inputs = meta.module_arguments(source)
    replacements = json.loads(COUNTERPARTS.read_text())['replacements']
    counterpart = row.get('counterpart')
    if counterpart:
        if counterpart not in replacements:
            raise RuntimeError('unregistered counterpart: ' + counterpart)
        inputs = ['--root=' + str(ROOT),
                  str(ROOT / 'compiler/tests/cortex-m/cases' / counterpart)]
    return meta, inputs


def refusal(run, refine, inputs, chip, row):
    run.command('compile-refusal', [refine, *inputs, '--target=xtensa',
                '--level=xtensa-' + chip, '--emit=asm', '-o', run.out / 'refused.s'],
                expected=1)
    text = (run.out / 'compile-refusal.log').read_text()
    codes = sorted(set(re.findall(r'error\[(L\d+)\]', text)))
    if codes != sorted(row['codes']) or not codes:
        raise RuntimeError('source refusal differs: expected %s, observed %s; inspect %s'
                           % (row['codes'], codes, run.out / 'compile-refusal.log'))
    if (run.out / 'refused.s').exists():
        raise RuntimeError('a refused source wrote assembly')
    return {'verdict': 'source-refusal', 'codes': codes}


def execute_inventory(output, refine, qemu, chip, selected=(), profiles=()):
    original = rows()
    if set(selected) - original.keys():
        raise RuntimeError('unknown exact fixture: ' + ', '.join(set(selected) - original.keys()))
    known = {'-'.join(p): p for p in PROFILES + SPECIALIZATION_PROFILES}
    if set(profiles) - known.keys():
        raise RuntimeError('unknown exact profile: ' + ', '.join(set(profiles) - known.keys()))
    output.mkdir(parents=True, exist_ok=False)
    work = []
    for name, shared in original.items():
        if selected and name not in selected:
            continue
        row = disposition(shared)
        meta, inputs = inputs_of(name, row)
        modes = PROFILES + (SPECIALIZATION_PROFILES
                            if meta.get('profiles') == 'specialization' else [])
        if row['mode'] != 'execute':
            modes = [('none', 'off')]
        elif profiles:
            modes = [mode for mode in modes if '-'.join(mode) in profiles]
        work += [(name, row, meta, inputs, opt, spec) for opt, spec in modes]

    def one(item):
        name, row, meta, inputs, opt, spec = item
        run = Run(output / (name.replace('/', '--') + '--' + opt + '-' + spec))
        record = {'fixture': name, 'chip': chip, 'optimize': opt, 'specialize': spec}
        try:
            if row['mode'] == 'restriction':
                witness = ROOT / row['witness']
                if not witness.is_file() or not row.get('reason'):
                    raise RuntimeError('target restriction has no retained witness and reason')
                record.update(verdict='target-restriction', reason=row['reason'],
                              witness_sha256=sha(witness))
            elif row['mode'] == 'refuse':
                record.update(refusal(run, refine, inputs, chip, row))
            else:
                if meta.get('args') or any(meta.get(key) for key in (
                        'run_args', 'run_files', 'run_expect', 'stdin')):
                    raise RuntimeError('execute row requires a hosted/compiler argument oracle')
                result = execute(run, refine, qemu, inputs, chip,
                                 expected=meta.status_at('xtensa-' + chip), traps=meta.traps,
                                 optimize=opt, specialize=spec)
                record.update(verdict='executed', image_sha256=result['image_sha256'],
                              values=result['values'])
            record['status'] = 'passed'
        except Exception as error:
            #  A failure remains a failure until an explicit inventory
            #  disposition describes and witnesses its actual boundary.
            record.update(status='failed', error=str(error))
        (run.out / 'verdict.json').write_text(json.dumps(record, indent=2) + '\n')
        return record

    jobs = int(__import__('os').environ.get('LANDIN_CORTEX_JOBS', '1'))
    if not 1 <= jobs <= 64:
        raise RuntimeError('LANDIN_CORTEX_JOBS must be 1 to 64')
    results = []
    with ThreadPoolExecutor(max_workers=jobs) as pool:
        for result in pool.map(one, work):
            results.append(result)
            print('Xtensa corpus %s %s %s/%s %s' % (
                chip, result['fixture'], result['optimize'], result['specialize'],
                result.get('verdict', 'FAILED: ' + result.get('error', ''))), flush=True)
    summary = {'scope': 'FILTERED' if selected or profiles else 'COMPLETE',
               'chip': chip, 'compiler_sha256': sha(refine),
               'inventory_sha256': sha(INVENTORY),
               'status': 'passed' if all(r['status'] == 'passed' for r in results) else 'failed',
               'results': results}
    (output / 'result.json').write_text(json.dumps(summary, indent=2) + '\n')
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--refine', required=True, type=Path)
    parser.add_argument('--qemu', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--chip', choices=('esp32', 'esp32s3'), required=True)
    parser.add_argument('--fixture', action='append', default=[])
    parser.add_argument('--profile', action='append', default=[])
    parser.add_argument('--all', action='store_true')
    args = parser.parse_args()
    if not args.all and not args.fixture:
        parser.error('select exact --fixture names or request --all')
    result = execute_inventory(args.output, args.refine.resolve(), args.qemu.resolve(),
                               args.chip, args.fixture, args.profile)
    return 0 if result['status'] == 'passed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
