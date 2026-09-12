#!/usr/bin/env python3
"""Exercise build.sh's real invalidation decision, without invoking a builder."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = (ROOT / "scripts/build.sh").read_text()
START = 'if [ -f "$Manifest" ] && [ "$Current" != "$(cat "$Manifest")" ]; then\n'
DECISION = SCRIPT[SCRIPT.index(START):SCRIPT.index("\nNoop_Arguments=no")]
BASE = ["1 10 /src/main.adb", "2 20 /src/host.c", "3 30 /src/host.h",
        "4 40 /src/lib.gpr", "5 50 /scripts/build.sh",
        "6 60 /scripts/build_lock.py", "mode debug tag test",
        "gnat pinned", "gprbuild pinned"]


class BuildInventory(unittest.TestCase):
    def decision(self, old, new, incremental="yes"):
        # This is deliberately the production branch including both inventory
        # and fixed-identity comparisons, not a copy of its regexes. Its only
        # destructive operation addresses our disposable fixture directory.
        with tempfile.TemporaryDirectory(prefix="landin-inventory-") as tmp:
            build = Path(tmp) / "build"
            build.mkdir()
            manifest = build / "source-manifest.txt"
            manifest.write_text("\n".join(sorted(old)) + "\n")
            result = subprocess.run(
                ["sh", "-eu", "-c", DECISION], text=True, capture_output=True,
                env={**os.environ, "Manifest": str(manifest),
                     "LANDIN_BUILD_DIR": str(build),
                     "Current": "\n".join(sorted(new)),
                     "Incremental": incremental}, check=True)
            return build.exists(), result.stdout

    def test_inventory_add_remove_rename(self):
        for extension in ("c", "h", "adb", "ads"):
            row = f"7 70 /src/member.{extension}"
            for operation, old, new in (
                ("add", BASE, BASE + [row]),
                ("remove", BASE + [row], BASE),
                ("rename", BASE + [row],
                 BASE + [f"7 70 /src/renamed.{extension}"]),
            ):
                with self.subTest(extension=extension, operation=operation):
                    exists, text = self.decision(old, new)
                    self.assertFalse(exists)
                    self.assertIn("inventory or project changed", text)

    def test_source_content_is_incremental(self):
        for extension in ("adb", "c", "h"):
            old = BASE + [f"0 70 /src/member.{extension}"]
            new = BASE + [f"999 71 /src/member.{extension}"]
            with self.subTest(extension=extension):
                exists, text = self.decision(old, new)
                self.assertTrue(exists)
                self.assertIn("using checksum recompilation", text)

    def test_fixed_identity_changes_are_clean(self):
        for row in BASE[3:]:
            with self.subTest(row=row):
                new = ["9" + entry if entry == row else entry for entry in BASE]
                exists, text = self.decision(BASE, new)
                self.assertFalse(exists)
                self.assertIn("inventory or project changed", text)

    def test_unchanged_does_nothing(self):
        self.assertEqual(self.decision(BASE, BASE), (True, ""))

    def test_ordinary_gate_still_cleans_content_changes(self):
        new = ["9 10 /src/main.adb"] + BASE[1:]
        exists, text = self.decision(BASE, new, incremental="no")
        self.assertFalse(exists)
        self.assertIn("sources changed since the last build", text)


if __name__ == "__main__":
    unittest.main()
