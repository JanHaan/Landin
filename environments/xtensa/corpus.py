#!/usr/bin/env python3
"""Execute the existing freestanding inventory on one pinned Xtensa configuration,
or with --program a program of your own."""
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
    SPECIALIZATION_PROFILES, CommandFailed, Run, build, configuration, disposition, execute,
    inventory, metadata, sha, workers)  # noqa: E402
from environments.xtensa.remote import observe  # noqa: E402
from environments.xtensa.tools import Tools  # noqa: E402


#  D986: what may stop a restriction, the shared inventory's own list.
sys.path.insert(0, str(ROOT / 'environments/cortex-m'))
from backend_corpus import STOPS, hosted_oracle, profile_name, program_names  # noqa: E402

#  The memory profile the gate's corpus runs at, and so the default: the
#  chips' own 128 KiB maps hold too little of the corpus to be its lane.
GATE_MEMORY_PROFILE = 'sim'

#  This target's own independent C controls, which an explanation of a
#  restriction or refusal points to rather than Cortex-M's.
C_CONTROLS = 'environments/xtensa/abi.py'


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
            if selected['mode'] == 'restriction' and selected.get('stops') not in STOPS:
                raise RuntimeError('target restriction names no stop of %s: %s'
                                   % (', '.join(STOPS), name))
            if not own.get('reason'):
                raise RuntimeError('target disposition has no explanation: ' + name)
    return result


def explained(row, chip, memory_profile, own):
    """A refusal's or restriction's explanation for this target: the
    selected configuration, the row's reason, its own where it has one, and
    this target's independent C controls."""
    selected = configuration(chip, memory_profile)
    return ('On Xtensa %s (%s, %s memory): %s Xtensa\'s independent C controls are %s.'
            % (chip, selected['cpu_level'], selected['memory_profile'],
               own.get('reason') or row.get('reason')
               or 'refine refuses it with %s.' % ', '.join(disposition(row).get('codes', [])),
               C_CONTROLS))


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
    run.command('compile-refusal', [refine, 'compile', *inputs, '--target=xtensa',
                '--level=xtensa-' + chip, '--emit=asm', '-o', run.out / 'refused.s'],
                expected=1)
    text = (run.out / 'compile-refusal.log').read_text()
    codes = sorted(set(re.findall(r'error\[(L\d+)\]', text)))
    if codes != sorted(row['codes']) or not codes:
        raise RuntimeError('source refusal differs: expected %s, observed %s; if Xtensa\'s'
                           ' verdict is its own, give the row "targets": {"xtensa": {"mode":'
                           ' "refuse", "codes": %s, "reason": ...}}; inspect %s'
                           % (row['codes'], codes, json.dumps(codes),
                              run.out / 'compile-refusal.log'))
    if (run.out / 'refused.s').exists():
        raise RuntimeError('a refused source wrote assembly')
    return {'verdict': 'source-refusal', 'codes': codes}


def c_stage(run, meta, chip):
    """Where an ABI fixture's C stops for CHIP, by the Cortex-M corpus's
    freestanding contract (D985) with the chip's pinned GCC: an option it
    refuses, a header no freestanding C has, or an error of its source;
    (None, []) when every source compiles."""
    gcc = 'xtensa-' + chip + '-elf-gcc'
    include = run.command('c-include-directory', [gcc, '-print-file-name=include']).strip()
    base = meta.directory
    compiler = [gcc, '-mabi=windowed', '-std=c11', '-nostdinc', '-ffreestanding',
                '-fno-builtin', '-O1', '-Wall', '-Wextra', '-Werror', '-isystem', include,
                '-I', base, *meta.c_args]
    for index, source in enumerate(meta.c_sources, start=1):
        for step, extra in (('headers', ['-M', '-MG']), ('compile', ['-c', '-o',
                                                                      run.out / 'c.o'])):
            name = '%s-%d' % (step, index)
            try:
                listed = run.command(name, [*compiler, *extra, base / source])
            except CommandFailed:
                text = (run.out / (name + '.log')).read_text()
                options = re.findall(r"unrecognized command-line option '(-[^']+)'", text)
                if options:
                    return 'c-options', sorted(set(options))
                error = next((line for line in text.splitlines() if 'error:' in line), text)
                return 'c-source', [error[error.find('error:'):].strip()]
            if step == 'headers':
                named = listed.replace('\\\n', ' ').split()[2:]
                missing = [one for one in named
                           if not Path(one).is_absolute() and not (base / one).exists()]
                if missing:
                    return 'c-headers', missing
    return None, []


def restriction(run, refine, name, meta, inputs, chip, row, memory_profile):
    """D986 on Xtensa: build the fixture as an execute row is and require it
    to stop where `stops` says: refine's compilation, the C sources by the
    freestanding contract with the chip's GCC, the link and the oracle.
    Xtensa's C ABI is disabled, so its corpus links no C peer, and a
    fixture refine refuses here needs a `targets.xtensa` refusal with its
    codes."""
    reached, found = None, []
    try:
        run.command('compile-restricted', [refine, 'compile', *inputs, '--target=xtensa',
                    '--level=xtensa-' + chip, '--emit=asm', '-o', run.out / 'restricted.s'])
    except Exception:
        text = (run.out / 'compile-restricted.log').read_text()
        said = next((line.strip() for line in text.splitlines()
                     if 'internal compiler defect' in line), None)
        if said is None:
            codes = sorted(set(re.findall(r'error\[(L\d+)\]', text)))
            raise RuntimeError(
                '%s: Xtensa refuses it with %s, so it is no restriction here: give its row'
                ' "targets": {"xtensa": {"mode": "refuse", "codes": %s, "reason": ...}};'
                ' inspect %s' % (name, ', '.join(codes) or 'no code', json.dumps(codes),
                                 run.out / 'compile-restricted.log')) from None
        reached, found = 'defect', [said]
    if reached is None and meta.c_sources:
        reached, found = c_stage(run, meta, chip)
        if reached is None:
            raise RuntimeError('%s: Xtensa compiles it and its C, and Xtensa\'s C ABI is'
                               ' disabled, so its corpus links no C peer; give its row a'
                               ' "targets": {"xtensa": ...} disposition' % name)
    if reached is None:
        try:
            build(run, refine, inputs, chip, memory_profile=memory_profile)
        except CommandFailed as error:
            text = Path(error.log).read_text()
            symbols = sorted(set(re.findall(r"undefined reference to `([^']+)'", text)))
            if error.name != 'link' or not symbols:
                raise
            reached, found = 'link', symbols
        else:
            said = hosted_oracle(meta)
            if not said:
                raise RuntimeError('%s: its restriction is stale on Xtensa: it builds and'
                                   ' links and needs nothing firmware lacks; give its row'
                                   ' "targets": {"xtensa": {"mode": "execute", "reason":'
                                   ' ...}}' % name)
            reached, found = 'oracle', [said]
    if reached != row['stops']:
        raise RuntimeError('%s: on Xtensa its build stops at %s (%s), and its row says'
                           ' "stops": "%s"; give its row "targets": {"xtensa": {"mode":'
                           ' "restriction", "stops": "%s", "reason": ...}}'
                           % (name, reached, '; '.join(found), row['stops'], reached))
    return {'verdict': 'target-restriction', 'stops': reached, 'stopped_by': found}


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


FRAME_BOUNDARY = "a single routine's frame exceeds the stack reservation"


def selected_frame_limit(run, row, error, chip, memory_profile):
    """A recorded limit that refine itself met: under the lane's firmware
    entry a routine whose frame the selected stack cannot hold is L0507,
    and that code alone, with no assembly written.  The Cortex-M lanes
    record the same frame from the build report, and no `refuse` row can
    hold it: a refusal is compiled without an entry, where L0507 is not
    given."""
    log = Path(error.log).read_text()
    codes = sorted(set(re.findall(r'error\[(L\d+)\]', log)))
    if codes != ['L0507'] or (run.out / 'program.s').exists():
        return None
    said = next(line.strip() for line in log.splitlines()
                if line.startswith('error[L0507]'))
    result = {'verdict': 'selected-image-limit', 'boundary': FRAME_BOUNDARY,
              'reason': row.get('reason', ''), 'codes': codes, 'diagnostic': said,
              'stack_bytes': configuration(chip, memory_profile)['stack_bytes'],
              'execution': 'not attempted: refine refuses the firmware build'}
    (run.out / 'selected-image-limit.json').write_text(json.dumps(result, indent=2) + '\n')
    return result


def selected_image_limit(run, row, error, chip, memory_profile):
    """Only a recorded limit plus actual independent link/section evidence,
    or refine's own refusal of a frame the stack cannot hold."""
    if row.get('profile_limit') != 'selected-image' or not isinstance(error, CommandFailed):
        return None
    if error.name == 'compile':
        return selected_frame_limit(run, row, error, chip, memory_profile)
    if error.name != 'link':
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


def capacity_advice(log, memory_profile):
    """What a capacity-only link failure with no recorded limit says: the
    profile whose map it did not fit, and the gate's where that differs."""
    if not capacity_only(log):
        return ''
    overflows = ', '.join('%s by %s bytes' % found for found in re.findall(
        r"region `(\w+)' overflowed by (\d+) bytes", log)) or 'its stack reservation'
    return ('; the image does not fit the %s memory profile\'s map: it overflows %s%s'
            % (memory_profile, overflows,
               '' if memory_profile == GATE_MEMORY_PROFILE else
               '; the gate\'s corpus runs --memory-profile=' + GATE_MEMORY_PROFILE))


def compile_advice(text):
    """What to do about an execute row refine did not compile, from its log.

    A diagnostic is a refusal, which a `targets.xtensa` row may record; an
    internal compiler defect is no verdict on the fixture, and a refusal
    row with no codes would only hide it, so it is named as refine's fault."""
    said = next((line.strip() for line in text.splitlines()
                 if 'internal compiler defect' in line), None)
    if said is not None:
        return ('; refine failed with an internal compiler defect, "%s": that is a'
                ' compiler fault to fix, not this fixture\'s verdict on Xtensa' % said)
    codes = sorted(set(re.findall(r'error\[(L\d+)\]', text)))
    if codes == ['L0507']:
        #  L0507 is given only under a firmware entry, and a refusal is
        #  compiled without one, so a refuse row with it never holds.
        return ('; a routine\'s frame does not fit this profile\'s stack (L0507), which'
                ' is a limit of the selected profile and no source refusal: give its row'
                ' "profile_limit": "selected-image" with a "reason", as'
                ' environments/cortex-m/README.md says')
    return ('; Xtensa refuses it with %s: if that is its verdict here,'
            ' give its row "targets": {"xtensa": {"mode": "refuse",'
            ' "codes": %s, "reason": ...}}'
            % (', '.join(codes) or 'no code', json.dumps(codes)))


def shard_of(text):
    """`I/N`, shard I of N, as (I, N), for argparse."""
    try:
        index, count = (int(part) for part in text.split('/'))
    except ValueError:
        index, count = 0, 0
    if not 1 <= index <= count:
        raise argparse.ArgumentTypeError('--shard needs I/N with 1 <= I <= N, such as 2/3')
    return index, count


def dealt(work, shard):
    """The I-th of N shares of WORK, dealt round the shards in its order."""
    return work[shard[0] - 1::shard[1]]


def scope_of(selected, profiles, locked, shard=(1, 1)):
    """The run's scope, as its head and last lines and result.json give it:
    COMPLETE only for every row and profile with the locked tools.  A shard
    of such a run is SHARD, and the N shards together are the COMPLETE run."""
    if selected or profiles:
        return 'FILTERED', 'FILTERED: %s%s' % (', '.join(
            ['--fixture ' + one for one in selected] + ['--profile ' + one for one in profiles]),
            '' if locked else ', with tools no --tools lock selected')
    if not locked:
        return 'UNLOCKED', ('UNLOCKED: every row, with tools no --tools lock selected;'
                            ' not COMPLETE')
    if shard[1] > 1:
        return 'SHARD', ('SHARD %d of %d: every row at every profile, with the locked tools,'
                         ' is COMPLETE only with the other shards' % shard)
    return 'COMPLETE', 'COMPLETE: every row at every profile, with the locked tools'


def execute_inventory(output, refine, qemu, chip, selected=(), profiles=(),
                      memory_profile=GATE_MEMORY_PROFILE, locked=True, shard=(1, 1)):
    """SHARD is (I, N): the runs are dealt round N shards in inventory order
    and the I-th share is made, so the N shards together are every run once."""
    original = rows()
    if set(selected) - original.keys():
        raise RuntimeError('unknown exact fixture: ' + ', '.join(sorted(
            set(selected) - original.keys())) + '; a fixture is a directory under'
            ' compiler/tests/fixtures with a row in ' + str(INVENTORY.relative_to(ROOT))
            + ', such as runtime/word-count; to run a program of your own, pass'
            ' --program PATH')
    profiles = [profile_name(one) for one in profiles]
    known = {'-'.join(p): p for p in PROFILES + SPECIALIZATION_PROFILES}
    if set(profiles) - known.keys():
        raise RuntimeError('unknown exact profile: ' + ', '.join(sorted(
            set(profiles) - known.keys())) + '; the profiles are ' + ', '.join(known))
    label, said = scope_of(selected, profiles, locked, shard)
    print('Xtensa corpus %s at %s memory: %s' % (chip, memory_profile, said), flush=True)
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
    listed = len(work)
    work = dealt(work, shard)

    def one(item):
        name, row, meta, inputs, opt, spec = item
        run = Run(output / (name.replace('/', '--') + '--' + opt + '-' + spec))
        record = {'fixture': name, 'chip': chip, 'optimize': opt, 'specialize': spec,
                  'configuration': configuration(chip, memory_profile)}
        try:
            own = original[name].get('targets', {}).get('xtensa', {})
            if row['mode'] == 'restriction':
                record.update(restriction(run, refine, name, meta, inputs, chip, row,
                                          memory_profile))
                record['reason'] = explained(original[name], chip, memory_profile, own)
            elif row['mode'] == 'refuse':
                record.update(refusal(run, refine, inputs, chip, row))
                record['reason'] = explained(original[name], chip, memory_profile, own)
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
                    said = str(error)
                    if isinstance(error, CommandFailed) and error.name == 'compile':
                        said += compile_advice(Path(error.log).read_text())
                    elif isinstance(error, CommandFailed) and error.name == 'link':
                        said += capacity_advice(Path(error.log).read_text(), memory_profile)
                    record.update(status='failed', error=said)
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
    summary = {'scope': label, 'scope_detail': said, 'locked_tools': locked,
               'shard': list(shard), 'runs_listed': listed,
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
    failed = sum(r['status'] != 'passed' for r in results)
    print('Xtensa corpus %s at %s memory %s%s: %s' % (
        chip, memory_profile, summary['status'],
        '' if not failed else ', %d of %d failed' % (failed, len(results)), said), flush=True)
    return summary


def describe_run(values):
    """What a program of one's own did, from the cells the oracle read."""
    if values.get('_landin_firmware_trap_count'):
        return 'trapped: cause %d at %#x%s' % (
            values['_landin_firmware_trap_cause'], values['_landin_firmware_trap_pc'],
            ', an ILL trap' if values.get('trap_instruction') == '000000' else '')
    status = values['_landin_xtensa_fixture_status']
    return 'returned %d' % (status - (1 << 32) if status & 0x80000000 else status)


def observe_programs(output, refine, qemu, chip, programs, profiles=(),
                     memory_profile=GATE_MEMORY_PROFILE, roots=()):
    """Run each of PROGRAMS, a source file or a module directory, at
    PROFILES on CHIP and say what it returned or where it trapped, as the
    Cortex-M corpus's --program does.

    No oracle is held: the status is printed, so a measured value comes back
    as a value; an image the profile's map cannot hold says by how much.
    The run fails only when a profile could not be built or run.  Nothing
    here is corpus evidence."""
    profiles = [profile_name(one) for one in profiles]
    known = {'-'.join(p): p for p in PROFILES + SPECIALIZATION_PROFILES}
    if set(profiles) - known.keys():
        raise RuntimeError('unknown profile: ' + ', '.join(sorted(
            set(profiles) - known.keys())) + '; the profiles are ' + ', '.join(known))
    paths = [Path(program).resolve(strict=True) for program in programs]
    print('Xtensa programs of your own on %s at %s memory: not corpus evidence'
          % (chip, memory_profile), flush=True)
    output.mkdir(parents=True, exist_ok=False)
    flags = ['--root=' + str(Path(root).resolve()) for root in roots]
    results = []
    for path, name in zip(paths, program_names(paths)):
        shown = path.name if name == path.stem else name
        for opt, spec in [known[one] for one in profiles] or PROFILES:
            run = Run(output / (name + '--' + opt + '-' + spec))
            result = {'program': str(path), 'name': shown, 'chip': chip, 'optimize': opt,
                      'specialize': spec, 'memory_profile': memory_profile}
            try:
                try:
                    elf, named = build(run, refine, [*flags, str(path)], chip, opt, spec,
                                       memory_profile)
                except CommandFailed as error:
                    advice = (capacity_advice(Path(error.log).read_text(), memory_profile)
                              if error.name == 'link' else '')
                    if not advice:
                        raise
                    result.update(status='does not fit', limit=advice[2:])
                    said = advice[2:].replace('the image ', '', 1)
                else:
                    seen = observe(qemu, chip, elf, named, run.out,
                                   memory_profile=memory_profile)
                    (run.out / 'observation.json').write_text(json.dumps(seen, indent=2) + '\n')
                    result.update(status='ran', values=seen['values'], image_sha256=sha(elf))
                    said = describe_run(seen['values'])
            except Exception as error:
                said = 'FAILED: ' + str(error)
                if isinstance(error, CommandFailed) and error.name == 'compile':
                    said += '; ' + next((line.strip() for line in Path(error.log).read_text()
                                         .splitlines() if line.startswith('error')), '')
                result.update(status='failed', error=said[len('FAILED: '):])
            print('Xtensa program: %s %s/%s %s' % (shown, opt, spec, said), flush=True)
            (run.out / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
            results.append(result)
    failed = [r for r in results if r['status'] == 'failed']
    summary = {'scope': 'programs of your own, not corpus evidence', 'chip': chip,
               'memory_profile': memory_profile,
               'configuration': configuration(chip, memory_profile),
               'compiler_sha256': sha(refine),
               'status': 'failed' if failed else 'passed', 'results': results}
    (output / 'result.json').write_text(json.dumps(summary, indent=2) + '\n')
    if failed:
        print('%d of the %d runs failed: %s' % (len(failed), len(results), ', '.join(
            '%s %s/%s' % (r['name'], r['optimize'], r['specialize']) for r in failed)),
            flush=True)
    return summary


def main():
    parser = argparse.ArgumentParser(
        description=__doc__,
        epilog='A run of every row at every profile with --tools is COMPLETE; one with'
               ' --fixture or --profile is FILTERED, and one with --qemu and no --tools is'
               ' UNLOCKED, each said in its first and last lines and in result.json.'
               ' --all --shard=I/N is SHARD, one of N shares that are COMPLETE together.'
               ' --program runs a source file or module directory of your own at the'
               ' corpus\'s profiles, or the --profiles named, and prints what it returned'
               ' or where it trapped; no oracle is held.')
    sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))
    import lane_refine  # the --refine every lane takes
    lane_refine.argument(parser)
    parser.add_argument('--qemu', type=Path,
                        help='the QEMU a run without --tools uses, its tools from PATH')
    parser.add_argument('--tools', type=Path,
                        help='the locked installation, which selects QEMU and the tools')
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--chip', choices=('esp32', 'esp32s3'), required=True)
    parser.add_argument('--memory-profile', choices=('chip', 'sim'),
                        default=GATE_MEMORY_PROFILE,
                        help='sim, the default and the gate\'s, is the selected CPU with'
                             ' virtual RAM; chip is the chip\'s own 128 KiB maps')
    parser.add_argument('--fixture', action='append', default=[],
                        help='a fixture directory under compiler/tests/fixtures with a row'
                             ' in the inventory, such as runtime/word-count; repeat for more')
    parser.add_argument('--profile', action='append', default=[],
                        help='none-off, size-off, size-auto, speed-auto, none-all or'
                             ' speed-all; none/off as the log prints it is the same profile;'
                             ' repeat for more')
    parser.add_argument('--all', action='store_true',
                        help='every row of the inventory')
    parser.add_argument('--shard', type=shard_of, default=(1, 1), metavar='I/N',
                        help='with --all, the I-th of N shares of its runs, dealt in'
                             ' inventory order; the N shards together are the complete run')
    parser.add_argument('--program', type=Path, action='append', default=[],
                        help='a .ldn file or module directory to run instead of the corpus;'
                             ' repeat for more')
    parser.add_argument('--root', action='append', default=[],
                        help='a module root for --program, passed to refine')
    args = parser.parse_args()
    if args.program and (args.all or args.fixture):
        parser.error('--program runs programs of your own; --fixture and --all select'
                     ' corpus rows')
    if args.root and not args.program:
        parser.error('--root is a module root for --program; a corpus row names its own')
    if args.shard[1] > 1 and (not args.all or args.fixture or args.profile):
        parser.error('--shard divides the complete run: give it with --all and without'
                     ' --fixture or --profile')
    if not args.all and not args.fixture and not args.program:
        parser.error('select exact --fixture names, request --all, or run --program PATH')
    tools = Tools(args.tools, args.qemu)
    try:
        if args.program:
            result = observe_programs(args.output, args.refine.resolve(), tools.qemu,
                                      args.chip, args.program, args.profile,
                                      args.memory_profile, args.root)
        else:
            result = execute_inventory(args.output, args.refine.resolve(), tools.qemu,
                                       args.chip, args.fixture, args.profile,
                                       args.memory_profile, locked=tools.root is not None,
                                       shard=args.shard)
    finally:
        if args.output.is_dir():
            tools.finish(args.output)
    return 0 if result['status'] == 'passed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
