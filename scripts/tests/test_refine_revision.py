"""scripts/refine_revision.py says when a refine is not its checkout's.

The digest decides whether it is; the revision says how it parts.  A
temporary repository gives the cases a history to be older, newer and
beside, and a stand-in refine answers `version --json` with whatever a
case needs.  Every lane that takes `--refine` is held to asking.
"""
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

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(Path(__file__).resolve().parent))

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


class Callers(unittest.TestCase):
    """Every lane that takes `--refine` asks, and the developer build."""

    def test_every_lane_asks(self):
        missing = []
        for path in sorted(ROOT.rglob("*.py")):
            relative = path.relative_to(ROOT).as_posix()
            if relative.startswith(("scripts/tests/", ".")) \
                    or "/build/" in relative or relative.startswith(
                        "compiler/ada/build"):
                continue
            text = path.read_text(encoding="utf-8", errors="replace")
            if re.search(r"add_argument\(\s*['\"]--refine['\"]", text) \
                    and "refine_revision.warn(" not in text \
                    and relative != "scripts/refine_revision.py":
                missing.append(relative)
        self.assertEqual(missing, [], "these take --refine and never ask"
                         " scripts/refine_revision.py whether it is the"
                         " checkout's")

    def test_the_developer_build_asks(self):
        build = (ROOT / "scripts/build.sh").read_text(encoding="utf-8")
        self.assertRegex(build, r'Incremental" = "yes" \]; then\n\s+python3'
                         r' "\$LANDIN_ROOT/scripts/refine_revision.py"')
        self.assertEqual(build.count("landin_built\n"), 3)
        self.assertEqual(build.count('echo "built: '), 1)


if __name__ == "__main__":
    unittest.main()
