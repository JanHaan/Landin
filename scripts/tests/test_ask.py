#!/usr/bin/env python3
"""Controls for the documentation snapshot and execution resource boundary.

These run tiny Python children, never the Landin compiler or user programs.
Native compiler and image checks belong on the native host or isolated runner.
"""
import importlib.util
import hashlib
import json
from pathlib import Path
import sys
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
ASK = ROOT / "docs/site/ask"
sys.path.insert(0, str(ASK / "runner"))


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    imported = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(imported)
    return imported


builder = module("ask_builder", ASK / "build.py")
runner = module("ask_runner", ASK / "runner/server.py")
entry = module("ask_entry", ASK / "runner/container_entry.py")


class Snapshot(unittest.TestCase):
    def test_sections_keep_fenced_headings_and_every_character(self):
        text = "# Title\n\n## First\n\n```landin\n# not a heading\n```\n\n### [1740] Rule\nbody\n"
        sections = list(builder.sections(text))
        self.assertEqual("".join(body for _, _, body in sections), text)
        self.assertEqual([anchor for _, anchor, _ in sections], ["title", "first", "1740"])

    def test_long_sections_are_bounded_and_lossless(self):
        text = "a line\n\n" * 5000 + "long line" * 2000
        chunks = list(builder.split_text(text))
        self.assertEqual("".join(chunks), text)
        self.assertTrue(all(0 < len(part) <= builder.MAX_CHARS for part in chunks))

    def test_stale_target_inventory_is_not_transcribed_into_the_primer(self):
        self.assertNotIn("Three native backends", builder.site.llms.SUMMARY)
        self.assertIn("README", builder.site.llms.SUMMARY)


class SandboxBoundary(unittest.TestCase):
    def test_image_preparation_rejects_wrong_compiler_before_writing_context(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            executable = directory / "refine"
            executable.write_bytes(b"\x7fELF\x02\x01" + b"\0" * 12 + b"\xb7\x00" + b"\0" * 44)
            output = directory / "image"
            command = [sys.executable, str(ASK / "runner/prepare_image.py"), "--cloudflare",
                       "--refine", str(executable), "--output", str(output), "--sha256"]
            mismatch = subprocess.run(command + ["0" * 64], capture_output=True, text=True)
            self.assertNotEqual(mismatch.returncode, 0)
            self.assertIn("hash does not match", mismatch.stderr)
            wrong_arch = subprocess.run(command + [hashlib.sha256(executable.read_bytes()).hexdigest()],
                                        capture_output=True, text=True)
            self.assertNotEqual(wrong_arch.returncode, 0)
            self.assertIn("x86-64 ELF", wrong_arch.stderr)
            self.assertFalse(output.exists())

    def test_untrusted_source_cannot_select_command_or_mounts(self):
        command = runner.container_command("sha256:" + "a" * 64, "landin-ask-test")
        for boundary in ("--runtime=runsc", "--network=none", "--read-only",
                         "--cap-drop=ALL", "--memory=512m", "--memory-swap=512m",
                         "--pids-limit=64", "--cpus=1", "--user=65532:65532",
                         "--pull=never", "--log-driver=none"):
            self.assertIn(boundary, command)
        self.assertFalse(any(arg in ("-v", "--mount", "--privileged", "--network=host") for arg in command))
        self.assertEqual(command[-1], "/opt/landin/container_entry.py")
        for image in ("latest", "image; rm -rf /", "sha256:short"):
            with self.assertRaises(ValueError):
                runner.container_command(image, "landin-ask-test")

    def test_daily_jobs_persist_across_runner_restarts(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "quota.sqlite"
            first = runner.Quotas(path)
            for _ in range(runner.DAILY_JOBS):
                self.assertTrue(first.reserve("2026-10-08"))
            self.assertFalse(runner.Quotas(path).reserve("2026-10-08"))
            self.assertTrue(runner.Quotas(path).reserve("2026-10-09"))

    def test_output_flood_is_stopped_while_reading(self):
        status, _, output = entry.execute([sys.executable, "-c",
            "import os\nwhile True: os.write(1, b'x'*4096)"], 2, 1000, cwd=None)
        self.assertEqual(status, "output_limit")
        self.assertEqual(len(output), 1000)

    def test_hang_is_stopped_even_after_closing_stdout(self):
        started = time.monotonic()
        status, _, _ = entry.execute([sys.executable, "-c",
            "import os,time; os.close(1); time.sleep(10)"], 0.15, cwd=None)
        self.assertEqual(status, "timeout")
        self.assertLess(time.monotonic() - started, 2)

    def test_stdin_transfer_is_bounded_and_does_not_use_shell_interpolation(self):
        payload = b"$(echo not-executed) `echo not-executed`" * 1000
        status, code, output = entry.execute([sys.executable, "-c",
            "import sys; print(len(sys.stdin.buffer.read()))"], 2, 1000,
            input_bytes=payload, cwd=None)
        self.assertEqual((status, code), ("finished", 0))
        self.assertEqual(int(output.strip()), len(payload))


if __name__ == "__main__":
    unittest.main()
