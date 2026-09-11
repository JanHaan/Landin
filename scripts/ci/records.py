"""Validate retained evidence before completion, export, or Git approval."""
from pathlib import Path
import re
import tarfile

from common import (digest, identity, read_json, require, safe_path,
                    validate_request, file_hash, decoded_name)


NATIVE_TOOLS = {"gnatls", "gprbuild", "x86_64-pc-linux-gnu-gcc", "as", "ld",
                "clang-19", "gdb", "python3", "rsync", "flock", "git"}
NATIVE_PACKAGES = {"libc6-dev", "binutils", "clang-19", "gdb", "python3", "rsync", "util-linux"}


def sha(value):
    return isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value)


def validate_environment(environment, request, root):
    require(set(environment) == {"platform", "kernel", "hostname", "os_release", "boot_id",
                                 "packages", "binaries", "slot_runner_sha256", "pins_sha256",
                                 "execution_environment"}, "incomplete native provenance fields")
    require(environment["platform"] == "Linux-x86_64", "provenance is not native Linux x86-64")
    for field in ("kernel", "hostname", "os_release"):
        require(isinstance(environment[field], str) and environment[field].strip(), "missing native " + field)
    require(re.fullmatch(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}", environment["boot_id"]),
            "missing/invalid native boot identity")
    require(sha(environment["slot_runner_sha256"]), "missing slot runner identity")
    pins_entry = [entry for entry in request["inventory"]
                  if decoded_name(entry["name"]) == request["policy"]["pins"]]
    require(len(pins_entry) == 1 and environment["pins_sha256"] == pins_entry[0]["sha256"],
            "native provenance pins mismatch")
    # Read versions from the accepted source, never another pin table.
    with tarfile.open(Path(root) / "source.tar.gz", "r:gz") as archive:
        members = [member for member in archive if member.name == request["policy"]["pins"]]
        require(len(members) == 1 and members[0].isfile(), "missing accepted pins file")
        pins = archive.extractfile(members[0]).read()
    require(digest(pins) == environment["pins_sha256"], "accepted pins bytes mismatch")
    versions = {}
    for family in ("GNAT", "GPRBUILD"):
        matches = re.findall(r"^LANDIN_" + family + r"_VERSION=([^\s]+)$", pins.decode(), re.M)
        require(len(matches) == 1, "missing accepted toolchain version")
        versions[family] = matches[0]
    require(set(environment["binaries"]) == NATIVE_TOOLS, "missing/extra native tool identity")
    for name, binary in environment["binaries"].items():
        require(set(binary) == {"path", "sha256", "version"} and
                isinstance(binary["path"], str) and Path(binary["path"]).is_absolute() and
                sha(binary["sha256"]) and isinstance(binary["version"], str) and binary["version"].strip(),
                "incomplete native tool identity: " + name)
    for tool, family, prefix in (("gnatls", "GNAT", "GNATLS "), ("gprbuild", "GPRBUILD", "GPRBUILD ")):
        require(prefix + versions[family].rsplit("-", 1)[0] in environment["binaries"][tool]["version"],
                "native compiler version differs from accepted pins")
    require("clang version 19." in environment["binaries"]["clang-19"]["version"], "native Clang must be major 19")
    require(isinstance(environment["packages"], str), "missing package provenance")
    packages = environment["packages"].splitlines()
    require(len(packages) == len(NATIVE_PACKAGES) and
            {line.split("=", 1)[0] for line in packages} == NATIVE_PACKAGES and
            all("=" in line and line.split("=", 1)[1] for line in packages), "incomplete native package versions")
    env = environment["execution_environment"]
    required = {"HOME", "PATH", "LANG", "LC_ALL", "TZ", "PYTHONDONTWRITEBYTECODE",
                "LANDIN_BUILD_INCREMENTAL", "LANDIN_BUILD_TAG", "CLANG", "LANDIN_GNAT_HOME", "LANDIN_GPRBUILD_HOME"}
    optional = {"GIT_EXEC_PATH", "GIT_TEMPLATE_DIR"}
    require(set(env) in (required, required | optional), "non-whitelisted or missing execution environment")
    require(all(isinstance(value, str) and value for value in env.values()), "invalid execution environment values")
    for key, value in {"LANG": "C.UTF-8", "LC_ALL": "C.UTF-8", "TZ": "UTC", "PYTHONDONTWRITEBYTECODE": "1",
                       "LANDIN_BUILD_INCREMENTAL": "no", "LANDIN_BUILD_TAG": request["policy"]["build_tag"],
                       "CLANG": "clang-19"}.items():
        require(env[key] == value, "unsafe acceptance environment: " + key)
    for family in ("GNAT", "GPRBUILD"):
        path = Path(env["LANDIN_" + family + "_HOME"])
        require(path.is_absolute() and path.name == family.lower() + "-" + versions[family], "tool home differs from pins")
    require(Path(env["HOME"]).is_absolute(), "invalid native HOME")
    suffix = "/usr/local/bin:/usr/bin:/bin"
    if optional <= set(env):
        tools = Path(env["HOME"]) / ".local/share/landin-ci-tools"
        require(env["GIT_EXEC_PATH"] == str(tools / "usr/lib/git-core") and
                env["GIT_TEMPLATE_DIR"] == str(tools / "usr/share/git-core/templates"), "unexpected Git helpers")
        suffix = str(tools / "usr/bin") + ":" + suffix
    require(env["PATH"] == env["LANDIN_GNAT_HOME"] + "/bin:" + env["LANDIN_GPRBUILD_HOME"] + "/bin:" + suffix,
            "native PATH differs from pinned tool selection")
    return environment


def commands_for(request, job):
    refine = "compiler/ada/build/" + request["policy"]["build_tag"] + "/" + job["mode"] + "/bin/refine"
    return [[word.replace("{refine}", refine) for word in argv] for argv in job["commands"]]


def validate_files(root, files):
    require(isinstance(files, list) and files, "missing evidence files")
    seen = set()
    for entry in files:
        require(set(entry) == {"path", "sha256", "size"}, "invalid evidence file entry")
        name = safe_path(entry["path"], source=False)
        require(name not in seen, "duplicate evidence file")
        seen.add(name)
        path = Path(root) / name
        require(path.is_file() and not path.is_symlink(), "missing or linked evidence: " + name)
        require(all(not (Path(root) / parent).is_symlink()
                    for parent in Path(name).parents if str(parent) != "."),
                "symlink in evidence path")
        require(path.stat().st_size == entry["size"] and file_hash(path) == entry["sha256"],
                "evidence hash mismatch: " + name)
    return seen


def validate_job(record, request, job, environment, root=None):
    require(root is not None, "retained evidence root is required")
    validate_environment(environment, request, root)
    require(set(record) == {"schema", "job", "request_sha256", "environment_sha256",
                           "source_before", "source_after", "policy_sha256", "status",
                           "started", "finished", "duration", "steps", "files", "fonts"},
            "invalid job record fields")
    require(record["schema"] == 1 and record["job"] == job["id"], "job identity mismatch")
    require(record["request_sha256"] == identity(request), "mixed job request")
    require(record["environment_sha256"] == identity(environment), "mixed job environment")
    require(record["policy_sha256"] == request["policy_sha256"], "mixed job policy")
    require(record["source_before"] == record["source_after"] == request["source_sha256"],
            "job source changed")
    require(record["status"] == "passed", "required job did not pass")
    require(isinstance(record["started"], str) and isinstance(record["finished"], str)
            and record["started"] <= record["finished"] and
            isinstance(record["duration"], (int, float)) and record["duration"] >= 0,
            "invalid job timing")
    require(record["fonts"] in ("available", "unavailable"), "missing font availability")
    expected = commands_for(request, job)
    require(len(record["steps"]) == len(expected), "missing or duplicate required command")
    paths = {entry["path"] for entry in record["files"]}
    require(len(paths) == len(record["files"]), "duplicate evidence files")
    for index, (step, argv) in enumerate(zip(record["steps"], expected)):
        require(set(step) == {"argv", "environment", "started", "finished", "duration", "exit", "log"},
                "invalid command record")
        require(step["argv"] == argv and type(step["exit"]) is int and step["exit"] == 0,
                "failed or substituted required command")
        expected_env = dict(environment["execution_environment"], LANDIN_BUILD_MODE=job["mode"])
        require(step["environment"] == expected_env, "command environment differs from provenance")
        require(step["log"] in paths and step["log"].endswith(f"/step-{index:02d}.log"),
                "missing command log")
        require(step["started"] <= step["finished"] and step["duration"] >= 0,
                "invalid command timing")
    if root is not None:
        validate_files(root, record["files"])
    return record


def validate_bundle(root):
    root = Path(root)
    request = validate_request(read_json(root / "request.json"))
    require(file_hash(root / "source.tar.gz") == request["archive_sha256"], "retained archive mismatch")
    environment = read_json(root / "environment.json")
    validate_environment(environment, request, root)
    record = read_json(root / "record.json")
    require(set(record) == {"schema", "request_sha256", "environment_sha256", "jobs"},
            "invalid completed record fields")
    require(record["schema"] == 1 and record["request_sha256"] == identity(request)
            and record["environment_sha256"] == identity(environment), "completed record identity mismatch")
    expected = request["policy"]["jobs"]
    require(set(record["jobs"]) == {j["id"] for j in expected}, "missing/extra completed job")
    for job in expected:
        entry = record["jobs"][job["id"]]
        require(set(entry) == {"path", "sha256"}, "invalid completed job reference")
        path = root / safe_path(entry["path"], source=False)
        require(path.is_file() and not path.is_symlink() and file_hash(path) == entry["sha256"],
                "job record hash mismatch")
        validate_job(read_json(path), request, job, environment, root)
    return request, environment, record


def approval_for(root):
    request, environment, record = validate_bundle(root)
    return {"schema": 1, "kind": "landin-native-acceptance", "commit": request["commit"],
            "tree": request["tree"], "run_id": request["run_id"],
            "archive_sha256": request["archive_sha256"], "source_sha256": request["source_sha256"],
            "policy_sha256": request["policy_sha256"], "request_sha256": identity(request),
            "environment_sha256": identity(environment), "record_sha256": identity(record),
            "jobs": {name: {"status": "passed", "sha256": value["sha256"]}
                     for name, value in record["jobs"].items()}}


def validate_approval(approval, source):
    require(set(approval) == {"schema", "kind", "commit", "tree", "run_id", "archive_sha256",
                              "source_sha256", "policy_sha256", "request_sha256",
                              "environment_sha256", "record_sha256", "jobs"},
            "invalid approval annotation fields")
    require(approval["schema"] == 1 and approval["kind"] == "landin-native-acceptance",
            "not a native acceptance approval")
    for field in ("commit", "tree", "archive_sha256", "source_sha256", "policy_sha256"):
        require(approval[field] == source[field], "approval " + field + " mismatch")
    request = {"schema": 1, "run_id": approval["run_id"], **source}
    validate_request(request)
    require(approval["request_sha256"] == identity(request), "approval request identity mismatch")
    for field in ("environment_sha256", "record_sha256"):
        require(isinstance(approval[field], str) and re.fullmatch(r"[0-9a-f]{64}", approval[field]),
                "invalid approval evidence hash")
    require(set(approval["jobs"]) == {j["id"] for j in source["policy"]["jobs"]},
            "approval missing required jobs")
    for job in approval["jobs"].values():
        require(set(job) == {"status", "sha256"} and job["status"] == "passed" and
                re.fullmatch(r"[0-9a-f]{64}", job["sha256"]), "approval contains failed/invalid job")
    return approval
