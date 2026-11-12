#!/usr/bin/env python3
"""assets/fonts.py reads a family's stylesheet without trusting it.

The licensed family's stylesheet is fetched at publish time from storage
outside the repository, and what the module makes of it lands inside a
`<style>` element on every page.  These cases give the module a stylesheet
that tries to leave that element, a declaration or the fonts directory, a
pinned file that changed, and a source to fetch from that names files it
should not.  A bare `--fetch` fills the cache from the project's storage,
replaces only a directory a fetch made, and keeps the earlier copy when
the new one is refused.
"""
import contextlib
import hashlib
import io
import os
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "assets"))
import fonts  # noqa: E402

HEADER = "/*! MonoLisa, licensed to one site. @preserve */\n"
FACE = """@font-face {
  font-family: 'MonoLisaCode';
  font-style: %(style)s;
  font-weight: 100 900;
  src: url(%(url)s) format('woff2');
  unicode-range: U+0000-00FF, U+26??;
%(more)s}
"""


class Licensed(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / "source"
        saved = fonts.PINS, os.environ.get(fonts.LICENSED_VAR)
        fonts.PINS = self.root / "licensed.sha256"
        os.environ[fonts.LICENSED_VAR] = str(self.source)

        def restore():
            fonts.PINS = saved[0]
            if saved[1] is None:
                os.environ.pop(fonts.LICENSED_VAR, None)
            else:
                os.environ[fonts.LICENSED_VAR] = saved[1]
        self.addCleanup(restore)

    def family(self, header=HEADER, url="/woff2/0-MonoLisa.woff2", more="",
               style="normal", files=("0-MonoLisa.woff2",)):
        folder = self.source / "monolisa"
        (folder / "woff2").mkdir(parents=True, exist_ok=True)
        for name in files:
            (folder / "woff2" / name).write_bytes(b"wOF2 " + name.encode())
        (folder / "LICENSE.md").write_text("terms\n")
        (self.source / "README.md").write_text("the faces\n")
        (folder / "monolisa.css").write_text(
            header + FACE % dict(url=url, more=more, style=style))

    def refused(self, words):
        with self.assertRaises(ValueError) as raised:
            fonts.css()
        self.assertIn(words, str(raised.exception))

    def test_a_plain_stylesheet_is_rebuilt_from_its_descriptors(self):
        self.family()
        block = fonts.css()
        self.assertIn(HEADER.strip(), block)
        self.assertIn('@font-face{src:url(fonts/0-MonoLisa.woff2) format("woff2");'
                      "font-family:'MonoLisaCode';font-style:normal;"
                      "font-weight:100 900;unicode-range:U+0000-00FF, U+26??;"
                      "font-display:swap}", block)
        self.assertNotIn("<", block)

    def test_a_header_that_would_end_the_style_element_is_refused(self):
        self.family(header="/*! licence </style><script>alert(1)</script><style> */\n")
        self.refused("preserved header holds a '<'")

    def test_a_value_that_is_more_than_a_value_is_refused(self):
        self.family(style="normal</style><script>alert(1)</script><style>")
        self.refused("font-style is")
        self.family(more="  font-display: swap} body{display:none;\n")
        self.assertNotIn("body", fonts.css())
        self.family(more="  font-stretch: url(https://example.org/x);\n")
        self.refused("font-stretch is")

    def test_a_declaration_the_pages_do_not_carry_is_refused(self):
        self.family(more="  background: red;\n")
        self.refused("declares background")

    def test_a_face_named_outside_the_fonts_directory_is_refused(self):
        for url in ("../../../docs/site/render_html.py", "/woff2/..woff2", "/woff2/a b.woff2",
                    "/woff2/x.woff2?</style>"):
            self.family(url=url)
            self.refused("a face's file is named")

    def test_a_pinned_file_that_changed_is_refused(self):
        self.family()
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(fonts.main(["--pin"]), 0)
        pinned = fonts.pins()
        self.assertEqual(sorted(pinned), ["monolisa/monolisa.css",
                                          "monolisa/woff2/0-MonoLisa.woff2"])
        self.assertEqual(pinned["monolisa/woff2/0-MonoLisa.woff2"],
                         hashlib.sha256(b"wOF2 0-MonoLisa.woff2").hexdigest())
        fonts.css()
        face = self.source / "monolisa/woff2/0-MonoLisa.woff2"
        face.write_bytes(b"another face")
        self.refused("monolisa/woff2/0-MonoLisa.woff2 is not the file")
        self.family()
        sheet = self.source / "monolisa/monolisa.css"
        sheet.write_text(sheet.read_text() + "/* a later edit */\n")
        self.refused("monolisa/monolisa.css is not the file")
        # A face the stylesheet came to name after the pin is not pinned.
        self.family(url="/woff2/1-MonoLisa.woff2", files=("1-MonoLisa.woff2",))
        fonts.PINS.write_text("%s  monolisa/monolisa.css\n" % hashlib.sha256(
            sheet.read_bytes()).hexdigest())
        self.refused("monolisa/woff2/1-MonoLisa.woff2 is not pinned")
        fonts.PINS.write_text("not a pin\n")
        self.refused("not a DIGEST  PATH line")

    def fetch(self):
        said = io.StringIO()
        with contextlib.redirect_stdout(said):
            status = fonts.main(["--fetch", self.source.as_uri(), str(self.root / "fetched")])
        return status, said.getvalue()

    def test_fetch_takes_the_faces_the_stylesheet_names(self):
        self.family()
        status, said = self.fetch()
        self.assertEqual(status, 0, said)
        fetched = self.root / "fetched"
        self.assertEqual(sorted(path.relative_to(fetched).as_posix()
                                for path in fetched.rglob("*") if path.is_file()),
                         [fonts.FETCHED, "README.md", "monolisa/LICENSE.md",
                          "monolisa/monolisa.css", "monolisa/woff2/0-MonoLisa.woff2"])
        # Unpinned, it says so where the run's summary shows it.
        self.assertIn("::warning::the licensed face is not pinned", said)
        # It refuses to fetch over something that is already there.
        status, said = self.fetch()
        self.assertEqual(status, 1)
        self.assertIn("wants a new directory", said)

    def test_fetch_writes_nothing_a_stylesheet_names_outside_woff2(self):
        victim = self.root / "render_html.py"
        victim.write_text("the renderer\n")
        (self.source / "served.py").parent.mkdir(parents=True)
        (self.source / "served.py").write_text("print('served by the bucket')\n")
        for url in ("../../render_html.py", "../served.py", "/woff2/../../served.py",
                    "/served.py", "woff2/sub/x.woff2"):
            with self.subTest(url=url):
                self.family(url=url)
                status, said = self.fetch()
                self.assertEqual(status, 1, said)
                self.assertIn("which is not woff2/FILE.woff2", said)
                self.assertEqual(victim.read_text(), "the renderer\n")
                # Nothing of the refused fetch is left, under its name or beside it.
                self.assertEqual(sorted(path.name for path in self.root.iterdir()),
                                 ["render_html.py", "source"])

    def test_fetch_holds_what_arrived_to_the_pins(self):
        self.family()
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(fonts.main(["--pin"]), 0)
        (self.source / "monolisa/woff2/0-MonoLisa.woff2").write_bytes(b"replaced in the bucket")
        os.environ[fonts.LICENSED_VAR] = str(self.root / "nowhere")
        status, said = self.fetch()
        self.assertEqual(status, 1, said)
        self.assertIn("is not the file licensed.sha256 pins", said)

    def bare_fetch(self):
        said = io.StringIO()
        with contextlib.redirect_stdout(said):
            status = fonts.main(["--fetch"])
        return status, said.getvalue()

    def test_a_bare_fetch_fills_the_cache_from_the_project_s_storage(self):
        self.family()
        saved = fonts.LICENSED_SOURCE, os.environ.get("XDG_CACHE_HOME")
        self.addCleanup(lambda: (setattr(fonts, "LICENSED_SOURCE", saved[0]),
                                 os.environ.pop("XDG_CACHE_HOME", None) if saved[1] is None
                                 else os.environ.__setitem__("XDG_CACHE_HOME", saved[1])))
        fonts.LICENSED_SOURCE = self.source.as_uri()
        os.environ["XDG_CACHE_HOME"] = str(self.root / "cache")
        os.environ.pop(fonts.LICENSED_VAR)
        cache = self.root / "cache/landin/fonts"
        self.assertEqual(fonts.licensed_root(), cache)
        self.assertEqual(fonts.missing(), ["MonoLisaCode"])
        status, said = self.bare_fetch()
        self.assertEqual(status, 0, said)
        self.assertIn("fetched into %s" % cache, said)
        self.assertEqual(fonts.missing(), [])
        self.assertIn("0-MonoLisa.woff2", [name for name, _ in fonts.files()])
        # Fetching again replaces what the first fetch made.
        (self.source / "monolisa/woff2/0-MonoLisa.woff2").write_bytes(b"wOF2 the next one")
        status, said = self.bare_fetch()
        self.assertEqual(status, 0, said)
        self.assertEqual((cache / "monolisa/woff2/0-MonoLisa.woff2").read_bytes(),
                         b"wOF2 the next one")
        # A fetch that is refused leaves the copy it would have replaced.
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(fonts.main(["--pin"]), 0)
        (self.source / "monolisa/woff2/0-MonoLisa.woff2").write_bytes(b"changed in storage")
        status, said = self.bare_fetch()
        self.assertEqual(status, 1, said)
        self.assertIn("is not the file licensed.sha256 pins", said)
        self.assertEqual((cache / "monolisa/woff2/0-MonoLisa.woff2").read_bytes(),
                         b"wOF2 the next one")
        self.assertEqual(sorted(path.name for path in cache.parent.iterdir()), ["fonts"])

    def test_a_bare_fetch_replaces_only_a_directory_a_fetch_made(self):
        self.family()
        saved = fonts.LICENSED_SOURCE
        self.addCleanup(setattr, fonts, "LICENSED_SOURCE", saved)
        fonts.LICENSED_SOURCE = self.source.as_uri()
        mine = self.root / "mine"
        (mine / "monolisa").mkdir(parents=True)
        (mine / "monolisa/notes.txt").write_text("a developer's own files\n")
        os.environ[fonts.LICENSED_VAR] = str(mine)
        status, said = self.bare_fetch()
        self.assertEqual(status, 1, said)
        self.assertIn("was not made by --fetch, so it is not replaced", said)
        self.assertEqual((mine / "monolisa/notes.txt").read_text(), "a developer's own files\n")
        self.assertEqual(sorted(path.name for path in self.root.iterdir()), ["mine", "source"])



class Vendored(unittest.TestCase):
    def test_the_vendored_family_reads_and_carries_no_markup(self):
        block = fonts.css()
        self.assertIn("@font-face{src:url(fonts/", block)
        self.assertNotIn("<", block)


if __name__ == "__main__":
    unittest.main()
