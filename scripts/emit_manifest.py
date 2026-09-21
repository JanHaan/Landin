#!/usr/bin/env python3
"""Emit assembly for every positive fixture on every target and hash it.

The point is a manifest that must be byte-identical on any host.  Emission
needs no target assembler, linker or emulator, so this runs anywhere the
compiler builds.  Every input to the declared equivalence relation is fixed
on the command line; only the host is free to vary.
"""
import hashlib, json, subprocess, sys, tempfile, os
from pathlib import Path

refine = Path(sys.argv[1]).resolve()
root = Path(sys.argv[2]).resolve()
out = Path(sys.argv[3])

TARGETS = ("linux-x86-64", "darwin-arm64", "cortex-m0")
MODES = ("debug", "release")
fixtures = sorted(p for p in (root / "compiler/tests/fixtures/positive").iterdir() if p.is_dir())

manifest, refused = {}, 0
with tempfile.TemporaryDirectory() as tmp:
    asm = Path(tmp) / "out.s"
    for fx in fixtures:
        src = fx / "program.ldn"
        if not src.exists():
            continue
        for target in TARGETS:
            for mode in MODES:
                key = "%s|%s|%s" % (fx.name, target, mode)
                if asm.exists():
                    asm.unlink()
                r = subprocess.run(
                    [str(refine), "--target=" + target, "--build-mode=" + mode,
                     "--optimize=size", "--specialize=auto", "--emit=asm",
                     "-o", str(asm), str(src)],
                    capture_output=True, cwd=tmp)
                if r.returncode != 0 or not asm.exists():
                    manifest[key] = "refused:%d" % r.returncode
                    refused += 1
                else:
                    manifest[key] = hashlib.sha256(asm.read_bytes()).hexdigest()

out.write_text(json.dumps(manifest, indent=1, sort_keys=True) + "\n")
emitted = len(manifest) - refused
print("fixtures %d  entries %d  emitted %d  refused %d"
      % (len(fixtures), len(manifest), emitted, refused))
print("manifest sha256:", hashlib.sha256(out.read_bytes()).hexdigest())
