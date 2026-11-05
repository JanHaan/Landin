#!/usr/bin/env python3
"""Run deterministic native controls against the production host adapters."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cc', default=os.environ.get('CC', 'cc'))
    parser.add_argument('--output', type=Path, help='new evidence directory')
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    root = (args.output.absolute() if args.output else
            Path(tempfile.mkdtemp(prefix='landin-publication-native-')))
    if args.output:
        root.mkdir(parents=True)
    platform = repo / 'compiler/ada/src/platform'
    sources = [platform / name for name in
               ('landin_publication.c', 'landin_format_replace.c',
                'landin_tool_process.c', 'landin_file_identity.c')]
    sources.append(repo / 'compiler/ada/tests/native/publication.c')
    binary = root / 'publication'
    command = [*shlex.split(args.cc), '-std=c11', '-Wall', '-Wextra',
               '-Werror', '-pedantic', '-pthread', '-I', str(platform),
               *map(str, sources), '-o', str(binary)]
    built = subprocess.run(command, capture_output=True, text=True, timeout=90)
    (root / 'compile.log').write_text(built.stdout + built.stderr)
    summary = dict(scope='FILTERED native production host adapters',
                   command=command, compile_exit=built.returncode,
                   inputs={str(p.relative_to(repo)): hashlib.sha256(
                       p.read_bytes()).hexdigest() for p in
                           sources + [platform / 'landin_publication.h',
                                      platform / 'landin_owned_directory.h']})
    if built.returncode == 0:
        env = dict(os.environ, TMPDIR=str(root))
        ran = subprocess.run([str(binary)], cwd=root, env=env,
                             capture_output=True, text=True, timeout=60)
        (root / 'controls.log').write_text(ran.stdout + ran.stderr)
        summary.update(exit_status=ran.returncode, stdout=ran.stdout,
                       stderr=ran.stderr)
    (root / 'results.json').write_text(json.dumps(summary, indent=2) + '\n')
    print('native publication evidence: ' + str(root), flush=True)
    passed = (built.returncode == 0 and summary['exit_status'] == 0
              and 'publication native:' in summary['stdout'])
    if not passed:
        print(built.stdout + built.stderr, end='')
        print(summary.get('stdout', '') + summary.get('stderr', ''), end='')
        raise SystemExit(1)
    print(summary['stdout'], end='')


if __name__ == '__main__':
    main()
