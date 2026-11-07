"""Focused controls for split-library links in the site renderer."""
import tempfile
import unittest
from pathlib import Path

import render_html


class LibraryLinks(unittest.TestCase):
    def test_resolves_split_and_index_fragments(self):
        render_html.LIBRARY_SECTIONS.clear()
        render_html.LIBRARY_SECTIONS["the-buffered-writer"] = "library-core-io.html"
        targets = render_html.guide_targets([], "tour.md")
        self.assertEqual(targets.resolve("docs/library.md#the-buffered-writer"),
                         "library-core-io.html#the-buffered-writer")
        self.assertEqual(targets.resolve("docs/library.md#introduction"),
                         "library.html#introduction")

    def test_verifier_rejects_a_missing_destination_anchor(self):
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory)
            (out / "tour.html").write_text('<a href="library-core-io.html#writer">writer</a>')
            (out / "library-core-io.html").write_text('<section id="writer"></section>')
            docs = [{"out": "tour.html"}]
            self.assertTrue(render_html.verify_library_links(out, docs))
            (out / "library-core-io.html").write_text('<section id="other"></section>')
            self.assertFalse(render_html.verify_library_links(out, docs))


if __name__ == "__main__":
    unittest.main()
