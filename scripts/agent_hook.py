#!/usr/bin/env python3
"""Install or check the SessionStart hook that gives a Claude Code session
the pinned environment.

    python3 scripts/agent_hook.py --check
    python3 scripts/agent_hook.py --install [--settings FILE]

The hook's command is the one docs/process.md gives under "Local agent
feedback", and this reads it from there, so there is one text.  A copy pasted
into a checkout's `.claude/settings.local.json` stays as it was pasted: an
older one appended the environment on every resume of a session until no
command of the session could start.

`--install` writes the command into the user's `~/.claude/settings.json`, or
--settings, replacing a Landin hook already there and leaving every other
setting as it is.  One copy there serves every checkout and worktree, and
does nothing in a project without `scripts/agent_env.sh`.  `--check` reads
that file and this checkout's `.claude/settings.local.json`, says of each
whether it holds the current command, an older one or none, and exits 1
when any copy is older or no copy is installed.
"""
import argparse
import json
import os
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
RECIPE = ROOT / "docs" / "process.md"
#  What tells a Landin hook from any other SessionStart hook.
MARK = "scripts/agent_env.sh"
USER_SETTINGS = Path.home() / ".claude" / "settings.json"


def recipe_hook(recipe=RECIPE):
    """The hook entry docs/process.md gives: its command and timeout."""
    for block in re.findall(r"```json\n(.*?)```", recipe.read_text(encoding="utf-8"), re.S):
        if '"SessionStart"' in block:
            return json.loads(block)["hooks"]["SessionStart"][0]["hooks"][0]
    raise SystemExit("%s gives no SessionStart hook" % recipe)


def read(settings):
    try:
        text = settings.read_text(encoding="utf-8")
    except FileNotFoundError:
        return {}
    try:
        value = json.loads(text) if text.strip() else {}
    except ValueError as error:
        raise SystemExit("%s is not JSON (%s); it is left as it is" % (settings, error))
    if not isinstance(value, dict):
        raise SystemExit("%s is not a JSON object; it is left as it is" % settings)
    return value


def landin_commands(value):
    """Every Landin hook command in a settings value."""
    found = []
    groups = value.get("hooks", {}).get("SessionStart", [])
    for group in groups if isinstance(groups, list) else []:
        for hook in group.get("hooks", []) if isinstance(group, dict) else []:
            if isinstance(hook, dict) and MARK in str(hook.get("command", "")):
                found.append(hook["command"])
    return found


def state(settings, current):
    commands = landin_commands(read(settings))
    if not commands:
        return "none"
    return "current" if all(command == current for command in commands) else "older"


def install(settings, entry):
    value = read(settings)
    groups = value.setdefault("hooks", {}).setdefault("SessionStart", [])
    kept = []
    for group in groups:
        hooks = [hook for hook in group.get("hooks", [])
                 if not (isinstance(hook, dict) and MARK in str(hook.get("command", "")))]
        if hooks:
            kept.append(dict(group, hooks=hooks))
    kept.append({"matcher": "", "hooks": [dict(
        entry, statusMessage="Loading the flake's development environment")]})
    value["hooks"]["SessionStart"] = kept
    settings.parent.mkdir(parents=True, exist_ok=True)
    temporary = settings.with_name(settings.name + ".tmp")
    temporary.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")
    if settings.exists():
        os.chmod(temporary, settings.stat().st_mode & 0o777)
    temporary.replace(settings)


def main(argv=None):
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    which = parser.add_mutually_exclusive_group(required=True)
    which.add_argument("--check", action="store_true")
    which.add_argument("--install", action="store_true")
    parser.add_argument("--settings", type=Path, default=USER_SETTINGS,
                        help="the settings file to install into or check (default"
                             " ~/.claude/settings.json)")
    args = parser.parse_args(argv)
    entry = recipe_hook()
    if args.install:
        install(args.settings, entry)
        print("installed: %s" % args.settings)
        print("it takes effect in sessions started from now on")
    places = [args.settings, ROOT / ".claude" / "settings.local.json"]
    states = [(place, state(place, entry["command"])) for place in places]
    for place, said in states:
        print("%-8s %s" % (said, place))
    if any(said == "older" for _, said in states):
        print("an older copy appends the environment on every resume of a session;"
              " replace it with `python3 scripts/agent_hook.py --install`, and remove"
              " the copy from a checkout's own file")
        return 1
    if all(said == "none" for _, said in states):
        print("no hook is installed: `python3 scripts/agent_hook.py --install`")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
