#!/usr/bin/env python3
"""What the site renderer refuses, reads and verifies beyond its word count.

`render_html.py --verify` holds that every word of a document is on its
page, which a page can satisfy while it carries a link that runs script, a
fenced block read as prose, an anchor that leads nowhere, or a primer short
of half its table.  Each case here gives the renderer one of those.
"""
import contextlib
import io
from pathlib import Path
import shutil
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "docs/site"))
import llms  # noqa: E402
import render_html  # noqa: E402


def inline(text):
    targets = render_html.guide_targets(render_html.DOCS + render_html.GUIDES, "README.md")
    return render_html.inline(text, lambda ref: None, targets)


class LinkTargets(unittest.TestCase):
    def test_addresses_and_repository_paths_are_linked(self):
        self.assertIn('<a href="https://example.org/a?b=1&amp;c=2">x</a>',
                      inline("[x](https://example.org/a?b=1&c=2)"))
        self.assertIn('href="mailto:someone@example.org"', inline("[x](mailto:someone@example.org)"))
        self.assertIn('<a href="process.html#the-loop-that-runs-now" '
                      'data-source-href="docs/process.md#the-loop-that-runs-now">the loop</a>',
                      inline("[the loop](docs/process.md#the-loop-that-runs-now)"))
        self.assertIn('<a href="#installing">', inline("[x](#installing)"))

    def test_a_target_that_runs_script_stops_the_build(self):
        for target in ("javascript:alert%28document.domain%29", "JavaScript:alert`1`",
                       "data:text/html,x", "vbscript:x", "file:///etc/passwd"):
            with self.subTest(target=target), self.assertRaises(SystemExit) as stopped:
                inline("[install](%s)" % target)
            self.assertIn("render_html: a link", str(stopped.exception))

    def test_a_target_that_would_leave_its_attribute_stops_the_build(self):
        for target in ('https://example.org/" onmouseover="alert`1`" x="',
                       'docs/process.md" onmouseover="alert`1`',
                       "docs/process.md' x='", "https://example.org/a b",
                       "https://example.org/<script>", "java\tscript:x"):
            with self.subTest(target=target), self.assertRaises(SystemExit) as stopped:
                inline("[x](%s)" % target)
            self.assertIn("no address is written with", str(stopped.exception))

    def test_markup_in_prose_is_still_text(self):
        self.assertEqual(inline("raw <script>alert(1)</script>"),
                         "raw &lt;script&gt;alert(1)&lt;/script&gt;")


class Fences(unittest.TestCase):
    def blocks(self, text):
        title, lead, sections = render_html.parse_guide(text)
        return lead + [block for section in sections for block in section["blocks"]]

    def test_a_fence_under_a_list_item_is_a_block_and_not_a_paragraph(self):
        blocks = self.blocks(
            "1. Run the check:\n"
            "\n"
            "   ```sh\n"
            "   python3 check.py \\\n"
            "       --catalogue\n"
            "   ```\n"
            "\n"
            "2. Substitute **exactly**:\n"
            "   ```text\n"
            "   **Current: [ITEM](x)**\n"
            "   ```\n"
            "   and go on.\n")
        self.assertEqual([kind for kind, _ in blocks],
                         ["list", "code", "list", "code", "para"])
        # The list's indentation is not the code's, and the code is not prose.
        self.assertEqual(blocks[1][1], ("sh", ["python3 check.py \\", "    --catalogue"]))
        self.assertEqual(blocks[3][1], ("text", ["**Current: [ITEM](x)**"]))
        self.assertEqual(blocks[2][1], (True, [[2, "Substitute **exactly**:"]]))

    def test_a_fence_at_the_margin_reads_as_before(self):
        blocks = self.blocks("```landin\nx := 1\n   ```\n  y := 2\n```\nafter\n")
        self.assertEqual(blocks, [("code", ("landin", ["x := 1", "   ```", "  y := 2"])),
                                  ("para", ["after"])])

    def test_an_indented_fence_that_is_never_closed_stops_the_build(self):
        with self.assertRaises(SystemExit) as stopped:
            self.blocks("- an item\n\n  ```sh\n  true\n```\n")
        self.assertIn("is never closed", str(stopped.exception))


class Fragments(unittest.TestCase):
    def said(self, pages, names=None, complete=True):
        with tempfile.TemporaryDirectory() as tmp:
            for name, text in pages.items():
                (Path(tmp) / name).write_text(text)
            printed = io.StringIO()
            with contextlib.redirect_stdout(printed):
                ok = render_html.verify_fragments(Path(tmp), names or sorted(pages), complete)
        return ok, printed.getvalue()

    def test_fragments_that_lead_to_ids_pass(self):
        ok, said = self.said({
            "a.html": '<h2 id="one">One</h2><a href="#one">x</a><a href="b.html#two">y</a>'
                      '<a href="https://example.org/#elsewhere">z</a><a href="b.html">w</a>'
                      '<a href="notes.txt#line">t</a>',
            "b.html": '<h2 id="two">Two</h2><a href="a.html#one">back</a>'})
        self.assertTrue(ok, said)

    def test_a_fragment_that_leads_nowhere_is_reported(self):
        ok, said = self.said({
            "a.html": '<a href="#nowhere">x</a><a href="b.html#no-such-heading">y</a>',
            "b.html": '<h2 id="two">Two</h2>'})
        self.assertFalse(ok)
        self.assertIn("a.html: #nowhere leads to no id", said)
        self.assertIn("a.html: b.html#no-such-heading leads to no id", said)

    def test_an_id_on_a_page_twice_is_reported(self):
        ok, said = self.said({"a.html": '<h3 id="details">Details</h3><h3 id="details">Details</h3>'})
        self.assertFalse(ok)
        self.assertIn("the id 'details' is on the page more than once", said)

    def test_a_page_that_is_not_there_is_a_fault_of_a_complete_render_only(self):
        pages = {"a.html": '<a href="absent.html#x">x</a>'}
        self.assertFalse(self.said(pages)[0])
        self.assertTrue(self.said(pages, complete=False)[0])


class Primer(unittest.TestCase):
    TABLES = [path for _, path, _ in llms.REFUSAL_TABLES]

    def tree(self, change=None):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        for path in self.TABLES:
            (root / path).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(ROOT / path, root / path)
        if change:
            change(root)
        return root

    def test_both_tables_are_read_whole(self):
        rows = llms.refusals(self.tree())
        self.assertEqual({whose for whose, *_ in rows}, {"the parser", "the checker"})
        for path, kind in ((self.TABLES[0], "Refused_Construct"), (self.TABLES[1], "Refused_Use")):
            text = (ROOT / path).read_text()
            self.assertGreater(len(llms.literals(text, kind)), 3)
        self.assertTrue(any(spelt for _, _, spelt, _, _ in rows))

    def test_a_table_that_is_not_there_stops_the_build(self):
        with self.assertRaises(SystemExit) as stopped:
            llms.refusals(self.tree(lambda root: (root / self.TABLES[0]).unlink()))
        self.assertIn("is not there", str(stopped.exception))

    def test_a_table_that_reads_as_nothing_stops_the_build(self):
        # One table still yields rows in each case, which is what let the
        # combined "nothing read" guard pass.
        def renamed(function, kind, path):
            def change(root):
                text = (root / path).read_text()
                old = "function %s (Item : %s)" % (function, kind)
                self.assertEqual(text.count(old), 1, old)
                (root / path).write_text(text.replace(old, old.replace("Item", "Kind")))
            return change

        for function, kind, path in (("Construct", "Refused_Use", self.TABLES[1]),
                                     ("Construct", "Refused_Construct", self.TABLES[0]),
                                     ("Standing", "Refused_Construct", self.TABLES[0]),
                                     ("Spelling", "Refused_Type_Name", self.TABLES[1]),
                                     ("Refusal", "Refused_Type_Name", self.TABLES[1])):
            with self.subTest(function=function, kind=kind):
                with self.assertRaises(SystemExit) as stopped:
                    llms.refusals(self.tree(renamed(function, kind, path)))
                self.assertIn("%s over %s was read for 0 of its" % (function, kind),
                              str(stopped.exception))

    def test_the_index_counts_the_programs_on_the_examples_page(self):
        programs = len([line for line in (ROOT / "examples.md").read_text().splitlines()
                        if line.startswith("Fixture source: ")])
        self.assertGreater(programs, 11)
        pages = [dict(key="examples", nav="running examples", out="examples.html")]
        text = llms.index(pages, "https://www.701.dev", "0.0.0",
                          dict(primer="1 KB", full="2 KB"), programs)
        self.assertIn("examples.html): %d complete programs" % programs, text)
        self.assertNotIn("eleven", text)


if __name__ == "__main__":
    unittest.main()
