#!/usr/bin/env python3
"""A reworded document is told about the control that quotes it by check.py.

A control of check.py's copies a real document and changes one place in
it; it finds the place by the document's words.  Those words are listed in
scripts/tests/control_quotes.json, check.py holds each document to still
saying them, and the controls take them through `check_controls.quote`.

Three things are held here.  check.py's check fires on a reworded document
and names the quote, the list and the command.  A control that passes a
document's own words to `replace`, `split`, `partition`, `index` or the
roadmap controls' `once` as a literal, without `quote`, is refused: that
is the quote nobody would be told about.  And the list holds nothing no
control uses.

What this cannot see is said plainly: a quote assembled at run time, from
a name read out of the roadmap, has no fixed text to list.
"""
import ast
import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from check_controls import QUOTES, ROOT, checker, quote, tree  # noqa: E402

#  The modules whose controls look for a real document's words, each with
#  the documents every one of its functions is read against: the library
#  page's controls read the rendered page, and name no file where they do.
CONTROLS = {"scripts/tests/test_check_controls.py": (),
            "scripts/tests/test_library_docs.py": ("docs/library.md",)}
QUOTING = ("replace", "split", "rsplit", "partition", "rpartition", "index")
#  The roadmap controls' own helper, which edits ROADMAP.md.
ROADMAP_EDIT = "once"


def literal(node):
    return (node.value if isinstance(node, ast.Constant)
            and isinstance(node.value, str) else None)


def unlisted(source, documents, always=()):
    """(line, text, document) for each bare literal quoting a document.

    DOCUMENTS is {path: text}.  A function is read against the documents
    it names, against ROADMAP.md when it calls ROADMAP_EDIT, and against
    ALWAYS.  A document the function does not name is matched by prose
    only, a literal with a space in it: a module's name or one word is on
    the rendered page from the library's sources as well, and listing it
    would tell a writer of the page about a control it does not reach.
    """
    found = []
    for function in ast.walk(ast.parse(source)):
        if not isinstance(function, ast.FunctionDef):
            continue
        calls = [node for node in ast.walk(function)
                 if isinstance(node, ast.Call) and node.args]
        #  A document named only as quote()'s own argument is not one the
        #  function reads a copy of.
        through = {id(call.args[0]) for call in calls
                   if isinstance(call.func, ast.Name)
                   and call.func.id == "quote"}
        named = {text for node in ast.walk(function)
                 for text in [literal(node)]
                 if text in documents and id(node) not in through}
        unnamed = set(always) - named
        named.update(always)
        if any(isinstance(call.func, ast.Name)
               and call.func.id == ROADMAP_EDIT for call in calls):
            named.add("ROADMAP.md")
        for call in calls:
            quoting = (isinstance(call.func, ast.Attribute)
                       and call.func.attr in QUOTING) or (
                isinstance(call.func, ast.Name)
                and call.func.id == ROADMAP_EDIT)
            text = literal(call.args[0])
            if not quoting or text is None or len(text) < 4:
                continue
            for document in sorted(named):
                if document in unnamed and " " not in text:
                    continue
                if text in documents.get(document, ""):
                    found.append((call.lineno, text, document))
                    break
    return found


def used(source):
    """The (document, text) pairs SOURCE passes to quote()."""
    return {(literal(call.args[0]), literal(call.args[1]))
            for call in ast.walk(ast.parse(source))
            if isinstance(call, ast.Call) and isinstance(call.func, ast.Name)
            and call.func.id == "quote" and len(call.args) == 2}


class ControlQuotes(unittest.TestCase):
    def setUp(self):
        self.quotes = json.loads((ROOT / QUOTES).read_text(encoding="utf-8"))

    def test_every_document_says_what_is_quoted_from_it(self):
        self.assertEqual(checker.check_control_quotes(True), [])
        self.assertEqual(checker.CONTROL_QUOTES, QUOTES)

    def test_a_reworded_document_is_told_which_quote_it_broke(self):
        document = "docs/format.md"
        text = self.quotes[document][0]
        with tree(copied=[document],
                  written={QUOTES: json.dumps({document: [text]})}) as root:
            self.assertEqual(checker.check_control_quotes(True), [])
            page = root / document
            page.write_text(page.read_text().replace(text, "Reworded.\n"))
            said = checker.check_control_quotes(True)
        self.assertEqual(len(said), 1, said)
        path, _, why = said[0]
        self.assertEqual(path, document)
        self.assertIn("no longer says " + json.dumps(text), why)
        self.assertIn("reword the quote in " + QUOTES, why)
        self.assertIn("python3 scripts/script_tests.py test_check_controls",
                      why)

    def test_a_missing_or_unreadable_list_is_reported(self):
        with tree(written={"README.md": "# Root\n"}):
            self.assertIn("missing", checker.check_control_quotes(True)[0][2])
        with tree(written={QUOTES: '{"README.md": [""]}'}):
            self.assertIn("unreadable",
                          checker.check_control_quotes(True)[0][2])
        with tree(written={QUOTES: '{"docs/gone.md": ["words"]}'}):
            self.assertIn("quotes docs/gone.md, which is not here",
                          checker.check_control_quotes(True)[0][2])

    def test_no_control_quotes_a_document_without_listing_it(self):
        documents = {
            str(path.relative_to(ROOT)): path.read_text(encoding="utf-8")
            for path in list(ROOT.glob("*.md")) + list(ROOT.glob("docs/*.md"))}
        for name, always in CONTROLS.items():
            bare = unlisted((ROOT / name).read_text(encoding="utf-8"),
                            documents, always)
            self.assertEqual(bare, [], "\n" + "\n".join(
                "%s:%d: %r is %s's text; write quote(%r, ...) and list it in "
                "%s, so that check.py tells whoever rewords the document"
                % (name, line, text, document, document, QUOTES)
                for line, text, document in bare))

    def test_a_bare_quote_is_found_and_a_listed_one_is_not(self):
        documents = {"docs/page.md": "# Page\n\nThe first sentence.\n",
                     "ROADMAP.md": "## Register\n\nWork that waits.\n"}
        source = (
            "def test_one(self):\n"
            "    with tree(copied=['docs/page.md']) as root:\n"
            "        text.replace('The first sentence.', 'x')\n"
            "        text.replace(quote('docs/page.md', '# Page'), 'x')\n"
            "        text.replace('not the page', 'x')\n"
            "def test_two(self):\n"
            "    once('Work that waits.', 'x')\n"
            "    once('| %s |' % name, 'x')\n")
        self.assertEqual(unlisted(source, documents), [
            (3, "The first sentence.", "docs/page.md"),
            (7, "Work that waits.", "ROADMAP.md")])
        #  A module read against a page none of its functions name.
        rendered = ("def test_three(self):\n"
                    "    read.index('The first sentence.')\n"
                    "    read.index('Page')\n")
        self.assertEqual(unlisted(rendered, documents, ("docs/page.md",)),
                         [(2, "The first sentence.", "docs/page.md")])

    def test_the_list_holds_only_what_a_control_uses(self):
        listed = {(document, text) for document, texts in self.quotes.items()
                  for text in texts}
        taken = set()
        for name in CONTROLS:
            taken |= used((ROOT / name).read_text(encoding="utf-8"))
        self.assertEqual(listed, taken)

    def test_quote_refuses_text_the_list_does_not_hold(self):
        self.assertEqual(quote("docs/format.md",
                               self.quotes["docs/format.md"][0]),
                         self.quotes["docs/format.md"][0])
        with self.assertRaisesRegex(AssertionError, "list it there"):
            quote("docs/format.md", "words no control listed")


if __name__ == "__main__":
    unittest.main()
