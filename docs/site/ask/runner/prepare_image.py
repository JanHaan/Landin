#!/usr/bin/env python3
"""Prepare an image context from a checked compiler; never download/build it."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--refine", type=Path, required=True)
    parser.add_argument("--sha256", required=True, help="hash from the compiler's checked artifact")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--cloudflare", action="store_true",
                        help="prepare the one-job Cloudflare microVM image")
    parser.add_argument("--commit", help="compiler's recorded source commit")
    args = parser.parse_args()
    digest = hashlib.sha256(args.refine.read_bytes()).hexdigest()
    if digest != args.sha256:
        raise SystemExit("runner: checked compiler hash does not match")
    if args.cloudflare:
        executable = args.refine.read_bytes()
        if executable[:6] != b"\x7fELF\x02\x01" or executable[18:20] != b"\x3e\x00":
            raise SystemExit("runner: Cloudflare requires a Linux x86-64 ELF compiler")
        if not args.commit or len(args.commit) != 40 or any(c not in "0123456789abcdef" for c in args.commit):
            raise SystemExit("runner: Cloudflare image requires recorded compiler commit")
        import subprocess
        changed = subprocess.check_output(["git", "status", "--porcelain", "--untracked-files=all",
                "--", "compiler/ada", "core"], cwd=ROOT, text=True)
        same_sources = subprocess.run(["git", "diff", "--quiet", args.commit, "HEAD",
                "--", "compiler/ada", "core"], cwd=ROOT).returncode == 0
        if not same_sources or changed:
            raise SystemExit("runner: compiler/core do not match the recorded revision")
    args.output.mkdir(parents=True, exist_ok=False)
    shutil.copyfile(args.refine, args.output / "refine")
    (args.output / "compiler.sha256").write_text(digest + "  refine\n")
    for name in ("Containerfile", "container_entry.py"):
        shutil.copyfile(HERE / name, args.output / name)
    if args.cloudflare:
        shutil.copyfile(HERE / "cloudflare_server.py", args.output / "cloudflare_server.py")
        import re
        pins = (ROOT / "environments/pins.sh").read_text()
        base = re.search(r"^LANDIN_BASE_IMAGE=(\S+)$", pins, re.MULTILINE).group(1)
        recipe = (HERE / "Cloudflare.Containerfile").read_text().replace("ARG BASE_IMAGE", f"ARG BASE_IMAGE={base}")
        (args.output / "Containerfile").write_text(recipe)
        (args.output / "provenance.json").write_text(json.dumps(dict(
            compilerSHA256=digest, commit=args.commit, baseImage=base)) + "\n")
    shutil.copyfile(ROOT / "environments/pins.sh", args.output / "pins.sh")
    shutil.copytree(ROOT / "core", args.output / "core",
                    ignore=shutil.ignore_patterns("*.md", "__pycache__"))
    print(f"prepared {args.output}; compiler {digest}")


if __name__ == "__main__":
    main()
