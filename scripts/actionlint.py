#!/usr/bin/env python3
"""Hold every workflow to actionlint, at the version environments/pins.sh pins.

    python3 scripts/actionlint.py                  # the actionlint on PATH
    python3 scripts/actionlint.py --install DIR    # fetch the pinned one first

`nix develop` puts the pinned release binary on PATH.  Outside it,
`--install DIR` fetches that release for this host from its publisher,
refuses it unless its SHA-256 is the one the pins hold, unpacks it into
DIR and runs it; the gate's scripts job runs it that way.  An actionlint of
any other version is refused rather than run: a linter whose version
nobody pinned is a verdict nobody can repeat.

It reads `.github/actionlint.yaml`, which names the runner labels GitHub
does not host, and lints every workflow under `.github/workflows`.  The
shellcheck and pyflakes passes actionlint makes when it finds those tools
are turned off, so the verdict is the pinned binary's alone and not the
host's PATH: a runner image and a developer's profile carry different
shellchecks, or none.
"""
import argparse
import hashlib
import os
import platform
import re
import shutil
import subprocess
import sys
import tarfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import download  # noqa: E402

PINS = ROOT / "environments/pins.sh"
CONFIG = ROOT / ".github/actionlint.yaml"
WORKFLOWS = ROOT / ".github/workflows"

#  (system, machine) -> (the pins' checksum suffix, the release's asset).
ASSETS = {
    ("Linux", "x86_64"): ("X86_64_LINUX", "linux_amd64"),
    ("Linux", "aarch64"): ("AARCH64_LINUX", "linux_arm64"),
    ("Darwin", "arm64"): ("AARCH64_DARWIN", "darwin_arm64"),
}


class Refusal(Exception):
    """A run that cannot give a verdict; its text says what to do."""


def pins(path=PINS):
    """environments/pins.sh's NAME=value assignments."""
    return dict(re.findall(r"^(LANDIN_\w+)=(\S+)$",
                           path.read_text(encoding="utf-8"), re.M))


def asset(values, system=None, machine=None):
    """(archive name, URL, sha256) of the pinned release for this host."""
    system = system or platform.system()
    machine = machine or platform.machine()
    if (system, machine) not in ASSETS:
        raise Refusal("actionlint: no pinned actionlint for %s %s; the pins "
                      "hold %s" % (system, machine, ", ".join(
                          "%s %s" % key for key in sorted(ASSETS))))
    suffix, name = ASSETS[(system, machine)]
    version = values["LANDIN_ACTIONLINT_VERSION"]
    archive = "actionlint_%s_%s.tar.gz" % (version, name)
    url = "%s/v%s/%s" % (values["LANDIN_ACTIONLINT_RELEASES"], version, archive)
    return archive, url, values["LANDIN_ACTIONLINT_SHA256_" + suffix]


def install(directory, values, opener=None, sleep=None):
    """The pinned actionlint, fetched, verified and unpacked into DIRECTORY."""
    archive, url, sha256 = asset(values)
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / archive

    def store(response):
        with path.open("wb") as out:
            shutil.copyfileobj(response, out)
    try:
        download.download(url, archive, store, opener=opener,
                          **({"sleep": sleep} if sleep else {}),
                          report=lambda line: print(line, file=sys.stderr, flush=True))
    except download.DownloadError as error:
        raise Refusal("actionlint: " + str(error)) from error
    found = hashlib.sha256(path.read_bytes()).hexdigest()
    if found != sha256:
        path.unlink()
        raise Refusal("actionlint: %s from %s has SHA-256 %s, not the %s "
                      "environments/pins.sh holds" % (archive, url, found, sha256))
    with tarfile.open(path) as tar:
        member = tar.getmember("actionlint")
        if not member.isfile():
            raise Refusal("actionlint: %s holds no actionlint program" % archive)
        tar.extract(member, directory, filter="data")
    path.unlink()
    binary = directory / "actionlint"
    binary.chmod(0o755)
    return binary


def located(values):
    """The actionlint on PATH, refused unless it is the pinned version."""
    version = values["LANDIN_ACTIONLINT_VERSION"]
    found = shutil.which("actionlint")
    if found is None:
        raise Refusal(
            "actionlint: no actionlint on PATH.  `nix develop` provides the "
            "pinned %s; outside it, `python3 scripts/actionlint.py --install "
            "DIR` fetches that release, checked against environments/pins.sh, "
            "into DIR and runs it." % version)
    return Path(found)


def version_of(binary):
    """The first line `actionlint -version` prints."""
    completed = subprocess.run([str(binary), "-version"], capture_output=True,
                               text=True, timeout=60)
    lines = completed.stdout.splitlines()
    return lines[0].strip() if completed.returncode == 0 and lines else None


def workflows(directory=WORKFLOWS):
    return sorted(path for path in directory.iterdir()
                  if path.suffix in (".yml", ".yaml") and path.is_file())


def lint(binary, values, root=ROOT):
    """actionlint's exit status over every workflow; its report is printed."""
    version = values["LANDIN_ACTIONLINT_VERSION"]
    found = version_of(binary)
    if found != version:
        raise Refusal(
            "actionlint: %s is version %s and environments/pins.sh pins %s; "
            "`nix develop` provides the pinned one, as does `python3 "
            "scripts/actionlint.py --install DIR`" % (binary, found, version))
    files = workflows(root / ".github/workflows")
    command = [str(binary), "-config-file", str(root / ".github/actionlint.yaml"),
               "-shellcheck=", "-pyflakes=", "-no-color",
               *(str(path.relative_to(root)) for path in files)]
    completed = subprocess.run(command, cwd=root, timeout=300)
    if completed.returncode == 0:
        print("actionlint %s: %d workflows clean" % (version, len(files)))
    return completed.returncode


def main(argv=None):
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--install", metavar="DIR", type=Path,
                        help="fetch the pinned actionlint into DIR and run it")
    args = parser.parse_args(argv)
    values = pins()
    try:
        binary = install(args.install, values) if args.install else located(values)
        return lint(binary, values)
    except Refusal as refusal:
        print(refusal, file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
