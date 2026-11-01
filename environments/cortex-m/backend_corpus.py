"""Complete inventoried Cortex-M corpus, with explicit target/image dispositions.

corpus.json is the executable selection record and says why each shared
fixture runs or does not; physical limits are retained as limits, never as
successful executions.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import re
import sys

from backend import (BOOT_PREFIX, BOOT_SUFFIX, HERE, LEVELS, ROOT, COUNTERPARTS, DESCRIPTIONS,
                     MATERIALIZATION, REFERENCE, THUMB_2, ImageLimit, build, derived,
                     describe_routines, describe_sizes,
                     execute as qemu, fixture, harness_start, image_contract, image_sizes,
                     hard_float, lane_inputs, lane_of, level_flags, levels_of, link,
                     measure_overflow, metadata, refine_level, region)
from run import CommandFailed, Run, require, workers
from setup import DEFAULT, installed_tools, sha, supported_host

PROFILES = [('none', 'off'), ('size', 'off'), ('size', 'auto'), ('speed', 'auto')]
#  Each emulator lane the whole inventory also runs on alone, a profile of
#  descriptions.json's `lanes`, and the key of backend.LEVELS that builds
#  and runs it there (D607, D619).
LANES = {LEVELS[key]['profile']: key for key in LEVELS if lane_of(key)}
SPECIALIZATION_PROFILES = [('none', 'all'), ('speed', 'all')]
INVENTORY = 'compiler/tests/cortex-m/corpus.json'
RULES = 'environments/cortex-m/README.md#the-corpus-inventory'


def profile_name(text):
    """A --profile as either spelling: `none-off`, or `none/off` as the log prints it."""
    return text.replace('/', '-')


def inventory():
    record = json.loads((COUNTERPARTS / 'corpus.json').read_text())
    require(record['schema'] == 1, 'unknown Cortex corpus schema')
    rows = record['fixtures']
    actual = {str(p.parent.relative_to(ROOT / 'compiler/tests/fixtures'))
              for kind in ('runtime', 'abi')
              for p in (ROOT / 'compiler/tests/fixtures' / kind).glob('*/fixture.meta')}
    missing, stale = sorted(actual - set(rows)), sorted(set(rows) - actual)
    require(not missing and not stale, '\n'.join(
        ['Cortex corpus inventory %s disagrees with the shared fixtures:' % INVENTORY]
        + ['  %s has no row; python3 scripts/add_fixture.py %s writes it, or add'
           ' "%s": {"mode": "execute"} if it runs on Cortex-M0, or a "refuse" or'
           ' "restriction" row with its reason (see %s)' % (name, name, name, RULES)
           for name in missing]
        + ['  %s has a row and no fixture; remove the row' % name for name in stale]))
    changes = json.loads((COUNTERPARTS / 'counterparts.json').read_text())['replacements']
    require(set(changes) == {r['counterpart'] for r in rows.values() if 'counterpart' in r},
            'Cortex counterpart inventory disagrees')
    for name, replacements in changes.items():
        source = (ROOT / 'compiler/tests/fixtures/runtime' / name / 'main.ldn').read_text()
        for old, new in replacements:
            require(old in source, 'stale counterpart source difference: ' + name)
            source = source.replace(old, new)
        expected = '-- Cortex-M0 counterpart: the original hosted fixture remains unchanged.\n' + source
        require((COUNTERPARTS / 'cases' / name / 'main.ldn').read_text() == expected,
                'unreviewed counterpart change: ' + name)
    hosted = []
    for name, row in rows.items():
        require(row['mode'] in ('execute', 'refuse', 'restriction'), 'unknown corpus disposition')
        #  D619: a lane's own disposition of a row: a restriction of an
        #  execute row, which the lane still runs and requires to fail, so a
        #  stale one is found, or the codes a refuse row is refused with on
        #  that lane's level and map, where they differ from the reference's.
        for lane, own in row.get('lanes', {}).items():
            require(lane in LANES and bool(own.get('reason')) and (
                        (row['mode'] == 'execute' and own.get('mode') == 'restriction')
                        or (row['mode'] == 'refuse' and own.get('mode') == 'refuse'
                            and bool(own.get('codes')) and own['codes'] != row['codes'])),
                    '%s: a "lanes" entry names a corpus lane (%s) and its reason, with'
                    ' "mode": "restriction" for an execute row, or "mode": "refuse" and the'
                    ' lane\'s own "codes" for a refuse row (see %s)'
                    % (name, ', '.join(LANES), RULES))
        meta = metadata(ROOT / 'compiler/tests/fixtures' / name / 'fixture.meta')
        if row['mode'] == 'execute' and (said := hosted_oracle(meta)):
            hosted.append('  %s %s' % (name, said))
        #  A source refusal on namespace availability alone explains
        #  itself: the corpus reads the refused imports from it.
        if (row['mode'] != 'execute' or 'profile_limit' in row) and not namespace_only(row):
            require(bool(row.get('reason')), 'unexplained corpus exclusion: ' + name)
        if 'selects' in row:
            require(row['mode'] == 'execute', '%s: only an execute row selects' % name)
            levels = set(row['selects']) - {'routine'}
            require(levels and levels <= set(LEVELS)
                    and all(set(row['selects'][one]) <= {'has', 'lacks'} for one in levels),
                    '%s: a row\'s selects names a routine and, for M-profile levels %s,'
                    ' what it has and lacks (see %s)' % (name, ', '.join(LEVELS), RULES))
        if row['mode'] == 'restriction':
            witness = ROOT / row['witness']
            require(witness.is_file(), 'missing restriction witness')
            if name.startswith('abi/'):
                meta = metadata(witness)
                require(meta['class'] == 'abi' and meta.get('c-sources'), 'C peer restriction changed')
            else:
                require('extern(c)' in witness.read_text(), 'hosted heap restriction changed')
    #  Firmware has no standard input, arguments, files or output to give a
    #  program, so one whose oracle needs them never executes: refused
    #  before anything builds, every one at once, with the two ways out.
    require(not hosted, '\n'.join(
        ['Cortex corpus inventory %s has execute rows firmware cannot run:' % INVENTORY]
        + hosted + ['Firmware gives a program no standard input, arguments, files or output,'
                    ' and a counterpart cannot help, since the original\'s metadata is read.'
                    ' Give each fixture a status oracle, or write a "refuse" row with the'
                    ' codes Cortex-M0 refuses it with or a "restriction" row with its reason'
                    ' (see %s)' % RULES]))
    return rows


#  What a fixture's metadata asks of a hosted run that firmware cannot give.
HOSTED_ORACLE = (('stdin', 'reads standard input (stdin:)'),
                 ('run_args', 'takes arguments (run_args:)'),
                 ('run_files', 'reads files beside it (run_files:)'),
                 ('run_expect', 'has its output as its oracle (run_expect:)'))


def hosted_oracle(meta):
    """What METADATA's oracle needs of a hosted run, said for a refusal, or ""."""
    return ' and '.join(said for key, said in HOSTED_ORACLE if meta.get(key))


def namespace_only(row):
    """A refuse row whose only code is L0015, namespace availability (D267)."""
    return row['mode'] == 'refuse' and row.get('codes') == ['L0015']


#  The module an L0015 refusal names, in the compiler's own words.
UNAVAILABLE = re.compile(r'error\[L0015\]: module unavailable for target: (\S+)')


def namespace_reason(refused, reason):
    """A namespace refusal's reason, its modules read from the refusal."""
    modules = sorted(refused)
    listed = modules[0] if len(modules) == 1 else (
        ', '.join(modules[:-1]) + ' and ' + modules[-1])
    text = ('Source namespace checking refuses %s on the freestanding target before'
            ' checking declarations' % listed)
    return text + ('. ' + reason if reason else '.')


def first_diagnostic(log):
    """The first `error[...]` line of a compiler log, or ""."""
    return next((line.strip() for line in log.splitlines() if line.startswith('error[')), '')


def source_refusal(run, refine, name, row, level='armv6-m'):
    base = ROOT / 'compiler/tests/fixtures' / name
    meta = metadata(base / 'fixture.meta')
    inputs = lane_inputs(level, meta.module_arguments(base))
    selected = [] if level == 'armv6-m' else ['--level=' + refine_level(level)]
    try:
        run.command('compile-refusal', [refine, *inputs, '--target=cortex-m0', *selected,
                    '--emit=asm', '-o', run.out / 'refused.s'], timeout=900)
    except RuntimeError:
        command = run.commands[-1]
        require(command.get('exit') == 1 and not command.get('timed_out'),
                'source restriction did not produce a compiler diagnostic')
    else:
        raise RuntimeError('recorded source restriction unexpectedly compiled: ' + name)
    log = (run.out / 'compile-refusal.log').read_text()
    codes = sorted(set(re.findall(r'error\[(L\d+)\]', log)))
    #  A refusal the row does not record says what refine said, first: a
    #  compiler with no library beside it refuses every fixture with
    #  L0006, which is no changed verdict.
    #  On a lane the row's own codes are the reference's, so a lane whose
    #  refusal differs is given an entry of its own rather than new codes.
    lane = lane_of(level)
    write = ('"codes": %s' % json.dumps(codes) if lane is None else
             '"lanes": {"%s": {"mode": "refuse", "codes": %s, "reason": ...}}'
             % (lane, json.dumps(codes)))
    require(codes == row['codes'] and bool(codes),
            '%s: refine refused it with %s, first %r, and its %s row records %s%s; if that'
            ' refusal is the fixture\'s verdict, write %s (see %s); inspect %s'
            % (name, ', '.join(codes) or 'no code', first_diagnostic(log), INVENTORY,
               ', '.join(row['codes']), '' if lane is None else ' on ' + lane, write, RULES,
               run.out / 'compile-refusal.log'))
    require(not (run.out / 'refused.s').exists(), 'refusal wrote an assembly artifact')
    if not namespace_only(row):
        return {'verdict': 'source-refusal', 'codes': codes, 'reason': row['reason']}
    #  The refused imports are the refusal's, so a row never repeats them
    #  and a module's rename or split leaves no stale reason behind.
    refused = sorted(set(UNAVAILABLE.findall(log)))
    require(bool(refused), 'an L0015 refusal names no module: ' + name)
    repeated = [module for module in refused if module in row.get('reason', '')]
    require(not repeated, '%s: the %s row\'s reason names %s, which the corpus reads from the'
            ' refusal; remove it from the reason (see %s)'
            % (name, INVENTORY, ', '.join(repeated), RULES))
    return {'verdict': 'source-refusal', 'codes': codes, 'refused_imports': refused,
            'reason': namespace_reason(refused, row.get('reason', ''))}


def overflowed(run, error, profile):
    """The parts a failed link overflowed, if overflow is why it failed.

    A region of the profile's text or data overflowing is `FLASH` or
    `RAM`, whatever the description names it; static RAM reaching the
    stack that shares its region is the derived script's assertion, and
    is `RAM` too, by as much as the measurement says.
    """
    if not (isinstance(error, CommandFailed) and error.name == 'assemble-link'):
        return None
    log = Path(error.log).read_text()
    if 'undefined reference' in log or 'Assembler messages' in log:
        return None
    parts = {region(profile, 'text')['name']: 'FLASH', region(profile, 'data')['name']: 'RAM'}
    overflows = {}
    for name, value in re.findall(r"region `(\w+)' overflowed by (\d+) bytes", log):
        if name not in parts:
            return None
        overflows[parts[name]] = int(value)
    if 'image overlaps the reserved' in log:
        overflows.setdefault('RAM', None)
    return overflows or None


def image_limit(run, row, error, profile, level='armv6-m'):
    text = str(error)
    result = {'verdict': 'selected-image-limit', 'reason': row.get('reason', '')}
    if isinstance(error, ImageLimit) and 'materialization' in text:
        result['boundary'] = 'represented static image exceeds selected memory map'
    elif isinstance(error, ImageLimit):
        report = json.loads((run.out / 'build.json').read_text())['build']
        result['minimum_frame_bytes'] = max(r['frame_bytes'] for r in report['routines'])
        require(result['minimum_frame_bytes'] > profile['stack_reserved'],
                'false frame-limit report')
        result['boundary'] = 'single routine frame exceeds stack reservation'
        result['stack_reserved'] = profile['stack_reserved']
    elif isinstance(error, CommandFailed) and error.name == 'assemble-link':
        log = Path(error.log).read_text()
        overflows = overflowed(run, error, profile)
        require(overflows is not None or 'undefined reference' in log
                or 'Assembler messages' in log,
                'link failed without an identified physical image overflow: ' + text)
        require(overflows is not None,
                'image limit conceals a code-generation/link defect: ' + text)
        result['image'] = measure_overflow(run, profile, level=level)
        result['overflow_bytes'] = over(overflows, result['image'])
        result['boundary'] = 'selected external linker map'
    else:
        raise error
    if row.get('profile_limit') != 'selected-image':
        #  An image the map cannot hold, in a fixture with no recorded
        #  limit, fails, and says by how much and which row would record it.
        raise RuntimeError(
            '%s; the image does not fit the selected map%s, and its %s row records no'
            ' profile_limit: make the program fit, or add "profile_limit": "selected-image"'
            ' with a reason and drop cortex-m0 from its targets: (see %s)'
            % (text, ': ' + describe_sizes(result['image']) if 'image' in result else '',
               INVENTORY, RULES))
    return result


def over(overflows, image):
    """OVERFLOWS with an amount the link did not state read from IMAGE."""
    return {part: value if value is not None else
            image['regions'][part]['used'] - image['regions'][part]['limit']
            for part, value in overflows.items()}


def stale_limits(rows, results):
    """Fixtures whose recorded image limit no profile met in this run.

    A limit is a record that an image does not fit; one every profile now
    fits is stale, and passing silently is how a stale limit went unnoticed.
    """
    stale = []
    for name, row in rows.items():
        if row.get('profile_limit') != 'selected-image' or row['mode'] != 'execute':
            continue
        mine = [r for r in results if r['fixture'] == name]
        if mine and all(r['status'] == 'passed' and r.get('verdict') == 'executed'
                        for r in mine):
            largest = max(mine, key=lambda r: r['image']['regions']['FLASH']['used'])
            stale.append('  %s: every profile fits, the largest at %s/%s with %s; remove'
                         ' profile_limit and reason from its %s row, and name cortex-m0 in its'
                         ' targets: (see %s)'
                         % (name, largest['optimize'], largest['specialize'],
                            describe_sizes(largest['image']), INVENTORY, RULES))
    return stale


def corpus_line(result):
    """The line a program's result prints: its verdict and its image against the map."""
    text = ('cortex corpus: ' + result['fixture'] + ' ' + result['optimize'] + '/' +
            result['specialize'] + ('' if 'level' not in result else ' ' + result['level']) +
            ' ' + result.get('verdict', 'FAILED: ' + result.get('error', '')))
    if 'image' in result:
        text += ': ' + describe_sizes(result['image'])
        largest = describe_routines(result['image'])
        if largest:
            text += '; ' + largest
    elif result.get('boundary') == 'represented static image exceeds selected memory map':
        text += ': its assembly materialises more than 8 MiB, past any region of the map'
    elif 'minimum_frame_bytes' in result:
        text += ': a routine frame of %d bytes exceeds the %d-byte stack reservation' % (
            result['minimum_frame_bytes'], result.get('stack_reserved', 4096))
    elif 'refused_imports' in result:
        text += ': ' + ', '.join(result['codes']) + ' refuses ' + ', '.join(result['refused_imports'])
    return text


#  The runtime helpers a Thumb-2 image never asks for: a product, which
#  SMULL, UMULL and MLA make (D605), and a 32-bit quotient, which SDIV and
#  UDIV make (D255).
THUMB_2_HELPERS = ('__aeabi_lmul', '__aeabi_idivmod', '__aeabi_uidivmod')


#  D617: the software helpers a float unit leaves unused, its arithmetic,
#  comparison and 32-bit conversion; the 64-bit integer conversions stay
#  helpers, since no VFP instruction converts 64 bits.
SOFT_FLOAT = re.compile(r'\bbl\s+[0-9a-f]+ <(__aeabi_(?:[fd](?:add|sub|rsub|mul|div|neg|cmp\w*)'
                        r'|f2d|d2f|[iu]i?2[fd]|ui2[fd]|[fd]2u?iz))>')
VFP_OPERATION = re.compile(r'\t(vadd|vsub|vmul|vdiv|vneg|vcmpe?|vcvt)\.')


#  The exit evidence of D617: at none/off, where nothing is inlined, each
#  routine of this fixture holds its own VFP operation, and the image holds
#  no software float routine at all.
VFP_EVIDENCE = ('runtime/float-operations-by-arguments', {
    'add_32': 'vadd', 'subtract_32': 'vsub', 'multiply_32': 'vmul', 'divide_32': 'vdiv',
    'negate_32': 'vneg', 'add_64': 'vadd', 'subtract_64': 'vsub', 'multiply_64': 'vmul',
    'divide_64': 'vdiv', 'negate_64': 'vneg', 'compare_32': 'vcmpe', 'compare_64': 'vcmpe',
    'widen': 'vcvt', 'narrow': 'vcvt', 'single_of': 'vcvt', 'double_of': 'vcvt',
    'truncate_32': 'vcvt', 'truncate_8': 'vcvt'})


def float_lowering(run, evidence=False):
    """What the executed image computes floats with, read from its disassembly.

    On a lane with a float unit no arithmetic, comparison or 32-bit
    conversion helper may be called, and every VFP operation is counted in
    the routine that holds it, so the unit is shown to have reached the
    bytes QEMU executed.
    """
    text = (run.out / 'disassembly.log').read_text()
    calls = sorted(set(SOFT_FLOAT.findall(text)))
    require(not calls, 'the image still computes floats in software: ' + ', '.join(calls))
    spans = [(first, first + size, routine) for routine, (first, size) in
             extents((run.out / 'sections-routines.log').read_text()).items()]
    routines = {}
    for line in text.splitlines():
        found = re.match(r'^\s*([0-9a-f]+):', line)
        op = VFP_OPERATION.search(line)
        if found and op:
            at = int(found.group(1), 16)
            name = next((n for lo, hi, n in spans if lo <= at < hi), '?')
            routines.setdefault(name, {}).setdefault(op.group(1), 0)
            routines[name][op.group(1)] += 1
    if evidence:
        missing = sorted(routine for routine, op in VFP_EVIDENCE[1].items()
                         if op not in routines.get(routine, {}))
        require(not missing, 'routines without their VFP operation: ' + ', '.join(missing))
        software = sorted(set(n for _, _, n in spans if re.match(r'__(aeabi_[fd]|\w+[sd]f\d?$)', n)))
        require(not software, 'the image holds software float routines: ' + ', '.join(software))
    return {'helper_float_calls': 0, 'vfp_operations': routines}


def instructions(listing):
    """Every instruction of an `objdump -d` listing as (address, mnemonic,
    operands), in order.  A width suffix, `.w` or `.n`, is not part of the
    mnemonic."""
    found = []
    for line in listing.splitlines():
        fields = line.split('\t')
        address = re.match(r'^\s*([0-9a-f]+):$', fields[0])
        if address and len(fields) >= 3:
            found.append((int(address.group(1), 16), re.sub(r'\.[wn]$', '', fields[2].strip()),
                          fields[3].strip() if len(fields) > 3 else ''))
    return found


def extents(listing):
    """Each routine's first address and size, from `nm -S --defined-only`;
    a Thumb routine's symbol has its low bit set, its first instruction
    not.  The compiler's local labels inside a routine are no routines."""
    found = {}
    for line in listing.splitlines():
        parts = line.split()
        if len(parts) == 4 and parts[2] in ('T', 't'):
            found[parts[3]] = (int(parts[0], 16) & ~1, int(parts[1], 16))
    return found


def holds(body, item):
    """Whether BODY has ITEM: `bl NAME`, a call of NAME, or a mnemonic."""
    if item.startswith('bl '):
        return any(op in ('bl', 'blx') and rest.endswith('<%s>' % item[3:])
                   for _, op, rest in body)
    return any(op == item for _, op, _ in body)


def lowering(run, name, row, level):
    """What the executed image selects, read from its linked disassembly.

    A level that changed nothing would still pass every status, so an image
    a Thumb-2 level ran is required to ask the runtime for no product and no
    32-bit quotient, and a row's `selects` names a routine, or the whole
    image without one, and what it must and must not hold at each level:
    the lowering is shown to have changed in the bytes QEMU executed, not
    only in the text refine wrote, and its same source at another level to
    have kept its own.
    """
    wanted = row.get('selects', {})
    thumb_2 = refine_level(level) in THUMB_2
    if not thumb_2 and level not in wanted:
        return {}
    image = instructions((run.out / 'disassembly.log').read_text())
    found = {}
    if thumb_2:
        asked = [helper for helper in THUMB_2_HELPERS if holds(image, 'bl ' + helper)]
        require(not asked, 'the %s image still calls %s' % (level, ', '.join(asked)))
        found['helpers_absent'] = list(THUMB_2_HELPERS)
    if level in wanted:
        routine = wanted.get('routine')
        body = image
        if routine:
            first, size = extents((run.out / 'sections-routines.log').read_text()).get(
                routine, (0, 0))
            body = [one for one in image if first <= one[0] < first + size]
        require(bool(body), '%s: the linked image has no routine %s, which its %s row'
                ' selects in' % (name, routine, INVENTORY))
        missing = [item for item in wanted[level].get('has', []) if not holds(body, item)]
        present = [item for item in wanted[level].get('lacks', []) if holds(body, item)]
        require(not missing and not present, '%s at %s: %s %s; its %s row says what it'
                ' selects (see %s)' % (
                    name, level, routine or 'the image',
                    '; '.join((['lacks ' + ', '.join(missing)] if missing else [])
                              + (['holds ' + ', '.join(present)] if present else [])),
                    INVENTORY, RULES))
        found.update(routine=routine or 'the whole image', **wanted[level])
    return found


def dominates(profile, reference):
    """Whether every image that fits REFERENCE fits PROFILE: as much flash
    past its boot prefix, vector table and boot suffix, static RAM and
    stack, so a
    program the corpus executed on the reference needs no link of its own
    to show it fits, and only the limited ones are linked again."""
    def room(one):
        return (one['flash_limit'] - BOOT_PREFIX[one['boot']] - 4 * one['vector_words']
                - BOOT_SUFFIX[one['boot']])
    return (room(profile) >= room(reference)
            and profile['static_ram_limit'] >= reference['static_ram_limit']
            and profile['stack_reserved'] >= reference['stack_reserved'])


def against(parent, profile, result):
    """A limited program linked again for another described PROFILE.

    The program's object the reference link left, or its assembly
    assembled here for one whose frame stopped it before assembly, is
    linked with that profile's derived script and the harness start
    assembled for it, under `DEVICE/` beside the program's own output.
    The verdict is the link's and the frame's against the profile's build
    report: nothing is run, for QEMU has no such chip.  An image past the
    harness's materialization guard is past every region of the profile,
    which is checked rather than assumed.
    """
    device = profile['device']
    verdict = {'device': device, 'linked': True}
    if result.get('boundary') == 'represented static image exceeds selected memory map':
        require(MATERIALIZATION > profile['flash_limit'] + profile['static_ram_limit'],
                '%s holds more than the harness materializes; link the image to judge it'
                % device)
        verdict.update(fits=False, linked=False,
                       boundary='its assembly materialises more than 8 MiB, past every region')
        return verdict
    out = parent.out / device
    out.mkdir()
    run = Run(out, parent.tools)
    program = parent.out / 'input-1.o'
    if not program.exists():
        program = out / 'input-1.o'
        run.command('assemble-1', [run.arm / 'arm-eabi-gcc', *level_flags('armv6-m'),
                    '-c', parent.out / 'program.s', '-o', program])
    objects = [harness_start(run, profile), program]
    elf = out / 'program.elf'
    try:
        link(run, objects, profile['script'], 'armv6-m', elf)
    except CommandFailed as error:
        overflows = overflowed(run, error, profile)
        require(overflows is not None,
                'the link for %s failed without an identified image overflow: %s'
                % (device, error))
        verdict['image'] = measure_overflow(run, profile, objects)
        verdict.update(fits=False, overflow_bytes=over(overflows, verdict['image']))
    else:
        image_contract(elf, profile)
        verdict.update(fits=True, image=image_sizes(run, elf, profile))
    if 'minimum_frame_bytes' in result and result['minimum_frame_bytes'] > profile['stack_reserved']:
        verdict.update(fits=False, minimum_frame_bytes=result['minimum_frame_bytes'],
                       stack_reserved=profile['stack_reserved'])
    return verdict


def profile_verdicts(results, others, own=REFERENCE):
    """Every capacity verdict again against each described profile, linked.

    OWN's, the reference's unless a run at one level ran another, are the
    corpus's own links; each other profile's are `against`'s, for the
    limited verdicts at the default level, the only ones its core is sure
    to execute.
    """
    limited = [r for r in results if r.get('verdict') == 'selected-image-limit']
    def tag(result):
        return '%s %s/%s' % (result['fixture'], result['optimize'], result['specialize'])
    verdicts = {}
    for device in [own] if own != REFERENCE else DESCRIPTIONS:
        if device == own:
            mine = [(r, False) for r in limited]
        elif device in others:
            mine = [(r, r['profiles'][device]['fits']) for r in limited
                    if device in r.get('profiles', {})]
        else:
            continue
        exceeds = [r for r, fits in mine if not fits]
        verdicts[device] = {'verdicts': len(mine), 'exceed': len(exceeds),
                            'fit': sorted(tag(r) for r, fits in mine if fits),
                            'programs_exceeding': len({r['fixture'] for r in exceeds}),
                            'linked': True}
    return verdicts


def observe(output, tools, refine, program, profiles, level='armv6-m', roots=()):
    """Run PROGRAM, a source file or a module directory, at PROFILES on the
    constrained reference and say what it returned or where it trapped.

    No oracle is held: the status is printed, with the image against the
    map, so a measured value comes back as a value.  The harness still
    holds the stack to its reservation and names the routine that overran
    it.  Nothing here is corpus evidence.
    """
    path = Path(program).resolve(strict=True)
    inputs = [*('--root=' + str(Path(root).resolve()) for root in roots)]
    inputs += (['--root=' + str(path.parent), str(path)] if path.is_dir() else [str(path)])
    results = []
    for opt, spec in profiles:
        out = output / (path.stem + '--' + opt + '-' + spec
                        + ('' if level == 'armv6-m' else '--' + level))
        out.mkdir(parents=True, exist_ok=False)
        run = Run(out, tools)
        result = {'program': str(path), 'optimize': opt, 'specialize': spec, 'level': level}
        try:
            try:
                elf = build(run, refine, inputs, opt, spec, level=level)
            except (ImageLimit, CommandFailed) as error:
                limit = image_limit(run, {'profile_limit': 'selected-image'}, error,
                                    derived(run, refine, LEVELS[level]['profile']), level)
                result.update(status='does not fit', limit=limit)
                text = corpus_line(dict(limit, fixture=str(path), optimize=opt, specialize=spec))
                print(text.replace('cortex corpus: ', 'cortex program: ', 1), flush=True)
                results.append(result)
                continue
            result['image'] = {key: json.loads((out / 'image.json').read_text())[key]
                               for key in ('regions', 'sections', 'routines')}
            qemu(run, elf, None, False, level=level)
            seen = json.loads((out / 'observed.json').read_text())
            result.update(seen, status='ran')
            said = ('trapped: HardFault at %s%s' % (seen['stacked_pc'],
                    ', a udf #1 trap' if seen['udf_1'] else '')
                    if seen['trapped'] else 'returned %d (r12 %d)' % (seen['status'], seen['r12']))
            print('cortex program: %s %s/%s %s: %s; %s' % (
                path.name, opt, spec, said, describe_sizes(result['image']),
                describe_routines(result['image'])), flush=True)
        except Exception as error:
            said = str(error)
            result.update(status='failed', error=said)
            print('cortex program: %s %s/%s FAILED: %s' % (path.name, opt, spec, said),
                  flush=True)
        results.append(result)
    (output / 'result.json').write_text(json.dumps(
        {'scope': 'one program, not corpus evidence', 'compiler_sha256': sha(refine),
         'results': results}, indent=2) + '\n')
    require(all(r['status'] != 'failed' for r in results),
            'the program failed at %d profiles' % sum(r['status'] == 'failed' for r in results))
    return results


def execute(output, tools, refine, selected=(), profiles=(), lane=None):
    """Run the corpus: every row at the default level, and each `execute`
    row at each M-profile level its fixture's `levels:` names, or with
    LANE every row alone on that emulator lane, at its level and on its
    description's map (D607, D619)."""
    rows = inventory()
    require(lane is None or lane in LANES, 'unknown corpus lane %s; the lanes are %s'
            % (lane, ', '.join(LANES)))
    profiles = [profile_name(p) for p in profiles]
    known = ['-'.join(p) for p in PROFILES + SPECIALIZATION_PROFILES]
    require(set(profiles) <= set(known),
            'unknown exact corpus profile %s; the profiles are %s, written with - or /'
            % (', '.join(sorted(set(profiles) - set(known))), ', '.join(known)))
    unknown = sorted(set(selected) - set(rows))
    require(not unknown, 'unknown exact corpus case %s: a case is a fixture directory under'
            ' compiler/tests/fixtures with a row in %s, such as runtime/word-count; to run a'
            ' program of your own, pass --program PATH' % (', '.join(unknown), INVENTORY))
    #  Every profile the corpus links with, derived once by refine: the
    #  reference's, which the corpus executes, and each other described
    #  device's, which a limited verdict is linked again against.
    deriving = Run(output, tools)
    reference = derived(deriving, refine, REFERENCE, output / 'profiles')
    lanes = {one: derived(deriving, refine, LEVELS[one]['profile'], output / 'profiles')
             for one in LEVELS}
    others = {}
    for device in DESCRIPTIONS:
        if device != REFERENCE and lane is None:
            others[device] = derived(deriving, refine, device, output / 'profiles')
            require(dominates(others[device], reference),
                    '%s holds less than the constrained reference somewhere, so a program'
                    ' that fits the reference may not fit it, and the corpus links only'
                    ' its limited programs again' % device)
    work = []
    for name, row in rows.items():
        if selected and name not in selected:
            continue
        meta = metadata(ROOT / 'compiler/tests/fixtures' / name / 'fixture.meta')
        modes = PROFILES + (SPECIALIZATION_PROFILES
                            if meta.get('profiles') == 'specialization' else [])
        if row['mode'] != 'execute':
            modes = [('none', 'off')]
        if profiles and row['mode'] == 'execute':
            modes = [p for p in modes if '-'.join(p) in profiles]
            if selected:
                require(bool(modes), 'profile is not applicable to the selected fixture')
        if lane is not None:
            levels = [LANES[lane]]
        else:
            levels = ['armv6-m']
            if row['mode'] == 'execute':
                levels += levels_of(meta)
        work += [(name, row, opt, spec, level)
                 for level in levels for opt, spec in modes]

    def one(item):
        name, row, opt, spec, level = item
        profile = lanes[level]
        out = output / (name.replace('/', '--') + '--' + opt + '-' + spec
                        + ('' if level == 'armv6-m' else '--' + level))
        out.mkdir(parents=True, exist_ok=False)
        run = Run(out, tools)
        result = {'fixture': name, 'optimize': opt, 'specialize': spec}
        if level != 'armv6-m':
            result['level'] = level
        try:
            if row['mode'] == 'restriction':
                result.update(verdict='target-restriction', reason=row['reason'],
                              witness_sha256=sha(ROOT / row['witness']))
            elif row['mode'] == 'refuse':
                own = row.get('lanes', {}).get(lane_of(level))
                result.update(source_refusal(run, refine, name, {**row, **own} if own else row,
                                             level))
            elif lane_of(level) in row.get('lanes', {}):
                own = row['lanes'][lane_of(level)]
                try:
                    fixture(run, refine, name, opt, spec, level,
                            include_compiler_sha256=False)
                except RuntimeError as error:
                    result.update(verdict='lane-restriction', reason=own['reason'],
                                  observed=str(error).split('; inspect ')[0])
                else:
                    raise RuntimeError(
                        'its %s lane restriction is stale: the program passes there; remove'
                        ' the "lanes" entry from its %s row (see %s)' % (lane_of(level), INVENTORY, RULES))
            else:
                try:
                    fixture(run, refine, name, opt, spec, level,
                            include_compiler_sha256=False)
                    result['verdict'] = 'executed'
                    result['image'] = {key: json.loads((out / 'image.json').read_text())[key]
                                       for key in ('regions', 'sections', 'routines')}
                    selects = lowering(run, name, row, level)
                    if hard_float(level):
                        selects.update(float_lowering(
                            run, name == VFP_EVIDENCE[0] and (opt, spec) == ('none', 'off')))
                    if selects:
                        result['lowering'] = selects
                except RuntimeError as error:
                    result.update(image_limit(run, row, error, profile, level))
                    if level == 'armv6-m':
                        result['profiles'] = {device: against(run, profile, result)
                                              for device, profile in others.items()}
            result['status'] = 'passed'
        except Exception as error:
            result.update(status='failed', error='%s: %s' % (out.name, error))
        result['artifacts'] = {str(p.relative_to(out)): sha(p)
                               for p in sorted(out.rglob('*')) if p.is_file()}
        (out / 'result.json').write_text(json.dumps(result, indent=2)+'\n')
        return result

    #  Each program has its own directory, emulator and debugger session, and
    #  each worker thread its own GDB; results are reported in inventory
    #  order whatever order they finished in.
    with ThreadPoolExecutor(max_workers=workers()) as pool:
        results = list(pool.map(one, work))
    for result in results:
        print(corpus_line(result), flush=True)
    #  A run filtered by profile cannot tell a stale limit from one that
    #  holds at a profile it did not run, and a run on one lane cannot tell
    #  one that holds at the default: limits are the default run's to judge.
    stale = [] if profiles or lane is not None else stale_limits(rows, results)
    scope = 'development-filtered' if selected or profiles else 'complete-inventory'
    summary = {'scope': scope if lane is None else scope + ' on ' + lane,
               'compiler_sha256': sha(refine), 'results': results, 'stale_limits': stale,
               'profiles': profile_verdicts(results, others) if lane is None else
               profile_verdicts(results, {}, lane)}
    if lane is not None:
        summary['lane'] = lane
    for device, verdict in summary['profiles'].items():
        print('cortex corpus capacity against %s: %d of %d limited verdicts still exceed it,'
              ' in %d programs, linked with its derived script'
              % (device, verdict['exceed'], verdict['verdicts'],
                 verdict['programs_exceeding']), flush=True)
    (output / 'result.json').write_text(json.dumps(summary, indent=2)+'\n')
    failed = [r for r in results if r['status'] != 'passed']
    require(not failed, 'Cortex corpus has %d failures:\n%s' % (len(failed), '\n'.join(
        '  %s %s/%s: %s' % (r['fixture'], r['optimize'], r['specialize'], r['error'])
        for r in failed)))
    require(not stale, 'Cortex corpus records image limits no profile met:\n' + '\n'.join(stale))
    if selected or profiles:
        print('FILTERED: this corpus run selected %s; it judges no stale limit and is not'
              ' the complete inventory' % ', '.join(
                  ['--case ' + one for one in selected] + ['--profile ' + one for one in profiles]),
              flush=True)
    elif lane is not None:
        print('this corpus run is every row on the %s lane alone, at %s; the default run'
              ' judges its image limits' % (lane, LANES[lane]), flush=True)
    return summary


def main():
    parser = argparse.ArgumentParser(
        description=__doc__,
        epilog='--program runs a source file or module directory of your own at the corpus\'s'
               ' profiles on the constrained reference, or with --level on that level\'s'
               ' machine and map, and prints what it returned, or where it trapped, with its'
               ' image against the map; no oracle is held.')
    parser.add_argument('--refine', type=Path, required=True)
    parser.add_argument('--tools', type=Path, default=DEFAULT)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--case', action='append', default=[],
                        help='a fixture directory under compiler/tests/fixtures, such as'
                             ' runtime/word-count; repeat for more')
    parser.add_argument('--profile', action='append', default=[],
                        help='none-off, size-off, size-auto, speed-auto, none-all or speed-all;'
                             ' none/off as the log prints it is the same profile')
    parser.add_argument('--program', type=Path,
                        help='a .ldn file or module directory to run instead of the corpus')
    parser.add_argument('--root', action='append', default=[],
                        help='a module root for --program, passed to refine')
    parser.add_argument('--level', default='armv6-m', choices=sorted(LEVELS),
                        help='the M-profile level --program is built and run at, on that'
                             ' level\'s machine and map')
    parser.add_argument('--lane', choices=sorted(LANES),
                        help='run every inventory row alone on this emulator lane, at its'
                             ' level and on its description\'s map (D607, D619); without it,'
                             ' every row runs at armv6-m and each execute row at the levels'
                             ' its fixture\'s levels: names')
    args = parser.parse_args()
    #  A rebuild of this build waits for the lane, rather than replace
    #  refine between two of its compilations.
    sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))
    import build_lock
    if args.refine:
        build_lock.reading(args.refine)
    if args.program is not None and args.case:
        parser.error('--program runs one program of your own; --case selects corpus fixtures')
    if args.program is not None and args.lane:
        parser.error('--program runs one program of your own, at --level; --lane runs the'
                     ' inventory on a lane')
    supported_host(args.output)
    args.tools = installed_tools(args.tools)
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    if args.program is not None:
        known = {'-'.join(p): p for p in PROFILES + SPECIALIZATION_PROFILES}
        chosen = [profile_name(p) for p in args.profile]
        require(set(chosen) <= set(known), 'unknown profile %s; the profiles are %s'
                % (', '.join(sorted(set(chosen) - set(known))), ', '.join(known)))
        observe(out, args.tools.resolve(), args.refine.resolve(), args.program,
                [known[p] for p in chosen] or PROFILES, args.level or 'armv6-m', args.root)
        return
    execute(out, args.tools.resolve(), args.refine.resolve(), args.case, args.profile,
            args.lane)


if __name__ == '__main__':
    main()
