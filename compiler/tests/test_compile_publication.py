#!/usr/bin/env python3
"""Native compiler publication controls; every input is in an owned root."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--refine', type=Path, required=True)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    refine = args.refine.resolve(strict=True)
    root = (args.output.absolute() if args.output else
            Path(tempfile.mkdtemp(prefix='landin-compile-publication-')))
    if args.output:
        root.mkdir(parents=True)
    temporary = root / 'temporary'
    temporary.mkdir()
    env = dict(os.environ, TMPDIR=str(temporary))
    source = root / 'main.ldn'
    source.write_text('public main: () -> (code: i32) =\n    code = 0\nend main\n')
    driver = shutil.which('clang' if sys.platform == 'darwin' else 'gcc')
    if not driver:
        parser.error('the native C driver is required')
    wrapper = root / 'owned-cc'
    wrapper.write_text('#!/bin/sh\nexec ' + shlex.quote(driver) + ' "$@"\n')
    wrapper.chmod(0o700)
    response = root / 'arguments.rsp'
    response.write_text(str(source) + '\n-o\n' + str(root / 'response-product') + '\n')
    library = root / 'lib'
    library.mkdir()
    peer = root / 'peer.c'
    peer.write_text('int landin_publication_peer(void) { return 42; }\n')
    subprocess.run([driver, '-c', str(peer), '-o', str(root / 'peer.o')], check=True,
                   capture_output=True, env=env)
    archive = library / 'libpublication.a'
    subprocess.run(['ar', 'rcs', str(archive), str(root / 'peer.o')], check=True,
                   capture_output=True, env=env)
    with_library = root / 'library.ldn'
    with_library.write_text('linker.library("publication")\n' + source.read_text())
    source_alias = root / 'source-alias'
    os.link(source, source_alias)
    cases = [
        ('plain', [str(source), '-o', str(root / 'plain')], source, True),
        ('tool-control', ['--toolchain=' + str(wrapper), str(source), '-o',
                          str(root / 'tool-product')], wrapper, True),
        ('response-control', ['@' + str(response)], response, True),
        ('library-control', ['--link=libc', '-L', str(library), str(with_library),
                             '-o', str(root / 'library-product')], archive, True),
        ('tool-as-report', ['--toolchain=' + str(wrapper), str(source), '-o',
                            str(root / 'tool-refused'), '--build-report=' + str(wrapper)], wrapper, False),
        ('response-as-report', ['@' + str(response), '--build-report=' + str(response)], response, False),
        ('library-as-report', ['--link=libc', '-L', str(library), str(with_library), '-o',
                               str(root / 'library-refused'), '--build-report=' + str(archive)], archive, False),
        ('source-hardlink-output', [str(source), '-o', str(source_alias)], source, False),
    ]
    if sys.platform == 'linux':
        # GNU ld accepts a selected .so as a textual library script. Its
        # INPUT payload is an input even though it was not named by refine.
        (library / 'libscriptpeer.so').write_text('INPUT ( ' + str(archive) + ' )\n')
        script_source = root / 'script-library.ldn'
        script_source.write_text('linker.library("scriptpeer")\n' + source.read_text())
        operands = ['--link=libc', '-L', str(library), str(script_source)]
        cases.extend([
            ('library-script-control', [*operands, '-o', str(root / 'script-product')], archive, True),
            ('library-script-payload-as-report', [*operands, '-o', str(root / 'script-refused'),
                                                  '--build-report=' + str(archive)], archive, False),
        ])
    results = []
    for name, operands, protected, succeeds in cases:
        before = protected.read_bytes()
        identity = protected.stat()
        result = subprocess.run([str(refine), 'compile', *operands], cwd=root,
                                env=env, capture_output=True, timeout=45)
        after = protected.stat()
        passed = ((result.returncode == 0 if succeeds else
                   result.returncode == 2 and b'L0002' in result.stderr)
                  and protected.read_bytes() == before
                  and (identity.st_dev, identity.st_ino) == (after.st_dev, after.st_ino)
                  and not list(temporary.iterdir())
                  and not list(root.glob('.refine-publication-*')))
        row = dict(case=name, command=result.args, exit_status=result.returncode,
                   passed=passed, protected=str(protected),
                   before_sha256=hashlib.sha256(before).hexdigest(),
                   stdout=result.stdout.decode(errors='replace'),
                   stderr=result.stderr.decode(errors='replace'))
        results.append(row)
        (root / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
        print(('PASS ' if passed else 'FAIL ') + name, flush=True)
        if not passed:
            raise AssertionError(row)
    print('compile publication: %d controls passed; evidence %s' % (len(results), root))


if __name__ == '__main__':
    main()
