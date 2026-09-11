#!/usr/bin/env python3
"""Native runner: immutable initialization, slot jobs, retained evidence and export."""
from __future__ import annotations

import argparse
import contextlib
from datetime import datetime, timezone
import fcntl
import io
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import uuid

from common import (Invalid, archive_inventory, canonical, decode, digest, file_hash,
                    identity, read_json, require, validate_policy, validate_request,
                    working_inventory, write_new)
from records import commands_for, validate_bundle, validate_job

WORK = Path("/home/landin/work/.acceptance")


def now():
    return datetime.now(timezone.utc).isoformat()


@contextlib.contextmanager
def lock(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a") as stream:
        try:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise Invalid("BUSY: " + str(path)) from exc
        yield stream.fileno()


def run_path(run_id):
    import re
    require(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,95}", run_id), "invalid run id")
    root = WORK / run_id
    require(not root.is_symlink(), "linked run directory")
    return root


def capture(argv, env):
    return subprocess.run(argv, env=env, check=True, stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT).stdout.decode(errors="replace")


def provenance(source, policy):
    require(platform.system() == "Linux" and platform.machine() == "x86_64",
            "acceptance requires native Linux x86-64")
    # A fixed environment prevents developer selectors, QEMU and alternate tools
    # leaking from the controller or SSH account into acceptance commands.
    env = {"HOME": str(Path.home()), "PATH": "/usr/local/bin:/usr/bin:/bin",
           "LANG": "C.UTF-8", "LC_ALL": "C.UTF-8", "TZ": "UTC",
           "PYTHONDONTWRITEBYTECODE": "1", "LANDIN_BUILD_INCREMENTAL": "no",
           "LANDIN_BUILD_TAG": policy["build_tag"], "CLANG": policy["clang"]}
    user_tools = Path.home() / ".local/share/landin-ci-tools"
    if (user_tools / "usr/bin/git").is_file():
        env["PATH"] = str(user_tools / "usr/bin") + ":" + env["PATH"]
        env["GIT_EXEC_PATH"] = str(user_tools / "usr/lib/git-core")
        env["GIT_TEMPLATE_DIR"] = str(user_tools / "usr/share/git-core/templates")
    pins = capture(["sh", "-eu", "-c",
                    '. "$1"; printf "%s\\n" "$LANDIN_GNAT_VERSION" "$LANDIN_GPRBUILD_VERSION"',
                    "pins", str(source / policy["pins"])], env).splitlines()
    require(len(pins) == 2, "invalid toolchain pins")
    for key, family, version in (("LANDIN_GNAT_HOME", "gnat", pins[0]),
                                 ("LANDIN_GPRBUILD_HOME", "gprbuild", pins[1])):
        path = Path(os.environ.get(key, "/opt/landin-toolchains/" + family + "-" + version))
        require(path.name == family + "-" + version and path.is_dir(), "toolchain differs from pins")
        env[key] = str(path.resolve())
    env["PATH"] = env["LANDIN_GNAT_HOME"] + "/bin:" + env["LANDIN_GPRBUILD_HOME"] + "/bin:" + env["PATH"]
    binaries = {}
    for tool in ("gnatls", "gprbuild", "x86_64-pc-linux-gnu-gcc", "as", "ld", "clang-19", "gdb", "python3", "rsync", "flock", "git"):
        path = shutil.which(tool, path=env["PATH"])
        require(path is not None, "required native tool missing: " + tool)
        version = capture([path, "--version"], env)
        binaries[tool] = {"path": str(Path(path).resolve()), "sha256": file_hash(path), "version": version}
    require("GNATLS " + pins[0].rsplit("-", 1)[0] in binaries["gnatls"]["version"], "wrong GNAT version")
    require("GPRBUILD " + pins[1].rsplit("-", 1)[0] in binaries["gprbuild"]["version"], "wrong GPRbuild version")
    require("clang version 19." in binaries["clang-19"]["version"], "Clang is not major 19")
    packages = capture(["dpkg-query", "-W", "-f=${Package}=${Version}\\n", "libc6-dev",
                        "binutils", "clang-19", "gdb", "python3", "rsync", "util-linux"], env)
    return {"platform": platform.system() + "-" + platform.machine(),
            "kernel": platform.release(), "hostname": platform.node(),
            "os_release": Path("/etc/os-release").read_text(),
            "boot_id": Path("/proc/sys/kernel/random/boot_id").read_text().strip(),
            "packages": packages, "binaries": binaries,
            "slot_runner_sha256": file_hash("/usr/local/bin/landin-ci"),
            "pins_sha256": file_hash(source / policy["pins"]), "execution_environment": env}


def initialize(request, archive_path):
    validate_request(request)
    root = run_path(request["run_id"])
    WORK.mkdir(parents=True, exist_ok=True)
    with lock(WORK / (".init-" + request["run_id"])):
        archive = Path(archive_path).read_bytes()
        require(digest(archive) == request["archive_sha256"], "transferred archive hash mismatch")
        inventory = archive_inventory(archive)
        require(inventory == request["inventory"], "transferred source identity mismatch")
        if root.exists():
            require(read_json(root / "request.json") == request, "run identity collision")
            require(file_hash(root / "source.tar.gz") == request["archive_sha256"], "retained source mismatch")
            require(provenance(root / "source", request["policy"]) == read_json(root / "environment.json"),
                    "environment changed; initialize a new run")
            print("initialized run already exists: " + request["run_id"])
            return
        temporary = Path(tempfile.mkdtemp(prefix=".initialize-", dir=WORK))
        try:
            archive_inventory(archive, temporary / "source")
            require(identity(working_inventory(temporary / "source")) == request["source_sha256"],
                    "extracted source inventory mismatch")
            require(read_json(temporary / "source/scripts/ci/policy.json") == request["policy"],
                    "extracted policy mismatch")
            environment = provenance(temporary / "source", request["policy"])
            (temporary / "source.tar.gz").write_bytes(archive)
            write_new(temporary / "request.json", request)
            write_new(temporary / "environment.json", environment)
            os.rename(temporary, root)
        finally:
            if temporary.exists():
                shutil.rmtree(temporary)
    print("initialized " + request["run_id"])


def evidence_entry(root, path):
    return {"path": path.relative_to(root).as_posix(), "sha256": file_hash(path), "size": path.stat().st_size}


def progress(message):
    # SSH/controller output is observational. Its loss cannot change the
    # command's verdict or stop draining its pipe into durable evidence.
    try:
        print(message, flush=True)
    except (BrokenPipeError, OSError):
        pass


def live_output(chunk):
    try:
        sys.stdout.buffer.write(chunk)
        sys.stdout.buffer.flush()
    except (BrokenPipeError, OSError):
        pass


def run_job(root, job_id, source):
    request = validate_request(read_json(root / "request.json"))
    jobs = [job for job in request["policy"]["jobs"] if job["id"] == job_id]
    require(len(jobs) == 1, "unknown job")
    job = jobs[0]
    with lock(root / "locks" / job_id) as job_lock:
        environment = provenance(source, request["policy"])
        require(environment == read_json(root / "environment.json"), "environment changed; new run required")
        require(identity(working_inventory(source)) == request["source_sha256"], "slot source mismatch")
        require(read_json(source / "scripts/ci/policy.json") == request["policy"], "slot policy mismatch")
        result_path = root / "jobs" / (job_id + ".json")
        if result_path.exists():
            validate_job(read_json(result_path), request, job, environment, root)
            progress("already passed: " + job_id)
            return 0
        require(not (root / "record.json").exists(), "completed run is immutable")
        # A nonzero completed attempt is a real failure, never a resumable gap.
        attempts = root / "attempts" / job_id
        if attempts.exists():
            for old in attempts.glob("*/result.json"):
                require(read_json(old)["status"] == "passed", "failed job requires a new acceptance run")
        attempt = attempts / (datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S") + "-" + uuid.uuid4().hex[:12])
        attempt.mkdir(parents=True)
        started = now()
        start_clock = time.monotonic()
        write_new(attempt / "started.json", {"started": started, "pid": os.getpid(),
                  "request_sha256": identity(request), "environment_sha256": identity(environment)})
        env = dict(environment["execution_environment"], LANDIN_BUILD_MODE=job["mode"])
        record = {"schema": 1, "job": job_id, "request_sha256": identity(request),
                  "environment_sha256": identity(environment), "source_before": request["source_sha256"],
                  "source_after": "", "policy_sha256": request["policy_sha256"],
                  "status": "failed", "started": started, "finished": started, "duration": 0,
                  "steps": [], "files": [], "fonts": "unavailable"}
        font_result = subprocess.run(["python3", "assets/fonts.py", "--require"], cwd=source,
                                     env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        record["fonts"] = "available" if font_result.returncode == 0 else "unavailable"
        (attempt / "fonts.log").write_bytes(font_result.stdout)
        progress("private font availability: " + record["fonts"])
        exit_code = 0
        try:
            for index, argv in enumerate(commands_for(request, job)):
                log = attempt / f"step-{index:02d}.log"
                stamp, tick = now(), time.monotonic()
                progress(f"[{job_id}] start {argv!r}")
                with log.open("wb") as out:
                    process = subprocess.Popen(argv, cwd=source, env=env, stdout=subprocess.PIPE,
                                               stderr=subprocess.STDOUT, pass_fds=(job_lock,))
                    # This deliberately streams partial lines too: a quiet long
                    # compile remains observable via status and its retained log.
                    while True:
                        chunk = process.stdout.read1(8192)
                        if not chunk:
                            break
                        out.write(chunk)
                        out.flush()
                        live_output(chunk)
                    exit_code = process.wait()
                record["steps"].append({"argv": argv, "environment": env, "started": stamp,
                                        "finished": now(), "duration": time.monotonic() - tick,
                                        "exit": exit_code, "log": log.relative_to(root).as_posix()})
                progress(f"[{job_id}] exit {exit_code}")
                if exit_code:
                    break
            after = identity(working_inventory(source))
            record["source_after"] = after
            if after != request["source_sha256"]:
                exit_code = 1
                progress("source changed during job")
            if provenance(source, request["policy"]) != environment:
                exit_code = 1
                progress("environment changed during job")
            products = source / "compiler/ada/build" / request["policy"]["build_tag"] / job["mode"]
            # Keep executable products, build inventory and quality/debugger
            # oracles (including their logs). They survive mutable slot reuse.
            for relative in ("bin", "source-manifest.txt", "quality", "debugging"):
                origin = products / relative
                destination = attempt / "artifacts" / relative
                if origin.is_dir():
                    shutil.copytree(origin, destination, symlinks=False)
                elif origin.is_file():
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(origin, destination)
            record["status"] = "passed" if exit_code == 0 else "failed"
        except Exception as exc:
            (attempt / "exception.log").write_text(str(exc) + "\n")
            exit_code = 1
        record["finished"] = now()
        record["duration"] = time.monotonic() - start_clock
        record["files"] = [evidence_entry(root, path) for path in sorted(attempt.rglob("*")) if path.is_file()]
        write_new(attempt / "result.json", record)
        if record["status"] == "passed":
            validate_job(record, request, job, environment, root)
            write_new(result_path, record)
        return exit_code


def finalize(root):
    with lock(root / "finalize.lock"):
        if (root / "record.json").exists():
            validate_bundle(root)
            return
        request = validate_request(read_json(root / "request.json"))
        require(file_hash(root / "source.tar.gz") == request["archive_sha256"],
                "retained archive mismatch before completion")
        environment = read_json(root / "environment.json")
        require(provenance(root / "source", request["policy"]) == environment,
                "environment changed before completion")
        entries = {}
        with contextlib.ExitStack() as locks:
            for job in request["policy"]["jobs"]:
                locks.enter_context(lock(root / "locks" / job["id"]))
                path = root / "jobs" / (job["id"] + ".json")
                require(path.is_file(), "missing required job: " + job["id"])
                validate_job(read_json(path), request, job, environment, root)
                entries[job["id"]] = {"path": path.relative_to(root).as_posix(), "sha256": file_hash(path)}
            write_new(root / "record.json", {"schema": 1, "request_sha256": identity(request),
                      "environment_sha256": identity(environment), "jobs": entries})
        validate_bundle(root)
    print("completed " + request["run_id"])


def status(root):
    request = validate_request(read_json(root / "request.json"))
    states = {}
    for job in request["policy"]["jobs"]:
        name = job["id"]
        if (root / "jobs" / (name + ".json")).exists():
            states[name] = "passed"
            continue
        try:
            with lock(root / "locks" / name):
                results = list((root / "attempts" / name).glob("*/result.json"))
                states[name] = "failed" if results else "missing/interrupted"
        except Invalid:
            states[name] = "running"
    print(canonical({"run_id": request["run_id"], "completed": (root / "record.json").exists(),
                     "jobs": states}).decode(), end="")


def export(root):
    validate_bundle(root)
    with tarfile.open(fileobj=sys.stdout.buffer, mode="w|gz") as archive:
        for path in sorted(root.rglob("*")):
            relative = path.relative_to(root)
            if relative.parts[0] in ("source", "locks") or path.name.endswith(".lock"):
                continue
            require(not path.is_symlink(), "linked export entry")
            archive.add(path, arcname=relative.as_posix(), recursive=False)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("init", "run", "finalize", "status", "export"))
    parser.add_argument("run_id")
    parser.add_argument("argument", nargs="?")
    args = parser.parse_args(argv)
    root = run_path(args.run_id)
    try:
        if args.action == "init":
            request = decode(sys.stdin.buffer.read())
            require(request["run_id"] == args.run_id, "initialization run mismatch")
            initialize(request, args.argument)
        elif args.action == "run":
            return run_job(root, args.argument, Path.cwd())
        elif args.action == "finalize":
            finalize(root)
        elif args.action == "status":
            status(root)
        else:
            export(root)
        return 0
    except (Invalid, OSError, subprocess.CalledProcessError) as exc:
        print("landin-ci: " + str(exc), file=sys.stderr)
        return 75 if str(exc).startswith("BUSY:") else 1


if __name__ == "__main__":
    raise SystemExit(main())
