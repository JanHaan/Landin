#!/usr/bin/env python3
"""What agent sessions cost in context, from Claude Code's own transcripts.

    python3 scripts/session_report.py [--since=YYYY-MM-DD] [--match=REGEX]
                                      [--by=day|session] [--projects=DIRECTORY]

Every model turn reads the whole conversation again.  While the prompt cache
holds it, that is a cached read at a tenth of the price; once the cache has
expired, the conversation is written again at more than full price.  A main
session's cache lives an hour and a subagent's five minutes, so a subagent
that blocks longer than that in one tool call pays for its conversation
twice.  This counts both costs, so a change to how sessions wait or how large
they grow can be held to a number:

  context/turn   the tokens a turn read or wrote as input, on average
  expired 5m     turns that wrote most of their context again after a pause
                 of five minutes to an hour, and the tokens they wrote
  expired 1h     the same after a pause of an hour or more

It reads `~/.claude/projects`, or --projects, and only the directories whose
name matches --match, by default the ones a Landin checkout or a Paseo
worktree leaves.  A transcript writes one line per block of a model message,
each repeating the message's usage, so a message is counted once.  It prints
numbers and names nothing a transcript says.  A harness that keeps no such
transcripts has nothing here to read, and the report says so.
"""
import argparse
import collections
import datetime
import json
from pathlib import Path
import re
import sys

DEFAULT_MATCH = r"[Ll]andin|paseo-worktrees"
#  A subagent's cache lives five minutes and a main session's an hour.
SHORT_LIFE = 300
LONG_LIFE = 3600
#  A turn is a rewrite when it wrote at least this share of its context and
#  the context is large enough for the cache to have held it.
REWRITTEN_SHARE = 0.5
SMALLEST_CONTEXT = 20000


def seconds(stamp):
    return datetime.datetime.fromisoformat(stamp.replace("Z", "+00:00")).timestamp()


def turns(path):
    """Each model message of one transcript once: (time, kind, usage)."""
    seen = set()
    in_subagent_file = "subagents" in path.parts
    with path.open(errors="replace") as lines:
        for line in lines:
            if '"usage"' not in line:
                continue
            try:
                entry = json.loads(line)
            except ValueError:
                continue
            message = entry.get("message")
            if entry.get("type") != "assistant" or not isinstance(message, dict):
                continue
            usage = message.get("usage")
            stamp = entry.get("timestamp")
            if not isinstance(usage, dict) or not stamp:
                continue
            identity = message.get("id") or entry.get("uuid")
            if identity in seen:
                continue
            seen.add(identity)
            kind = "subagent" if in_subagent_file or entry.get("isSidechain") else "main"
            yield seconds(stamp), kind, usage


def measure(path, since):
    """One transcript's rows: (day, kind, counters)."""
    last = {}
    for at, kind, usage in turns(path):
        previous = last.get(kind)
        last[kind] = at
        if at < since:
            continue
        read = usage.get("cache_read_input_tokens") or 0
        written = usage.get("cache_creation_input_tokens") or 0
        context = read + written + (usage.get("input_tokens") or 0)
        row = collections.Counter(turns=1, context=context, read=read, written=written,
                                  output=usage.get("output_tokens") or 0)
        pause = at - previous if previous is not None else 0
        if (pause >= SHORT_LIFE and context >= SMALLEST_CONTEXT
                and written >= REWRITTEN_SHARE * context):
            life = "1h" if pause >= LONG_LIFE else "5m"
            row["expired_" + life] = 1
            row["expired_%s_tokens" % life] = written
        day = datetime.datetime.fromtimestamp(at, datetime.timezone.utc).strftime("%Y-%m-%d")
        yield day, kind, row


def transcripts(projects, match):
    wanted = re.compile(match)
    for directory in sorted(projects.iterdir()) if projects.is_dir() else []:
        if directory.is_dir() and wanted.search(directory.name):
            yield from sorted(directory.rglob("*.jsonl"))


def report(projects, match, since, by):
    """The table's rows as (key, kind, counters), and the totals by kind."""
    rows = collections.defaultdict(collections.Counter)
    for path in transcripts(projects, match):
        for day, kind, row in measure(path, since):
            key = day if by == "day" else path.parent.name[-28:] + "/" + path.stem[:8]
            rows[key, kind].update(row)
            rows["total", kind].update(row)
    return rows


def millions(count):
    return "%.1fM" % (count / 1e6)


def render(rows):
    if not rows:
        return ["no model turn found: nothing matched, or this harness keeps no"
                " Claude Code transcripts"]
    lines = ["%-38s %-8s %7s %12s %9s %9s %14s %14s" % (
        "", "", "turns", "context/turn", "read", "written", "expired 5m", "expired 1h")]
    for (key, kind), row in sorted(rows.items(), key=lambda item: (item[0][0] == "total",
                                                                 item[0])):
        lines.append("%-38s %-8s %7d %12d %9s %9s %5d %8s %5d %8s" % (
            key, kind, row["turns"], row["context"] // max(row["turns"], 1),
            millions(row["read"]), millions(row["written"]),
            row["expired_5m"], millions(row["expired_5m_tokens"]),
            row["expired_1h"], millions(row["expired_1h_tokens"])))
    return lines


def day_of(text):
    try:
        return datetime.datetime.strptime(text, "%Y-%m-%d").replace(
            tzinfo=datetime.timezone.utc).timestamp()
    except ValueError:
        raise argparse.ArgumentTypeError("--since needs a day such as 2026-11-01")


def main(argv=None):
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--projects", type=Path, default=Path.home() / ".claude" / "projects",
                        help="where the harness keeps its transcripts")
    parser.add_argument("--match", default=DEFAULT_MATCH,
                        help="a regular expression a project directory's name must match")
    parser.add_argument("--since", type=day_of, default=0.0, metavar="YYYY-MM-DD",
                        help="count turns from this day on, UTC")
    parser.add_argument("--by", choices=("day", "session"), default="day")
    args = parser.parse_args(argv)
    try:
        re.compile(args.match)
    except re.error as error:
        parser.error("--match is not a regular expression: %s" % error)
    print("\n".join(render(report(args.projects, args.match, args.since, args.by))))
    return 0


if __name__ == "__main__":
    sys.exit(main())
