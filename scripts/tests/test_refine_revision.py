"""scripts/refine_revision.py says when a refine is not its checkout's.

The digest decides whether it is; the revision says how it parts.  A
temporary repository gives the cases a history to be older, newer and
beside, and a stand-in refine answers `version --json` with whatever a
case needs.  A split command is judged by what `--describe` names.
scripts/lane_refine.py, which every lane takes `--refine` from, asks once
and builds the command a lane runs; every lane is held to it.
"""
import contextlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(Path(__file__).resolve().parent))

import lane_refine  # noqa: E402
import refine_revision  # noqa: E402
from temporary_git import environment  # noqa: E402

DIGEST = "a" * 64
OTHER = "b" * 64


class History(unittest.TestCase):
    """A repository with main at A <- B, and a side branch C off A."""

    @classmethod
    def setUpClass(cls):
        cls.directory = Path(tempfile.mkdtemp(prefix="refine-revision-"))
        cls.addClassCleanup(shutil.rmtree, cls.directory)
        env = environment()

        def git(*words):
            return subprocess.run(["git", *words], cwd=cls.directory,
                                  env=env, check=True, capture_output=True,
                                  text=True).stdout.strip()

        git("init", "-q", "-b", "main")
        commits = {}
        for name in ("A", "B"):
            (cls.directory / "file").write_text(name)
            git("add", "file")
            git("commit", "-q", "-m", name)
            commits[name] = git("rev-parse", "HEAD")
        git("checkout", "-q", "-b", "side", commits["A"])
        (cls.directory / "file").write_text("C")
        git("commit", "-q", "-am", "C")
        commits["C"] = git("rev-parse", "HEAD")
        git("checkout", "-q", "main")
        cls.commits = commits

    def judged(self, revision, dirty=False, digest=OTHER, head=None):
        checkout = (head or self.commits["B"], DIGEST, False, "debug", "")
        return refine_revision.judgement((revision, digest, dirty), checkout,
                                         self.directory)

    def test_the_checkouts_sources_are_current_whatever_the_revision(self):
        self.assertIsNone(self.judged(self.commits["A"], digest=DIGEST))
        self.assertIsNone(self.judged(self.commits["C"], True, DIGEST))

    def test_an_ancestor_is_older_by_its_commits(self):
        said = self.judged(self.commits["A"])
        self.assertIn("is older than this checkout", said)
        self.assertIn("1 commit before its HEAD", said)

    def test_head_with_the_trees_edits_since_is_older_than_the_tree(self):
        said = self.judged(self.commits["B"])
        self.assertIn("is older than this checkout's tree", said)

    def test_head_built_dirty_is_neither(self):
        said = self.judged(self.commits["B"], dirty=True)
        self.assertIn("is not this checkout's tree", said)
        self.assertIn("(dirty)", said)

    def test_a_descendant_is_newer(self):
        said = self.judged(self.commits["B"], head=self.commits["A"])
        self.assertIn("is newer than this checkout", said)
        self.assertIn("1 commit after", said)

    def test_a_revision_beside_head_is_another_line(self):
        said = self.judged(self.commits["C"])
        self.assertIn("on another line of history", said)
        self.assertIn("they part at %s" % self.commits["A"][:12], said)

    def test_a_revision_the_checkout_lacks_is_said(self):
        said = self.judged("0123456789abcdef" * 2 + "01234567")
        self.assertIn("a revision this checkout does not have", said)

    def test_a_build_outside_git_is_other_sources(self):
        self.assertIn("built outside a git checkout", self.judged("unknown"))


class Answers(unittest.TestCase):
    """What a binary says, through a stand-in refine."""

    def stand_in(self, said, status=0):
        directory = Path(tempfile.mkdtemp(prefix="refine-stand-in-"))
        self.addCleanup(shutil.rmtree, directory)
        program = directory / "refine"
        program.write_text("#!/bin/sh\nprintf '%%s\\n' '%s'\nexit %d\n"
                           % (said, status))
        program.chmod(0o755)
        return program

    def answer(self, **fields):
        said = dict(schema=1, compiler="refine", version=None,
                    revision="unknown", source_digest=OTHER, dirty=False)
        said.update(fields)
        return json.dumps(said)

    def test_a_refine_is_asked_its_identity(self):
        self.assertEqual(
            refine_revision.binary_identity(self.stand_in(self.answer(
                revision="abc", dirty=True))), ("abc", OTHER, True))

    def test_what_is_no_refine_is_not_judged(self):
        for program in (self.stand_in("not json"),
                        self.stand_in(self.answer(), status=2),
                        self.stand_in(self.answer(compiler="other")),
                        self.stand_in(self.answer(dirty="yes")),
                        Path("/nonexistent/refine")):
            self.assertIsNone(refine_revision.binary_identity(program))
            self.assertIsNone(refine_revision.warn(program,
                                                   stream=io.StringIO()))

    def test_a_stale_refine_is_one_warning_naming_the_rebuild(self):
        program = self.stand_in(self.answer())
        stream = io.StringIO()
        said = refine_revision.warn(program, ROOT, stream)
        self.assertEqual(stream.getvalue(), said + "\n")
        self.assertTrue(said.startswith("landin: warning: %s " % program))
        self.assertIn("./scripts/dev-build.sh", said)

    def test_the_command_never_fails(self):
        program = self.stand_in(self.answer())
        ran = subprocess.run([sys.executable,
                              str(ROOT / "scripts/refine_revision.py"),
                              "--refine", str(program)],
                             capture_output=True, text=True, check=False)
        self.assertEqual(ran.returncode, 0)
        self.assertIn("landin: warning:", ran.stderr)


class Splits(unittest.TestCase):
    """A split command, `refine-NAME`, answers `--describe` (D1387)."""

    def setUp(self):
        self.prefix = Path(tempfile.mkdtemp(prefix="refine-split-"))
        self.addCleanup(shutil.rmtree, self.prefix)
        (self.prefix / "bin").mkdir()
        (self.prefix / "libexec/landin").mkdir(parents=True)

    def program(self, path, said):
        path.write_text("#!/bin/sh\nprintf '%%s\\n' '%s'\n" % said)
        path.chmod(0o755)
        return path

    def split(self, digest=OTHER, **fields):
        said = dict(format="landin-command-1", name="svd", summary="s",
                    source_digest=digest, codes=[])
        said.update(fields)
        return self.program(self.prefix / "libexec/landin/refine-svd",
                            json.dumps(said))

    def beside(self, digest, revision="abc"):
        self.program(self.prefix / "bin/refine", json.dumps(dict(
            schema=1, compiler="refine", version=None, revision=revision,
            source_digest=digest, dirty=False)))

    def test_its_name_is_read_from_the_path(self):
        self.assertEqual(refine_revision.split_name("/x/refine-svd"), "svd")
        self.assertEqual(refine_revision.split_name("refine-site.exe"), "site")
        self.assertIsNone(refine_revision.split_name("/x/refine"))
        self.assertIsNone(refine_revision.split_name("/x/refine-"))

    def test_the_installed_refine_of_its_build_names_the_revision(self):
        self.beside(OTHER)
        self.assertEqual(refine_revision.binary_identity(self.split()),
                         ("abc", OTHER, False))

    def test_without_one_its_digest_alone_is_judged(self):
        self.beside(DIGEST)
        identity = refine_revision.binary_identity(self.split())
        self.assertEqual(identity, (None, OTHER, False))
        checkout = ("0" * 40, DIGEST, False, "debug", "")
        self.assertIn("no refine of the same build",
                      refine_revision.judgement(identity, checkout, ROOT))
        self.assertIsNone(refine_revision.judgement(
            (None, DIGEST, False), checkout, ROOT))

    def test_a_contributed_or_misnamed_command_is_not_judged(self):
        for fields in (dict(source_digest=None), dict(name="bindings"),
                       dict(format="landin-command-2")):
            self.assertIsNone(refine_revision.binary_identity(
                self.split(**fields)))


class Lanes(unittest.TestCase):
    """scripts/lane_refine.py: the argument, and the command it runs."""

    def setUp(self):
        lane_refine._asked.clear()
        self.addCleanup(lane_refine._asked.clear)

    def parser(self, **options):
        import argparse
        parser = argparse.ArgumentParser(prog="lane")
        lane_refine.argument(parser, **options)
        return parser

    def test_the_command_follows_the_binary(self):
        self.assertEqual(lane_refine.command(Path("/b/bin/refine"), "svd"),
                         ["/b/bin/refine", "svd"])
        self.assertEqual(lane_refine.command("/b/libexec/landin/refine-svd",
                                             "svd"),
                         ["/b/libexec/landin/refine-svd"])
        with self.assertRaisesRegex(lane_refine.LaneError,
                                    "refine-bindings is the split command"
                                    " bindings, not svd"):
            lane_refine.command("/b/refine-bindings", "svd")

    def test_a_split_compiles_with_the_refine_installed_beside_it(self):
        prefix = Path(tempfile.mkdtemp(prefix="lane-refine-"))
        self.addCleanup(shutil.rmtree, prefix)
        split = prefix / "libexec/landin/refine-svd"
        self.assertEqual(lane_refine.dispatcher(prefix / "bin/refine"),
                         prefix / "bin/refine")
        with self.assertRaisesRegex(lane_refine.LaneError, "no refine"):
            lane_refine.dispatcher(split)
        (prefix / "bin").mkdir()
        (prefix / "bin/refine").write_text("")
        self.assertEqual(lane_refine.dispatcher(split), prefix / "bin/refine")

    def test_the_argument_is_asked_once_as_it_is_parsed(self):
        with mock.patch.object(refine_revision, "warn") as warn:
            args = self.parser().parse_args(["--refine", "r"])
            self.parser().parse_args(["--refine", "r"])
            self.assertEqual(args.refine, Path("r"))
            warn.assert_called_once_with(Path("r"))
            with mock.patch.dict(os.environ, {"LANDIN_REFINE": ""}), \
                    contextlib.redirect_stderr(io.StringIO()), \
                    self.assertRaises(SystemExit):
                self.parser().parse_args([])
            self.assertIsNone(self.parser(required=False).parse_args([]).refine)

    def test_the_environment_names_one_and_is_asked_too(self):
        with mock.patch.object(refine_revision, "warn") as warn, \
                mock.patch.dict(os.environ, {"LANDIN_REFINE": "/e/refine"}):
            args = self.parser(environment=True).parse_args([])
            self.assertEqual(args.refine, Path("/e/refine"))
            warn.assert_called_once_with(Path("/e/refine"))


#  Where a lane runs a command a split may own with a refine it was given,
#  rather than through lane_refine.command.
SPLIT_LITERAL = re.compile(
    r"(?<!command\()(?<![\w.])(?:\w+\.)*\w*(?:refine|REFINE)\w*(?:\(\))?\)?(?:\.resolve\(\))?\s*,\s*"
    r"['\"](?:svd|bindings|site)['\"]")


def lanes():
    """Every Python file of the checkout but the script tests, with its
    path relative to the root."""
    for path in sorted(ROOT.rglob("*.py")):
        relative = path.relative_to(ROOT).as_posix()
        if relative.startswith(("scripts/tests/", ".")) \
                or "/build/" in relative or relative.startswith(
                    "compiler/ada/build"):
            continue
        yield relative, path.read_text(encoding="utf-8", errors="replace")


class Callers(unittest.TestCase):
    """Every lane takes `--refine` from scripts/lane_refine.py, and the
    developer build asks."""

    #  The warning's own command line, and the rig's board tools, which
    #  run with no scripts/ beside them (environments/boards/common.py).
    OWN = {"scripts/refine_revision.py", "environments/boards/common.py"}

    def test_every_lane_takes_refine_from_the_helper(self):
        declared, asking = [], []
        for relative, text in lanes():
            if relative in self.OWN or relative == "scripts/lane_refine.py":
                continue
            if re.search(r"add_argument\(\s*['\"]--refine['\"]", text):
                declared.append(relative)
            if "refine_revision.warn(" in text:
                asking.append(relative)
        self.assertEqual(declared, [], "these declare their own --refine;"
                         " take it with lane_refine.argument(parser)")
        self.assertEqual(asking, [], "these ask scripts/refine_revision.py"
                         " themselves; lane_refine.argument asks once")

    def test_a_board_leg_asks_once_it_knows_there_is_no_bundle(self):
        unasked = [relative for relative, text in lanes()
                   if "common.refine_argument(" in text
                   and "common.warn_stale_refine(args)" not in text]
        self.assertEqual(unasked, [], "these take --refine from"
                         " common.refine_argument and never call"
                         " common.warn_stale_refine(args)")

    def test_a_split_command_is_run_through_the_helper(self):
        found = ["%s:%d" % (relative, text.count("\n", 0, match.start()) + 1)
                 for relative, text in lanes()
                 for match in SPLIT_LITERAL.finditer(text)]
        self.assertEqual(found, [], "these run svd, bindings or site with"
                         " the refine they were given; build the command"
                         " with lane_refine.command(refine, NAME), so a"
                         " refine-NAME runs as itself")

    def test_the_scan_sees_the_spellings_lanes_used(self):
        for written in ("[str(REFINE), 'svd', x]", "refine(), \"bindings\",",
                        "[args.refine.resolve(), 'site'", "[refine, 'site',"):
            self.assertRegex(written, SPLIT_LITERAL)
        self.assertNotRegex("[*lane_refine.command(refine, 'site'), x]",
                            SPLIT_LITERAL)

    def test_the_developer_build_asks(self):
        build = (ROOT / "scripts/build.sh").read_text(encoding="utf-8")
        self.assertRegex(build, r'Incremental" = "yes" \]; then\n\s+python3'
                         r' "\$LANDIN_ROOT/scripts/refine_revision.py"')
        self.assertEqual(build.count("landin_built\n"), 3)
        self.assertEqual(
            build.count('echo "built: $LANDIN_BUILD_DIR/bin/refine"'), 1)


if __name__ == "__main__":
    unittest.main()
