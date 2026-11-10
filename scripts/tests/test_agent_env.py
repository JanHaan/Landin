"""scripts/agent_env.sh prints a path that is safe to source in every
shell, the one that already has the environment among them."""

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/agent_env.sh"


class AgentEnvTest(unittest.TestCase):
    def path_with(self, directory, tools):
        """A PATH holding the shell's own tools and fakes named TOOLS."""
        for tool in ("bash", "sh", "dirname", "cat", "sha256sum", "cut"):
            os.symlink(shutil.which(tool), directory / tool)
        for tool in tools:
            fake = directory / tool
            fake.write_text("#!/bin/sh\nexit 0\n")
            fake.chmod(0o755)
        return str(directory)

    def test_nothing_to_add_is_still_a_file_to_source(self):
        #  A shell that has python3 and gprbuild, and one with no nix: the
        #  file adds nothing, and sourcing it neither fails nor changes PATH.
        for tools in (("python3", "gprbuild", "nix"), ()):
            with self.subTest(tools=tools), \
                    tempfile.TemporaryDirectory() as scratch:
                path = self.path_with(Path(scratch), tools)
                printed = subprocess.run(
                    [str(SCRIPT)], env={"PATH": path}, capture_output=True,
                    text=True, timeout=60, check=True).stdout
                self.assertEqual(printed, "/dev/null\n")
                for shell in ("sh", "bash"):
                    sourced = subprocess.run(
                        [shell, *(["--noprofile", "--norc"]
                                  if shell == "bash" else []), "-c",
                         '. "$("$0")" && printf %s "$PATH"', str(SCRIPT)],
                        env={"PATH": path}, stdin=subprocess.DEVNULL,
                        capture_output=True, text=True, timeout=60)
                    self.assertEqual(sourced.returncode, 0, sourced.stderr)
                    self.assertEqual(sourced.stdout, path)


if __name__ == "__main__":
    unittest.main()
