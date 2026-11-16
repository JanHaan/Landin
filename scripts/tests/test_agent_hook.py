#!/usr/bin/env python3
"""Hold the hook installer to one text of the command and to leaving every
other setting alone."""
import contextlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import agent_hook

OLDER = ('s="$CLAUDE_PROJECT_DIR/scripts/agent_env.sh"; [ -x "$s" ] && f=$("$s")'
         ' && cat "$f" >> "$CLAUDE_ENV_FILE"; exit 0')


class AgentHook(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="landin-hook-")
        self.addCleanup(temporary.cleanup)
        self.settings = Path(temporary.name) / "home" / "settings.json"
        self.entry = agent_hook.recipe_hook()

    def run_main(self, *arguments):
        said = io.StringIO()
        with contextlib.redirect_stdout(said):
            status = agent_hook.main([*arguments, "--settings", str(self.settings)])
        return status, said.getvalue()

    def test_the_recipes_command_is_the_guarded_deduplicating_one(self):
        command = self.entry["command"]
        self.assertIn(agent_hook.MARK, command)
        self.assertIn("grep -qxF", command)
        self.assertIn("98304", command)

    def test_installing_keeps_every_other_setting_and_hook(self):
        self.settings.parent.mkdir(parents=True)
        other = {"type": "command", "command": "echo other"}
        self.settings.write_text(json.dumps({
            "theme": "dark",
            "hooks": {"Stop": [{"matcher": "", "hooks": [other]}],
                      "SessionStart": [{"matcher": "", "hooks": [
                          other, {"type": "command", "command": OLDER}]}]}}))
        self.assertEqual(agent_hook.state(self.settings, self.entry["command"]), "older")
        status, said = self.run_main("--install")
        self.assertEqual(status, 0, said)
        value = json.loads(self.settings.read_text())
        self.assertEqual(value["theme"], "dark")
        self.assertEqual(value["hooks"]["Stop"][0]["hooks"], [other])
        commands = [hook["command"] for group in value["hooks"]["SessionStart"]
                    for hook in group["hooks"]]
        self.assertEqual(commands, ["echo other", self.entry["command"]])
        #  Installing again changes nothing.
        before = self.settings.read_text()
        self.assertEqual(self.run_main("--install")[0], 0)
        self.assertEqual(self.settings.read_text(), before)

    def test_installing_makes_the_file_and_checking_names_what_is_there(self):
        status, said = self.run_main("--check")
        self.assertIn("none     %s" % self.settings, said)
        status, said = self.run_main("--install")
        self.assertEqual(status, 0)
        self.assertIn("current  %s" % self.settings, said)
        self.settings.write_text(json.dumps({"hooks": {"SessionStart": [
            {"matcher": "", "hooks": [{"type": "command", "command": OLDER}]}]}}))
        status, said = self.run_main("--check")
        self.assertEqual(status, 1)
        self.assertIn("older    %s" % self.settings, said)
        self.assertIn("--install", said)

    def test_a_file_that_is_not_settings_is_left_as_it_is(self):
        self.settings.parent.mkdir(parents=True)
        for text in ("{ not json", "[1, 2]"):
            self.settings.write_text(text)
            with self.subTest(text=text), self.assertRaises(SystemExit) as refused:
                self.run_main("--install")
            self.assertIn("left as it is", str(refused.exception))
            self.assertEqual(self.settings.read_text(), text)


if __name__ == "__main__":
    unittest.main()
