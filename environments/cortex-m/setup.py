#!/usr/bin/env python3
"""Install the pinned Cortex-M tools privately on Linux x86-64 (no sudo)."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import urllib.request

HERE = Path(__file__).resolve().parent
DEFAULT = Path.home() / "work/.cortex-m"


def sha(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def inventory(root):
    return {p.relative_to(root).as_posix(): sha(p) for p in sorted(root.rglob("*"))
            if p.is_file() and '__pycache__' not in p.parts}


#  The lock carries every shared library its tools load except the C and C++
#  runtimes, which come from the host.  Its newest binary asks for glibc 2.38,
#  so that is the host it needs, whichever distribution supplies it.
GLIBC = (2, 38)


def supported_host():
    if platform.system() != "Linux" or platform.machine() != "x86_64":
        raise RuntimeError("embedded probes require native Linux x86-64")
    library, version = platform.libc_ver()
    parts = version.split('.')[:2]
    if (library != 'glibc' or not all(part.isdigit() for part in parts)
            or tuple(map(int, parts)) < GLIBC):
        raise RuntimeError("embedded profile requires glibc %d.%d or later" % GLIBC)


def compile_gdb_python(root):
    """Byte-compile the Python GDB embeds, with GDB's own interpreter.

    The lock ships its standard library as source, and without bytecode every
    GDB start compiles what it imports: about 200 ms a session where 80 would
    do, over two thousand sessions.  Compiling once here, rather than letting
    the first session write it, makes every session start the same way;
    `inventory` still ignores `__pycache__`, so the record is unchanged.
    """
    usr = root / 'root/usr'
    env = dict(os.environ, LD_LIBRARY_PATH=str(usr / 'lib/x86_64-linux-gnu'))
    program = ('import compileall, sys; ok = all(compileall.compile_dir(d, quiet=1)'
               ' for d in sys.argv[1:]); print("compiled" if ok else "failed")')
    completed = subprocess.run(
        [usr / 'bin/gdb-multiarch', '-q', '-nx', '-batch', '-ex',
         'python import sys; sys.argv = %r; exec(%r)'
         % (['', str(usr / 'lib/python3.13'), str(usr / 'share/gdb/python')], program)],
        env=env, capture_output=True, text=True, timeout=300)
    if completed.returncode != 0 or completed.stdout.strip() != 'compiled':
        raise RuntimeError('compiling GDB\'s Python failed: ' + completed.stdout + completed.stderr)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tools', type=Path, default=DEFAULT)
    args = parser.parse_args()
    supported_host()
    root = args.tools.resolve()
    if root.exists():
        raise RuntimeError("installation already exists; choose a fresh --tools directory")
    root.mkdir(parents=True)
    packages = root / 'downloads'
    packages.mkdir()
    for item in json.loads((HERE / 'tools.lock.json').read_text()):
        dest = packages / item['file']
        with urllib.request.urlopen(item['url'], timeout=60) as src, dest.open('wb') as out:
            shutil.copyfileobj(src, out)
        if sha(dest) != item['sha256']:
            raise RuntimeError('archive hash mismatch: ' + item['file'])
        if item['kind'] != 'deb':
            raise RuntimeError('unknown archive kind: ' + item['kind'])
        subprocess.run(['dpkg-deb', '-x', str(dest), str(root / 'root')], check=True, timeout=30)
    compile_gdb_python(root)
    record = {'lock_sha256': sha(HERE / 'tools.lock.json'),
              'files': {area: inventory(root / area) for area in ('root',)}}
    (root / 'installation.json').write_text(json.dumps(record, sort_keys=True) + '\n')
    print('installed pinned Cortex-M environment at', root)


if __name__ == '__main__':
    main()
