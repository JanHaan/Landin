#!/usr/bin/env python3
"""Explicit native development, committed acceptance, evidence and promotion."""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
import io
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tarfile
import tempfile
import uuid

from common import (Invalid, archive_inventory, canonical, clean_checkout, commit_source,
                    digest, file_hash, git, identity, read_json, require, validate_request,
                    write_new)
from records import approval_for, validate_bundle
from approval import CANONICAL, read_approval, remote_ref, tag_name

ROOT = Path(__file__).resolve().parents[2]
STATE = Path.home() / ".local/state/landin/acceptance"
REMOTE_WORK = "/home/landin/work/.acceptance"
PROMOTION_REMOTE = "git@git.sr.ht:~sinnfrei/landin"

# Only the fixed envelope names are unpacked by this bootstrap. Repository
# code performs full validation before initializing any durable run state.
BOOTSTRAP = r'''
import hashlib, io, os, pathlib, subprocess, sys, tarfile, tempfile
with tempfile.TemporaryDirectory(prefix="landin-ci-init-") as d:
 p=pathlib.Path(d)
 with tarfile.open(fileobj=sys.stdin.buffer,mode="r|gz") as tar:
  seen=set()
  for m in tar:
   if m.name not in ("source.tar.gz","request.json") or m.name in seen or not m.isfile():
    raise SystemExit("invalid initialization envelope")
   seen.add(m.name)
   (p/m.name).write_bytes(tar.extractfile(m).read())
  if seen != {"source.tar.gz","request.json"}: raise SystemExit("incomplete initialization envelope")
 import json
 request=json.loads((p/"request.json").read_bytes())
 if hashlib.sha256((p/"source.tar.gz").read_bytes()).hexdigest()!=request["archive_sha256"]:
  raise SystemExit("archive transfer hash mismatch")
 with tarfile.open(p/"source.tar.gz") as tar:
  for name in ("common.py","records.py","job.py"):
   members=[m for m in tar.getmembers() if m.name=="scripts/ci/"+name]
   if len(members)!=1 or not members[0].isfile(): raise SystemExit("missing bootstrap module")
   (p/name).write_bytes(tar.extractfile(members[0]).read())
 with (p/"request.json").open("rb") as data:
  raise SystemExit(subprocess.call(["python3",str(p/"job.py"),"init",request["run_id"],str(p/"source.tar.gz")],stdin=data))
'''


def ssh_command(host, argv):
    import re
    require(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", host), "invalid SSH host")
    ssh = shlex.split(os.environ.get("LANDIN_CI_SSH", "ssh"))
    require(ssh, "empty SSH command")
    # shlex parsing is argv parsing, not shell evaluation. Expand ~ only for
    # explicitly named local arguments such as the SSH identity file.
    ssh = [os.path.expanduser(word) for word in ssh]
    return ssh + ["-o", "BatchMode=yes", "landin@" + host, shlex.join(argv)]


def remote(host, argv, data=None, stdout=None):
    return subprocess.run(ssh_command(host, argv), input=data, stdout=stdout, check=True)


def remote_job(host, run_id, action, argument=None, stdout=None):
    validate_run_id(run_id)
    argv = ["python3", REMOTE_WORK + "/" + run_id + "/source/scripts/ci/job.py", action, run_id]
    if argument is not None:
        argv.append(argument)
    return remote(host, argv, stdout=stdout)


def validate_run_id(run_id):
    import re
    require(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,95}", run_id), "invalid run id")


def initialize(host, archive, request):
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w:gz") as tar:
        for name, data in (("source.tar.gz", archive), ("request.json", canonical(request))):
            entry = tarfile.TarInfo(name)
            entry.size = len(data)
            entry.mode = 0o644
            tar.addfile(entry, io.BytesIO(data))
    remote(host, ["python3", "-c", BOOTSTRAP], buffer.getvalue())


def slot_run(host, slot, argv, archive, log=None, prefix="development"):
    import re
    require(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", slot), "invalid slot")
    # Communicate input from a file rather than a PIPE: consuming live output
    # must not deadlock while the runner is still receiving its snapshot.
    with tempfile.TemporaryFile() as incoming:
        incoming.write(archive)
        incoming.seek(0)
        process = subprocess.Popen(ssh_command(host, ["landin-ci", "run", slot, "--", *argv]),
                                   stdin=incoming, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        output = log.open("wb") if log else None
        try:
            for line in iter(process.stdout.readline, b""):
                if output:
                    output.write(line)
                    output.flush()
                print("[" + prefix + "] " + line.decode(errors="replace").rstrip(), flush=True)
        finally:
            if output:
                output.close()
        code = process.wait()
        if code == 75:
            print("[" + prefix + "] BUSY; no compiler verdict", flush=True)
        return code


def accept(root, revision, host, state, resume=None):
    clean_checkout(root)
    archive, source = commit_source(root, revision)
    run_id = resume or (datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex[:12])
    request = {"schema": 1, "run_id": run_id, **source}
    validate_request(request)
    local = state / run_id
    local.mkdir(parents=True, exist_ok=True)
    if (local / "request.json").exists():
        require(read_json(local / "request.json") == request, "resume request differs")
    else:
        require(not resume, "resume requires the original local request")
        write_new(local / "request.json", request)
    initialize(host, archive, request)
    print("ACCEPTANCE " + run_id + " commit=" + source["commit"], flush=True)
    results = {}
    with ThreadPoolExecutor(max_workers=8) as pool:
        pending = {}
        for job in request["policy"]["jobs"]:
            name = job["id"]
            log = local / (name + "-" + uuid.uuid4().hex[:8] + ".log")
            future = pool.submit(slot_run, host, "accept-" + run_id + "-" + name,
                                 ["python3", "scripts/ci/job.py", "run", run_id, name], archive, log, name)
            pending[future] = name
        for future in as_completed(pending):
            results[pending[future]] = future.result()
    require(all(code == 0 for code in results.values()),
            "acceptance incomplete/failed; records retained: " + str(results))
    remote_job(host, run_id, "finalize")
    export(host, run_id, state)
    return run_id


def export(host, run_id, state):
    validate_run_id(run_id)
    local = state / run_id
    local.mkdir(parents=True, exist_ok=True)
    destination = local / "bundle"
    if destination.exists():
        validate_bundle(destination)
        print("verified retained export: " + str(destination))
        return destination
    with tempfile.TemporaryDirectory(prefix=".export-", dir=local) as tmp:
        archive = Path(tmp) / "evidence.tar.gz"
        with archive.open("wb") as out:
            remote_job(host, run_id, "export", stdout=out)
        unpacked = Path(tmp) / "bundle"
        archive_inventory(archive.read_bytes(), unpacked)
        request, _, _ = validate_bundle(unpacked)
        require(request["run_id"] == run_id, "exported wrong run")
        os.rename(unpacked, destination)
    print("verified durable export: " + str(destination))
    return destination


def approve(root, bundle):
    clean_checkout(root)
    approval = approval_for(bundle)
    _, source = commit_source(root, approval["commit"])
    from records import validate_approval
    validate_approval(approval, source)
    name = tag_name(approval["commit"])
    # No --force, no identity overrides and no commit trailers.
    git(root, "tag", "-a", name, approval["commit"], "-F", "-", input=canonical(approval))
    require(read_approval(root, approval["commit"]) == approval, "created approval differs")
    print("created administrative approval " + name)
    return approval["commit"]


def promote(root, commit, remote=PROMOTION_REMOTE):
    clean_checkout(root)
    read_approval(root, commit)
    git(root, "fetch", "--no-tags", remote, "refs/heads/main")
    main = git(root, "rev-parse", "FETCH_HEAD").decode().strip()
    git(root, "merge-base", "--is-ancestor", main, commit)
    ref = "refs/tags/" + tag_name(commit)
    require(not git(root, "ls-remote", "--refs", remote, ref).strip(), "canonical approval tag already exists")
    # Both ref updates succeed or neither does. Plain main push enforces FF
    # on the server too, including a race after the fetch above.
    git(root, "push", "--atomic", remote, ref + ":" + ref, commit + ":refs/heads/main")
    require(remote_ref(root, remote, "refs/heads/main") == commit, "main moved after promotion")
    print("promoted approved commit " + commit)


def dev(root, host, slot, command):
    names = git(root, "ls-files", "-z", "--cached", "--others", "--exclude-standard").split(b"\0")
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w:gz", dereference=False) as archive:
        for name in sorted(set(names)):
            if name and os.path.lexists(root / os.fsdecode(name)):
                archive.add(root / os.fsdecode(name), arcname=os.fsdecode(name), recursive=False)
    data = buffer.getvalue()
    archive_inventory(data)
    print("DEVELOPMENT / NOT ACCEPTANCE", flush=True)
    return slot_run(host, slot, command or ["./scripts/dev-test.sh"], data)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="landin-ci-x86-64")
    parser.add_argument("--state", type=Path, default=STATE)
    parser.add_argument("--root", type=Path, default=ROOT)
    sub = parser.add_subparsers(dest="action", required=True)
    accept_parser = sub.add_parser("accept")
    accept_parser.add_argument("commit")
    accept_parser.add_argument("--resume")
    for name in ("status", "export"):
        sub.add_parser(name).add_argument("run_id")
    sub.add_parser("approve").add_argument("bundle", type=Path)
    sub.add_parser("promote").add_argument("commit")
    development = sub.add_parser("dev")
    development.add_argument("--slot", default="development")
    development.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    try:
        if args.action == "accept":
            accept(args.root, args.commit, args.host, args.state, args.resume)
        elif args.action == "status":
            remote_job(args.host, args.run_id, "status")
        elif args.action == "export":
            export(args.host, args.run_id, args.state)
        elif args.action == "approve":
            approve(args.root, args.bundle)
        elif args.action == "promote":
            promote(args.root, args.commit)
        else:
            command = args.command[1:] if args.command[:1] == ["--"] else args.command
            return dev(args.root, args.host, args.slot, command)
        return 0
    except (Invalid, OSError, subprocess.CalledProcessError) as exc:
        print("landin-ci: " + str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
