#!/usr/bin/env python3
"""Install the pinned Cortex-M tools privately on Debian 13 x86-64 (no sudo)."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tarfile
import urllib.request

HERE = Path(__file__).resolve().parent
DEFAULT = Path.home() / "work/.cortex-m"


def sha(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def inventory(root):
    return {p.relative_to(root).as_posix(): sha(p) for p in sorted(root.rglob("*"))
            if p.is_file() and '__pycache__' not in p.parts}


def supported_host():
    if platform.system() != "Linux" or platform.machine() != "x86_64":
        raise RuntimeError("embedded probes require native Linux x86-64")
    release = Path('/etc/os-release').read_text()
    if 'ID=debian\n' not in release or 'VERSION_ID="13"' not in release:
        raise RuntimeError("embedded profile requires Debian 13")


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
        if item['kind'] == 'deb':
            subprocess.run(['dpkg-deb', '-x', str(dest), str(root / 'root')], check=True, timeout=30)
        else:
            # Trusted pinned archive; reject escaping members and link targets.
            with tarfile.open(dest) as archive:
                archive.extractall(root / 'renode', filter='data')
    record = {'lock_sha256': sha(HERE / 'tools.lock.json'),
              'files': {area: inventory(root / area) for area in ('root', 'renode')}}
    (root / 'installation.json').write_text(json.dumps(record, sort_keys=True) + '\n')
    print('installed pinned Cortex-M environment at', root)


if __name__ == '__main__':
    main()
