#!/usr/bin/env python3
"""Run install.sh against a packaged compiler served as a release would be.

    scripts/install_check.py --archive ARCHIVE --work DIR [--version VERSION]
    scripts/install_check.py --published TAG

With `--archive`, ARCHIVE is what `scripts/package.sh` made for this host,
the archive a release publishes.  It is served from 127.0.0.1 in the
layout GitHub serves a release in: `releases/latest` redirects to
`releases/tag/vVERSION`, and the archive and its `.sha256` are under
`releases/download/vVERSION/` by the names the release workflow gives
them.  `install.sh`, pointed there by `LANDIN_RELEASES`, then

- installs the newest release into the default directory under a scratch
  HOME, whose `refine run` runs the first program and prints its output;
- installs the named version into a directory given with `--dir`, and
  replaces it when run again;
- refuses a damaged archive, saying the checksum differs, and installs
  nothing;
- refuses a host no archive serves, a FreeBSD and a Linux RISC-V that a
  `uname` earlier on PATH reports, naming the routes that do serve them;
- refuses a version the releases do not have.

The script runs with PATH and HOME alone besides `LANDIN_RELEASES`, so
nothing a developer's shell provides stands in for what it lacks.  VERSION
is 0.0.0 when not given: the archive's compiler is the gate's development
build, and the script takes the version from the release's address, never
from the compiler.

With `--published`, TAG is a published release: every name `install.sh
--list` gives for its version must be one of the release's assets, and
every archive the release publishes must be one `install.sh` names, as
`gh release view` lists them.  docs/process.md's release recipe runs it.
"""

import argparse
import hashlib
import http.server
import json
import os
import pathlib
import platform as host
import re
import shutil
import stat
import subprocess
import sys
import threading

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "install.sh"
FIRST_PROGRAM = ROOT / "compiler/tests/fixtures/runtime/first-program"
DAMAGED = "0.0.1"
MISSING = "0.0.2"
SERVED = "0.0.0"


def host_platform():
    machine = {"x86_64": "x86_64", "amd64": "x86_64", "aarch64": "aarch64",
               "arm64": "aarch64"}.get(host.machine().lower())
    system = {"Linux": "linux", "Darwin": "darwin"}.get(host.system())
    if machine is None or system is None:
        raise SystemExit("install check: no release archive serves %s on %s"
                         % (host.system(), host.machine()))
    return "%s-%s" % (machine, system)


def publish(root, version, platform, data, digest=None):
    """Put DATA where a release of VERSION serves PLATFORM's archive, with
    a .sha256 of DIGEST, or of DATA itself."""
    name = "landin-%s-%s.tar.gz" % (version, platform)
    where = root / "releases" / "download" / ("v" + version)
    where.mkdir(parents=True, exist_ok=True)
    (where / name).write_bytes(data)
    digest = digest or hashlib.sha256(data).hexdigest()
    (where / (name + ".sha256")).write_text("%s  %s\n" % (digest, name))


class Releases(http.server.SimpleHTTPRequestHandler):
    """GitHub's layout: `latest` redirects to the newest tag's page."""

    newest = None

    def do_GET(self):  # noqa: N802 -- the base class's name
        if self.path.rstrip("/") == "/releases/latest":
            self.send_response(302)
            self.send_header("Location", "/releases/tag/v" + self.newest)
            self.end_headers()
            return
        if self.path.startswith("/releases/tag/"):
            body = b"a release page\n"
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        super().do_GET()

    def log_message(self, *args):
        pass


def serve(root, newest):
    handler = type("Served", (Releases,), {"newest": newest})
    server = http.server.ThreadingHTTPServer(
        ("127.0.0.1", 0),
        lambda *a, **k: handler(*a, directory=str(root), **k))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def fake_uname(bin_dir, system, machine):
    bin_dir.mkdir(parents=True, exist_ok=True)
    path = bin_dir / "uname"
    path.write_text("#!/bin/sh\ncase $1 in -s) echo %s ;; -m) echo %s ;; "
                    "*) echo %s ;; esac\n" % (system, machine, system))
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP
               | stat.S_IXOTH)


class Checks:
    def __init__(self, work, releases, path):
        self.work = work
        self.releases = releases
        self.path = path
        self.failures = []
        self.passed = 0

    def install(self, *argv, home=None, path=None):
        home = home or self.work / "home"
        home.mkdir(parents=True, exist_ok=True)
        env = {"PATH": path or self.path, "HOME": str(home),
               "LANDIN_RELEASES": self.releases}
        return subprocess.run(["sh", str(SCRIPT)] + list(argv), env=env,
                              cwd=self.work, capture_output=True, text=True,
                              timeout=600)

    def expect(self, what, ran, status, *said):
        shown = "%s exited %d\n%s%s" % (what, ran.returncode, ran.stdout,
                                       ran.stderr)
        if (ran.returncode == 0) != (status == 0):
            self.failures.append("%s: expected %s\n%s" % (
                what, "success" if status == 0 else "a refusal", shown))
            return False
        missing = [one for one in said
                   if one not in ran.stdout + ran.stderr]
        if missing:
            self.failures.append("%s: did not say %r\n%s"
                                 % (what, missing, shown))
            return False
        return True

    def ok(self, what):
        self.passed += 1
        print("ok   %s" % what)

    def first_program(self, prefix, what):
        """The installed refine runs the first program."""
        project = self.work / ("first-" + prefix.name)
        project.mkdir(exist_ok=True)
        shutil.copy(FIRST_PROGRAM / "main.ldn", project / "main.ldn")
        env = {"PATH": "%s:%s" % (prefix / "bin", self.path),
               "TMPDIR": str(self.work)}
        ran = subprocess.run(["refine", "run", "main.ldn"], cwd=project,
                             env=env, capture_output=True, timeout=600)
        expected = (FIRST_PROGRAM / "output.txt").read_bytes()
        if ran.returncode != 0 or ran.stdout != expected:
            self.failures.append(
                "%s: refine run main.ldn exited %d, printing\n%s%s" % (
                    what, ran.returncode,
                    ran.stdout.decode("utf-8", "replace"),
                    ran.stderr.decode("utf-8", "replace")))
            return False
        return True


def run_checks(archive, work, version, platform=None, path=None):
    """Every case against ARCHIVE served as VERSION's; the failures.
    PLATFORM, given, is passed as `--platform` rather than detected."""
    work = pathlib.Path(work).resolve()
    if work == ROOT or ROOT in work.parents:
        raise SystemExit("install check: %s is inside the checkout" % work)
    if work.exists():
        shutil.rmtree(work)
    work.mkdir(parents=True)
    named = platform or host_platform()
    chosen = ["--platform", platform] if platform else []
    data = pathlib.Path(archive).read_bytes()
    served = work / "served"
    publish(served, version, named, data)
    damaged = bytearray(data)
    damaged[len(damaged) // 2] ^= 0xFF
    publish(served, DAMAGED, named, bytes(damaged),
            hashlib.sha256(data).hexdigest())
    server = serve(served, version)
    path = path or os.environ.get("PATH", "/usr/bin:/bin")
    checks = Checks(work, "http://127.0.0.1:%d/releases"
                    % server.server_address[1], path)
    try:
        home = work / "home"
        what = "the newest release into $HOME/.landin"
        ran = checks.install(*chosen)
        if (checks.expect(what, ran, 0, "installed refine %s" % version,
                          'export PATH="%s/.landin/bin:$PATH"' % home)
                and checks.first_program(home / ".landin", what)):
            checks.ok(what)

        target = work / "opt" / "landin"
        what = "version %s into --dir" % version
        ran = checks.install(*chosen, "--version", "v" + version,
                             "--dir", str(target))
        if (checks.expect(what, ran, 0, "installed refine %s in %s"
                          % (version, target))
                and checks.first_program(target, what)):
            checks.ok(what)

        what = "the same again over the earlier install, on PATH"
        ran = checks.install(*chosen, "--version", version, "--dir",
                             str(target), path="%s:%s" % (target / "bin",
                                                          path))
        if (checks.expect(what, ran, 0, "is on your PATH already")
                and checks.first_program(target, what)
                and sorted(p.name for p in target.parent.iterdir())
                == ["landin"]):
            checks.ok(what)

        stranger = work / "stranger"
        stranger.mkdir()
        (stranger / "notes.txt").write_text("mine\n")
        what = "a directory holding something else"
        ran = checks.install(*chosen, "--version", version, "--dir",
                             str(stranger))
        if (checks.expect(what, ran, 1, "holds no earlier install")
                and sorted(p.name for p in stranger.iterdir())
                == ["notes.txt"]):
            checks.ok(what)

        damaged_dir = work / "damaged"
        what = "a damaged archive"
        ran = checks.install(*chosen, "--version", DAMAGED, "--dir",
                             str(damaged_dir))
        if (checks.expect(what, ran, 1, "does not match its checksum",
                          "Nothing was installed")
                and not damaged_dir.exists()
                and not any(p.name.startswith(".landin-install")
                            for p in work.iterdir())):
            checks.ok(what)

        what = "a version the releases do not have"
        ran = checks.install(*chosen, "--version", MISSING, "--dir",
                             str(work / "missing"))
        if (checks.expect(what, ran, 1, "could not download")
                and not (work / "missing").exists()):
            checks.ok(what)

        for system, machine in (("FreeBSD", "amd64"), ("Linux", "riscv64")):
            fake = work / ("uname-%s-%s" % (system, machine))
            fake_uname(fake, system, machine)
            what = "an unserved host, %s on %s" % (system, machine)
            ran = checks.install("--dir", str(work / "unserved"),
                                 path="%s:%s" % (fake, path))
            if (checks.expect(what, ran, 1, "no release archive serves %s on %s"
                              % (system, machine),
                              "nix profile install", "from-source")
                    and not (work / "unserved").exists()):
                checks.ok(what)
    finally:
        server.shutdown()
        server.server_close()
    return checks.passed, checks.failures


def published_check(tag):
    version = tag[1:] if tag.startswith("v") else tag
    listed = subprocess.run(
        ["sh", str(SCRIPT), "--list", "--version", version],
        capture_output=True, text=True, check=True).stdout.split()
    viewed = subprocess.run(
        ["gh", "release", "view", "v" + version, "--repo", "701-dev/Landin",
         "--json", "assets"], capture_output=True, text=True, check=True)
    assets = {one["name"] for one in json.loads(viewed.stdout)["assets"]}
    failures = ["install.sh names %s, which v%s does not publish"
                % (name, version) for name in listed if name not in assets]
    archives = {name for name in assets
                if re.fullmatch(r"landin-[0-9.]+-[a-z0-9_]+-[a-z]+\.tar\.gz",
                                name)}
    failures += ["v%s publishes %s, which install.sh does not name"
                 % (version, name) for name in sorted(archives - set(listed))]
    return len(listed), failures


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--archive", type=pathlib.Path)
    parser.add_argument("--work", type=pathlib.Path)
    parser.add_argument("--version")
    parser.add_argument("--published", metavar="TAG")
    args = parser.parse_args()
    if args.published:
        count, failures = published_check(args.published)
        what = "names"
    elif args.archive and args.work:
        count, failures = run_checks(args.archive, args.work,
                                     args.version or SERVED)
        what = "cases passed"
    else:
        parser.error("give --archive and --work, or --published")
    for failure in failures:
        print("FAIL " + failure, file=sys.stderr)
    print("install check: %d %s, %d failed" % (count, what, len(failures)))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
