#!/usr/bin/env python3
"""Exercise roadmap status pointers and the nonpublishing landing-page track."""
import importlib.util
from pathlib import Path
import re
import tempfile
import unittest
import warnings


ROOT = Path(__file__).resolve().parents[2]


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


CHECK = load_module("landin_check", ROOT / "check.py")
RENDER = load_module("landin_render", ROOT / "docs/site/render_html.py")


#  Synthetic items.  They are built rather than written, because check.py
#  refuses a roadmap identity written anywhere but ROADMAP.md, and a test
#  of the rules that read one is no exception.
FIRST, SECOND, THIRD = ("R%d.%d" % (4, n) for n in (50, 60, 70))


BETWEEN_ITEMS = """\
Execution order: R{phase}

### {first} — Finish the baseline

Status: complete
Depends on: none

### {second} — Start source debugging

Status: planned
Depends on: {first}
""".format(phase=4, first=FIRST, second=SECOND)

ACTIVE_ITEM = BETWEEN_ITEMS.replace("Status: complete", "Status: active", 1)
#  The endpoint: the same two items, with nothing left to do.  It differs
#  from the blocked fixture below in exactly one status, which is the whole
#  point -- "everything is done" and "something is stuck" must not be the same
#  answer.
ENDPOINT = BETWEEN_ITEMS.replace("Status: planned", "Status: complete", 1)


#  The serial lane's first items, in execution order, by title.
PROCESS = ("The register reviewed and typed", "The question queue",
           "Lanes and standing authority in the checks",
           "The item skill rebuilt", "Gate wall time")


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
        marker = ("**Next roadmap item: " + SECOND + " — Start source debugging "
                  "(planned).**")
        self.assertEqual(self.project_status(BETWEEN_ITEMS, marker), [])
        progress = RENDER.roadmap_progress(BETWEEN_ITEMS)
        self.assertIsNone(progress["current"])
        self.assertEqual(progress["following"]["key"], SECOND)
        self.assertEqual(progress["following"]["status"], "planned")

    def test_active_item_keeps_the_current_pointer(self):
        marker = "**Current roadmap work: " + FIRST + " — Finish the baseline.**"
        self.assertEqual(self.project_status(ACTIVE_ITEM, marker), [])
        progress = RENDER.roadmap_progress(ACTIVE_ITEM)
        self.assertEqual(progress["current"]["key"], FIRST)
        self.assertEqual(progress["following"]["key"], SECOND)

    def test_an_item_started_early_runs_beside_the_serial_item(self):
        #  An item of a serial phase that depends on nothing may start
        #  beside the serial lane's item; the pointers keep naming the
        #  serial lane's, active or still planned, and the page shows both.
        beside = ACTIVE_ITEM + (
            "\n### %s — Start the container program\n\n"
            "Status: active\nDepends on: none\n" % THIRD)
        marker = "**Current roadmap work: " + FIRST + " — Finish the baseline.**"
        self.assertEqual(self.project_status(beside, marker), [])
        progress = RENDER.roadmap_progress(beside)
        self.assertEqual(progress["current"]["key"], FIRST)
        self.assertEqual(progress["following"]["key"], SECOND)
        self.assertEqual([item["key"] for item in progress["beside"]], [THIRD])
        #  The serial item not yet started: it is still the one named.
        waiting = beside.replace("Status: active", "Status: planned", 1)
        marker = "**Next roadmap item: " + FIRST + " — Finish the baseline (planned).**"
        self.assertEqual(self.project_status(waiting, marker), [])
        progress = RENDER.roadmap_progress(waiting)
        self.assertIsNone(progress["current"])
        self.assertEqual(progress["following"]["key"], FIRST)
        self.assertEqual([item["key"] for item in progress["beside"]], [THIRD])
        wrong = "**Current roadmap work: " + THIRD + " — Start the container program.**"
        problems = self.project_status(waiting, wrong)
        self.assertTrue(any("roadmap status pointer" in problem[2]
                            for problem in problems))

    def test_a_blocked_item_is_passed_over_and_its_dependencies_read(self):
        #  The reason stands between the status and the dependencies, as
        #  the Mechanics' order puts it; neither reader may lose the
        #  dependency line behind it.
        blocked = BETWEEN_ITEMS + (
            "\n### %s — Start the container program\n\n"
            "Status: blocked\nBlocked because: a control says so\n"
            "Depends on: %s\n" % (THIRD, SECOND))
        items = RENDER.roadmap_items(blocked)
        self.assertEqual(items[THIRD]["depends"], [SECOND])
        self.assertEqual(items[THIRD]["blocked"], "a control says so")
        marker = ("**Next roadmap item: " + SECOND + " — Start source debugging "
                  "(planned).**")
        self.assertEqual(self.project_status(blocked, marker), [])
        self.assertEqual(RENDER.roadmap_progress(blocked)["following"]["key"],
                         SECOND)

    def test_parallel_ready_items_follow_roadmap_order(self):
        two_ready = BETWEEN_ITEMS + """\

### %s — Start the container program

Status: planned
Depends on: none
""" % THIRD
        marker = ("**Next roadmap item: " + SECOND + " — Start source debugging "
                  "(planned).**")
        self.assertEqual(self.project_status(two_ready, marker), [])
        progress = RENDER.roadmap_progress(two_ready)
        self.assertIsNone(progress["current"])
        self.assertEqual(progress["following"]["key"], SECOND)
        wrong = marker.replace(SECOND + " — Start source debugging",
                               THIRD + " — Start the container program")
        problems = self.project_status(two_ready, wrong)
        self.assertTrue(any("roadmap status pointer" in problem[2]
                            for problem in problems))

    def test_explicit_item_order_controls_both_status_and_site(self):
        roadmap = BETWEEN_ITEMS + (
            "\n### %s — Start the container program\n\n"
            "Status: planned\nDepends on: none\n" % THIRD)
        roadmap = roadmap.replace("Execution order: R%d" % 4,
                                  "Execution order: "
                                  + ", ".join([FIRST, THIRD, SECOND]))
        marker = ("**Next roadmap item: " + THIRD
                  + " — Start the container program (planned).**")
        self.assertEqual(self.project_status(roadmap, marker), [])
        progress = RENDER.roadmap_progress(roadmap)
        self.assertEqual(progress["following"]["key"], THIRD)
        #  An item started out of order runs beside the serial lane's
        #  item, which the order still names.
        active = roadmap.replace("Status: planned", "Status: active", 1)
        self.assertEqual(self.project_status(active, marker), [])
        progress = RENDER.roadmap_progress(active)
        self.assertIsNone(progress["current"])
        self.assertEqual(progress["following"]["key"], THIRD)
        self.assertEqual([item["key"] for item in progress["beside"]], [SECOND])
        self.assertEqual([item["key"] for item in progress["recent"]], [FIRST])
        #  Started in order, it is the serial lane's, with nothing after it.
        active = active.replace(
            "Status: planned\nDepends on: none", "Status: complete\nDepends on: none")
        marker = "**Current roadmap work: " + SECOND + " — Start source debugging.**"
        self.assertEqual(self.project_status(active, marker), [])
        progress = RENDER.roadmap_progress(active)
        self.assertEqual(progress["current"]["key"], SECOND)
        self.assertIsNone(progress["following"])
        self.assertEqual([item["key"] for item in progress["recent"]],
                         [FIRST, THIRD])

    def test_invalid_execution_order_is_refused_by_both_readers(self):
        valid = "Execution order: R%d" % 4
        for replacement in ("", valid + "\n" + valid,
                            "Execution order: " + FIRST,
                            "Execution order: " + ", ".join([FIRST, SECOND, FIRST]),
                            "Execution order: R%d" % 99,
                            "Execution order: " + FIRST + "; " + SECOND):
            with self.subTest(replacement=replacement):
                roadmap = BETWEEN_ITEMS.replace(valid, replacement)
                problems = self.project_status(roadmap, "unused")
                self.assertTrue(any("order" in problem[2].lower()
                                    for problem in problems))
                with self.assertRaises(SystemExit):
                    RENDER.roadmap_progress(roadmap)

    def test_a_phase_dependency_waits_for_every_item_of_the_phase(self):
        later = "R%d.%d" % (5, 10)
        roadmap = BETWEEN_ITEMS + (
            "\n### %s — Start the container program\n\n"
            "Status: planned\nDepends on: R%d\n" % (later, 4))
        roadmap = roadmap.replace("Execution order: R%d" % 4,
                                  "Execution order: R%d, R%d" % (4, 5))
        marker = ("**Next roadmap item: " + SECOND + " — Start source debugging "
                  "(planned).**")
        self.assertEqual(self.project_status(roadmap, marker), [])
        done = roadmap.replace("Status: planned", "Status: complete", 1)
        marker = ("**Next roadmap item: " + later
                  + " — Start the container program (planned).**")
        self.assertEqual(self.project_status(done, marker), [])
        self.assertEqual(RENDER.roadmap_progress(done)["following"]["key"],
                         later)

    def test_the_continuous_lane_follows_the_serial_order(self):
        roadmap = BETWEEN_ITEMS + (
            "\n### %s — Start the container program\n\n"
            "Status: planned\nDepends on: %s\n" % (THIRD, FIRST))
        roadmap = roadmap.replace(
            "Execution order: R%d" % 4,
            "Execution order: %s, %s\nContinuous: %s onward"
            % (FIRST, SECOND, THIRD))
        order = CHECK.execution_order(roadmap, [FIRST, SECOND, THIRD])
        self.assertEqual(order, [FIRST, SECOND, THIRD])
        marker = ("**Next roadmap item: " + SECOND + " — Start source debugging "
                  "(planned).**")
        self.assertEqual(self.project_status(roadmap, marker), [])
        for line, expected in (
                ("Continuous: %s" % THIRD, "malformed Continuous"),
                ("Continuous: R%d.%d onward" % (4, 90), "unknown"),
                ("Continuous: %s onward\nContinuous: %s onward"
                 % (THIRD, THIRD), "at most one Continuous")):
            with self.subTest(line=line):
                with self.assertRaisesRegex(ValueError, expected):
                    CHECK.execution_order(roadmap.replace(
                        "Continuous: %s onward" % THIRD, line),
                        [FIRST, SECOND, THIRD])
        with self.assertRaisesRegex(ValueError, "continuous lane holds"):
            CHECK.execution_order(roadmap.replace(
                "Execution order: %s, %s" % (FIRST, SECOND),
                "Execution order: R%d" % 4), [FIRST, SECOND, THIRD])

    def test_site_refuses_duplicate_item_identities(self):
        duplicate = BETWEEN_ITEMS + BETWEEN_ITEMS.split("\n\n", 1)[1]
        with self.assertRaisesRegex(SystemExit, "repeats"):
            RENDER.roadmap_progress(duplicate)

    def test_real_serial_sequence(self):
        text = (ROOT / "ROADMAP.md").read_text()
        headings = {match.group(3): match.group(1)
                    for line in text.splitlines()
                    if (match := CHECK.ROADMAP_WORK.match(line))}
        #  Every item back to planned, a blocked one's reason with it.
        text = re.sub(r"^Blocked because: .*\n", "", text, flags=re.M)
        text = re.sub(r"^Status: (active|complete|blocked)$",
                      "Status: planned", text, flags=re.M)

        def complete(identities):
            nonlocal text
            for identity in identities:
                start = text.index("### " + identity + " — ")
                text = text[:start] + text[start:].replace(
                    "Status: planned", "Status: complete", 1)

        def assert_next(title):
            marker = ("**Next roadmap item: " + headings[title] + " — "
                      + title + " (planned).**")
            self.assertEqual(self.project_status(text, marker), [])
            progress = RENDER.roadmap_progress(text)
            self.assertEqual(progress["following"]["key"], headings[title])

        for title in PROCESS:
            assert_next(title)
            complete([headings[title]])
        #  The measurement waits for the whole process phase, and then
        #  comes before the command split.
        assert_next("Measure generated code")
        complete([headings["Measure generated code"]])
        #  Register allocation is continuous: ready now, but never the
        #  serial lane's next item while one remains.
        assert_next("Decide the commands")

    def test_the_endpoint_uses_its_own_pointer(self):
        marker = ("**Roadmap endpoint: " + SECOND + " — Start source debugging"
                  " (complete).**")
        self.assertEqual(self.project_status(ENDPOINT, marker), [])
        progress = RENDER.roadmap_progress(ENDPOINT)
        self.assertIsNone(progress["current"])
        self.assertIsNone(progress["following"])
        self.assertEqual(progress["endpoint"]["key"], SECOND)
        self.assertEqual([item["key"] for item in progress["recent"]], [FIRST])

    def test_the_endpoint_pointer_is_refused_before_the_endpoint(self):
        marker = ("**Roadmap endpoint: " + SECOND + " — Start source debugging"
                  " (complete).**")
        problems = self.project_status(BETWEEN_ITEMS, marker)
        self.assertTrue(any("roadmap status pointer is endpoint" in problem[2]
                            for problem in problems))

    def test_a_next_item_pointer_is_refused_after_the_endpoint(self):
        marker = ("**Next roadmap item: " + SECOND + " — Start source debugging "
                  "(planned).**")
        problems = self.project_status(ENDPOINT, marker)
        self.assertTrue(any("roadmap status pointer is next" in problem[2]
                            for problem in problems))

    def test_the_endpoint_names_the_last_item_in_roadmap_order(self):
        marker = "**Roadmap endpoint: " + FIRST + " — Finish the baseline (complete).**"
        problems = self.project_status(ENDPOINT, marker)
        self.assertTrue(any("roadmap status pointer" in problem[2]
                            for problem in problems))

    def test_unavailable_status_is_refused(self):
        roadmap = BETWEEN_ITEMS.replace("Status: planned", "Status: blocked", 1)
        marker = "**Current roadmap work: " + FIRST + " — Finish the baseline.**"
        problems = self.project_status(roadmap, marker)
        self.assertTrue(any("no roadmap item is active or planned with its"
                            " dependencies complete" in problem[2]
                            for problem in problems))
        with self.assertRaisesRegex(SystemExit, "no active item and no"):
            RENDER.roadmap_progress(roadmap)
        #  A stall and an endpoint differ by one status, and the rule that
        #  admits the second must keep refusing the first.
        self.assertEqual(roadmap.replace("Status: blocked", "Status: complete"),
                         ENDPOINT)

    def test_wrong_marker_is_refused(self):
        marker = ("**Next roadmap item: " + SECOND + " — Start source debugging "
                  "(planned).**")
        problems = self.project_status(ACTIVE_ITEM, marker)
        self.assertTrue(any("roadmap status pointer" in problem[2]
                            for problem in problems))

    def front_page(self, roadmap):
        """The front page the renderer writes for this roadmap, alone.

        Only the page that carries the status, from the real README's
        status line and a stand-in program: rendering the whole site to
        read two lines of it took twenty seconds a run.  The whole render
        and its check that every roadmap item reached the front page run
        in test_library_docs.py, which renders the site once anyway.
        """
        status = RENDER.readme_status((ROOT / "README.md").read_text())
        self.assertTrue(status)
        program = ("sensors.ldn", ["main: () -> i32 = 0"], [])
        return RENDER.index_page(RENDER.DOCS + RENDER.GUIDES, {},
                                 ["Landin is a language."], status,
                                 RENDER.roadmap_progress(roadmap), program,
                                 set(), None, "")

    def assertShowsItems(self, index, *titles):
        """Each item by its title alone: a roadmap number means nothing to
        a reader who has not opened the roadmap, so the page shows none."""
        for title in titles:
            self.assertIn("<span>" + title + "</span>", index)
        for key in (FIRST, SECOND):
            self.assertNotIn(key, index)

    def test_front_page_shows_the_planned_next_item(self):
        index = self.front_page(BETWEEN_ITEMS)
        self.assertIn("next planned item", index)
        self.assertShowsItems(index, "Finish the baseline",
                              "Start source debugging")
        self.assertNotIn('<div class="roadmap-now">', index)
        self.assertNotIn("roadmap endpoint", index)

    def test_front_page_shows_the_active_item(self):
        index = self.front_page(ACTIVE_ITEM)
        self.assertIn('<div class="roadmap-now">', index)
        self.assertIn("up next", index)
        self.assertShowsItems(index, "Finish the baseline",
                              "Start source debugging")
        self.assertNotIn("next planned item", index)

    def test_front_page_shows_the_serial_item_beside_continuous_items(self):
        #  The serial lane's item in progress, and two continuous items
        #  active beside it: the page shows all three and names none.
        fourth, fifth = ("R%d.%d" % (4, n) for n in (80, 81))
        roadmap = ACTIVE_ITEM + "".join(
            "\n### %s — %s\n\nStatus: active\nDepends on: none\n"
            % (key, title)
            for key, title in ((fourth, "Measure the stack"),
                               (fifth, "Fold the constants")))
        roadmap = roadmap.replace(
            "Execution order: R%d" % 4,
            "Execution order: %s, %s\nContinuous: %s onward"
            % (FIRST, SECOND, fourth))
        marker = "**Current roadmap work: " + FIRST + " — Finish the baseline.**"
        self.assertEqual(self.project_status(roadmap, marker), [])
        progress = RENDER.roadmap_progress(roadmap)
        self.assertEqual(progress["current"]["key"], FIRST)
        self.assertEqual(progress["following"]["key"], SECOND)
        self.assertEqual([item["key"] for item in progress["beside"]],
                         [fourth, fifth])
        index = self.front_page(roadmap)
        self.assertIn("also in progress", index)
        self.assertIn("up next", index)
        self.assertShowsItems(index, "Finish the baseline",
                              "Start source debugging", "Measure the stack",
                              "Fold the constants")
        for key in (fourth, fifth):
            self.assertNotIn(key, index)
        #  Without them, there is no lane beside it.
        self.assertNotIn("also in progress", self.front_page(ACTIVE_ITEM))

    def test_front_page_shows_the_endpoint(self):
        index = self.front_page(ENDPOINT)
        self.assertIn("roadmap endpoint", index)
        self.assertShowsItems(index, "Start source debugging")
        self.assertNotIn("next planned item", index)
        self.assertNotIn('<div class="roadmap-now">', index)


class HostedParity(unittest.TestCase):
    def problems(self, *, kinds=("runtime",), targets="linux-x86-64",
                 program="main.ldn", applicability="hosted-now",
                 static=False, codes="L0301"):
        rows = [(7, {"Construct": "`[0650]`", "Applicability": applicability,
                     "Disposition": "audited"})]
        fixtures = {kind + "/probe": ("fixture.meta", {
            "program": program, "constructs": "0650", "targets": targets,
            "codes": codes}) for kind in kinds}
        static_rows = [(9, {"Construct": "`[0650]`", "Accepted": "none",
                            "Refused": "`negative/probe`",
                            "Rationale": "a compile-time prohibition"})] if static else []
        return CHECK.hosted_parity_problems(rows, static_rows, fixtures)

    def test_runtime_and_abi_are_linux_execution_witnesses(self):
        for kind in ("runtime", "abi"):
            self.assertEqual(self.problems(kinds=(kind,)), [])

    def test_refusal_or_emission_alone_cannot_close_runtime_surface(self):
        for kind in ("negative", "positive"):
            self.assertTrue(self.problems(kinds=(kind,)))

    def test_other_target_and_metadata_without_program_are_not_execution(self):
        self.assertTrue(self.problems(targets="darwin-arm64"))
        self.assertTrue(self.problems(program=""))

    def test_static_exception_requires_its_exact_diagnostic_program(self):
        self.assertEqual(self.problems(kinds=("negative",), static=True), [])
        self.assertTrue(self.problems(kinds=("runtime",), static=True))
        self.assertTrue(self.problems(kinds=("negative",), static=True, codes=""))

    def test_a_freestanding_row_needs_no_linux_witness(self):
        self.assertEqual(self.problems(kinds=(), applicability="freestanding"),
                         [])

    def test_a_hosted_row_with_no_witness_is_reported(self):
        self.assertTrue(self.problems(kinds=()))

    def test_unreadable_registers_are_reported(self):
        self.assertTrue(CHECK.hosted_parity_problems(None, [], {}))


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


class GuideLinks(unittest.TestCase):
    def target(self, source, href):
        targets = RENDER.guide_targets(RENDER.DOCS + RENDER.GUIDES, source)
        return targets.resolve(href)

    def test_repeated_readme_names_resolve_in_their_source_directory(self):
        self.assertEqual(self.target("README.md", "README.md"), "readme.html")
        self.assertEqual(self.target("compiler/ada/README.md", "README.md"),
                         "compiler.html")
        self.assertEqual(self.target("compiler/ada/README.md", "../tests/README.md"),
                         "fixtures.html")
        self.assertEqual(self.target("compiler/ada/README.md", "../../bindings/README.md"),
                         "bindings.html")
        self.assertEqual(self.target("docs/environments.md", "../compiler/ada/README.md#build"),
                         "compiler.html#build")
        self.assertEqual(self.target("compiler/ada/README.md", "../../spec.md#1770"),
                         "spec.html#1770")

    def test_unrendered_files_link_to_the_repository(self):
        self.assertEqual(self.target("highlight/README.md", "vim/README.md"),
                         RENDER.REPO + "/blob/main/highlight/vim/README.md")
        self.assertEqual(self.target("README.md", "a%20b.md?q=1#section"),
                         RENDER.REPO + "/blob/main/a%20b.md?q=1#section")

    def test_external_and_page_local_links_keep_their_identity(self):
        for href in ("https://example.org/README.md", "mailto:me@example.org",
                     "//example.org/a", "#section", "/index.html", "?q=1"):
            with self.subTest(href=href):
                self.assertEqual(self.target("compiler/ada/README.md", href), href)

    def test_verification_retains_source_targets_but_still_detects_lost_words(self):
        written = "[read the fixture guide](../tests/README.md)"
        targets = RENDER.guide_targets(RENDER.DOCS + RENDER.GUIDES,
                                       "compiler/ada/README.md")
        rendered = RENDER.inline(written, lambda _: None, targets)
        self.assertIn('href="fixtures.html"', rendered)
        self.assertIn('data-source-href="../tests/README.md"', rendered)
        with tempfile.TemporaryDirectory() as directory:
            source, page = Path(directory) / "README.md", Path(directory) / "page.html"
            source.write_text(written)
            page.write_text("<main>" + rendered + "</main>")
            self.assertTrue(RENDER.verify(source, page))
            page.write_text("<main>" + rendered.replace("fixture guide", "") + "</main>")
            self.assertFalse(RENDER.verify(source, page))


if __name__ == "__main__":
    unittest.main()
