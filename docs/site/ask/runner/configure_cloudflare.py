#!/usr/bin/env python3
"""Generate a private container deployment config from checked image inputs."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import shlex

HERE = Path(__file__).resolve().parent
ASK = HERE.parent
ROOT = ASK.parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--context", type=Path, required=True)
    args = parser.parse_args()
    context = args.context.resolve()
    provenance = json.loads((context / "provenance.json").read_text())
    digest = hashlib.sha256((context / "refine").read_bytes()).hexdigest()
    commit = provenance["commit"]
    if not isinstance(commit, str) or len(commit) != 40 or any(c not in "0123456789abcdef" for c in commit):
        raise SystemExit("ask: invalid compiler source revision")
    changed = subprocess.check_output(["git", "status", "--porcelain", "--untracked-files=all",
            "--", "compiler/ada", "core"], cwd=ROOT, text=True)
    same_sources = subprocess.run(["git", "diff", "--quiet", commit, "HEAD",
            "--", "compiler/ada", "core"], cwd=ROOT).returncode == 0
    if digest != provenance["compilerSHA256"] or not same_sources or changed:
        raise SystemExit("ask: checked compiler provenance does not match this checkout")
    for name in ("container_entry.py", "cloudflare_server.py"):
        if (context / name).read_bytes() != (HERE / name).read_bytes():
            raise SystemExit("ask: prepared image launcher is stale; prepare a fresh context")
    config = json.loads((ASK / "wrangler.jsonc").read_text())
    config["main"] = str(ASK / config["main"])
    config["$schema"] = str(ASK / config["$schema"])
    config["assets"]["directory"] = str(ASK / config["assets"]["directory"])
    config["build"]["command"] = "python3 " + shlex.quote(str(ASK / "build.py"))
    config["limits"] = {"cpu_ms": 25}
    config["durable_objects"]["bindings"].append({"name": "EXECUTION", "class_name": "Execution"})
    config["migrations"].append({"tag": "v2", "new_sqlite_classes": ["Execution"]})
    config["containers"] = [{"class_name": "Execution", "scheduling_policy": "default",
        "image": str(context / "Containerfile"), "image_build_context": str(context),
        "max_instances": 1, "instance_type": {"vcpu": 1, "memory_mib": 1024, "disk_mb": 4096}}]
    config["vars"].update(EXECUTION_BACKEND="cloudflare", COMPILER_SHA256=digest,
                          EXECUTION_ENABLED="false", PRIVATE_MODE="true")
    output = ASK / "build/wrangler.containers.json"
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(config, indent=2) + "\n")
    print(f"prepared {output}; private mode; execution disabled; compiler {digest}")


if __name__ == "__main__":
    main()
