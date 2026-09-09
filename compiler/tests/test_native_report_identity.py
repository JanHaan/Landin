#!/usr/bin/env python3
"""Native namespace regressions; pass an already-built refine, never build.

Deliberate real-host exception: these fixtures exercise Platform.Native's
filesystem identity, using only files owned by each TemporaryDirectory.
--directory can select a case-sensitive or case-insensitive mounted volume.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SOURCE = b"public main: () -> (code: i32) = code = 0 end main\n"
REFINE = None
DIRECTORY = None


class NativeReportIdentity(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="landin-identity-",
                                                 dir=DIRECTORY)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "main.ldn").write_bytes(SOURCE)
        self.tool = self.root / "tool"
        self.tool.write_text("#!/bin/sh\nprintf invoked > tool-invoked\nexit 1\n")
        self.tool.chmod(0o755)
        # A test-owned fixture establishes this destination volume's rules;
        # production identity checking must never create such a probe.
        upper = self.root / "CaseProbe"
        upper.write_bytes(b"probe")
        self.insensitive = (self.root / "caseprobe").exists()
        upper.unlink()

    def snapshot(self):
        result = {}
        for path in self.root.rglob("*"):
            name = str(path.relative_to(self.root))
            if path.is_symlink():
                result[name] = ("link", os.readlink(path))
            elif path.is_file():
                result[name] = ("file", path.read_bytes())
            else:
                result[name] = ("directory",)
        return result

    def compile(self, output, report, *, source="main.ldn", executable=False):
        return subprocess.run(
            [str(REFINE), source, "--emit=" + ("exe" if executable else "asm"),
             "-o", output, "--build-report=" + report,
             "--toolchain=" + str(self.tool)], cwd=self.root,
            capture_output=True, timeout=30)

    def refuses_without_effects(self, output, report, **kwargs):
        before = self.snapshot()
        result = self.compile(output, report, **kwargs)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn(b"L0002", result.stderr)
        self.assertEqual(self.snapshot(), before,
                         "collision must precede every artifact and tool")

    def test_missing_case_variants(self):
        # Every generated destination is reserved even when a particular
        # source would not otherwise require a caller source map.
        cases = [("OUT.s", "out.s", False),
                 ("PROGRAM", "program", True),
                 ("PROGRAM", "program.s", True),
                 ("PROGRAM", "program.sources.json", True),
                 ("OUT.s", "out.s.sources.json", False)]
        parent = self.root
        for index, (output, report, executable) in enumerate(cases):
            # Isolate subcases even when an old compiler corrupts a file.
            self.root = parent / str(index)
            self.root.mkdir()
            (self.root / "main.ldn").write_bytes(SOURCE)
            with self.subTest(output=output, report=report):
                if self.insensitive:
                    self.refuses_without_effects(output, report,
                                                 executable=executable)
                elif not executable:
                    result = self.compile(output, report)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertFalse(os.path.samefile(self.root / output,
                                                      self.root / report))
                    json.loads((self.root / report).read_bytes())
                    (self.root / output).unlink()
                    (self.root / report).unlink()
                else:
                    # The deliberately failing tool proves identity checking
                    # accepted genuinely distinct case variants for exe too.
                    result = self.compile(output, report, executable=True)
                    self.assertEqual(result.returncode, 1, result.stderr)
                    self.assertTrue((self.root / "tool-invoked").exists())
                    (self.root / "tool-invoked").unlink()
                    (self.root / (output + ".s")).unlink()

    def test_alias_parent_missing_destinations(self):
        (self.root / "real").mkdir()
        (self.root / "alias").symlink_to("real", target_is_directory=True)
        self.refuses_without_effects("real/out.s", "alias/./out.s")
        if self.insensitive:
            self.refuses_without_effects("real/OUT.s", "alias/out.s")
        else:
            result = self.compile("real/OUT.s", "alias/out.s")
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_symlink_dotdot_distinguishes_source(self):
        (self.root / "a").mkdir()
        (self.root / "b/child").mkdir(parents=True)
        (self.root / "a/link").symlink_to("../b/child", target_is_directory=True)
        (self.root / "a/main.ldn").write_bytes(SOURCE)
        result = self.compile("out.s", "a/link/../main.ldn", source="a/main.ldn")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / "a/main.ldn").read_bytes(), SOURCE)
        json.loads((self.root / "b/main.ldn").read_bytes())

    def test_symlink_dotdot_distinguishes_artifact(self):
        (self.root / "a").mkdir()
        (self.root / "b/child").mkdir(parents=True)
        (self.root / "a/link").symlink_to("../b/child", target_is_directory=True)
        result = self.compile("a/out.s", "a/link/../out.s")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotEqual((self.root / "a/out.s").read_bytes()[:1], b"{")
        json.loads((self.root / "b/out.s").read_bytes())

    def test_symlink_dotdot_true_alias(self):
        (self.root / "a").mkdir()
        (self.root / "b/child").mkdir(parents=True)
        (self.root / "a/link").symlink_to("../b/child", target_is_directory=True)
        self.refuses_without_effects("b/out.s", "a/link/../out.s")

    def test_existing_source_links(self):
        os.link(self.root / "main.ldn", self.root / "hard.json")
        (self.root / "soft.json").symlink_to("main.ldn")
        for report in ("hard.json", "soft.json", "./main.ldn"):
            with self.subTest(report=report):
                self.refuses_without_effects("out.s", report)
        if self.insensitive:
            self.refuses_without_effects("out.s", "MAIN.ldn")

    def test_existing_artifact_links(self):
        (self.root / "out.s").write_bytes(b"previous assembly")
        os.link(self.root / "out.s", self.root / "hard.json")
        (self.root / "soft.json").symlink_to("out.s")
        for report in ("hard.json", "soft.json"):
            with self.subTest(report=report):
                self.refuses_without_effects("out.s", report)

    def test_dangling_links_resolve_destinations(self):
        (self.root / "report-link").symlink_to("out.s")
        self.refuses_without_effects("out.s", "report-link")
        (self.root / "other-link").symlink_to("report.json")
        result = self.compile("out.s", "other-link")
        self.assertEqual(result.returncode, 0, result.stderr)
        json.loads((self.root / "report.json").read_bytes())

    def test_indeterminate_identity_refuses(self):
        (self.root / "loop").symlink_to("loop")
        self.refuses_without_effects("out.s", "loop")
        self.refuses_without_effects("out.s", "missing/report.json")

    def test_many_parent_spellings_do_not_create_outputs(self):
        (self.root / "real").mkdir()
        for index in range(64):
            name = f"alias{index}"
            (self.root / name).symlink_to("real", target_is_directory=True)
            self.refuses_without_effects("real/out.s", name + "/out.s")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--refine", type=Path, required=True)
    parser.add_argument("--directory", type=Path)
    args, tests = parser.parse_known_args()
    REFINE = args.refine.resolve(strict=True)
    DIRECTORY = args.directory
    unittest.main(argv=[__file__, *tests])
