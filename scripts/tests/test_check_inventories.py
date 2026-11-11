#!/usr/bin/env python3
"""Controls for the checks of check.py that had none.

Fifteen checks had never been shown to fire: a sixteenth, the lowering
stage's verifier call, could be deleted unnoticed until it was given a
control.  These are in the form scripts/tests/test_check_controls.py uses,
each check silent on a tree that satisfies it and speaking on one that
does not, in a module of their own so that they run beside its shards.

A real document copied here is edited by a pattern over its structure, a
version number or a heading, never by its prose, so rewording a document
reaches none of these and scripts/tests/control_quotes.json lists nothing
for them.
"""
import re
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from check_controls import checker, reasons, tree   # noqa: E402


def checked(check, root_change=None, **kinds):
    """What CHECK says about a tree after ROOT_CHANGE edited it."""
    with tree(**kinds) as root:
        if root_change is not None:
            root_change(root)
        return [why for _, _, why in check(True)]


def edit(relative, pattern, replacement):
    """An edit of one file of a tree by pattern, which must match."""
    def change(root):
        path = root / relative
        text, made = re.subn(pattern, replacement, path.read_text(),
                             count=1, flags=re.M | re.S)
        assert made, "%s holds no %r" % (relative, pattern)
        path.write_text(text)
    return change


class SpecificationVersion(unittest.TestCase):
    """Every hand-written spelling of the version is README.md's."""

    INPUTS = (["README.md", "docs/site/render_html.py", "handoff.md",
               "tour.md"] + list(checker.PROTOTYPE_FILES))

    def test_the_real_documents_agree(self):
        self.assertEqual(checked(checker.check_specification_version,
                                 copied=self.INPUTS), [])

    def test_each_place_left_behind_is_reported(self):
        for path, pattern in (
                ("docs/site/render_html.py",
                 r'^VERSION_LINE = "specification [0-9.]+"$'),
                ("handoff.md", r"Kept current at specification \*\*[0-9.]+"),
                ("tour.md", r"^Version [0-9.]+(?= —)"),
                (checker.PROTOTYPE_FILES[0],
                 r"^Current with specification [0-9.]+(?=\.)")):
            with self.subTest(path=path):
                def older(root, path=path, pattern=pattern):
                    target = root / path
                    text, made = re.subn(
                        pattern,
                        lambda found: re.sub(r"[0-9][0-9.]*[0-9]", "0.0.1",
                                             found.group()),
                        target.read_text(), count=1, flags=re.M)
                    self.assertEqual(made, 1)
                    target.write_text(text)
                said = checked(checker.check_specification_version, older,
                               copied=self.INPUTS)
                self.assertEqual(len(said), 1, said)
                self.assertIn("says specification 0.0.1; README.md says",
                              said[0])

    def test_a_place_that_states_none_and_a_readme_without_one(self):
        said = checked(checker.check_specification_version,
                       edit("handoff.md", r"Kept current at specification",
                            "Kept current at the specification"),
                       copied=self.INPUTS)
        self.assertEqual(len(said), 1, said)
        self.assertIn("states no specification version", said[0])
        said = checked(checker.check_specification_version,
                       edit("README.md", r"^\*\*Status: specification",
                            "**Status: the specification"),
                       copied=self.INPUTS)
        self.assertEqual(said, ["the status line states no specification"
                                " version"])

    def test_a_missing_place_is_reported_rather_than_skipped(self):
        said = checked(checker.check_specification_version,
                       copied=self.INPUTS[1:])
        self.assertTrue(any("needed by a check" in why for why in said))


class FindingLetters(unittest.TestCase):
    """The site renderer links the findings of check.py's prototypes."""

    PATH = "docs/site/render_html.py"

    def test_the_real_renderer_agrees(self):
        self.assertEqual(checked(checker.check_finding_letters,
                                 copied=[self.PATH]), [])

    def test_other_letters_and_none_are_reported(self):
        said = checked(checker.check_finding_letters,
                       edit(self.PATH, r'^FINDING_LETTERS = "\[[A-Z]+\]"$',
                            'FINDING_LETTERS = "[XYZW]"'),
                       copied=[self.PATH])
        self.assertEqual(len(said), 1, said)
        self.assertIn("links findings [XYZW]; check.py's prototypes have",
                      said[0])
        said = checked(checker.check_finding_letters,
                       edit(self.PATH, r"^FINDING_LETTERS = ", "LETTERS = "),
                       copied=[self.PATH])
        self.assertEqual(said, ["has no FINDING_LETTERS for the prototypes'"
                                " findings"])
        self.assertTrue(checked(checker.check_finding_letters, written={}))


class FirstProgram(unittest.TestCase):
    """README.md's first program is the fixture every hosted target runs."""

    INPUTS = ["README.md", checker.FIRST_PROGRAM]

    def test_the_real_listing_and_output_are_the_fixture_s(self):
        self.assertEqual(checked(checker.check_first_program,
                                 copied=self.INPUTS), [])

    def test_a_changed_source_or_output_is_reported(self):
        for name, said in (("main.ldn", "listing differs"),
                           ("output.txt", "shown output differs")):
            with self.subTest(name=name):
                def longer(root, name=name):
                    path = root / checker.FIRST_PROGRAM / name
                    path.write_text(path.read_text() + "\n")
                found = checked(checker.check_first_program, longer,
                                copied=self.INPUTS)
                self.assertEqual(len(found), 1, found)
                self.assertIn(said, found[0])

    def test_a_readme_without_the_section_is_reported(self):
        said = checked(checker.check_first_program,
                       edit("README.md", r"^## Your first program$",
                            "## A first program"), copied=self.INPUTS)
        self.assertEqual(len(said), 1, said)
        self.assertIn("has 0 sections instead of one", said[0])
        self.assertTrue(checked(checker.check_first_program,
                                copied=["README.md"]))


class FromCPage(unittest.TestCase):
    """docs/from-c.md shows the files of its fixture, and all of them."""

    INPUTS = [checker.FROM_C, checker.FROM_C_FIXTURE]

    def test_the_real_page_is_its_fixture(self):
        self.assertEqual(checked(checker.check_from_c_page,
                                 copied=self.INPUTS), [])

    def test_a_file_the_page_does_not_show_as_it_is(self):
        def longer(root):
            source = sorted((root / checker.FROM_C_FIXTURE).glob("*.ldn"))[0]
            source.write_text(source.read_text() + "extra: u8 = 1\n")
        said = checked(checker.check_from_c_page, longer, copied=self.INPUTS)
        self.assertEqual(len(said), 2, said)
        self.assertTrue(any("this block is no file of" in why for why in said))
        self.assertTrue(any("the page shows no block with this file's text"
                            in why for why in said))

    def test_a_file_the_page_leaves_out_and_a_block_shown_twice(self):
        def added(root):
            (root / checker.FROM_C_FIXTURE / "unshown.ldn").write_text(
                "unshown: u8 = 1\n")
        said = checked(checker.check_from_c_page, added, copied=self.INPUTS)
        self.assertEqual(len(said), 1, said)
        self.assertIn("the page shows no block", said[0])

        def twice(root):
            page = root / checker.FROM_C
            block = re.search(r"^```landin\n.*?^```\n", page.read_text(),
                              re.M | re.S).group()
            page.write_text(page.read_text() + "\n" + block)
        said = checked(checker.check_from_c_page, twice, copied=self.INPUTS)
        self.assertEqual(len(said), 1, said)
        self.assertIn("this block repeats the one at line", said[0])

    def test_a_missing_page_is_reported_rather_than_skipped(self):
        self.assertTrue(checked(checker.check_from_c_page,
                                copied=[checker.FROM_C_FIXTURE]))


class LibraryPage(unittest.TestCase):
    """Each program docs/library.md shows is a fixture source it links."""

    SOURCE = "compiler/tests/fixtures/runtime/shown/main.ldn"
    PROGRAM = "main: () -> none =\n    x: u8 = 1\nend main\n"

    def page(self, block, link=True):
        return ("# Library\n\n## A module\n\n"
                + ("See [the fixture](../%s).\n\n" % self.SOURCE
                   if link else "")
                + "```landin\n" + block + "```\n\n## Another\n\nProse.\n")

    def said(self, block, link=True, source=True):
        written = {checker.LIBRARY_PAGE: self.page(block, link)}
        if source:
            written[self.SOURCE] = self.PROGRAM
        return checked(checker.check_library_page, written=written)

    def test_a_whole_file_and_whole_lines_of_one_pass(self):
        self.assertEqual(self.said(self.PROGRAM), [])
        self.assertEqual(self.said("    x: u8 = 1\nend main\n"), [])

    def test_a_block_that_is_no_text_of_the_fixture_is_reported(self):
        said = self.said("    x: u8 = 2\n")
        self.assertEqual(len(said), 1, said)
        self.assertIn("is not the text, or whole lines of the text", said[0])
        #  Part of a line is not whole lines.
        self.assertTrue(self.said("x: u8 = 1\n"))

    def test_a_section_that_links_nothing_or_a_missing_file(self):
        said = self.said(self.PROGRAM, link=False)
        self.assertEqual(len(said), 1, said)
        self.assertIn("links no fixture source", said[0])
        said = self.said(self.PROGRAM, source=False)
        self.assertTrue(any("which is not there" in why for why in said), said)

    def test_the_real_page_and_a_missing_one(self):
        self.assertEqual(checked(
            checker.check_library_page,
            copied=[checker.LIBRARY_PAGE, "compiler/tests/fixtures"]), [])
        self.assertTrue(checked(checker.check_library_page, written={}))


class LibraryDocumentation(unittest.TestCase):
    """Every public library declaration is documented before rendering."""

    INPUTS = ["core", "hosted", "platform", "docs/library.md", "docs/site",
              "compiler/tests", "environments/cortex-m/probes",
              "examples"]

    def test_the_real_library_is_documented(self):
        self.assertEqual(checked(checker.check_library_documentation,
                                 copied=self.INPUTS), [])

    def test_an_undocumented_public_declaration_is_reported(self):
        with tree(copied=self.INPUTS) as root:
            source = root / "core/mem/mem.ldn"
            source.write_text(source.read_text()
                              + "\npublic zz_undocumented: u32 = 1\n")
            said = checker.check_library_documentation(True)
        self.assertEqual(len(said), 1, said)
        self.assertEqual(said[0][0], "docs/library.md")
        self.assertIn("undocumented public zz_undocumented", said[0][2])


class CitationTable(unittest.TestCase):
    """`refine explain`'s constructs and decisions are the documents'."""

    INPUTS = ["spec.md", "tour.md", "docs/site", "highlight", "assets",
              checker.CITATIONS_ADA, checker.CITATION_TEXTS_ADA]

    def test_the_real_bodies_are_what_the_documents_generate(self):
        self.assertEqual(checked(checker.check_citation_table,
                                 copied=self.INPUTS), [])

    def test_a_retitled_decision_makes_the_titles_stale(self):
        with tree(copied=self.INPUTS) as root:
            edit("spec.md", r"^(### D\d+ — [^\n]+)$", r"\1 retitled")(root)
            said = checker.check_citation_table(True)
        self.assertEqual([path for path, _, _ in said],
                         [checker.CITATIONS_ADA], said)
        self.assertIn("the citations are stale", said[0][2])

    def test_an_amended_rule_makes_the_texts_stale(self):
        with tree(copied=self.INPUTS) as root:
            edit("spec.md", r"^\*\*Chosen:\*\* ", "**Chosen:** amended ")(root)
            said = checker.check_citation_table(True)
        self.assertEqual([path for path, _, _ in said],
                         [checker.CITATION_TEXTS_ADA], said)

    def test_a_number_recorded_twice_and_a_decision_without_its_rule(self):
        with tree(copied=self.INPUTS) as root:
            spec = root / "spec.md"
            text = spec.read_text()
            entry = re.search(r"^### D(\d+) — [^\n]+\n.*?(?=^### )", text,
                              re.M | re.S)
            spec.write_text(text + "\n" + entry.group())
            said = [why for _, _, why in checker.check_citation_table(True)]
            self.assertIn("D%s is recorded 2 times" % entry.group(1), said)
            spec.write_text(text + "\n### D99999 — A decision with no"
                            " rule\n\n**The alternatives:** none.\n")
            said = [why for _, _, why in checker.check_citation_table(True)]
        self.assertIn("D99999 has no `**Chosen` paragraph for `refine explain"
                      " --full`", said)

    def test_a_missing_body_is_stale(self):
        said = checked(checker.check_citation_table, copied=self.INPUTS[:-1])
        self.assertTrue(any("the citations are stale" in why for why in said))


class FixtureMetadata(unittest.TestCase):
    """A fixture's constructs are paragraphs, and its profiles its class's."""

    SPEC = "# Spec\n\n### [0380] A binding\n\nText.\n"

    def written(self, kind, meta):
        base = "compiler/tests/fixtures/%s/sample/" % kind
        return {"spec.md": self.SPEC,
                base + "fixture.meta": "class: %s\nsummary: s\n%s"
                % (kind, meta),
                base + "program.ldn": "x: u8 = 1\n"}

    def constructs(self, meta, kind="positive"):
        return reasons(lambda full: checker.fixture_constructs(),
                       written=self.written(kind, meta))

    def test_a_construct_either_document_defines_passes(self):
        self.assertEqual(self.constructs(
            "program: program.ldn\nconstructs: 0380\n"), [])
        #  A fixture about the tool carries no program and names none.
        self.assertEqual(self.constructs("args: --version\n"), [])

    def test_a_construct_no_document_defines_is_reported(self):
        said = self.constructs("program: program.ldn\nconstructs: 0380, 9990\n")
        self.assertEqual(said, ["this names [9990], which neither document"
                                " defines"])

    def test_a_malformed_construct_and_a_program_naming_none(self):
        said = self.constructs("program: program.ldn\nconstructs: 380\n")
        self.assertEqual(said, ["`380` is not a four-digit construct"])
        said = self.constructs("program: program.ldn\n")
        self.assertEqual(said, ["this carries a program and names no"
                                " construct it is evidence about"])

    def profiles(self, kind, meta):
        return reasons(lambda full: checker.fixture_profiles(),
                       written=self.written(kind, meta))

    def test_a_runtime_fixture_names_one_known_profile_set(self):
        for kind in ("runtime", "abi"):
            with self.subTest(kind=kind):
                self.assertEqual(self.profiles(kind, "profiles: standard\n"),
                                 [])
                self.assertEqual(
                    self.profiles(kind, "profiles: specialization\n"), [])
                self.assertEqual(self.profiles(kind, ""),
                                 ["exactly one profiles key is required"])
                self.assertEqual(
                    self.profiles(kind, "profiles: standard\n"
                                  "profiles: standard\n"),
                    ["exactly one profiles key is required"])
                self.assertEqual(self.profiles(kind, "profiles: fast\n"),
                                 ["profiles must be standard or"
                                  " specialization"])

    def test_another_class_names_none(self):
        self.assertEqual(self.profiles("positive", ""), [])
        self.assertEqual(self.profiles("negative", "profiles: standard\n"),
                         ["profiles belongs only to runtime or ABI"])


class Inventories(unittest.TestCase):
    """The suite, package, status, witness and notice inventories."""

    def test_the_suite_inventory_and_its_disagreements(self):
        inputs = ["compiler/ada/tests/src"]
        main = "compiler/ada/tests/src/landin_tests.adb"

        def check(full_run):
            return checker.test_suite_inventory()
        self.assertEqual(checked(check, copied=inputs), [])
        said = checked(check, edit(main, r'^\s+"harness\s+",\n', ""),
                       copied=inputs)
        self.assertEqual(said, ["expected suite names differ from source:"
                                " harness"])
        said = checked(
            check, edit(main, r"^   Landin\.Tests\.Harness_Suite\.Register"
                        r" \(Cases\);\n", ""), copied=inputs)
        self.assertEqual(said, ["suite package inventory and registration"
                                " disagree"])
        said = checked(
            check, edit(main, r"^(   Landin\.Tests\.Harness_Suite\.Register"
                        r" \(Cases\);\n)", r"\1\1"), copied=inputs)
        self.assertEqual(said, ["a suite package is registered more than"
                                " once"])
        said = checked(check, edit(main, r"Expected_Suites", "Expected"),
                       copied=inputs)
        self.assertEqual(said, ["expected suite inventory is missing"])

        def unregistered(root):
            (root / "compiler/ada/tests/src/landin-tests-empty_suite.adb"
             ).write_text("package body Landin.Tests.Empty_Suite is\n"
                          "end Landin.Tests.Empty_Suite;\n")
        said = checked(check, unregistered, copied=inputs)
        self.assertIn("suite has no named registration:"
                      " landin-tests-empty_suite.adb", said)

    def test_the_package_inventory_and_its_disagreements(self):
        inputs = ["compiler/ada/README.md", "compiler/ada/src"]
        guide = "compiler/ada/README.md"

        def check(full_run):
            return checker.compiler_package_inventory()
        self.assertEqual(checked(check, copied=inputs), [])
        row = r"^(\| `Landin\.Targets` \|[^\n]*\n)"
        said = checked(check, edit(guide, row, ""), copied=inputs)
        self.assertEqual(said, ["package ownership row is missing:"
                                " Landin.Targets"])
        said = checked(check, edit(guide, row, r"\1\1"), copied=inputs)
        self.assertEqual(said, ["package ownership row repeats:"
                                " landin.targets"])
        said = checked(
            check, edit(guide, row, r"\1| `Landin.No_Such_Package` | x |\n"),
            copied=inputs)
        self.assertEqual(said, ["package ownership row has no specification:"
                                " landin.no_such_package"])

        def hosted_name(root):
            body = root / "compiler/ada/src/stages/landin-stages-checking.adb"
            body.write_text(body.read_text()
                            + '--  Name : constant String :='
                            ' "_landin_host_write";\n')
        said = checked(check, hosted_name, copied=inputs)
        self.assertEqual(said, ["hosted identity must come from"
                                " Landin.Hosted"])
        self.assertTrue(checked(check, copied=inputs[:1]))

    def test_decision_evidence_calls_only_an_active_item_active(self):
        roadmap = ("# Roadmap\n\n### R1.10 — First\n\nStatus: active\n\n"
                   "### R1.20 — Second\n\nStatus: done\n")

        def said(owner):
            return reasons(
                lambda full: checker.decision_status_references(),
                written={"ROADMAP.md": roadmap, "spec.md":
                         "### D1 — A rule\n\n**Chosen:** it.\n\n**Pinned"
                         " by** the fixture of active %s.\n" % owner})
        self.assertEqual(said("R1.10"), [])
        self.assertEqual(said("R1.20"),
                         ["decision evidence calls R1.20 active, but"
                          " ROADMAP.md records done"])
        self.assertEqual(said("R9.90"),
                         ["decision evidence calls R9.90 active, but"
                          " ROADMAP.md records no such owner"])

    WITNESSES = ["tour.md"] + ["compiler/tests/fixtures/" + name for name in (
        "runtime/first-program", "runtime/tour-line-count",
        "runtime/tour-line-count-missing", "runtime/tour-printed-values",
        "positive/r491-tour-allocator-examples",
        "positive/match-arm-names-several-cases")]

    def test_a_tour_example_is_its_compiled_witness(self):
        def check(full_run):
            return checker.tour_example_witnesses()
        self.assertEqual(checked(check, copied=self.WITNESSES), [])
        for name, source, pattern, said in (
                ("runtime/first-program", "main.ldn", r"\Z",
                 "tour Hello, world"),
                ("runtime/tour-line-count", "main.ldn", r"\Z",
                 "tour Reading a file"),
                ("runtime/tour-printed-values", "main.ldn",
                 r"^end print_born$", "tour print_born"),
                ("positive/r491-tour-allocator-examples", "main.ldn",
                 r"^end make_widget$", "tour make_widget"),
                ("positive/match-arm-names-several-cases", "program.ldn",
                 r"^end describe$", "tour describe")):
            with self.subTest(name=name):
                where = "compiler/tests/fixtures/%s/%s" % (name, source)
                found = checked(check, edit(where, pattern, "\n-- changed\n"),
                                copied=self.WITNESSES)
                self.assertEqual(
                    found, ["compiled witness differs from " + said], found)

    def test_a_shared_routine_s_copy_is_the_published_text(self):
        published, copies = sorted(checker.SHARED_ROUTINES.items())[0]
        copy, names = sorted(copies.items())[0]
        every = sorted({path for source, held in
                        checker.SHARED_ROUTINES.items()
                        for path in [source, *held]})

        def check(full_run):
            return checker.shared_routine_witnesses()
        self.assertEqual(checked(check, copied=every), [])
        end = r"^end %s$" % re.escape(names[0])
        said = checked(check, edit(copy, end, "    -- differs\n"
                                   "end " + names[0]), copied=every)
        self.assertEqual(len(said), 1, said)
        self.assertIn("%s differs from %s's" % (names[0], published), said[0])
        self.assertIn(checker.SYNC_ROUTINES, said[0])
        said = checked(check, edit(published, r"^%s: " % names[0],
                                   "renamed: "), copied=every)
        self.assertTrue(any("the shared routine %s is not declared here"
                            % names[0] in why for why in said), said)
        self.assertTrue(any("needed by a check" in why for why in checked(
            check, copied=[one for one in every if one != copy])))

    NOTICES = ["LICENSE", "assets/icons.py",
               "assets/fonts/nunito-sans/OFL.txt",
               "highlight/tree-sitter/src/tree_sitter/LICENSE",
               "devices/notices/LICENSE.pico-sdk",
               "devices/notices/LICENSE-Apache-2.0.stm32h7",
               "devices/notices/LICENSE-Apache-2.0.cmsis"]

    def test_the_root_inventory_names_every_vendored_notice(self):
        def check(full_run):
            return checker.third_party_notices()
        self.assertEqual(checked(check, copied=self.NOTICES), [])
        notice = "devices/notices/LICENSE.pico-sdk"
        def unnamed(root):
            inventory = root / "LICENSE"
            self.assertIn(notice, inventory.read_text())
            inventory.write_text(re.sub(re.escape(notice),
                                        "devices/notices/LICENSE.other",
                                        inventory.read_text()))
        said = checked(check, unnamed, copied=self.NOTICES)
        self.assertEqual(said, ["missing third-party notice: " + notice])
        said = checked(check, edit(notice, r"Raspberry Pi \(Trading\) Ltd",
                                   "Somebody"), copied=self.NOTICES)
        self.assertEqual(said, ["notice attribution is missing: Raspberry Pi"
                                " (Trading) Ltd"])
        said = checked(check, copied=[one for one in self.NOTICES
                                      if one != notice])
        self.assertEqual(said, ["vendored material's notice is missing"])


if __name__ == "__main__":
    unittest.main()
