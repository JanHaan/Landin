"""Complete inventoried R6.50 corpus, with explicit target/image dispositions.

ROADMAP.md owns the decisions. corpus.json is the executable selection record;
physical limits are retained as limits, never as successful executions.
"""
import argparse
import json
from pathlib import Path
import re

from backend import ROOT, COUNTERPARTS, fixture, metadata
from run import Run, require
from setup import DEFAULT, sha, supported_host

PROFILES = [('none', 'off'), ('size', 'off'), ('size', 'auto'), ('speed', 'auto')]


def inventory():
    record = json.loads((COUNTERPARTS / 'corpus.json').read_text())
    require(record['schema'] == 1, 'unknown Cortex corpus schema')
    rows = record['fixtures']
    actual = {str(p.parent.relative_to(ROOT / 'compiler/tests/fixtures'))
              for kind in ('runtime', 'abi')
              for p in (ROOT / 'compiler/tests/fixtures' / kind).glob('*/fixture.meta')}
    require(set(rows) == actual, 'Cortex corpus inventory disagrees with shared fixtures')
    changes = json.loads((COUNTERPARTS / 'counterparts.json').read_text())['replacements']
    require(set(changes) == {r['counterpart'] for r in rows.values() if 'counterpart' in r},
            'Cortex counterpart inventory disagrees')
    for name, replacements in changes.items():
        source = (ROOT / 'compiler/tests/fixtures/runtime' / name / 'main.ldn').read_text()
        for old, new in replacements:
            require(old in source, 'stale counterpart source difference: ' + name)
            source = source.replace(old, new)
        expected = '-- R6.50 counterpart: the original hosted fixture remains unchanged.\n' + source
        require((COUNTERPARTS / 'cases' / name / 'main.ldn').read_text() == expected,
                'unreviewed counterpart change: ' + name)
    for name, row in rows.items():
        require(row['mode'] in ('execute', 'refuse', 'restriction'), 'unknown corpus disposition')
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
    inputs = (['--root=' + str((base / meta['root']).resolve()), str(base)]
              if meta.get('root') else [str(base / meta['program'])])
    inputs += [str(base / p.strip()) for p in meta.get('with', '').split(',') if p.strip()]
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


def image_limit(run, row, error):
    require(row.get('profile_limit') == 'selected-image', str(error))
    text = str(error)
    result = {'verdict': 'selected-image-limit', 'reason': row['reason']}
    if text == 'bounded assembly materialization exceeds 8 MiB':
        result['boundary'] = 'represented static image exceeds selected memory map'
    elif text == 'routine frame exceeds selected 4 KiB test stack reservation':
        report = json.loads((run.out / 'build.json').read_text())['build']
        result['minimum_frame_bytes'] = max(r['frame_bytes'] for r in report['routines'])
        require(result['minimum_frame_bytes'] > 4096, 'false frame-limit report')
        result['boundary'] = 'single routine frame exceeds stack reservation'
    elif text == 'assemble-link failed; inspect retained log':
        log = (run.out / 'assemble-link.log').read_text()
        overflows = re.findall(r"region `(FLASH|RAM)' overflowed by (\d+) bytes", log)
        require(bool(overflows), 'link failed without an identified physical image overflow')
        require('undefined reference' not in log and 'Assembler messages' not in log,
                'image limit conceals a code-generation/link defect')
        result['overflow_bytes'] = {key: int(value) for key, value in overflows}
        result['boundary'] = 'selected external linker map'
    else:
        raise RuntimeError(text)
    return result


def execute(output, tools, refine, selected=(), profiles=()):
    rows = inventory()
    require(set(profiles) <= {'none-off', 'size-off', 'size-auto', 'speed-auto', 'none-all', 'speed-all'},
            'unknown exact corpus profile')
    require(not selected or set(selected) <= set(rows), 'unknown exact corpus case')
    results = []
    for name, row in rows.items():
        if selected and name not in selected:
            continue
        meta = metadata(ROOT / 'compiler/tests/fixtures' / name / 'fixture.meta')
        modes = PROFILES + ([('none', 'all'), ('speed', 'all')]
                            if meta.get('profiles') == 'specialization' else [])
        if row['mode'] != 'execute':
            modes = [('none', 'off')]
        if profiles and row['mode'] == 'execute':
            modes = [p for p in modes if '-'.join(p) in profiles]
            if selected:
                require(bool(modes), 'profile is not applicable to the selected fixture')
        for opt, spec in modes:
            out = output / (name.replace('/', '--') + '--' + opt + '-' + spec)
            out.mkdir(parents=True, exist_ok=False)
            run = Run(out, tools)
            result = {'fixture': name, 'optimize': opt, 'specialize': spec}
            try:
                if row['mode'] == 'restriction':
                    result.update(verdict='target-restriction', reason=row['reason'],
                                  witness_sha256=sha(ROOT / row['witness']))
                elif row['mode'] == 'refuse':
                    result.update(source_refusal(run, refine, name, row))
                else:
                    try:
                        fixture(run, refine, name, opt, spec)
                        result['verdict'] = 'executed'
                    except RuntimeError as error:
                        result.update(image_limit(run, row, error))
                result['status'] = 'passed'
            except Exception as error:
                result.update(status='failed', error=str(error))
            result['artifacts'] = {str(p.relative_to(out)): sha(p)
                                   for p in sorted(out.rglob('*')) if p.is_file()}
            (out / 'result.json').write_text(json.dumps(result, indent=2)+'\n')
            results.append(result)
            print('cortex corpus: ' + name + ' ' + opt + '/' + spec + ' ' +
                  result.get('verdict', 'FAILED: ' + result.get('error', '')), flush=True)
    summary = {'scope': 'development-filtered' if selected or profiles else 'complete-inventory',
               'compiler_sha256': sha(refine), 'results': results}
    (output / 'result.json').write_text(json.dumps(summary, indent=2)+'\n')
    require(all(r['status'] == 'passed' for r in results), 'Cortex corpus has failures')
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--refine', type=Path, required=True)
    parser.add_argument('--tools', type=Path, default=DEFAULT)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--case', action='append', default=[])
    parser.add_argument('--profile', action='append', default=[])
    args = parser.parse_args()
    supported_host()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    execute(out, args.tools.resolve(), args.refine.resolve(), args.case, args.profile)


if __name__ == '__main__':
    main()
