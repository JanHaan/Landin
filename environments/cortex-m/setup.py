#!/usr/bin/env python3
"""Install the pinned Cortex-M tools privately on Linux x86-64 (no sudo)."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import urllib.request

HERE = Path(__file__).resolve().parent
DEFAULT = Path.home() / "work/.cortex-m"
PINS = HERE.parent / "pins.sh"
#  GCC and binutils are GNAT's arm-elf archive, and for the RV32 lanes its
#  riscv64-elf archive, from the release the host GNAT comes from, and
#  pinned beside it in environments/pins.sh; the lock keeps QEMU, Espressif's
#  QEMU for the RV32 lanes, and the GDB whose Python the sessions run.
ARM = "gnat-arm-elf"
RISCV = "gnat-riscv64-elf"
#  Where Espressif's QEMU release, one of the lock's archives, is unpacked.
ESPRESSIF = "qemu-espressif"


def pins():
    """environments/pins.sh's assignments, which this file never repeats."""
    return dict(re.findall(r"^(LANDIN_\w+)=(\S+)$", PINS.read_text(), re.M))


def arm_archive():
    """The pinned arm-elf archive for this host: its URL, file and sha256."""
    values = pins()
    version = values["LANDIN_GNAT_ARM_ELF_VERSION"]
    name = "gnat-arm-elf-linux64-x86_64-%s.tar.gz" % version
    return {"url": "%s/gnat-%s/%s" % (values["LANDIN_RELEASES"], version, name),
            "file": name, "version": version,
            "sha256": values["LANDIN_GNAT_ARM_ELF_SHA256_X86_64_LINUX"]}


def riscv_archive():
    """The pinned riscv64-elf archive for this host: its URL, file and sha256."""
    values = pins()
    version = values["LANDIN_GNAT_RISCV64_ELF_VERSION"]
    name = "gnat-riscv64-elf-linux64-x86_64-%s.tar.gz" % version
    return {"url": "%s/gnat-%s/%s" % (values["LANDIN_RELEASES"], version, name),
            "file": name, "version": version,
            "sha256": values["LANDIN_GNAT_RISCV64_ELF_SHA256_X86_64_LINUX"]}


def sha(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


#  What an installation holds, each inventoried whole.
AREAS = ('root', ARM, RISCV, ESPRESSIF)


def inventory(root):
    return {p.relative_to(root).as_posix(): sha(p) for p in sorted(root.rglob("*"))
            if p.is_file() and '__pycache__' not in p.parts}


#  The lock carries every shared library its tools load except the C and C++
#  runtimes, which come from the host.  Its newest binary asks for glibc 2.38,
#  so that is the host it needs, whichever distribution supplies it.
GLIBC = (2, 38)


def supported_host(output=None):
    """Refuse a host the locked tools cannot run on, before anything builds.

    OUTPUT is the lane's --output, which must outlive the run.
    """
    if platform.system() != "Linux" or platform.machine() != "x86_64":
        raise RuntimeError("embedded probes require native Linux x86-64")
    library, version = platform.libc_ver()
    parts = version.split('.')[:2]
    if (library != 'glibc' or not all(part.isdigit() for part in parts)
            or tuple(map(int, parts)) < GLIBC):
        raise RuntimeError("embedded profile requires glibc %d.%d or later" % GLIBC)
    nixos_route(output)


LOADER = '/lib64/ld-linux-x86-64.so.2'


def nixos_route(output=None):
    """On NixOS, refuse what the locked Debian binaries cannot run under,
    naming the route that runs them.

    NixOS's own loader path holds a stub that refuses a binary built for
    another distribution, so QEMU and GDB start only inside an FHS
    environment such as steam-run's.  That environment gives /tmp a
    private namespace: a TMPDIR the outer shell set into it does not exist
    inside, so refine cannot make its files, and an --output under /tmp
    vanishes when the lane ends.
    """
    lane = 'environments/cortex-m/' + os.path.basename(sys.argv[0] or 'run.py')
    route = (
        'mkdir -p $HOME/.cache/landin/tmp\n'
        '  NIXPKGS_ALLOW_UNFREE=1 nix-shell -p steam-run python3 --run \\\n'
        '    "TMPDIR=$HOME/.cache/landin/tmp steam-run python3 %s'
        ' --tools DIR --refine REFINE --output $HOME/NEW-DIRECTORY ..."\n'
        'See environments/cortex-m/README.md#on-nixos.' % lane)
    stub = 'stub-ld' in os.path.realpath(LOADER) or (
        os.path.exists('/etc/NIXOS') and not os.path.exists(LOADER))
    if stub:
        raise SystemExit(
            'cortex-m: the locked QEMU and GDB are Debian binaries, and this NixOS host\'s'
            ' %s is its stub loader, which refuses them.  Run the lane inside steam-run\'s'
            ' FHS environment, with TMPDIR and --output under $HOME, because steam-run'
            ' gives /tmp a private namespace:\n  %s' % (LOADER, route))
    inside = not os.path.exists('/etc/NIXOS') and os.path.isdir('/run/current-system')
    if not inside:
        return
    temporary = os.environ.get('TMPDIR')
    if temporary and not os.path.isdir(temporary):
        raise SystemExit(
            'cortex-m: TMPDIR is %s, which does not exist inside this FHS environment:'
            ' steam-run gives /tmp a private namespace, so set TMPDIR under $HOME:\n  %s'
            % (temporary, route))
    if output is not None and Path(os.path.abspath(output)).is_relative_to('/tmp'):
        raise SystemExit(
            'cortex-m: --output %s is under /tmp, which this FHS environment keeps private'
            ' and discards when the lane ends; give an --output under $HOME:\n  %s'
            % (output, route))


def installed_tools(path):
    """The resolved tool root, refused before any build if nothing is installed there.

    Every lane runs `gnat-arm-elf/bin/arm-eabi-gcc` and friends under the
    root its --tools names, which defaults to DEFAULT; without this a host
    whose tools are elsewhere failed each profile with "No such file or
    directory" from a compile, naming neither where it looked nor how to
    look elsewhere.
    """
    root = Path(path).expanduser().resolve()
    missing = [relative for relative in ('installation.json', ARM + '/bin/arm-eabi-gcc',
                                         RISCV + '/bin/riscv64-elf-gcc',
                                         'root/usr/bin/qemu-system-arm', 'root/usr/bin/gdb-multiarch',
                                         ESPRESSIF + '/bin/qemu-system-riscv32')
               if not (root / relative).is_file()]
    if missing:
        raise SystemExit(
            'cortex-m: the locked Cortex-M tools are not installed at %s (no %s).\n'
            'Pass --tools DIRECTORY where `python3 environments/cortex-m/setup.py --tools DIRECTORY`'
            ' installed them, or install them there; the default is %s.'
            % (root, ', '.join(missing), DEFAULT))
    return root


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


def fetch(packages, item):
    """ITEM's archive downloaded into PACKAGES and verified before anything unpacks it."""
    dest = packages / item['file']
    with urllib.request.urlopen(item['url'], timeout=60) as src, dest.open('wb') as out:
        shutil.copyfileobj(src, out)
    if sha(dest) != item['sha256']:
        raise RuntimeError('archive hash mismatch: ' + item['file'])
    return dest


def unpack(archive, into, mode):
    """A release archive's one top directory unpacked as INTO itself."""
    into.mkdir()
    subprocess.run(['tar', mode, str(archive), '-C', str(into), '--strip-components=1'],
                   check=True, timeout=600)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tools', type=Path, default=DEFAULT)
    args = parser.parse_args()
    supported_host(args.tools)
    root = args.tools.resolve()
    if root.exists():
        raise RuntimeError("installation already exists; choose a fresh --tools directory")
    root.mkdir(parents=True)
    packages = root / 'downloads'
    packages.mkdir()
    for item in json.loads((HERE / 'tools.lock.json').read_text()):
        dest = fetch(packages, item)
        if item['kind'] == 'deb':
            subprocess.run(['dpkg-deb', '-x', str(dest), str(root / 'root')], check=True, timeout=30)
        elif item['kind'] == 'tar.xz' and item.get('into') == ESPRESSIF:
            unpack(dest, root / item['into'], '-xJf')
        else:
            raise RuntimeError('unknown archive kind: ' + item['kind'])
    for area, archive in ((ARM, arm_archive()), (RISCV, riscv_archive())):
        unpack(fetch(packages, archive), root / area, '-xzf')
    compile_gdb_python(root)
    record = {'lock_sha256': sha(HERE / 'tools.lock.json'),
              'arm': {key: arm_archive()[key] for key in ('version', 'sha256')},
              'riscv': {key: riscv_archive()[key] for key in ('version', 'sha256')},
              'files': {area: inventory(root / area) for area in AREAS}}
    (root / 'installation.json').write_text(json.dumps(record, sort_keys=True) + '\n')
    print('installed pinned Cortex-M environment at', root)


if __name__ == '__main__':
    main()
