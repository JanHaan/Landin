#!/usr/bin/env python3
"""Serialize SourceHut Pages publication through a canonical Git lease."""
import argparse
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tarfile
import tempfile
import time
import uuid

from common import Invalid, require

CANONICAL_WRITE = "git@git.sr.ht:~sinnfrei/landin"
LOCK_REF = "refs/tags/ci/publication-lock"


def run(argv, *, cwd=None, input=None, capture=False, timeout=30):
    """Bound the complete subprocess group, including approval's Git calls."""
    process = subprocess.Popen(argv, cwd=cwd, stdin=subprocess.PIPE if input is not None else None,
                               stdout=subprocess.PIPE if capture else None,
                               stderr=subprocess.PIPE if capture else None,
                               start_new_session=True)
    try:
        stdout, stderr = process.communicate(input, timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.communicate()
        raise
    if process.returncode:
        raise subprocess.CalledProcessError(process.returncode, argv, stdout, stderr)
    return stdout


def git(root, *args, input=None):
    return run(["git", "-C", str(root), *args], input=input, capture=True)


def approved(root):
    output = run([sys.executable, str(root / "scripts/ci/approval.py"),
                  "--root", str(root)], capture=True, timeout=60).decode().strip()
    prefix = "approved canonical publication: "
    require(output.startswith(prefix), "approval returned no canonical revision")
    commit = output[len(prefix):]
    require(re.fullmatch(r"[0-9a-f]{40}", commit), "invalid approved revision")
    return commit


class PublicationLock:
    def __init__(self, root, commit, remote=CANONICAL_WRITE):
        self.root, self.remote = Path(root), remote
        owner = {"schema": 1, "commit": commit, "nonce": uuid.uuid4().hex,
                 "build_id": os.environ.get("JOB_ID", "manual"), "started": int(time.time())}
        tag = (f"object {commit}\ntype commit\ntag ci/publication-lock\n"
               f"tagger Landin publisher <publisher@invalid> {owner['started']} +0000\n\n"
               + json.dumps(owner, sort_keys=True) + "\n")
        self.oid = git(self.root, "hash-object", "-t", "tag", "-w", "--stdin",
                       input=tag.encode()).decode().strip()

    def current(self):
        rows = git(self.root, "ls-remote", "--refs", self.remote, LOCK_REF).splitlines()
        if not rows:
            return None
        require(len(rows) == 1, "ambiguous publication lock")
        oid, ref = rows[0].split(b"\t")
        require(ref.decode() == LOCK_REF and re.fullmatch(rb"[0-9a-f]{40}", oid),
                "invalid publication lock")
        return oid.decode()

    def acquire(self, wait_seconds=300):
        deadline = time.monotonic() + wait_seconds
        while True:
            owner = self.current()
            if owner is None:
                try:
                    git(self.root, "push", "--porcelain",
                        "--force-with-lease=" + LOCK_REF + ":", self.remote,
                        self.oid + ":" + LOCK_REF)
                    return
                except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
                    # A lost response may still have created our unique tag.
                    owner = self.current()
                    if owner == self.oid:
                        return
                    if owner is None:
                        raise
            remaining = deadline - time.monotonic()
            require(remaining > 0, "publication busy: " + LOCK_REF + " at " + str(owner))
            time.sleep(min(5, remaining))

    def release(self):
        git(self.root, "push", "--porcelain",
            "--force-with-lease=" + LOCK_REF + ":" + self.oid,
            self.remote, ":" + LOCK_REF)


def prepare_archive(root, directory):
    site = directory / "site"
    run([sys.executable, str(root / "assets/fonts.py"), "--require"])
    run([sys.executable, str(root / "docs/site/render_html.py"),
         "--from", str(root), "--to", str(site), "--verify"], timeout=60)
    archive = directory / "site.tar.gz"
    with tarfile.open(archive, "w:gz") as output:
        for path in sorted(site.rglob("*")):
            require(not path.is_symlink() and (path.is_file() or path.is_dir()),
                    "site contains a nonordinary entry: " + str(path))
            entry = output.gettarinfo(str(path), arcname=path.relative_to(site).as_posix())
            entry.mode = 0o755 if path.is_dir() else 0o644
            entry.uid = entry.gid = 0
            entry.uname = entry.gname = ""
            if path.is_file():
                with path.open("rb") as source:
                    output.addfile(entry, source)
            else:
                output.addfile(entry)
    return archive


def publish(root, domain, alias):
    root = Path(root).resolve()
    commit = approved(root)
    lock = PublicationLock(root, commit)
    print("publication lock request: " + LOCK_REF + " at " + lock.oid, flush=True)
    lock.acquire()
    started, complete = False, False
    try:
        require(approved(root) == commit, "approved revision changed while waiting")
        with tempfile.TemporaryDirectory(prefix="landin-publication-") as temporary:
            archive = prepare_archive(root, Path(temporary))
            require(approved(root) == commit, "approved revision changed while rendering")
            for destination in [domain] + ([alias] if alias and alias != domain else []):
                started = True
                run(["hut", "pages", "publish", "-d", destination, str(archive)], timeout=120)
                print("published: https://" + destination, flush=True)
            complete = True
    finally:
        if complete or not started:
            lock.release()
        else:
            # A failed/timed-out client cannot prove that the server stopped.
            # Never let another worker overlap that uncertain upload.
            print("landin: publication lock retained: " + LOCK_REF + " at " + lock.oid
                  + "; inspect the job and server outcome before manual recovery", file=sys.stderr)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    args = parser.parse_args(argv)
    try:
        publish(args.root, (os.environ.get("LANDIN_PAGES_DOMAIN") or "www.701.dev"),
                os.environ.get("LANDIN_PAGES_ALIAS", "701.dev"))
        return 0
    except (Invalid, OSError, subprocess.SubprocessError) as exc:
        print("landin: publication refused: " + str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
