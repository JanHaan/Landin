#!/usr/bin/env python3
"""Exercise roadmap status pointers and the nonpublishing landing-page track."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import warnings


ROOT = Path(__file__).resolve().parents[2]


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


CHECK = load_module("landin_check", ROOT / "check.py")
RENDER = load_module("landin_render", ROOT / "docs/site/render_html.py")


BETWEEN_ITEMS = """\
### R4.50 — Finish the baseline

Status: complete
Depends on: none

### R4.60 — Start source debugging

Status: planned
Depends on: R4.50
"""

ACTIVE_ITEM = BETWEEN_ITEMS.replace("Status: complete", "Status: active", 1)


class RoadmapProgress(unittest.TestCase):
    def project_status(self, roadmap, marker):
        with tempfile.TemporaryDirectory(prefix="landin-roadmap-") as directory:
            root = Path(directory)
            (root / "ROADMAP.md").write_text(roadmap)
            for name in ("README.md", "handoff.md"):
                (root / name).write_text(marker + "\n")
            old_root = CHECK.ROOT
            CHECK.ROOT = str(root)
            try:
                with warnings.catch_warnings():
                    warnings.simplefilter("ignore", ResourceWarning)
                    return CHECK.check_project_status(True)
            finally:
                CHECK.ROOT = old_root

    def test_between_items_uses_the_ready_planned_pointer(self):
        marker = ("**Next roadmap item: R4.60 — Start source debugging "
                  "(planned).**")
        self.assertEqual(self.project_status(BETWEEN_ITEMS, marker), [])
        progress = RENDER.roadmap_progress(BETWEEN_ITEMS)
        self.assertIsNone(progress["current"])
        self.assertEqual(progress["following"]["key"], "R4.60")
        self.assertEqual(progress["following"]["status"], "planned")

    def test_active_item_keeps_the_current_pointer(self):
        marker = "**Current roadmap work: R4.50 — Finish the baseline.**"
        self.assertEqual(self.project_status(ACTIVE_ITEM, marker), [])
        progress = RENDER.roadmap_progress(ACTIVE_ITEM)
        self.assertEqual(progress["current"]["key"], "R4.50")
        self.assertEqual(progress["following"]["key"], "R4.60")

    def test_ambiguous_status_pointers_are_refused(self):
        two_active = ACTIVE_ITEM.replace("Status: planned", "Status: active", 1)
        two_ready = BETWEEN_ITEMS + """\

### R4.70 — Start the container program

Status: planned
Depends on: none
"""
        marker = "**Current roadmap work: R4.50 — Finish the baseline.**"
        for name, roadmap, needle in (
                ("active", two_active, "2 active"),
                ("ready", two_ready, "2 dependency-ready")):
            with self.subTest(name=name):
                problems = self.project_status(roadmap, marker)
                self.assertTrue(any(needle in problem[2] for problem in problems))
                with self.assertRaisesRegex(SystemExit, "exactly one active"):
                    RENDER.roadmap_progress(roadmap)

    def test_unavailable_status_is_refused(self):
        roadmap = BETWEEN_ITEMS.replace("Status: planned", "Status: blocked", 1)
        marker = "**Current roadmap work: R4.50 — Finish the baseline.**"
        problems = self.project_status(roadmap, marker)
        self.assertTrue(any("0 active and 0 dependency-ready" in problem[2]
                            for problem in problems))
        with self.assertRaisesRegex(SystemExit, "exactly one active"):
            RENDER.roadmap_progress(roadmap)

    def test_wrong_marker_is_refused(self):
        marker = ("**Next roadmap item: R4.60 — Start source debugging "
                  "(planned).**")
        problems = self.project_status(ACTIVE_ITEM, marker)
        self.assertTrue(any("roadmap status pointer" in problem[2]
                            for problem in problems))

    def test_renderer_smoke_shows_the_planned_next_item(self):
        with tempfile.TemporaryDirectory(prefix="landin-site-") as directory:
            old_site = RENDER.SITE
            RENDER.SITE = Path(directory) / "site"
            try:
                progress = RENDER.roadmap_progress(BETWEEN_ITEMS)
                with patch.object(RENDER, "roadmap_progress", return_value=progress):
                    self.assertEqual(
                        RENDER.main(["--from", str(ROOT), "--verify"]), 0)
                index = (RENDER.SITE / "index.html").read_text()
            finally:
                RENDER.SITE = old_site
        self.assertIn("next planned item", index)
        self.assertIn("R4.60", index)
        self.assertNotIn('<div class="roadmap-now">', index)


if __name__ == "__main__":
    unittest.main()
