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

    def key(self):
        """This checkout's key, as the helper and flake.nix compute it."""
        import hashlib
        digest = hashlib.sha256()
        for name in ("flake.nix", "flake.lock", "environments/pins.sh"):
            digest.update((ROOT / name).read_bytes())
        return digest.hexdigest()[:16]

    def test_this_checkouts_shell_is_left_as_it_is(self):
        #  The flake's shell exports its key; the helper computes the same.
        flake = (ROOT / "flake.nix").read_text(encoding="utf-8")
        self.assertIn("export LANDIN_ENV_KEY=${environmentKey}", flake)
        with tempfile.TemporaryDirectory() as scratch:
            path = self.path_with(Path(scratch),
                                  ("python3", "gprbuild", "nix"))
            for tag in ("nix-x86_64-linux", ""):
                with self.subTest(tag=tag):
                    completed = subprocess.run(
                        [str(SCRIPT)], env={"PATH": path,
                                            "LANDIN_ENV_KEY": self.key(),
                                            "LANDIN_BUILD_TAG": tag},
                        capture_output=True, text=True, timeout=60,
                        check=True)
                    self.assertEqual(completed.stdout, "/dev/null\n")
                    self.assertEqual(completed.stderr, "")

    def test_another_checkouts_shell_gets_this_ones(self):
        #  A session started in one checkout has that checkout's shell on
        #  PATH in every worktree: the helper says so, and prints this
        #  checkout's exports, every one of them, the build tag the other
        #  shell set to the same value among them.
        for caller in ({"LANDIN_BUILD_TAG": "nix-x86_64-linux"},
                       {"LANDIN_BUILD_TAG": "nix-x86_64-linux",
                        "LANDIN_ENV_KEY": "0123456789abcdef"}):
            with self.subTest(caller=caller), \
                    tempfile.TemporaryDirectory() as scratch:
                scratch = Path(scratch)
                tools = scratch / "bin"
                store = scratch / "store/bin"
                tools.mkdir()
                store.mkdir(parents=True)
                path = self.path_with(tools, ("python3", "gprbuild"))
                for tool in ("env", "mkdir", "mktemp", "mv", "rm", "sed"):
                    os.symlink(shutil.which(tool), tools / tool)
                nix = tools / "nix"
                nix.write_text(
                    "#!/bin/sh\n"
                    "cat <<'EOF'\n"
                    "PATH=${PATH:-}\n"
                    "nix_saved_PATH=\"$PATH\"\n"
                    f"PATH='{store}'\n"
                    "export PATH\n"
                    "LANDIN_BUILD_TAG=nix-x86_64-linux\n"
                    "export LANDIN_BUILD_TAG\n"
                    f"LANDIN_ENV_KEY={self.key()}\n"
                    "export LANDIN_ENV_KEY\n"
                    "PATH=\"$PATH${nix_saved_PATH:+:$nix_saved_PATH}\"\n"
                    "EOF\n")
                nix.chmod(0o755)
                completed = subprocess.run(
                    [str(SCRIPT)],
                    env={"PATH": path, "HOME": str(scratch),
                         "XDG_CACHE_HOME": str(scratch / "cache"), **caller},
                    capture_output=True, text=True, timeout=60)
                self.assertEqual(completed.returncode, 0, completed.stderr)
                self.assertIn("the shell of another flake.nix, flake.lock or"
                              " pins.sh", completed.stderr)
                self.assertIn(self.key(), completed.stderr)
                printed = Path(completed.stdout.strip())
                self.assertEqual(printed.parent,
                                 scratch / "cache/landin/agent-env")
                sourced = subprocess.run(
                    ["sh", "-c", '. "$0" && printf "%s %s %s" "$PATH"'
                     ' "$LANDIN_BUILD_TAG" "$LANDIN_ENV_KEY"', str(printed)],
                    env={"PATH": path, **caller}, capture_output=True,
                    text=True, timeout=60)
                self.assertEqual(sourced.returncode, 0, sourced.stderr)
                self.assertEqual(sourced.stdout.split(" "), [
                    f"{store}:{path}", "nix-x86_64-linux", self.key()])


class SessionStartHookTest(unittest.TestCase):
    """The hook docs/process.md gives leaves a session one environment.

    Claude Code names the file a SessionStart hook writes after the hook's
    place among those it runs, keeps it across resumes, and puts every such
    file of the session into the one argument each Bash command runs as,
    which Linux limits to 128 KiB.  Appending on each resume, and under a
    second number when the hook's place moved, took a session to 137.8 KB
    on 2026-11-17, and every command failed with E2BIG.
    """

    LIMIT = 64 * 1024

    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="landin-hook-")
        self.addCleanup(temporary.cleanup)
        scratch = Path(temporary.name)
        self.exports = scratch / "agent-env.sh"
        helper = scratch / "project/scripts/agent_env.sh"
        helper.parent.mkdir(parents=True)
        helper.write_text("#!/bin/sh\nprintf '%s\\n' '" + str(self.exports) + "'\n")
        helper.chmod(0o755)
        self.project = helper.parents[1]
        self.session = scratch / "session-env/63700778-8ea9-41f2-86a8-07f32a41b1e4"
        self.session.mkdir(parents=True)

    def environment(self, generation, padding=23000):
        """An environment like the flake's: its key, a probe and its bulk."""
        self.exports.write_text(
            "export LANDIN_ENV_KEY=%016x\nexport LANDIN_HOOK_PROBE=%d\n"
            "export PADDING='%s'\n" % (generation, generation, "x" * padding))

    def start(self, place):
        completed = subprocess.run(
            ["sh", "-c", session_start_command()],
            env={"PATH": os.environ["PATH"],
                 "CLAUDE_PROJECT_DIR": str(self.project),
                 "CLAUDE_ENV_FILE": str(self.session / ("sessionstart-hook-%d.sh" % place))},
            stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=60)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        return completed.stderr

    def argument(self):
        """What Claude Code puts ahead of a command: every hook file, trimmed."""
        return "\n".join(
            text for text in (path.read_text().strip()
                              for path in sorted(self.session.glob("*-hook-*.sh")))
            if text)

    def sourced(self):
        completed = subprocess.run(
            ["sh", "-c", self.argument() + '\nprintf %s "$LANDIN_HOOK_PROBE"'],
            env={"PATH": os.environ["PATH"]}, capture_output=True, text=True,
            timeout=60)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        return completed.stdout

    def test_reopens_and_moved_places_leave_one_environment(self):
        #  The files of the session that failed: the same environment four
        #  times, three of them from a hook that wrote no marker, and two
        #  environments under the next number.
        self.environment(1)
        unmarked = self.exports.read_text()
        (self.session / "sessionstart-hook-0.sh").write_text(
            unmarked * 3 + "# landin agent_env 1 2\n" + unmarked)
        (self.session / "sessionstart-hook-1.sh").write_text(
            "# landin agent_env 1 2\n" + unmarked + "# landin agent_env 3 4\n" + unmarked)
        #  Another tool's hook is not Landin's to empty.
        other = self.session / "sessionstart-hook-5.sh"
        other.write_text("export OTHER_TOOL=1\n")
        for generation, place in enumerate([1, 1, 0, 2, 2, 0, 1, 3, 0, 0, 2, 1], 2):
            if generation % 3:
                self.environment(generation)
            self.assertEqual(self.start(place), "")
            argument = self.argument()
            self.assertEqual(argument.count("export LANDIN_ENV_KEY="), 1, argument[:200])
            self.assertLess(len(argument.encode()), self.LIMIT)
            self.assertEqual(self.sourced(), self.exports.read_text().split(
                "LANDIN_HOOK_PROBE=")[1].split("\n")[0])
            self.assertTrue((self.session / ("sessionstart-hook-%d.sh" % place))
                            .read_text().startswith("# landin agent_env "))
        self.assertEqual(other.read_text(), "export OTHER_TOOL=1\n")

    def test_an_environment_that_would_pass_the_limit_is_refused_aloud(self):
        other = self.session / "sessionstart-hook-0.sh"
        other.write_text("export OTHER_TOOL='%s'\n" % ("y" * 45000))
        self.environment(1, padding=15000)
        self.assertEqual(self.start(1), "")
        self.assertEqual(self.sourced(), "1")
        #  A larger environment would take the session's files past 64 KiB:
        #  none is loaded, the file is left empty, and the hook says why.
        self.environment(2, padding=21000)
        said = self.start(1)
        self.assertIn("start a fresh session", said)
        self.assertIn("is not loaded", said)
        self.assertEqual((self.session / "sessionstart-hook-1.sh").read_text(), "")
        self.assertLess(len(self.argument().encode()), self.LIMIT)
        self.assertEqual(self.sourced(), "")

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
