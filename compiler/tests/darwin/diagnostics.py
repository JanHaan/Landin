#!/usr/bin/env python3
"""Check every applicable shared source verdict with the Darwin target selected."""
import argparse
import hashlib
import json
from pathlib import Path
import re

from check import ROOT, Run, hash_file, require


def candidates(root):
    for cls in ('negative', 'positive'):
        for path in sorted((root / 'compiler/tests/fixtures' / cls).glob('*/fixture.meta')):
            meta = dict(line.split(': ', 1) for line in path.read_text().splitlines()
                        if ': ' in line and not line.startswith('#'))
            if 'macos-arm64' in meta['targets'].split(', ') and ('program' in meta or 'args' in meta):
                yield str(path.parent.relative_to(root / 'compiler/tests/fixtures')), meta


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--refine', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--case', help='exact fixture; development only')
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    run = Run(output)
    summary = dict(scope='filtered' if args.case else 'parity', status='failed',
                   refine_sha256=hash_file(args.refine), results=[])
    selected = list(candidates(ROOT))
    differences = json.loads((ROOT / 'compiler/tests/darwin/parity.json').read_text())['diagnostics']
    summary['differences'] = differences
    require(not args.case or args.case in {n for n, _ in selected}, 'unknown diagnostic case')
    try:
        for name, meta in selected:
            if args.case and name != args.case:
                continue
            meta = {**meta, **{k: v for k, v in differences.get(name, {}).items() if k != 'reason'}}
            base = Path('../tests/fixtures') / name
            if 'args' in meta:
                argv = meta['args'].split()
            elif 'root' in meta:
                argv = ['--root=' + str(base / meta['root']), str(base)]
            else:
                argv = [str(base / meta['program'])]
                argv += [str(base / part.strip()) for part in meta.get('with', '').split(',') if part.strip()]
            # Explicit target-refusal fixtures retain their own request; the
            # ordinary shared source selects Darwin, including recorded errors.
            argv = [a.replace('--target=linux-x86-64', '--target=darwin-arm64') for a in argv]
            if not any(a.startswith('--target=') for a in argv):
                argv.append('--target=darwin-arm64')
            label = name.replace('/', '-')
            status, stdout, stderr = run.command([args.refine.resolve(), *argv], label,
                                                 ROOT / 'compiler/ada', expected=None, timeout=180,
                                                 merged=meta.get('stream', 'merged') == 'merged')
            expected_status = int(meta.get('status', '1' if meta['class'] == 'negative' else '0'))
            require(status == expected_status, f'{name}: expected {expected_status}, got {status}')
            actual = stdout + stderr
            codes = re.findall(rb'error\[(L[0-9]{4})\]', actual)
            expected_codes = [c.strip().encode() for c in meta.get('codes', '').split(',') if c.strip()]
            require(codes == expected_codes, f'{name}: diagnostic codes differ: {codes!r}')
            if 'expect' in meta:
                expected = (ROOT / 'compiler/tests/fixtures' / name / meta['expect']).read_bytes()
                require(actual == expected, f'{name}: exact diagnostic differs')
            if meta.get('stream') == 'output':
                require(not stderr, f'{name}: unexpected stderr')
            summary['results'].append(dict(case=name, status='passed', exit=status,
                                            output_sha256=hashlib.sha256(actual).hexdigest()))
        summary['status'] = 'passed'
    finally:
        (output / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(f"Darwin {summary['scope']}: {len(summary['results'])} source verdicts passed")


if __name__ == '__main__':
    main()
