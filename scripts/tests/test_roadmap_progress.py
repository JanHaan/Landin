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

    def test_multiple_active_status_pointers_are_refused(self):
        two_active = ACTIVE_ITEM.replace("Status: planned", "Status: active", 1)
        marker = "**Current roadmap work: R4.50 — Finish the baseline.**"
        problems = self.project_status(two_active, marker)
        self.assertTrue(any("2 active" in problem[2] for problem in problems))
        with self.assertRaisesRegex(SystemExit, "exactly one active"):
            RENDER.roadmap_progress(two_active)

    def test_parallel_ready_items_follow_roadmap_order(self):
        two_ready = BETWEEN_ITEMS + """\

### R4.70 — Start the container program

Status: planned
Depends on: none
"""
        marker = ("**Next roadmap item: R4.60 — Start source debugging "
                  "(planned).**")
        self.assertEqual(self.project_status(two_ready, marker), [])
        progress = RENDER.roadmap_progress(two_ready)
        self.assertIsNone(progress["current"])
        self.assertEqual(progress["following"]["key"], "R4.60")
        wrong = marker.replace("R4.60 — Start source debugging",
                               "R4.70 — Start the container program")
        problems = self.project_status(two_ready, wrong)
        self.assertTrue(any("roadmap status pointer" in problem[2]
                            for problem in problems))

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


class HostedParity(unittest.TestCase):
    def problems(self, *, kinds=("runtime",), targets="linux-x86-64",
                 program="main.ldn", applicability="hosted-now",
                 static=False, codes="L0301", status="complete",
                 extra_statuses=None):
        rows = [(7, {"Construct": "`[0650]`", "Applicability": applicability,
                     "Owner": "R4.90", "Disposition": "audited"})]
        fixtures = {kind + "/probe": ("fixture.meta", {
            "program": program, "constructs": "0650", "targets": targets,
            "codes": codes}) for kind in kinds}
        static_rows = [(9, {"Construct": "`[0650]`", "Accepted": "none",
                            "Refused": "`negative/probe`",
                            "Rationale": "a compile-time prohibition"})] if static else []
        return CHECK.hosted_parity_problems(
            {"R4.90": status, **(extra_statuses or {})}, rows, static_rows, fixtures)

    def test_later_repairs_do_not_rewrite_prior_acceptance(self):
        self.assertEqual(self.problems(extra_statuses={"R4.91": "active"}), [])
        self.assertTrue(self.problems(extra_statuses={"R4.80": "active"}))

    def test_runtime_and_abi_are_linux_execution_witnesses(self):
        for kind in ("runtime", "abi"):
            self.assertEqual(self.problems(kinds=(kind,)), [])

    def test_refusal_or_emission_alone_cannot_close_runtime_surface(self):
        for kind in ("negative", "positive"):
            self.assertTrue(self.problems(kinds=(kind,)))

    def test_other_target_and_metadata_without_program_are_not_execution(self):
        self.assertTrue(self.problems(targets="macos-arm64"))
        self.assertTrue(self.problems(program=""))

    def test_static_exception_requires_its_exact_diagnostic_program(self):
        self.assertEqual(self.problems(kinds=("negative",), static=True), [])
        self.assertTrue(self.problems(kinds=("runtime",), static=True))
        self.assertTrue(self.problems(kinds=("negative",), static=True, codes=""))

    def test_later_r4_cannot_survive_closure(self):
        self.assertTrue(self.problems(applicability="later-r4"))
        self.assertEqual(self.problems(applicability="freestanding"), [])

    def test_active_audit_does_not_claim_closure(self):
        self.assertEqual(self.problems(kinds=(), status="active"), [])


class QualityWorkloads(unittest.TestCase):
    def problems(self, missing=None, profile_missing=False):
        names = tuple(name for name in ("derived-parser", "derived-containers",
                                        "derived-hosted-memory") if name != missing)
        profiles = (("none", "off"), ("size", "off"), ("size", "auto"),
                    ("speed", "auto"), ("none", "all"), ("speed", "all"))
        return CHECK.quality_workload_problems({
            "FIXTURE_NAMES": names,
            "profiles_for": lambda name: profiles[:-1] if profile_missing else profiles})

    def test_complete_prototypes_and_repeated_profiles_are_required(self):
        self.assertEqual(self.problems(), [])
        for missing in ("derived-parser", "derived-containers", "derived-hosted-memory"):
            self.assertTrue(self.problems(missing=missing))
        self.assertTrue(self.problems(profile_missing=True))


class DebuggerWorkloads(unittest.TestCase):
    def problems(self, workloads=("parser", "containers", "hosted"),
                 profiles=(("none-off", "none", "off"),
                           ("size-auto", "size", "auto"),
                           ("size-all", "size", "all"))):
        def schedule(measure):
            return {name: {profile[0]: measure(name, profile)
                           for profile in profiles} for name in workloads}
        return CHECK.debugger_workload_problems({"measure_workloads": schedule})

    def test_all_complete_prototypes_and_profiles_are_required(self):
        self.assertEqual(self.problems(), [])
        for missing in ("parser", "containers", "hosted"):
            self.assertTrue(self.problems(workloads=tuple(
                name for name in ("parser", "containers", "hosted")
                if name != missing)))

    def test_missing_or_mislabelled_profile_is_refused(self):
        self.assertTrue(self.problems(profiles=(("none-off", "none", "off"),)))
        self.assertTrue(self.problems(profiles=(
            ("none-off", "none", "off"), ("size-auto", "none", "off"),
            ("size-all", "size", "all"))))


if __name__ == "__main__":
    unittest.main()
