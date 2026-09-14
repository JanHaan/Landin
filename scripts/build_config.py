#!/usr/bin/env python3
"""Snapshot the native GPR configuration and identify its selected C driver."""
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile


def run(arguments):
    process = subprocess.Popen(arguments, text=True, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, start_new_session=True)
    try:
        out, err = process.communicate(timeout=10)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.communicate()
        raise
    if process.returncode:
        raise ValueError(f"{arguments[0]} failed ({process.returncode}): {err.strip()}")
    return out


def snapshot(destination):
    destination = Path(destination).absolute()
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="landin-config-") as temporary:
        generated = Path(temporary) / "native.cgpr"
        run(["gprconfig", "--batch", "--fallback-targets", "-q",
             "--config=C", "--config=Ada", "-o", str(generated)])
        # The generated header records its temporary filename. Comments are
        # not configuration identity; retain all project declarations verbatim.
        content = "\n".join(line for line in generated.read_text().splitlines()
                            if not line.lstrip().startswith("--")) + "\n"
        drivers = re.findall(
            r'\bfor\s+Driver\s*\(\s*"C"\s*\)\s*use\s*'
            r'"((?:[^"\n]|"")*)"\s*;', content, re.IGNORECASE)
        if len(drivers) != 1:
            raise ValueError("native configuration must name one literal C driver")
        driver = Path(drivers[0].replace('""', '"'))
        if not driver.is_absolute() or not driver.is_file():
            raise ValueError("configured C driver must be an existing absolute file")
        version = run([str(driver), "--version"]).strip()
        if not version:
            raise ValueError("configured C driver returned no version")
        digest = hashlib.sha256()
        with driver.open("rb") as stream:
            for chunk in iter(lambda: stream.read(65536), b""):
                digest.update(chunk)
        identity = {
            "path": str(driver),
            "sha256": digest.hexdigest(),
            "version": version,
        }
        # A failed probe leaves the previous snapshot and successful source
        # manifest alone. The caller holds the per-mode build lock throughout.
        if not destination.exists() or destination.read_text() != content:
            staged = destination.with_suffix(".tmp")
            staged.write_text(content)
            staged.replace(destination)
        return ("toolchain configuration "
                + hashlib.sha256(content.encode()).hexdigest() + "\n"
                + "toolchain c-driver " + json.dumps(identity, sort_keys=True))


if __name__ == "__main__":
    try:
        if len(sys.argv) != 2:
            raise ValueError("expected the configuration snapshot path")
        print(snapshot(sys.argv[1]))
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        print(f"landin: build configuration: {error}", file=sys.stderr)
        sys.exit(2)
