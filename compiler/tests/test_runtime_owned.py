#!/usr/bin/env python3
"""Native deterministic controls for owned capture and scratch namespaces."""
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
    output = (args.output.absolute() if args.output else
              Path(tempfile.mkdtemp(prefix='landin-runtime-ownership-')))
    if args.output:
        output.mkdir(parents=True)
    platform = repo / 'compiler/ada/src/platform'
    sources = [platform / name for name in
               ('landin_tool_process.c', 'landin_file_identity.c',
                'landin_publication.c', 'landin_format_replace.c')]
    sources.append(repo / 'compiler/tests/runtime_owned.c')
    headers = [platform / name for name in
               ('landin_publication.h', 'landin_owned_directory.h')]
    executable = output / 'runtime-owned'
    command = [*shlex.split(args.cc), '-std=c11', '-Wall', '-Wextra',
               '-Werror', '-pedantic', '-pthread', '-I', str(platform),
               *map(str, sources), '-o', str(executable)]
    built = subprocess.run(command, capture_output=True, text=True, timeout=90)
    (output / 'compile.log').write_text(built.stdout + built.stderr)
    result = dict(scope='FILTERED native production capture/private-root controls',
                  command=command, compile_exit=built.returncode,
                  inputs={str(path.relative_to(repo)): hashlib.sha256(
                      path.read_bytes()).hexdigest() for path in sources + headers})
    if built.returncode == 0:
        ran = subprocess.run([str(executable)], cwd=output,
                             env=dict(os.environ, TMPDIR=str(output)),
                             capture_output=True, text=True, timeout=60)
        (output / 'controls.log').write_text(ran.stdout + ran.stderr)
        result.update(exit_status=ran.returncode, stdout=ran.stdout,
                      stderr=ran.stderr)
    (output / 'results.json').write_text(json.dumps(result, indent=2) + '\n')
    print('runtime ownership evidence: ' + str(output), flush=True)
    if (built.returncode != 0 or result.get('exit_status') != 0 or
            'runtime ownership native: 7/7 controls passed' not in result.get('stdout', '')):
        print(built.stdout + built.stderr, end='')
        print(result.get('stdout', '') + result.get('stderr', ''), end='')
        raise SystemExit(1)
    print(result['stdout'], end='')


if __name__ == '__main__':
    main()
