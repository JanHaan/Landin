#!/usr/bin/env python3
"""Exact-revision native Darwin acceptance and retained evidence verification."""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import uuid

from common import (archive_inventory, canonical, checkout_inventory, clean_checkout,
                    commit_source, file_hash, read_json,
                    require, safe_path, write_new)

MARKER = "environments/macos-arm64/acceptance.json"


def required_policy(debugging=True, parity=False):
    if parity:
        commands = []
        for mode in ("debug", "release"):
            prefix = ["env", "LANDIN_BUILD_MODE=" + mode]
            commands += [prefix + ["./scripts/build.sh", "-j8"],
                         prefix + ["./scripts/test.sh", "--host"],
                         prefix + ["python3", "compiler/tests/darwin/diagnostics.py", "--refine",
                                   "{refine-" + mode + "}", "--output", "{diagnostics-" + mode + "}"],
                         prefix + ["python3", "compiler/tests/darwin/check.py", "--parity", "--refine",
                                   "{refine-" + mode + "}", "--output", "{executions-" + mode + "}"],
                         prefix + ["python3", "compiler/tests/darwin/bindings.py", "--parity", "--refine",
                                   "{refine-" + mode + "}", "--output", "{bindings-" + mode + "}"],
                         prefix + ["./scripts/debug.sh", "--target=darwin-arm64", "--parity",
                                   "--output", "{debugging-" + mode + "}"]]
        return {"schema": 3, "scope": "R5.50 hosted parity", "modes": ["debug", "release"],
                "commands": commands}
    policy = {"schema": 1, "scope": "R5.30 native lowering", "mode": "release", "commands": [
        ["./scripts/build.sh", "-j8"], ["./scripts/test.sh", "--host"],
        ["python3", "compiler/tests/darwin/check.py", "--refine", "{refine}", "--output", "{executions}"],
        ["python3", "compiler/tests/darwin/bindings.py", "--refine", "{refine}", "--output", "{bindings}"]]}
    if debugging:
        policy.update(schema=2, scope="R5.40 native source debugging")
        policy["commands"].append(["./scripts/debug.sh", "--target=darwin-arm64",
                                   "--output", "{debugging}"])
    return policy


def scoped_policy(scope, debugger=False):
    """Schema 4: full hosted coverage with explicit compiler/debugger modes."""
    require(scope in ("routine", "milestone"), "unknown Darwin scope")
    require(type(debugger) is bool, "invalid Darwin debugger choice")
    hosted = ["debug", "release"] if scope == "milestone" else ["release"]
    debugging = hosted if debugger or scope == "milestone" else []
    commands = []
    historical = required_policy(parity=True)["commands"]
    for index, mode in enumerate(("debug", "release")):
        commands.extend(historical[index * 6:index * 6 + 2])
        if mode in hosted:
            commands.extend(historical[index * 6 + 2:index * 6 + 5])
        if mode in debugging:
            commands.append(historical[index * 6 + 5])
    return dict(schema=4, scope=scope, debugger=bool(debugging),
                modes=["debug", "release"], hosted_modes=hosted,
                debugger_modes=debugging, commands=commands)


def validate_policy(policy):
    require(isinstance(policy, dict) and type(policy.get("schema")) is int
            and policy["schema"] in (1, 2, 3, 4), "unsupported Darwin policy schema")
    if policy["schema"] == 4:
        expected = scoped_policy(policy.get("scope"), policy.get("debugger"))
    else:
        expected = required_policy(policy["schema"] != 1, policy["schema"] == 3)
    require(policy == expected, "invalid Darwin policy")
    return policy


def required(source):
    from common import encoded_name
    return any(row["name"] == encoded_name(MARKER) for row in source["inventory"])


def files_under(root):
    result = {}
    for path in sorted(root.rglob("*")):
        relative = path.relative_to(root)
        if relative.parts[0] == "source" or str(relative) == "record.json":
            continue
        require(not path.is_symlink(), "symlink in Darwin evidence")
        require(path.is_file() or path.is_dir(), "special file in Darwin evidence")
        if path.is_file():
            result[str(relative)] = file_hash(path)
    return result


def validate(bundle, source):
    bundle = Path(bundle)
    record = read_json(bundle / "record.json")
    require(record["status"] == "passed" and record["scope"] == record["policy"]["scope"],
            "Darwin acceptance did not pass")
    require(record["source"] == source, "Darwin source differs from Linux acceptance")
    require(file_hash(bundle / "source.tar.gz") == source["archive_sha256"], "Darwin archive mismatch")
    require(archive_inventory((bundle / "source.tar.gz").read_bytes()) == source["inventory"],
            "Darwin archive inventory mismatch")
    require(record["files"] == files_under(bundle), "Darwin retained evidence mismatch")
    require(record["environment"]["platform"] == "Darwin-arm64"
            and record["environment"]["translated"] is False, "Darwin native host missing")
    for path in record["files"]:
        require(not (bundle / safe_path(path, source=False)).is_symlink(), "symlink in Darwin evidence")
    policy = record["policy"]
    validate_policy(policy)
    from common import encoded_name
    marker = next(row for row in source["inventory"] if row["name"] == encoded_name(MARKER))
    require(file_hash(bundle / "policy.json") == marker["sha256"]
            and read_json(bundle / "policy.json") == policy, "Darwin policy is not committed")
    for original, retained in (("compiler/tests/darwin/cases.json", "cases.json"),
                               ("environments/macos-arm64/policy.json", "environment-policy.json")):
        row = next(row for row in source["inventory"] if row["name"] == encoded_name(original))
        require(file_hash(bundle / retained) == row["sha256"], "uncommitted Darwin input: " + original)
    require(record["environment"]["policy"] == read_json(bundle / "environment-policy.json"),
            "Darwin environment policy differs")
    if policy["schema"] < 3:
        require(all(path in record["files"] for path in
                    ("refine", "source-manifest.txt", "configuration.cgpr")), "missing Darwin build identity")
    commands = read_json(bundle / "evidence/commands.json")
    steps = [c for c in commands if c["name"].startswith("step-")]
    require(len(steps) == len(policy["commands"]), "missing Darwin step")
    mapping = record["paths"]
    for index, (actual, template) in enumerate(zip(steps, policy["commands"])):
        expected = [mapping.get(arg, arg) for arg in template]
        require(actual["name"] == f"step-{index}" and actual["argv"] == expected
                and actual["cwd"] == mapping["source"]
                and actual["returncode"] == 0 and not actual["timeout"], "failed/substituted Darwin command")
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    from macos_environment import harness_result
    if policy["schema"] >= 3:
        if policy["schema"] == 3:
            from darwin_parity import validate as validate_parity
        else:
            from darwin_scoped import validate as validate_parity
        validate_parity(bundle, record)
        return {"status": "passed", "run_id": record["run_id"],
                "commit": source["commit"], "tree": source["tree"],
                "archive_sha256": source["archive_sha256"], "source_sha256": source["source_sha256"],
                "policy_sha256": marker["sha256"], "record_sha256": file_hash(bundle / "record.json")}
    harness_result(0, (bundle / "evidence/step-1.stdout").read_text(), host_only=True)
    execution = read_json(bundle / "executions/summary.json")
    manifest = read_json(bundle / "cases.json")
    expected = [(name, opt, spec) for name in
                manifest["fixtures"] + [c["name"] for c in manifest["darwin"]]
                for opt, spec in manifest["profiles"]]
    require(execution["status"] == "passed" and execution["scope"] == "R5.30"
            and [(r["case"], r["optimize"], r["specialize"]) for r in execution["results"]] == expected
            and all(r["status"] == "passed" for r in execution["results"]), "incomplete Darwin executions")
    require(execution["refine_sha256"] == file_hash(bundle / "refine")
            and execution["cases_sha256"] == file_hash(bundle / "cases.json"), "Darwin execution inputs differ")
    bindings = read_json(bundle / "bindings/summary.json")
    require(bindings["status"] == "passed" and bindings["archive_selection"] == "passed"
            and bindings["refine_sha256"] == file_hash(bundle / "refine"),
            "Darwin bindings incomplete")
    if policy["schema"] == 2:
        validate_debugging(bundle, record)
    return {"status": "passed", "run_id": record["run_id"],
            "commit": source["commit"], "tree": source["tree"],
            "archive_sha256": source["archive_sha256"], "source_sha256": source["source_sha256"],
            "policy_sha256": marker["sha256"], "record_sha256": file_hash(bundle / "record.json")}


def validate_debugging(bundle, record):
    debug = bundle / "debugging"
    summary = read_json(debug / "summary.json")
    require(summary["status"] == "passed" and summary["scope"] == "R5.40"
            and summary["filtered"] is False, "incomplete native LLDB scope")
    require(summary["refine_sha256"] == file_hash(bundle / "refine"), "LLDB compiler identity differs")
    profiles = [("none", "off"), ("size", "auto"), ("size", "all")]
    require([(r["optimize"], r["specialize"]) for r in summary["results"]] == profiles,
            "incomplete native LLDB profiles")
    from common import encoded_name
    inventory = {r["name"]: r["sha256"] for r in record["source"]["inventory"]}
    expected_sources = ["compiler/tests/debugging/main.ldn",
                        'compiler/tests/debugging/caller"\\path.ldn',
                        "compiler/tests/debugging/darwin-scalars.ldn"]
    require(set(summary["sources"]) == set(expected_sources), "LLDB source set differs")
    for name in expected_sources:
        require(summary["sources"][name] == inventory[encoded_name(name)], "LLDB source identity differs")
    tools = summary["tools"]
    require(set(tools) == {"clang", "lldb", "dwarfdump", "dsymutil", "strip", "otool"},
            "missing native debugger tool identities")
    require(tools["lldb"] == record["environment"]["tools"]["debugger"]
            and tools["clang"] == record["environment"]["tools"]["clang"]
            and tools["dsymutil"] == record["environment"]["tools"]["dsymutil"]
            and tools["dwarfdump"] == record["environment"]["tools"]["dwarfdump"],
            "LLDB tools differ from native policy")
    import macho_identity
    for row in summary["results"]:
        key = row["optimize"] + "-" + row["specialize"]
        require(row["status"] == "passed", "native LLDB profile failed")
        session = read_json(debug / (key + "-session.json"))
        require(session["status"] == "passed" and len(session["checks"]) >= 168
                and len(session["checks"]) == row["checks"], "incomplete native LLDB assertions")
        require(read_json(debug / (key + "-scalars-session.json")) ==
                {"status": "passed", "scalar_types": 13}, "native scalar debugger checks missing")
        for suffix in ("", ".s", ".o", ".sources.json", ".lldb", "-lldb.stdout",
                       "-verify.stdout", "-object-verify.stdout", "-unwind.stdout", "-uuid.stdout",
                       "-debug-map.stdout", "-stripped", ".dSYM/Contents/Resources/DWARF/" + key):
            require("debugging/" + key + suffix in record["files"], "missing native debug artifact: " + suffix)
        table = read_json(debug / (key + ".sources.json"))
        require(table["assembly_sha256"] == file_hash(debug / (key + ".s")),
                "native debug assembly identity differs")
        try:
            linked = macho_identity.match(table, debug / key,
                debug / (key + ".dSYM/Contents/Resources/DWARF/" + key))
            stripped = macho_identity.match(table, debug / (key + "-stripped"))
        except ValueError as error:
            raise ValueError("native debug identity mismatch: " + str(error)) from error
        require(linked == row["identity"] and stripped == linked, "native debug artifact identities differ")
        require("LANDIN LLDB ACCEPTANCE PASSED" in (debug / (key + "-lldb.stdout")).read_text(),
                "native LLDB session did not finish")
    require(read_json(debug / "identity-checks.json") == {name: "passed" for name in (
        "default_none", "caller_only", "optional_filenames", "comment_mismatch", "dsym_mismatch")},
        "native debug identity checks incomplete")


def validate_annotation(annotation, source):
    from common import encoded_name
    marker = next(row for row in source["inventory"] if row["name"] == encoded_name(MARKER))
    require(set(annotation) == {"status", "run_id", "commit", "tree", "archive_sha256",
                               "source_sha256", "policy_sha256", "record_sha256"}, "invalid Darwin approval fields")
    require(annotation["status"] == "passed", "Darwin approval did not pass")
    for name in ("commit", "tree", "archive_sha256", "source_sha256"):
        require(annotation[name] == source[name], "Darwin approval " + name + " mismatch")
    require(annotation["policy_sha256"] == marker["sha256"], "Darwin approval policy mismatch")
    import re
    require(re.fullmatch(r"[0-9a-f]{64}", annotation["record_sha256"])
            and re.fullmatch(r"[0-9]{8}T[0-9]{6}Z-[0-9a-f]{12}", annotation["run_id"]),
            "invalid Darwin evidence identity")


def worker(bundle):
    bundle = Path(bundle).resolve()
    source_root = bundle / "source"
    source = read_json(bundle / "source.json")
    require(checkout_inventory(source_root, source["inventory"]) == source["inventory"],
            "Darwin source changed before build")
    sys.path.insert(0, str(source_root / "scripts"))
    import macos_environment as mac
    mac.ROOT = source_root
    mac.POLICY = source_root / "environments/macos-arm64/policy.json"
    evidence = bundle / "evidence"
    evidence.mkdir()
    capture = mac.Capture(evidence)
    policy = read_json(source_root / MARKER)
    validate_policy(policy)
    shutil.copyfile(source_root / MARKER, bundle / "policy.json")
    shutil.copyfile(source_root / "compiler/tests/darwin/cases.json", bundle / "cases.json")
    shutil.copyfile(mac.POLICY, bundle / "environment-policy.json")
    record = {"schema": 1, "scope": policy["scope"], "run_id": bundle.parent.name,
              "source": source, "policy": policy, "status": "failed"}
    try:
        native_policy, sdk, tools = mac.validate(capture)
        record["environment"] = {"platform": "Darwin-arm64", "translated": False,
                                  "policy": native_policy, "sdk": sdk, "tools": tools}
        env = {**os.environ, "LANDIN_BUILD_MODE": "release", "LANDIN_BUILD_TAG": "darwin-acceptance",
               "LANDIN_BUILD_INCREMENTAL": "no", "SDKROOT": sdk}
        env.pop("LANDIN_TEST_FILTER", None)
        refine = source_root / "compiler/ada/build/darwin-acceptance/release/bin/refine"
        mapping = {"{refine}": str(refine), "{executions}": str(bundle / "executions"),
                   "{bindings}": str(bundle / "bindings"),
                   "{debugging}": str(bundle / "debugging"), "source": str(source_root)}
        record["paths"] = mapping
        if policy["schema"] >= 3:
            for mode in policy["modes"]:
                (bundle / mode).mkdir()
                mapping["{refine-" + mode + "}"] = str(source_root /
                    ("compiler/ada/build/darwin-acceptance/" + mode + "/bin/refine"))
                for name in ("executions", "diagnostics", "bindings", "debugging"):
                    mapping["{" + name + "-" + mode + "}"] = str(bundle / mode / name)
        for index, command in enumerate(policy["commands"]):
            capture.run(f"step-{index}", [mapping.get(arg, arg) for arg in command],
                        cwd=source_root, env=env, timeout=7200)
        require(capture.text("refine-architecture", ["lipo", "-archs", refine]) == "arm64",
                "Darwin compiler is not native arm64")
        capture.run("refine-identity", [refine, "--identify"], env=env)
        require(checkout_inventory(source_root, source["inventory"]) == source["inventory"],
                "Darwin source changed during acceptance")
        for tool in tools.values():
            require(file_hash(Path(tool["path"])) == tool["sha256"], "Darwin tool changed during acceptance")
        for mode in policy.get("modes", ["release"]):
            compiler = source_root / ("compiler/ada/build/darwin-acceptance/" + mode + "/bin/refine")
            retained = bundle / mode if policy["schema"] >= 3 else bundle
            require(capture.text("refine-architecture-" + mode, ["lipo", "-archs", compiler]) == "arm64",
                    "Darwin compiler is not native arm64")
            shutil.copy2(compiler, retained / "refine")
            shutil.copyfile(compiler.parents[1] / "source-manifest.txt", retained / "source-manifest.txt")
            shutil.copyfile(source_root / ("compiler/ada/.build-locks/darwin-acceptance-" + mode + ".cgpr"),
                            retained / "configuration.cgpr")
        record["status"] = "passed"
    finally:
        record["files"] = files_under(bundle)
        (bundle / "record.json").write_bytes(canonical(record))
    validate(bundle, source)


def accept(root, revision, state):
    clean_checkout(root)
    archive, source = commit_source(root, revision)
    require(required(source), "revision has no Darwin acceptance policy")
    run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex[:12]
    bundle = state / run_id / "bundle"
    bundle.mkdir(parents=True)
    (bundle / "source.tar.gz").write_bytes(archive)
    write_new(bundle / "source.json", source)
    archive_inventory(archive, bundle / "source")
    print("DARWIN ACCEPTANCE " + run_id + " commit=" + source["commit"], flush=True)
    env = dict(os.environ)
    for key in ("LANDIN_GNAT_HOME", "LANDIN_GPRBUILD_HOME"):
        if env.get(key):
            env["PATH"] = str(Path(env[key]) / "bin") + os.pathsep + env["PATH"]
    subprocess.run([sys.executable, str(bundle / "source/scripts/ci/darwin.py"),
                    "worker", str(bundle)], env=env, check=True)
    validate(bundle, source)
    exported = state / "exports" / run_id
    exported.parent.mkdir(exist_ok=True)
    shutil.copytree(bundle, exported, ignore=lambda directory, names:
                    ["source"] if Path(directory) == bundle else [])
    validate(exported, source)
    print("verified Darwin export: " + str(exported), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["accept", "worker", "verify"])
    parser.add_argument("value")
    parser.add_argument("--state", type=Path, default=Path.home() / ".local/state/landin/darwin")
    args = parser.parse_args()
    if args.action == "worker":
        worker(Path(args.value))
    elif args.action == "verify":
        bundle = Path(args.value)
        print(json.dumps(validate(bundle, read_json(bundle / "source.json")), indent=2))
    else:
        accept(Path(__file__).resolve().parents[2], args.value, args.state.resolve())


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print("Darwin acceptance: " + str(error), file=sys.stderr)
        raise SystemExit(1)
