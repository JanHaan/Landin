#!/usr/bin/env python3
"""Hold the session report to counting each model message once and each
expired cache at the life it outlasted."""
import contextlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import run_logged
import session_report


def turn(identity, stamp, read=0, written=0, fresh=10, sidechain=False):
    return json.dumps({
        "type": "assistant", "timestamp": stamp, "isSidechain": sidechain,
        "message": {"id": identity, "usage": {
            "input_tokens": fresh, "output_tokens": 5,
            "cache_read_input_tokens": read, "cache_creation_input_tokens": written}}})


class SessionReport(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="landin-sessions-")
        self.addCleanup(temporary.cleanup)
        self.projects = Path(temporary.name)

    def transcript(self, name, *lines, project="-home-x-src-Landin"):
        path = self.projects / project / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("\n".join(lines) + "\n")
        return path

    def rows(self, **given):
        return session_report.report(self.projects, given.get("match", session_report.DEFAULT_MATCH),
                                     given.get("since", 0.0), given.get("by", "day"))

    def test_a_message_written_as_several_lines_is_counted_once(self):
        line = turn("m1", "2026-11-01T10:00:00Z", read=100000)
        self.transcript("a.jsonl", line, line, line,
                        turn("m2", "2026-11-01T10:01:00Z", read=100000))
        total = self.rows()["total", "main"]
        self.assertEqual((total["turns"], total["read"]), (2, 200000))
        self.assertEqual(total["context"], 200020)

    def test_a_rewrite_is_charged_to_the_life_its_pause_outlasted(self):
        self.transcript(
            "a.jsonl",
            turn("m1", "2026-11-01T10:00:00Z", written=90000),   # the first write is no expiry
            turn("m2", "2026-11-01T10:04:00Z", read=90000),      # inside five minutes
            turn("m3", "2026-11-01T10:14:00Z", written=90000),   # ten minutes: the short life
            turn("m4", "2026-11-01T12:14:00Z", written=95000),   # two hours: the long life
            turn("m5", "2026-11-01T12:30:00Z", read=95000))      # read from the cache after a pause
        total = self.rows()["total", "main"]
        self.assertEqual((total["expired_5m"], total["expired_5m_tokens"]), (1, 90000))
        self.assertEqual((total["expired_1h"], total["expired_1h_tokens"]), (1, 95000))

    def test_a_small_context_or_a_small_write_after_a_pause_is_no_rewrite(self):
        self.transcript(
            "a.jsonl",
            turn("m1", "2026-11-01T10:00:00Z", written=90000),
            turn("m2", "2026-11-01T10:30:00Z", read=90000, written=9000),
            turn("m3", "2026-11-01T11:00:00Z", written=5000))
        total = self.rows()["total", "main"]
        self.assertEqual(total["expired_5m"] + total["expired_1h"], 0)

    def test_subagents_are_told_apart_by_their_file_and_by_their_mark(self):
        self.transcript("s/subagents/agent-1.jsonl", turn("m1", "2026-11-01T10:00:00Z", read=7))
        self.transcript("a.jsonl", turn("m2", "2026-11-01T10:00:00Z", read=5, sidechain=True),
                        turn("m3", "2026-11-01T10:00:00Z", read=3))
        rows = self.rows()
        self.assertEqual(rows["total", "subagent"]["read"], 12)
        self.assertEqual(rows["total", "main"]["read"], 3)

    def test_since_and_match_select_and_a_pause_spans_the_cut(self):
        self.transcript("a.jsonl", turn("m1", "2026-10-31T23:50:00Z", written=90000),
                        turn("m2", "2026-11-01T00:10:00Z", written=90000))
        self.transcript("b.jsonl", turn("m3", "2026-11-01T10:00:00Z", read=1),
                        project="-home-x-src-other")
        rows = self.rows(since=session_report.day_of("2026-11-01"))
        self.assertEqual(sorted(rows), [("2026-11-01", "main"), ("total", "main")])
        self.assertEqual(rows["total", "main"]["expired_5m"], 1)
        self.assertEqual(self.rows(match="other")["total", "main"]["read"], 1)

    def test_by_session_names_the_transcript_and_broken_lines_are_passed_over(self):
        self.transcript("0123456789ab.jsonl", '{"usage" broken',
                        json.dumps({"type": "user", "message": {"usage": {}}}),
                        turn("m1", "2026-11-01T10:00:00Z", read=4))
        rows = self.rows(by="session")
        self.assertIn(("-home-x-src-Landin/01234567", "main"), rows)
        self.assertEqual(rows["total", "main"]["turns"], 1)

    def test_nothing_to_read_says_so_and_a_bad_option_is_refused(self):
        said = io.StringIO()
        with contextlib.redirect_stdout(said):
            self.assertEqual(session_report.main(["--projects", str(self.projects / "none")]), 0)
        self.assertIn("no model turn found", said.getvalue())
        for arguments in (["--since=yesterday"], ["--match=("]):
            with self.subTest(arguments=arguments), self.assertRaises(SystemExit), \
                    contextlib.redirect_stderr(io.StringIO()):
                session_report.main(arguments)

    def test_the_default_wait_returns_inside_a_subagents_cache(self):
        self.assertLess(run_logged.DEFAULT_WAIT, session_report.SHORT_LIFE)


if __name__ == "__main__":
    unittest.main()
