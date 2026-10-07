#!/usr/bin/env python3
"""Version reporting drains tool output and preserves producer failures."""
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[2]
ACTION = ROOT / ".github/actions/pinned-toolchain/action.yml"


def version_block():
    """Read the actual composite-action shell block without a YAML dependency."""
    blocks = re.findall(r"^      run: \|\n((?:        [^\n]*\n|\n)+)",
                        ACTION.read_text(), re.MULTILINE)
    selected = [textwrap.dedent(block) for block in blocks
                if '"$LANDIN_GNAT_HOME/bin/gnat" --version' in block
                and '"$LANDIN_GPRBUILD_HOME/bin/gprbuild" --version' in block]
    if len(selected) != 1:
        raise AssertionError("expected one pinned-toolchain version shell block")
    return selected[0]


FAKE_TOOL = '''import os
from pathlib import Path
import signal
import sys

signal.signal(signal.SIGPIPE, signal.SIG_IGN)
tool = Path(sys.argv[1]).name
assert sys.argv[2:] == ["--version"]
version = {"gnat": "GNAT fake version", "gprbuild": "GPRBUILD fake version"}[tool]
try:
    os.write(1, (version + "\\n").encode())
    if os.environ["LANDIN_TEST_LARGE"] in ("both", tool):
        # Far larger than a pipe buffer, so head cannot consume all of it
        # before exiting. Ignore SIGPIPE to model the affected runner host.
        for unused in range(2048):
            payload = b"x" * 4095 + b"\\n"
            while payload:
                payload = payload[os.write(1, payload):]
except BrokenPipeError:
    Path(os.environ["LANDIN_TEST_MARKERS"], tool + "-broken").touch()
    os.write(2, (tool + ": version output pipe closed\\n").encode())
    sys.exit({"gnat": 2, "gprbuild": 7}[tool])
Path(os.environ["LANDIN_TEST_MARKERS"], tool + "-drained").touch()
if os.environ.get("LANDIN_TEST_FAIL") == tool:
    os.write(2, (tool + ": version query failed\\n").encode())
    sys.exit({"gnat": 17, "gprbuild": 23}[tool])
'''


class PinnedToolchainVersions(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="landin-pinner-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.markers = self.root / "markers"
        self.markers.mkdir()
        self.bash = shutil.which("bash")
        self.assertIsNotNone(self.bash, "the action requires bash")
        fake = self.root / "fake_tool.py"
        fake.write_text(FAKE_TOOL)
        for tool in ("gnat", "gprbuild"):
            path = self.root / tool / "bin" / tool
            path.parent.mkdir(parents=True)
            path.write_text("#!" + self.bash + "\nexec "
                            + shlex.quote(sys.executable) + " "
                            + shlex.quote(str(fake)) + ' "$0" "$@"\n')
            path.chmod(0o755)
        self.block = version_block()

    def run_block(self, block=None, large="both", fail=""):
        for marker in self.markers.iterdir():
            marker.unlink()
        return subprocess.run(
            [self.bash, "--noprofile", "--norc", "-e", "-o", "pipefail", "-c",
             'trap "" PIPE\n' + (self.block if block is None else block)],
            env={**os.environ, "LANDIN_GNAT_HOME": str(self.root / "gnat"),
                 "LANDIN_GPRBUILD_HOME": str(self.root / "gprbuild"),
                 "LANDIN_TEST_MARKERS": str(self.markers),
                 "LANDIN_TEST_LARGE": large, "LANDIN_TEST_FAIL": fail},
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=20)

    def test_actual_action_drains_both_tools_and_prints_only_first_lines(self):
        result = self.run_block()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "GNAT fake version\nGPRBUILD fake version\n")
        self.assertEqual(result.stderr, "")
        self.assertEqual({path.name for path in self.markers.iterdir()},
                         {"gnat-drained", "gprbuild-drained"})

    def test_early_exit_control_reproduces_each_producers_broken_pipe(self):
        early = self.block.replace("sed -n '1p'", "head -1")
        self.assertNotEqual(early, self.block, "control must change the real action")
        for tool, code in (("gnat", 2), ("gprbuild", 7)):
            with self.subTest(tool=tool):
                result = self.run_block(early, large=tool)
                self.assertEqual(result.returncode, code, result.stderr)
                self.assertIn(tool + ": version output pipe closed", result.stderr)
                self.assertTrue((self.markers / (tool + "-broken")).exists())
                self.assertFalse((self.markers / (tool + "-drained")).exists())

    def test_actual_action_preserves_each_producers_real_failure(self):
        for tool, code in (("gnat", 17), ("gprbuild", 23)):
            with self.subTest(tool=tool):
                result = self.run_block(fail=tool)
                self.assertEqual(result.returncode, code, result.stderr)
                self.assertIn(tool + ": version query failed", result.stderr)
                self.assertTrue((self.markers / (tool + "-drained")).exists())
                self.assertFalse(any(path.name.endswith("-broken")
                                     for path in self.markers.iterdir()))
                expected = "GNAT fake version\n"
                if tool == "gprbuild":
                    expected += "GPRBUILD fake version\n"
                self.assertEqual(result.stdout, expected)


if __name__ == "__main__":
    unittest.main()
