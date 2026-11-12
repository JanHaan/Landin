"""scripts/agent_env.sh prints a path that is safe to source in every
shell, the one that already has the environment among them."""

import json
import os
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/agent_env.sh"
RECIPE = ROOT / "docs/process.md"


def session_start_command():
    """The SessionStart hook's command, as docs/process.md gives it."""
    text = RECIPE.read_text(encoding="utf-8")
    for block in re.findall(r"```json\n(.*?)```", text, re.S):
        if '"SessionStart"' in block:
            hooks = json.loads(block)["hooks"]["SessionStart"]
            return hooks[0]["hooks"][0]["command"]
    raise AssertionError("docs/process.md gives no SessionStart hook")


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


class SessionStartHookTest(unittest.TestCase):
    """The hook docs/process.md gives appends the environment once.

    Claude Code runs it at every start of a session, a resume among them,
    and keeps the session's CLAUDE_ENV_FILE across resumes; appending each
    time took the file past 128 KiB after six, and every Bash command then
    failed with E2BIG.
    """

    def test_a_resumed_session_appends_the_environment_once(self):
        command = session_start_command()
        with tempfile.TemporaryDirectory() as scratch:
            scratch = Path(scratch)
            exports = scratch / "agent-env.sh"
            exports.write_text("export LANDIN_HOOK_PROBE=1\n")
            helper = scratch / "project/scripts/agent_env.sh"
            helper.parent.mkdir(parents=True)
            helper.write_text("#!/bin/sh\nprintf '%s\\n' '" + str(exports) + "'\n")
            helper.chmod(0o755)
            target = scratch / "claude-env"
            environment = {"PATH": os.environ["PATH"],
                           "CLAUDE_PROJECT_DIR": str(scratch / "project"),
                           "CLAUDE_ENV_FILE": str(target)}

            def start():
                completed = subprocess.run(
                    ["sh", "-c", command], env=environment,
                    stdin=subprocess.DEVNULL, capture_output=True, text=True,
                    timeout=60)
                self.assertEqual(completed.returncode, 0, completed.stderr)
                return target.read_text().count("LANDIN_HOOK_PROBE")

            self.assertEqual(start(), 1)
            for _ in range(6):
                self.assertEqual(start(), 1)
            #  A regenerated environment, its store paths collected and
            #  made again, is a different file and is appended once more.
            exports.write_text("export LANDIN_HOOK_PROBE=2\n")
            self.assertEqual(start(), 2)
            self.assertEqual(start(), 2)
            sourced = subprocess.run(
                ["sh", "-c", '. "$0" && printf %s "$LANDIN_HOOK_PROBE"',
                 str(target)], env={"PATH": os.environ["PATH"]},
                capture_output=True, text=True, timeout=60)
            self.assertEqual(sourced.stdout, "2", sourced.stderr)

    def test_a_host_without_the_helper_is_left_alone(self):
        command = session_start_command()
        with tempfile.TemporaryDirectory() as scratch:
            target = Path(scratch) / "claude-env"
            completed = subprocess.run(
                ["sh", "-c", command],
                env={"PATH": os.environ["PATH"], "CLAUDE_PROJECT_DIR": scratch,
                     "CLAUDE_ENV_FILE": str(target)},
                capture_output=True, text=True, timeout=60)
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertFalse(target.exists())


if __name__ == "__main__":
    unittest.main()
