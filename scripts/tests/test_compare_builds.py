#!/usr/bin/env python3
"""compare_builds.py over builds written here, without a toolchain."""

import contextlib
import io
import re
import struct
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GATE = ROOT / ".github/workflows/gate.yml"
sys.path.insert(0, str(ROOT / "scripts"))
import compare_builds  # noqa: E402

SHT_PROGBITS, SHT_STRTAB = 1, 3
SHF_ALLOC, SHF_EXEC, SHF_WRITE = 2, 4, 1
MANIFEST = ("mode release tag linux-amd64\nswitches -q\n"
            "source abc compiler/ada/src/landin.adb\n")


def elf(text=b"\x90" * 16, data=b"\x01\x02", debug=b"GNU Ada 16.1.0\0"):
    """A 64-bit little-endian executable: .text loaded by one PT_LOAD
    segment, .data, .debug_str and the section names, then the section
    headers."""
    names = b"\0.text\0.data\0.debug_str\0.shstrtab\0"
    offsets = {name: names.index(name.encode() + b"\0")
               for name in (".text", ".data", ".debug_str", ".shstrtab")}
    body = bytearray(64 + 56)
    placed = []
    for name, contents, kind, flags, address in (
            (".text", text, SHT_PROGBITS, SHF_ALLOC | SHF_EXEC, 0x1000),
            (".data", data, SHT_PROGBITS, SHF_ALLOC | SHF_WRITE, 0x2000),
            (".debug_str", debug, SHT_PROGBITS, 0, 0),
            (".shstrtab", names, SHT_STRTAB, 0, 0)):
        placed.append((offsets[name], kind, flags, address, len(body),
                       len(contents)))
        body += contents
    shoff = len(body)
    body += bytes(64)
    for name, kind, flags, address, offset, size in placed:
        body += struct.pack("<IIQQQQIIQQ", name, kind, flags, address, offset,
                            size, 0, 0, 1, 0)
    struct.pack_into("<4sBBBB8sHHIQQQIHHHHHH", body, 0, b"\x7fELF", 2, 1, 1,
                     0, bytes(8), 2, 62, 1, 0x1000, 64, shoff, 0, 64, 56, 1,
                     64, len(placed) + 1, len(placed))
    text_offset = placed[0][4]
    struct.pack_into("<IIQQQQQQ", body, 64, 1, 5, text_offset, 0x1000, 0x1000,
                     len(text), len(text), 0x1000)
    return bytes(body)


class CompareBuilds(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="landin-compare-builds-"))
        self.addCleanup(lambda: __import__("shutil").rmtree(self.root))

    def build(self, name, refine=None, tests=None, manifest=MANIFEST,
              linked="linked refine 00\n"):
        directory = self.root / name
        (directory / "bin").mkdir(parents=True)
        (directory / "bin/refine").write_bytes(refine or elf())
        (directory / "bin/landin_tests").write_bytes(tests or elf(data=b"t"))
        for stamp in compare_builds.MANIFESTS:
            (directory / stamp).write_text(manifest + linked)
        return directory

    def run_compare(self, clean, cached, names=("refine", "landin_tests")):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stderr(err):
            status = compare_builds.compare(clean, cached, list(names), out)
        return status, out.getvalue(), err.getvalue()

    def test_the_same_files_and_inputs_are_the_same_build(self):
        status, out, _ = self.run_compare(self.build("clean"), self.build("cached"))
        self.assertEqual(status, 0, out)
        self.assertIn("SAME refine", out)
        self.assertIn("SAME landin_tests", out)
        self.assertIn("the cached build is the clean build's equal", out)

    def test_a_difference_in_the_debugging_information_alone_still_fails(self):
        cached = self.build("cached", refine=elf(debug=b"GNU Ada 16.1.0 -gnatec=/tmp/GPR.1\0"))
        status, out, _ = self.run_compare(self.build("clean"), cached)
        self.assertEqual(status, 1)
        self.assertIn("DIFFER refine", out)
        self.assertIn("section .debug_str differs", out)
        self.assertIn("only the debugging information differs", out)
        self.assertIn("SAME landin_tests", out)
        self.assertIn("no lane that took it counts", out)

    def test_a_difference_in_code_names_the_section_and_the_loaded_bytes(self):
        cached = self.build("cached", refine=elf(text=b"\x90" * 15 + b"\xc3"))
        status, out, _ = self.run_compare(self.build("clean"), cached)
        self.assertEqual(status, 1)
        self.assertIn("section .text differs", out)
        self.assertNotIn("only the debugging information differs", out)
        self.assertIn("loaded byte(s) outside every named symbol differ", out)

    def test_a_difference_in_data_that_is_not_loaded_says_so(self):
        cached = self.build("cached", refine=elf(data=b"\x01\x03"))
        status, out, _ = self.run_compare(self.build("clean"), cached)
        self.assertEqual(status, 1)
        self.assertIn("section .data differs", out)
        self.assertIn("the loaded bytes are the same", out)

    def test_other_recorded_inputs_fail_and_name_the_rows(self):
        cached = self.build("cached", manifest=MANIFEST.replace("abc", "abd"))
        status, out, _ = self.run_compare(self.build("clean"), cached)
        self.assertEqual(status, 1)
        self.assertIn("DIFFER source-manifest.txt", out)
        self.assertIn("clean: source abc compiler/ada/src/landin.adb", out)
        self.assertIn("cached: source abd compiler/ada/src/landin.adb", out)

    def test_the_linked_rows_are_not_inputs(self):
        cached = self.build("cached", linked="linked refine 01\n")
        status, out, _ = self.run_compare(self.build("clean"), cached)
        self.assertEqual(status, 0, out)

    def test_a_file_that_is_no_elf_is_reported_and_fails(self):
        cached = self.build("cached", refine=b"#!/bin/sh\nexit 0\n")
        status, out, _ = self.run_compare(self.build("clean"), cached)
        self.assertEqual(status, 1)
        self.assertIn("cannot read the sections: not an ELF file", out)

    def test_a_missing_executable_or_manifest_is_an_error(self):
        clean, cached = self.build("clean"), self.build("cached")
        (cached / "bin/landin_tests").unlink()
        (clean / "tests-manifest.txt").unlink()
        status, out, err = self.run_compare(clean, cached)
        self.assertEqual(status, 2)
        self.assertEqual(out, "")
        self.assertIn("cached/bin/landin_tests is missing", err)
        self.assertIn("clean/tests-manifest.txt is missing", err)

    def test_the_command_line_compares_what_it_names(self):
        clean, cached = self.build("clean"), self.build("cached", tests=elf(data=b"u"))
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(compare_builds.main([str(clean), str(cached), "refine"]), 0)
        with contextlib.redirect_stdout(out):
            self.assertEqual(compare_builds.main(
                [str(clean), str(cached), "refine", "landin_tests"]), 1)


def jobs(source):
    """{job id: its text} of a workflow's top-level jobs."""
    body = source.split("\njobs:\n", 1)[1]
    found = {}
    for match in re.finditer(r"^  ([a-z0-9-]+):\n((?:(?!  [a-z0-9-]+:\n).*\n?)*)",
                             body, re.M):
        found[match.group(1)] = match.group(2)
    return found


def takes(text):
    """The names of the artifacts a job downloads."""
    return set(re.findall(r"actions/download-artifact@\S+.*\n"
                          r"\s+with:\n\s+name: (\S+)\n", text))


class Workflow(unittest.TestCase):
    """gate.yml's two Linux x86-64 release builds and who takes which."""

    def setUp(self):
        self.jobs = jobs(GATE.read_text())

    def test_the_jobs_about_the_executable_take_the_clean_build(self):
        clean = {name for name, text in self.jobs.items()
                 if "linux-release-clean" in takes(text)}
        self.assertEqual(clean, {"release", "outside-user-stock",
                                 "linux-release-compare"})
        for name in ("release", "outside-user-stock"):
            self.assertNotIn("linux-release", takes(self.jobs[name]), name)
            self.assertIn("needs: [inputs, linux-release-clean]",
                          self.jobs[name], name)

    def test_no_shell_name_runs_into_an_expression(self):
        #  `$prefix${{ github.run_id }}` reaches the shell as
        #  `$prefix43940386551`, another and unset name: the cached build's
        #  first gate run stopped there, and neither actionlint nor
        #  shellcheck sees it, since the expression is expanded first.
        import re
        for workflow in sorted(GATE.parent.glob("*.yml")):
            for number, line in enumerate(workflow.read_text().splitlines(), 1):
                self.assertIsNone(
                    re.search(r"\$[A-Za-z_][A-Za-z0-9_]*\$\{\{", line),
                    "%s:%d: brace the shell name before the expression: %s"
                    % (workflow.name, number, line.strip()))

    def test_the_clean_build_never_sees_the_cache(self):
        clean = self.jobs["linux-release-clean"]
        self.assertIn("run: ./scripts/build.sh -j4", clean)
        self.assertNotIn("actions/cache", clean)
        self.assertNotIn("dev-build", clean)
        self.assertIn("dev-build.sh", self.jobs["linux-release-build"])

    def test_only_a_compared_or_clean_tree_is_saved_to_the_cache(self):
        saving = {name for name, text in self.jobs.items()
                  if "actions/cache/save@" in text
                  and "compiler/ada/build/linux-amd64/release" in text}
        self.assertEqual(saving, {"linux-release-cache", "board-bundles"})
        self.assertIn("needs: [inputs, linux-release-build, linux-release-compare]",
                      self.jobs["linux-release-cache"])
        self.assertIn("run: ./scripts/build.sh -j4", self.jobs["board-bundles"])
        self.assertIn("if: github.ref == 'refs/heads/main'\n        uses: "
                      "actions/cache/save@", self.jobs["board-bundles"])

    def test_the_comparison_compares_both_archives_and_the_gate_needs_it(self):
        compare = self.jobs["linux-release-compare"]
        self.assertIn("needs: [inputs, linux-release-build, linux-release-clean]",
                      compare)
        self.assertEqual(takes(compare), {"linux-release", "linux-release-clean"})
        self.assertRegex(compare, r"compare_builds\.py \"\$RUNNER_TEMP/clean\""
                                  r" \"\$RUNNER_TEMP/cached\" \\\n\s+refine landin_tests\n")
        needs = re.search(r"needs: \[([^]]*)\]", self.jobs["gate"]).group(1)
        self.assertIn("linux-release-compare",
                      [name.strip() for name in needs.split(",")])


if __name__ == "__main__":
    unittest.main()
