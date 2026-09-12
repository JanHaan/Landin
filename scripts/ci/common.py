"""Strict source, policy and evidence contracts shared by the native CI tools."""
from __future__ import annotations

import base64
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import tarfile
import tempfile


class Invalid(ValueError):
    """An acceptance contract was not satisfied."""


def require(condition, message):
    if not condition:
        raise Invalid(message)


def canonical(value):
    return (json.dumps(value, sort_keys=True, separators=(",", ":"),
                       ensure_ascii=True) + "\n").encode("ascii")


def digest(data):
    return hashlib.sha256(data).hexdigest()


def identity(value):
    return digest(canonical(value))


def file_hash(path):
    h = hashlib.sha256()
    with open(path, "rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def no_duplicates(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "duplicate JSON key: " + key)
        result[key] = value
    return result


def decode(data):
    try:
        return json.loads(data, object_pairs_hook=no_duplicates,
                          parse_constant=lambda x: (_ for _ in ()).throw(
                              Invalid("invalid JSON constant: " + x)))
    except (ValueError, UnicodeError) as exc:
        raise Invalid("invalid JSON: " + str(exc)) from exc


def read_json(path):
    return decode(Path(path).read_bytes())


def write_new(path, value):
    """Publish a complete file atomically without ever replacing an old one."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".write-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as out:
            out.write(canonical(value))
            out.flush()
            os.fsync(out.fileno())
        os.link(tmp, path)
    finally:
        os.unlink(tmp)


def git(root, *args, input=None):
    return subprocess.run(["git", "-C", str(root), *args], input=input,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          check=True).stdout


def clean_checkout(root):
    require(not git(root, "status", "--porcelain=v1", "-z",
                    "--untracked-files=all"), "invocation checkout is dirty")
    expected = tree_inventory(root, "HEAD")
    require(checkout_inventory(root, expected) == expected,
            "checkout bytes differ from HEAD (including hidden index flags)")


def name_bytes(name):
    return os.fsencode(name)


def encoded_name(name):
    return base64.b64encode(name_bytes(name)).decode("ascii")


def decoded_name(name):
    try:
        return os.fsdecode(base64.b64decode(name, validate=True))
    except (ValueError, TypeError) as exc:
        raise Invalid("invalid encoded filename") from exc


GENERATED = ("compiler/ada/build", "docs/site/site", "docs/site/landin-site.tar.gz",
             "highlight/build", "highlight/tree-sitter/node_modules",
             "highlight/textmate/node_modules")


def safe_path(name, source=True):
    require(isinstance(name, str) and name and "\0" not in name,
            "empty or invalid archive path")
    parts = name.split("/")
    require(not name.startswith("/") and all(x not in ("", ".", "..") for x in parts),
            "noncanonical archive path: " + repr(name))
    require(parts[0] not in (".git", ".acceptance", ".landin-ci", ".scratch"),
            "reserved archive path: " + repr(name))
    if source:
        require(not any(name == x or name.startswith(x + "/") for x in GENERATED)
                and "__pycache__" not in parts,
                "generated/cache path in source: " + repr(name))
    return name


def source_entry(name, mode, data):
    return {"name": encoded_name(name), "mode": mode, "sha256": digest(data),
            "size": len(data)}


def archive_inventory(data, destination=None):
    """Validate all members before extraction; never traverse a symlink parent."""
    members = {}
    rows = []
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:*") as archive:
        for member in archive:
            name = safe_path(member.name.rstrip("/") if member.isdir() else member.name)
            require(name not in members, "duplicate archive destination: " + repr(name))
            require(member.isdir() or member.isfile() or member.issym(),
                    "unsupported archive member: " + repr(name))
            require(not member.mode & 0o7000, "special permission bits in archive")
            if member.isdir():
                payload = None
                mode = "040000"
            elif member.issym():
                payload = name_bytes(member.linkname)
                mode = "120000"
                require(member.linkname and not member.linkname.startswith("/"),
                        "absolute or empty symlink")
            else:
                payload = archive.extractfile(member).read()
                mode = "100755" if member.mode & 0o111 else "100644"
            members[name] = (mode, payload)
            if payload is not None:
                rows.append(source_entry(name, mode, payload))
        for name in members:
            parent = PurePosixPath(name).parent
            while str(parent) != ".":
                require(str(parent) not in members or members[str(parent)][0] == "040000",
                        "archive member has non-directory parent: " + repr(name))
                parent = parent.parent
        for name, (mode, payload) in members.items():
            if mode != "120000":
                continue
            pending = name.split("/")[:-1] + os.fsdecode(payload).split("/")
            resolved = []
            visited = set()
            while pending:
                part = pending.pop(0)
                if part in ("", "."):
                    continue
                if part == "..":
                    require(resolved, "escaping symlink: " + repr(name))
                    resolved.pop()
                    continue
                resolved.append(part)
                target = "/".join(resolved)
                if target in members and members[target][0] == "120000":
                    require(target not in visited, "cyclic symlink: " + repr(name))
                    visited.add(target)
                    resolved.pop()
                    pending = os.fsdecode(members[target][1]).split("/") + pending
            if resolved:
                safe_path("/".join(resolved))
        if destination is not None:
            destination = Path(destination)
            require(not destination.exists(), "extraction destination already exists")
            destination.mkdir(parents=True)
            for name, (mode, payload) in sorted(members.items()):
                path = destination / name
                path.parent.mkdir(parents=True, exist_ok=True)
                if mode == "040000":
                    path.mkdir(exist_ok=True)
                elif mode == "120000":
                    path.symlink_to(os.fsdecode(payload))
                else:
                    path.write_bytes(payload)
                    path.chmod(0o755 if mode == "100755" else 0o644)
    return sorted(rows, key=lambda row: row["name"])


def tree_inventory(root, commit):
    entries = []
    for row in git(root, "ls-tree", "-rz", "--full-tree", commit).split(b"\0"):
        if not row:
            continue
        header, path = row.split(b"\t", 1)
        mode, kind, oid = header.split()
        require(kind == b"blob" and mode in (b"100644", b"100755", b"120000"),
                "unsupported committed object: " + repr(path))
        safe_path(os.fsdecode(path))
        entries.append((mode.decode(), path, oid))
    blobs = git(root, "cat-file", "--batch", input=b"".join(x[2] + b"\n" for x in entries))
    stream = io.BytesIO(blobs)
    result = []
    for mode, path, oid in entries:
        found, kind, size = stream.readline().rstrip(b"\n").split()
        require(found == oid and kind == b"blob", "Git blob identity mismatch")
        payload = stream.read(int(size))
        require(stream.read(1) == b"\n", "truncated Git blob")
        result.append(source_entry(os.fsdecode(path), mode, payload))
    return sorted(result, key=lambda row: row["name"])


def checkout_inventory(root, expected):
    """Read committed entries directly, independent of Git's cached stat flags."""
    root = Path(root)
    rows = []
    for entry in expected:
        name = safe_path(decoded_name(entry["name"]))
        path = root / name
        require(all(not (root / parent).is_symlink() for parent in Path(name).parents
                    if str(parent) != "."), "symlink parent in checkout")
        try:
            mode = path.lstat().st_mode
            if stat.S_ISLNK(mode):
                rows.append(source_entry(name, "120000", name_bytes(os.readlink(path))))
            else:
                require(stat.S_ISREG(mode), "non-file committed checkout entry")
                rows.append(source_entry(name, "100755" if mode & 0o111 else "100644",
                                         path.read_bytes()))
        except OSError as exc:
            raise Invalid("missing/unreadable committed checkout entry: " + repr(name)) from exc
    return sorted(rows, key=lambda row: row["name"])


def working_inventory(root):
    rows = []
    for base, dirs, files in os.walk(root, followlinks=False):
        for name in list(dirs):
            if (Path(base) / name).is_symlink():
                dirs.remove(name)
                files.append(name)
        relative = os.path.relpath(base, root)
        def generated(name):
            path = name if relative == "." else relative + "/" + name
            return (name == "__pycache__" or path == ".git" or
                    any(path == x or path.startswith(x + "/") for x in GENERATED))
        dirs[:] = [name for name in dirs if not generated(name)]
        for name in files:
            if generated(name):
                continue
            path = Path(base) / name
            rel = path.relative_to(root).as_posix()
            safe_path(rel)
            mode = path.lstat().st_mode
            require(stat.S_ISREG(mode) or stat.S_ISLNK(mode), "special source file")
            if stat.S_ISLNK(mode):
                rows.append(source_entry(rel, "120000", name_bytes(os.readlink(path))))
            else:
                rows.append(source_entry(rel, "100755" if mode & 0o111 else "100644",
                                         path.read_bytes()))
    return sorted(rows, key=lambda row: row["name"])


def commit_source(root, revision):
    commit = git(root, "rev-parse", "--verify", revision + "^{commit}").decode().strip()
    tree = git(root, "rev-parse", commit + "^{tree}").decode().strip()
    archive = git(root, "-c", "tar.umask=0002",
                  "-c", "tar.tar.gz.command=git archive gzip",
                  "archive", "--format=tar.gz", "-9", commit)
    inventory = archive_inventory(archive)
    require(inventory == tree_inventory(root, commit),
            "Git archive differs from committed tree (check export attributes)")
    policy = decode(git(root, "show", commit + ":scripts/ci/policy.json"))
    validate_policy(policy)
    return archive, {"commit": commit, "tree": tree, "archive_sha256": digest(archive),
                     "source_sha256": identity(inventory), "inventory": inventory,
                     "policy_sha256": identity(policy), "policy": policy}


def required_jobs():
    result = []
    for purpose in ("suite", "quality", "debugger"):
        for mode in ("debug", "release"):
            commands = [["./scripts/clean.sh", "--all"], ["./scripts/build.sh"]]
            if purpose == "suite":
                commands += [["./scripts/test.sh"],
                             ["python3", "compiler/tests/test_native_report_identity.py",
                              "--refine", "{refine}"], ["{refine}", "--identify"]]
            else:
                commands += [["./scripts/quality.sh" if purpose == "quality" else
                              "./scripts/debug.sh"]]
            result.append({"id": purpose + "-" + mode, "mode": mode, "commands": commands})
    result += [{"id": "bindings", "mode": "debug", "commands": [["clang-19", "--version"],
                 ["python3", "bindings/test.py"]]},
               {"id": "documents", "mode": "debug", "commands": [
                   ["python3", "scripts/tests/test_build_inventory.py"],
                   ["python3", "scripts/tests/test_build_lock.py"],
                   ["python3", "scripts/tests/test_roadmap_progress.py"],
                   ["python3", "scripts/tests/test_ci.py"],
                   ["python3", "compiler/tests/debugging/test_check.py"],
                   ["python3", "check.py"], ["./scripts/site.sh"]]}]
    return result


def validate_policy(policy):
    expected = {"schema": 1, "platform": "Linux-x86_64", "pins": "environments/pins.sh",
                "build_tag": "native-ci", "clang": "clang-19", "jobs": required_jobs()}
    require(policy == expected, "acceptance policy omits or changes required native checks")
    return policy


def validate_request(request):
    require(set(request) == {"schema", "run_id", "commit", "tree", "archive_sha256",
                            "source_sha256", "inventory", "policy_sha256", "policy"},
            "invalid initialized request fields")
    require(request["schema"] == 1, "unsupported request schema")
    require(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,95}", request["run_id"]),
            "invalid run identity")
    for key in ("commit", "tree"):
        require(re.fullmatch(r"[0-9a-f]{40}", request[key]), "invalid " + key)
    for key in ("archive_sha256", "source_sha256", "policy_sha256"):
        require(re.fullmatch(r"[0-9a-f]{64}", request[key]), "invalid " + key)
    validate_policy(request["policy"])
    require(identity(request["policy"]) == request["policy_sha256"], "policy hash mismatch")
    require(identity(request["inventory"]) == request["source_sha256"], "source hash mismatch")
    return request
