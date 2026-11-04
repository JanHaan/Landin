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
    SPECIALIZATION_PROFILES, CommandFailed, Run, configuration, disposition, execute,
    inventory, metadata, sha, workers)  # noqa: E402
from environments.xtensa.tools import Tools  # noqa: E402


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


def capacity_only(log):
    """Every linker diagnostic must describe capacity or its final consequence."""
    patterns = (
        r".+ section `[^']+' will not fit in region `(?:IRAM|DRAM)'",
        r"region `(?:IRAM|DRAM)' overflowed by \d+ bytes",
        r'DRAM RAM capacity exceeded: image overlaps the reserved \d+ KiB stack; '
        r'use --firmware-layout=boot for the board boot check')
    capacity = False
    for line in log.splitlines():
        if not line.strip():
            continue
        if line == 'collect2: error: ld returned 1 exit status':
            continue
        prefix, separator, diagnostic = line.partition(': ')
        tool = prefix.rsplit('/', 1)[-1]
        if (not separator or tool not in ('ld', 'ld.bfd')
                or not any(re.fullmatch(pattern, diagnostic) for pattern in patterns)):
            return False
        capacity = True
    return capacity


def selected_image_limit(run, row, error, chip, memory_profile):
    """Only a recorded limit plus actual independent link/section evidence."""
    if (row.get('profile_limit') != 'selected-image'
            or not isinstance(error, CommandFailed) or error.name != 'link'):
        return None
    log = Path(error.log).read_text()
    if not capacity_only(log):
        return None
    overflows = {name: int(size) for name, size in re.findall(
        r"region `(\w+)' overflowed by (\d+) bytes", log)}
    if ((not overflows and 'image overlaps the reserved' not in log)
            or set(overflows) - {'IRAM', 'DRAM'}):
        return None
    profile = configuration(chip, memory_profile)
    script = (run.out / 'program.ld').read_text()
    for name, region in profile['regions'].items():
        expected = r'^  %s \(\w+\) : ORIGIN = %d, LENGTH = %d$' % (
            name, region['origin'], region['bytes'])
        if not re.search(expected, script, re.M):
            return None
    mapping = (run.out / 'program.map').read_text()
    sections = {name: (int(address, 16), int(size, 16)) for name, address, size
                in re.findall(r'^(\.\S+)\s+0x([0-9a-f]+)\s+0x([0-9a-f]+)(?:\s|$)',
                              mapping, re.M)}
    roles = {'IRAM': ('.isr_vector', '.landin_entry', '.text', '.ramtext'),
             'DRAM': ('.rodata', '.data', '.bss')}
    regions = {}
    for name, members in roles.items():
        region = profile['regions'][name]
        present = [sections[part] for part in members if part in sections]
        if not present or any(address < region['origin'] for address, _ in present):
            return None
        minimum = max(address + size for address, size in present) - region['origin']
        reserved = profile['stack_bytes'] if name == 'DRAM' else 0
        regions[name] = {'minimum_bytes': minimum, 'region_bytes': region['bytes'],
                         'reserved_bytes': reserved, 'available_bytes': region['bytes'] - reserved}
    if not any(part['minimum_bytes'] > part['available_bytes'] for part in regions.values()):
        return None
    listing = run.command('limit-object-sections',
                          ['xtensa-' + chip + '-elf-objdump', '-h', run.out / 'program.o'])
    extents = {name: int(size, 16) for name, size in re.findall(
        r'^\s*\d+\s+(\S+)\s+([0-9a-f]+)\s+', listing, re.M)}
    if not extents:
        return None
    retained = []
    for name, size in extents.items():
        pattern = r'^ ' + re.escape(name) + r'\s+0x([0-9a-f]+)\s+0x([0-9a-f]+)\s+' + re.escape(
            str(run.out / 'program.o')) + r'$'
        for address, mapped_size in re.findall(pattern, mapping, re.M):
            address, mapped_size = int(address, 16), int(mapped_size, 16)
            if size != mapped_size:
                continue
            for region_name, region in profile['regions'].items():
                measured = regions[region_name]
                if (region['origin'] <= address < region['origin'] + measured['minimum_bytes']
                        and address + size > region['origin'] + measured['available_bytes']):
                    retained.append({'section': name, 'address': address, 'bytes': size,
                                     'region': region_name})
    if not retained:
        return None
    result = {'verdict': 'selected-image-limit', 'boundary': 'selected external linker map',
              'reason': row.get('reason', ''), 'regions': regions,
              'overflow_bytes': overflows, 'largest_object_section_bytes': max(extents.values()),
              'retained_object_sections_beyond_capacity': retained,
              'minimum_static_bytes': regions['DRAM']['minimum_bytes'],
              'execution': 'not attempted: the selected linker map cannot hold this image'}
    (run.out / 'selected-image-limit.json').write_text(json.dumps(result, indent=2) + '\n')
    return result


def execute_inventory(output, refine, qemu, chip, selected=(), profiles=(), memory_profile='chip'):
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
        record = {'fixture': name, 'chip': chip, 'optimize': opt, 'specialize': spec,
                  'configuration': configuration(chip, memory_profile)}
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
                                 expected=row.get('status', meta.status_at('xtensa-' + chip)),
                                 traps=meta.traps,
                                 optimize=opt, specialize=spec, memory_profile=memory_profile)
                record.update(verdict='executed', image_sha256=result['image_sha256'],
                              values=result['values'], qemu_command=result['qemu_command'])
            record['status'] = 'passed'
        except Exception as error:
            #  A failure remains a failure until an explicit inventory
            #  disposition describes and witnesses its actual boundary.
            try:
                limit = selected_image_limit(run, row, error, chip, memory_profile)
            except Exception as measurement_error:
                record.update(status='failed', error=str(error)
                              + '; image-limit measurement failed: ' + str(measurement_error))
            else:
                if limit is None:
                    record.update(status='failed', error=str(error))
                else:
                    record.update(status='passed', **limit)
        record['artifacts'] = {str(path.relative_to(run.out)): sha(path)
                               for path in sorted(run.out.rglob('*')) if path.is_file()}
        (run.out / 'verdict.json').write_text(json.dumps(record, indent=2) + '\n')
        return record

    jobs = workers()
    results = []
    with ThreadPoolExecutor(max_workers=jobs) as pool:
        for result in pool.map(one, work):
            results.append(result)
            print('Xtensa corpus %s %s %s/%s %s' % (
                chip, result['fixture'], result['optimize'], result['specialize'],
                result.get('verdict', 'FAILED: ' + result.get('error', ''))), flush=True)
    summary = {'scope': 'FILTERED' if selected or profiles else 'COMPLETE',
               'chip': chip, 'compiler_sha256': sha(refine),
               'configuration': configuration(chip, memory_profile),
               'memory_profile': memory_profile,
               'evidence_scope': configuration(chip, memory_profile)['evidence_scope'],
               'inventory_sha256': sha(INVENTORY), 'counterparts_sha256': sha(COUNTERPARTS),
               'status': 'passed' if all(r['status'] == 'passed' for r in results) else 'failed',
               'verdict_counts': {kind: sum(r.get('verdict', 'failed') == kind for r in results)
                                  for kind in sorted({r.get('verdict', 'failed') for r in results})},
               'results': results}
    (output / 'result.json').write_text(json.dumps(summary, indent=2) + '\n')
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--refine', required=True, type=Path)
    parser.add_argument('--qemu', type=Path)
    parser.add_argument('--tools', type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--chip', choices=('esp32', 'esp32s3'), required=True)
    parser.add_argument('--memory-profile', choices=('chip', 'sim'), default='chip')
    parser.add_argument('--fixture', action='append', default=[])
    parser.add_argument('--profile', action='append', default=[])
    parser.add_argument('--all', action='store_true')
    args = parser.parse_args()
    if not args.all and not args.fixture:
        parser.error('select exact --fixture names or request --all')
    if args.all and not args.fixture and not args.profile and args.tools is None:
        parser.error('a COMPLETE lane requires --tools DIRECTORY with its locked installation')
    tools = Tools(args.tools, args.qemu)
    try:
        result = execute_inventory(args.output, args.refine.resolve(), tools.qemu,
                                   args.chip, args.fixture, args.profile, args.memory_profile)
    finally:
        if args.output.is_dir():
            tools.finish(args.output)
    return 0 if result['status'] == 'passed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
