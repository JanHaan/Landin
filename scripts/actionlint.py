#!/usr/bin/env python3
"""Hold every workflow to actionlint and shellcheck, at the versions
environments/pins.sh pins.

    python3 scripts/actionlint.py                  # the two on PATH
    python3 scripts/actionlint.py --install DIR    # fetch the pinned ones first

`nix develop` puts both pinned release binaries on PATH.  Outside it,
`--install DIR` fetches those releases for this host from their
publishers, refuses each unless its SHA-256 is the one the pins hold,
unpacks them into DIR and runs actionlint; the gate's scripts job runs it
that way.  A program of any other version is refused rather than run: a
linter whose version nobody pinned is a verdict nobody can repeat.

It reads `.github/actionlint.yaml`, which names the runner labels GitHub
does not host, and lints every workflow under `.github/workflows`.
actionlint's shellcheck pass runs the pinned shellcheck, named by its path,
over every `run:` script, so a finding there fails the run as actionlint's
own do.  The pyflakes pass is turned off: no step runs Python as its shell,
so it has nothing to read, and pyflakes publishes no release binary to pin
as these two are.
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

#  (system, machine) -> the pins' checksum suffix, and each tool's asset.
ASSETS = {
    ("Linux", "x86_64"): ("X86_64_LINUX", "linux_amd64", "linux.x86_64"),
    ("Linux", "aarch64"): ("AARCH64_LINUX", "linux_arm64", "linux.aarch64"),
    ("Darwin", "arm64"): ("AARCH64_DARWIN", "darwin_arm64", "darwin.aarch64"),
}

#  The two programs: the pins' name for each, the archive member that is
#  the program, and how the release names its archive from the version
#  and the asset.
TOOLS = {
    "actionlint": ("ACTIONLINT", 1, "actionlint",
                   lambda version, name: "actionlint_%s_%s.tar.gz" % (version, name)),
    "shellcheck": ("SHELLCHECK", 2, "shellcheck-v{version}/shellcheck",
                   lambda version, name: "shellcheck-v%s.%s.tar.xz" % (version, name)),
}


class Refusal(Exception):
    """A run that cannot give a verdict; its text says what to do."""


def pins(path=PINS):
    """environments/pins.sh's NAME=value assignments."""
    return dict(re.findall(r"^(LANDIN_\w+)=(\S+)$",
                           path.read_text(encoding="utf-8"), re.M))


def asset(values, system=None, machine=None, tool="actionlint"):
    """(archive name, URL, sha256) of TOOL's pinned release for this host."""
    system = system or platform.system()
    machine = machine or platform.machine()
    if (system, machine) not in ASSETS:
        raise Refusal("actionlint: no pinned %s for %s %s; the pins "
                      "hold %s" % (tool, system, machine, ", ".join(
                          "%s %s" % key for key in sorted(ASSETS))))
    pinned, column, _, archive_of = TOOLS[tool]
    suffix, name = ASSETS[(system, machine)][0], ASSETS[(system, machine)][column]
    version = values["LANDIN_%s_VERSION" % pinned]
    archive = archive_of(version, name)
    url = "%s/v%s/%s" % (values["LANDIN_%s_RELEASES" % pinned], version, archive)
    return archive, url, values["LANDIN_%s_SHA256_%s" % (pinned, suffix)]


def fetch(directory, values, tool, opener=None, sleep=None):
    """TOOL's pinned release, fetched, verified and unpacked into DIRECTORY."""
    archive, url, sha256 = asset(values, tool=tool)
    pinned, _, member_name, _ = TOOLS[tool]
    member_name = member_name.format(
        version=values["LANDIN_%s_VERSION" % pinned])
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
    binary = directory / tool
    with tarfile.open(path) as tar:
        try:
            member = tar.getmember(member_name)
        except KeyError:
            member = None
        if member is None or not member.isfile():
            path.unlink()
            raise Refusal("actionlint: %s holds no %s program" % (archive, tool))
        with tar.extractfile(member) as source, binary.open("wb") as out:
            shutil.copyfileobj(source, out)
    path.unlink()
    binary.chmod(0o755)
    return binary


def install(directory, values, opener=None, sleep=None):
    """The pinned actionlint and shellcheck, fetched, verified and unpacked
    into DIRECTORY: {tool: path}."""
    return {tool: fetch(directory, values, tool, opener=opener, sleep=sleep)
            for tool in TOOLS}


def located(values):
    """The actionlint and shellcheck on PATH, {tool: path}; refused when
    one is missing.  Their versions are lint's to judge."""
    found = {tool: shutil.which(tool) for tool in TOOLS}
    missing = [tool for tool in TOOLS if found[tool] is None]
    if missing:
        raise Refusal(
            "actionlint: no %s on PATH.  `nix develop` provides the pinned "
            "%s; outside it, `python3 scripts/actionlint.py --install DIR` "
            "fetches those releases, checked against environments/pins.sh, "
            "into DIR and runs them." % (
                " or ".join(missing),
                " and ".join("%s %s" % (tool, values["LANDIN_%s_VERSION"
                                                    % TOOLS[tool][0]])
                             for tool in TOOLS)))
    return {tool: Path(path) for tool, path in found.items()}


def version_of(binary, tool="actionlint"):
    """The version TOOL's BINARY says it is: actionlint's first line of
    `-version`, shellcheck's `version:` line of `--version`."""
    flag = "-version" if tool == "actionlint" else "--version"
    completed = subprocess.run([str(binary), flag], capture_output=True,
                               text=True, timeout=60)
    if completed.returncode != 0:
        return None
    lines = completed.stdout.splitlines()
    if tool == "actionlint":
        return lines[0].strip() if lines else None
    for line in lines:
        if line.startswith("version:"):
            return line[len("version:"):].strip()
    return None


def workflows(directory=WORKFLOWS):
    return sorted(path for path in directory.iterdir()
                  if path.suffix in (".yml", ".yaml") and path.is_file())


def lint(binaries, values, root=ROOT):
    """actionlint's exit status over every workflow, with the pinned
    shellcheck's pass over each `run:` script; its report is printed."""
    for tool, binary in sorted(binaries.items()):
        version = values["LANDIN_%s_VERSION" % TOOLS[tool][0]]
        found = version_of(binary, tool)
        if found != version:
            raise Refusal(
                "actionlint: %s is %s version %s and environments/pins.sh "
                "pins %s; `nix develop` provides the pinned one, as does "
                "`python3 scripts/actionlint.py --install DIR`"
                % (binary, tool, found, version))
    files = workflows(root / ".github/workflows")
    command = [str(binaries["actionlint"]),
               "-config-file", str(root / ".github/actionlint.yaml"),
               "-shellcheck=" + str(binaries["shellcheck"]), "-pyflakes=",
               "-no-color",
               *(str(path.relative_to(root)) for path in files)]
    completed = subprocess.run(command, cwd=root, timeout=300)
    if completed.returncode == 0:
        print("actionlint %s with shellcheck %s: %d workflows clean" % (
            values["LANDIN_ACTIONLINT_VERSION"],
            values["LANDIN_SHELLCHECK_VERSION"], len(files)))
    return completed.returncode


def main(argv=None):
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--install", metavar="DIR", type=Path,
                        help="fetch the pinned actionlint and shellcheck"
                        " into DIR and run them")
    args = parser.parse_args(argv)
    values = pins()
    try:
        binaries = (install(args.install, values) if args.install
                    else located(values))
        return lint(binaries, values)
    except Refusal as refusal:
        print(refusal, file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
