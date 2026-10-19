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

from backend import (ROOT, COUNTERPARTS, describe_routines, describe_sizes, fixture,
                     levels_of, measure_overflow, metadata)
from run import CommandFailed, Run, require, workers
from setup import DEFAULT, installed_tools, sha, supported_host

PROFILES = [('none', 'off'), ('size', 'off'), ('size', 'auto'), ('speed', 'auto')]
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
        + ['  %s has no row; add "%s": {"mode": "execute"} if it runs on Cortex-M0, or a'
           ' "refuse" or "restriction" row with its reason (see %s)' % (name, name, RULES)
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
    for name, row in rows.items():
        require(row['mode'] in ('execute', 'refuse', 'restriction'), 'unknown corpus disposition')
        #  Firmware has no standard input to give a program, so one that
        #  reads it is refused by name or restricted, never executed.
        meta = metadata(ROOT / 'compiler/tests/fixtures' / name / 'fixture.meta')
        require(row['mode'] != 'execute' or not meta.get('stdin'),
                'a fixture reading standard input cannot execute on firmware: ' + name)
        if row['mode'] != 'execute' or 'profile_limit' in row:
            require(bool(row.get('reason')), 'unexplained corpus exclusion: ' + name)
        if row['mode'] == 'restriction':
            witness = ROOT / row['witness']
            require(witness.is_file(), 'missing restriction witness')
            if name.startswith('abi/'):
                meta = metadata(witness)
                require(meta['class'] == 'abi' and meta.get('c-sources'), 'C peer restriction changed')
            else:
                require('extern(c)' in witness.read_text(), 'hosted heap restriction changed')
    return rows


def source_refusal(run, refine, name, row):
    base = ROOT / 'compiler/tests/fixtures' / name
    meta = metadata(base / 'fixture.meta')
    inputs = meta.module_arguments(base)
    try:
        run.command('compile-refusal', [refine, *inputs, '--target=cortex-m0', '--emit=asm',
                    '-o', run.out / 'refused.s'], timeout=900)
    except RuntimeError:
        command = run.commands[-1]
        require(command.get('exit') == 1 and not command.get('timed_out'),
                'source restriction did not produce a compiler diagnostic')
    else:
        raise RuntimeError('recorded source restriction unexpectedly compiled: ' + name)
    codes = sorted(set(re.findall(r'error\[(L\d+)\]', (run.out / 'compile-refusal.log').read_text())))
    require(codes == row['codes'] and bool(codes), 'source restriction diagnostics changed: ' + name)
    require(not (run.out / 'refused.s').exists(), 'refusal wrote an assembly artifact')
    return {'verdict': 'source-refusal', 'codes': codes, 'reason': row['reason']}


def overflowed(run, error):
    """The regions a failed link overflowed, if overflow is why it failed."""
    if not (isinstance(error, CommandFailed) and error.name == 'assemble-link'):
        return None
    log = (run.out / 'assemble-link.log').read_text()
    overflows = re.findall(r"region `(FLASH|RAM)' overflowed by (\d+) bytes", log)
    if not overflows or 'undefined reference' in log or 'Assembler messages' in log:
        return None
    return {key: int(value) for key, value in overflows}


def image_limit(run, row, error, level='armv6-m'):
    text = str(error)
    result = {'verdict': 'selected-image-limit', 'reason': row.get('reason', '')}
    if text == 'bounded assembly materialization exceeds 8 MiB':
        result['boundary'] = 'represented static image exceeds selected memory map'
    elif text == 'routine frame exceeds selected 4 KiB test stack reservation':
        report = json.loads((run.out / 'build.json').read_text())['build']
        result['minimum_frame_bytes'] = max(r['frame_bytes'] for r in report['routines'])
        require(result['minimum_frame_bytes'] > 4096, 'false frame-limit report')
        result['boundary'] = 'single routine frame exceeds stack reservation'
    elif isinstance(error, CommandFailed) and error.name == 'assemble-link':
        log = (run.out / 'assemble-link.log').read_text()
        overflows = overflowed(run, error)
        require(overflows is not None or 'undefined reference' in log
                or 'Assembler messages' in log,
                'link failed without an identified physical image overflow: ' + text)
        require(overflows is not None,
                'image limit conceals a code-generation/link defect: ' + text)
        result['overflow_bytes'] = overflows
        result['boundary'] = 'selected external linker map'
        result['image'] = measure_overflow(run, level)
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
        text += ': a routine frame of %d bytes exceeds the 4096-byte stack reservation' % (
            result['minimum_frame_bytes'])
    return text


def divide_lowering(run):
    """What the executed image divides with, read from its disassembly.

    A level that changed nothing would still pass every status, so the
    image a higher level ran is required to divide in hardware and to have
    asked the runtime for no 32-bit quotient: the lowering is shown to have
    changed in the bytes QEMU executed, not only in the text refine wrote.
    """
    text = (run.out / 'disassembly.log').read_text()
    divides = len(re.findall(r'\t[su]div\t', text))
    calls = re.findall(r'\bbl\s+[0-9a-f]+ <(__aeabi_u?idivmod)>', text)
    require(divides > 0, 'the image divides in no hardware instruction')
    require(not calls, 'the image still calls ' + ', '.join(sorted(set(calls))))
    return {'hardware_divides': divides, 'helper_divides': 0}


def execute(output, tools, refine, selected=(), profiles=()):
    rows = inventory()
    profiles = [profile_name(p) for p in profiles]
    known = ['-'.join(p) for p in PROFILES + SPECIALIZATION_PROFILES]
    require(set(profiles) <= set(known),
            'unknown exact corpus profile %s; the profiles are %s, written with - or /'
            % (', '.join(sorted(set(profiles) - set(known))), ', '.join(known)))
    require(not selected or set(selected) <= set(rows), 'unknown exact corpus case')
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
        levels = ['armv6-m']
        if row['mode'] == 'execute':
            levels += levels_of(meta)
        work += [(name, row, opt, spec, level)
                 for level in levels for opt, spec in modes]

    def one(item):
        name, row, opt, spec, level = item
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
                result.update(source_refusal(run, refine, name, row))
            else:
                try:
                    fixture(run, refine, name, opt, spec, level,
                            include_compiler_sha256=False)
                    result['verdict'] = 'executed'
                    result['image'] = {key: json.loads((out / 'image.json').read_text())[key]
                                       for key in ('regions', 'sections', 'routines')}
                    if level != 'armv6-m':
                        result['lowering'] = divide_lowering(run)
                except RuntimeError as error:
                    result.update(image_limit(run, row, error, level))
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
    #  holds at a profile it did not run.
    stale = [] if profiles else stale_limits(rows, results)
    summary = {'scope': 'development-filtered' if selected or profiles else 'complete-inventory',
               'compiler_sha256': sha(refine), 'results': results, 'stale_limits': stale}
    (output / 'result.json').write_text(json.dumps(summary, indent=2)+'\n')
    failed = [r for r in results if r['status'] != 'passed']
    require(not failed, 'Cortex corpus has %d failures:\n%s' % (len(failed), '\n'.join(
        '  %s %s/%s: %s' % (r['fixture'], r['optimize'], r['specialize'], r['error'])
        for r in failed)))
    require(not stale, 'Cortex corpus records image limits no profile met:\n' + '\n'.join(stale))
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--refine', type=Path, required=True)
    parser.add_argument('--tools', type=Path, default=DEFAULT)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--case', action='append', default=[])
    parser.add_argument('--profile', action='append', default=[],
                        help='none-off, size-off, size-auto, speed-auto, none-all or speed-all;'
                             ' none/off as the log prints it is the same profile')
    args = parser.parse_args()
    #  A rebuild of this build waits for the lane, rather than replace
    #  refine between two of its compilations.
    sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))
    import build_lock
    if args.refine:
        build_lock.reading(args.refine)
    supported_host()
    args.tools = installed_tools(args.tools)
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    execute(out, args.tools.resolve(), args.refine.resolve(), args.case, args.profile)


if __name__ == '__main__':
    main()
