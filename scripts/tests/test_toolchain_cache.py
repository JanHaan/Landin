#!/usr/bin/env python3
"""Installed tool reuse checks pins, every file, link, mode and inventory path."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("toolchain_cache", ROOT / "scripts/toolchain_cache.py")
CACHE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CACHE)


class ToolchainCache(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.into = Path(self.temporary.name) / "tools"
        self.pins = {"platform": "x86_64-linux", "gnat": "1", "gprbuild": "2",
                     "gnat_sha256": "a" * 64, "gprbuild_sha256": "b" * 64}

    def installer(self, stage):
        for name in CACHE.directories(self.pins):
            (stage / name / "bin").mkdir(parents=True)
            executable = stage / name / "bin/tool"
            executable.write_bytes(b"checked executable bytes")
            executable.chmod(0o755)
            (stage / name / "bin/alias").symlink_to("tool")

    def install(self):
        CACHE.install(self.into, self.pins, self.installer)
        self.assertTrue(CACHE.verify(self.into, self.pins))

    def test_verified_install_is_reusable_but_missing_record_is_not(self):
        self.assertFalse(CACHE.verify(self.into, self.pins))
        self.install()
        (self.into / ".landin-install-x86_64-linux.json").unlink()
        self.assertFalse(CACHE.verify(self.into, self.pins))

    def test_changed_archive_pin_or_platform_is_not_reusable(self):
        self.install()
        for name in ("gnat", "gprbuild", "gnat_sha256", "gprbuild_sha256", "platform"):
            with self.subTest(name=name):
                other = dict(self.pins, **{name: "changed"})
                self.assertFalse(CACHE.verify(self.into, other))

    def test_modified_removed_extra_mode_and_symlink_files_require_reinstall(self):
        for mutation in ("bytes", "removed", "extra", "mode", "link", "directory-mode"):
            with self.subTest(mutation=mutation):
                self.install()
                directory = self.into / "gnat-1"
                executable = directory / "bin/tool"
                if mutation == "bytes":
                    executable.write_bytes(b"other executable")
                elif mutation == "removed":
                    executable.unlink()
                elif mutation == "extra":
                    (directory / "extra").write_text("unexpected")
                elif mutation == "mode":
                    executable.chmod(0o644)
                elif mutation == "link":
                    (directory / "bin/alias").unlink()
                    (directory / "bin/alias").symlink_to("different")
                else:
                    directory.chmod(directory.stat().st_mode ^ 0o010)
                self.assertFalse(CACHE.verify(self.into, self.pins))
                self.install()
                self.assertFalse((directory / "extra").exists())

    def test_failed_fresh_install_preserves_previous_verified_installation(self):
        self.install()
        def broken(stage):
            self.installer(stage)
            raise RuntimeError("archive validation failed")
        with self.assertRaisesRegex(RuntimeError, "archive validation failed"):
            CACHE.install(self.into, self.pins, broken)
        self.assertTrue(CACHE.verify(self.into, self.pins))

    def test_failed_publish_rolls_back_both_tool_directories(self):
        self.install()
        original = {name: (self.into / name).stat().st_ino
                    for name in CACHE.directories(self.pins)}
        rename = Path.rename
        def fail_second_publish(path, target):
            if path.name == "gprbuild-2" and path.parent != self.into:
                raise OSError("interrupted publish")
            return rename(path, target)
        with mock.patch.object(Path, "rename", fail_second_publish):
            with self.assertRaisesRegex(OSError, "interrupted publish"):
                CACHE.install(self.into, self.pins, self.installer)
        self.assertTrue(CACHE.verify(self.into, self.pins))
        self.assertEqual(original, {name: (self.into / name).stat().st_ino
                                    for name in CACHE.directories(self.pins)})

    def test_malformed_record_and_missing_directory_are_not_reusable(self):
        self.install()
        record = self.into / ".landin-install-x86_64-linux.json"
        record.write_text(json.dumps({"schema": 1, "pins": self.pins}))
        self.assertFalse(CACHE.verify(self.into, self.pins))
        self.install()
        (self.into / "gnat-1").rename(self.into / "missing-gnat")
        self.assertFalse(CACHE.verify(self.into, self.pins))


if __name__ == "__main__":
    unittest.main()
