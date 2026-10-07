#!/usr/bin/env python3
"""Verify a persistent pinned installation, or install it from checked archives.

The record binds archive pins to the complete installed byte/path/mode inventory.
A missing record, changed pin or altered inventory installs into a fresh directory.
It records tool installation only, never compiler or test success.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def inventory(root):
    rows = [[".", stat.S_IMODE(root.stat().st_mode), "directory"]]
    def walk_error(error):
        raise error
    for parent, dirs, files in os.walk(root, followlinks=False, onerror=walk_error):
        for name in sorted(dirs + files):
            path = Path(parent) / name
            info = path.lstat()
            row = [path.relative_to(root).as_posix(), stat.S_IMODE(info.st_mode)]
            if stat.S_ISLNK(info.st_mode):
                row += ["link", os.readlink(path)]
            elif stat.S_ISDIR(info.st_mode):
                row += ["directory"]
            elif stat.S_ISREG(info.st_mode):
                digest = hashlib.sha256()
                with path.open("rb") as stream:
                    for block in iter(lambda: stream.read(1024 * 1024), b""):
                        digest.update(block)
                row += ["file", digest.hexdigest()]
            else:
                raise ValueError("unsupported toolchain file: " + str(path))
            rows.append(row)
    return sorted(rows)


def pins(platform):
    suffix = platform.upper().replace("-", "_")
    if platform not in ("x86_64-linux", "aarch64-linux", "aarch64-darwin"):
        raise ValueError("unsupported toolchain platform: " + platform)
    names = ["LANDIN_GNAT_VERSION", "LANDIN_GPRBUILD_VERSION",
             "LANDIN_GNAT_SHA256_" + suffix, "LANDIN_GPRBUILD_SHA256_" + suffix]
    command = '. ./environments/pins.sh\n'
    command += '\nprintf "%s\\n" ' + " ".join('"$%s"' % name for name in names)
    values = subprocess.run(["bash", "-eu", "-c", command], cwd=ROOT,
                            check=True, stdout=subprocess.PIPE, text=True).stdout.splitlines()
    if len(values) != 4 or not all(values):
        raise ValueError("incomplete toolchain pins")
    return {"platform": platform, "gnat": values[0], "gprbuild": values[1],
            "gnat_sha256": values[2], "gprbuild_sha256": values[3]}


def directories(expected):
    return ["gnat-" + expected["gnat"], "gprbuild-" + expected["gprbuild"]]


def installed_inventory(into, expected):
    result = {}
    for directory in directories(expected):
        root = into / directory
        if not root.is_dir() or root.is_symlink():
            raise ValueError("missing toolchain directory: " + str(root))
        result[directory] = inventory(root)
    return result


def verify(into, expected):
    record = into / (".landin-install-" + expected["platform"] + ".json")
    try:
        saved = json.loads(record.read_text())
        return (saved["schema"] == 1 and saved["pins"] == expected
                and saved["inventory"] == installed_inventory(into, expected))
    except (OSError, ValueError, KeyError, TypeError):
        return False


def install(into, expected, installer=None):
    into.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".landin-install-", dir=into) as temporary:
        stage = Path(temporary)
        if installer is None:
            subprocess.run([
                "bash", "-eu", "-c",
                '. ./environments/pins.sh; landin_install_toolchain "$1" "$2"',
                "landin-install", str(stage), expected["platform"]], cwd=ROOT, check=True)
        else:
            installer(stage)
        checked = installed_inventory(stage, expected)
        moved = []
        try:
            for name in directories(expected):
                destination = into / name
                backup = stage / (name + ".previous")
                if destination.exists() or destination.is_symlink():
                    destination.rename(backup)
                moved.append((destination, backup))
                (stage / name).rename(destination)
            record = into / (".landin-install-" + expected["platform"] + ".json")
            pending = stage / "record.json"
            pending.write_text(json.dumps({"schema": 1, "pins": expected,
                                           "inventory": checked}, sort_keys=True) + "\n")
            pending.replace(record)
        except BaseException:
            for destination, backup in reversed(moved):
                if destination.is_symlink():
                    destination.unlink()
                elif destination.exists():
                    shutil.rmtree(destination)
                if backup.exists() or backup.is_symlink():
                    backup.rename(destination)
            raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("into", type=Path)
    parser.add_argument("platform")
    parser.add_argument("--fresh", action="store_true",
                        help="install even if the complete inventory matches")
    args = parser.parse_args()
    expected = pins(args.platform)
    if not args.fresh and verify(args.into, expected):
        print("landin: pinned toolchain installation verified; reusing installed bytes")
    else:
        install(args.into, expected)
        if not verify(args.into, expected):
            raise ValueError("installed toolchain failed inventory verification")
        print("landin: pinned toolchain installed and inventory verified")


if __name__ == "__main__":
    main()
