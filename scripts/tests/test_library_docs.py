"""Source attachment, coverage and generated-link controls for library docs."""
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'docs/site'))
import library
import render_html


class Declarations(unittest.TestCase):
    def read(self, text):
        return library.read_items(text, 'core/demo/demo.ldn')

    def test_docs_attach_only_to_immediately_following_line(self):
        for separator in ('\n', '-- ordinary\n', 'private: atom\n'):
            with self.subTest(separator=separator), self.assertRaisesRegex(ValueError, 'undocumented'):
                self.read('--- Detached.\n' + separator + 'public value: atom\n')
        result = self.read('--- First.\n---\n--- Second.\npublic value: atom\n')
        self.assertEqual(result[0].documentation, 'First.\n\nSecond.')

    def test_trailing_docs_do_not_attach(self):
        with self.assertRaisesRegex(ValueError, 'undocumented'):
            self.read('private: atom --- Trailing.\npublic value: atom\n')

    def test_multiline_signature_excludes_body_and_ignores_literals(self):
        text = '''--( public imaginary: atom )--
private: []u8 = "public hidden: atom"
--- Copy one value.
public copy: (value: i32)
             -> (result: i32) =
    result = value
end copy
'''
        result = self.read(text)
        self.assertEqual([i.name for i in result], ['copy'])
        self.assertEqual(result[0].line, 4)
        self.assertNotIn('result =', result[0].signature)
        self.assertIn('-> (result: i32)', result[0].signature)

    def test_concept_entries_and_struct_fields_are_preserved(self):
        text = '''--- Input capability.
public reader: type = concept (provider: type)
    --- Return input.
    read: (self: ptr provider) -> (byte: u8)
end reader
--- A pair.
public pair: type = struct
    first: u32
    second: u32
end pair
'''
        result = self.read(text)
        self.assertEqual([i.kind for i in result], ['concept', 'type'])
        self.assertIn('--- Return input.', result[0].signature)
        self.assertIn('second: u32', result[1].signature)

    def test_target_branches_are_not_silently_collapsed(self):
        items = self.read('''fixed if compiler.c_aapcs64_lp64 then
    --- Unsigned char.
    public c_char: type = u8
else
    --- Signed char.
    public c_char: type = i8
end if
''')
        self.assertEqual(len(items), 2)
        self.assertEqual(items[0].condition, 'compiler.c_aapcs64_lp64')
        self.assertEqual(items[1].condition, 'not (compiler.c_aapcs64_lp64)')
        self.assertEqual(items[0].anchor, items[1].anchor)

    def test_unknown_public_form_and_unclosed_type_fail(self):
        with self.assertRaisesRegex(ValueError, 'unsupported public'):
            self.read('--- Forward.\npublic import core/mem\n')
        with self.assertRaisesRegex(ValueError, 'unsupported public'):
            self.read('fixed if compiler.hosted then public hidden: atom\n')
        with self.assertRaisesRegex(ValueError, 'unsupported multiline'):
            self.read('--- Union.\npublic choice: type = one |\n    two\n')
        with self.assertRaisesRegex(ValueError, 'unclosed'):
            self.read('--- Broken.\npublic broken: type = struct\n')

    def test_literal_and_comment_payloads_cannot_create_exports(self):
        text = '''private: []u8 = """
public string_fake: atom
"""
--(
--- Comment fake.
public comment_fake: atom
)--
--- Real.
public real: atom
'''
        self.assertEqual([i.name for i in self.read(text)], ['real'])

    def test_all_live_exports_have_documentation_and_an_overview(self):
        modules, sources = library.collect(ROOT)
        _, descriptions = library.overviews(ROOT, modules)
        self.assertEqual(set(modules), set(descriptions))
        self.assertTrue(all(i.documentation for items in modules.values() for i in items))
        for items in modules.values():
            for item in items:
                self.assertIn('public ' + item.name + ':', sources[item.source].splitlines()[item.line-1])


class GeneratedReference(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.destination = Path(cls.temp.name)
        result = subprocess.run([sys.executable, str(ROOT / 'docs/site/render_html.py'),
                                 '--from', str(ROOT), '--to', cls.temp.name, '--verify'],
                                capture_output=True, text=True)
        if result.returncode:
            cls.temp.cleanup()
            raise AssertionError(result.stdout + result.stderr)
        cls.modules, _ = library.collect(ROOT)
        cls.pages = [p.name for p in cls.destination.glob('library*.html')]

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def test_every_export_is_searchable_with_a_stable_destination(self):
        index = json.loads((self.destination / 'library-index.json').read_text())
        wanted = {m + '.' + i.name for m, items in self.modules.items() for i in items}
        self.assertEqual({i['name'] for i in index}, wanted)
        self.assertEqual(len(index), len(wanted))
        for item in index:
            page, anchor = item['url'].split('#')
            self.assertIn('id="' + anchor + '"', (self.destination / page).read_text())
        self.assertIn('library.html', (self.destination / 'sitemap.xml').read_text())
        self.assertIn('library.html', (self.destination / 'index.html').read_text())
        self.assertIn('href="library.html"', (self.destination / 'readme.html').read_text())
        self.assertIn('library-index.json', (self.destination / 'llms.txt').read_text())

    def test_missing_item_prose_is_detected_despite_search_and_source_copies(self):
        target = self.destination / 'library-core-vec.html'
        original = target.read_text()
        # The search JSON also holds the summary: remove only the visible text.
        start = original.index('<section class="api-item" id="item-new">')
        changed = original[:start] + original[start:].replace('Create an empty list without allocating.', 'Omitted.', 1)
        self.assertNotEqual(original, changed)
        try:
            target.write_text(changed)
            with self.assertRaisesRegex(ValueError, 'lost words'):
                library.verify(self.destination, self.pages, self.modules, render_html)
        finally:
            target.write_text(original)

    def test_missing_source_anchor_is_detected(self):
        target = self.destination / 'library-core-vec.html'
        original = target.read_text()
        changed = re.sub(r'(library-source-core-vec-vec-ldn.html)#L\d+', r'\1#L999999', original, count=1)
        try:
            target.write_text(changed)
            with self.assertRaisesRegex(ValueError, 'missing link anchor'):
                library.verify(self.destination, self.pages, self.modules, render_html)
        finally:
            target.write_text(original)

    def test_source_listing_text_is_verified_independently(self):
        target = self.destination / library.source_name('core/vec/vec.ldn')
        original = target.read_text()
        start = original.index('<span class="api-source-line"')
        changed = original[:start] + original[start:].replace('Growable', 'Changed', 1)
        self.assertNotEqual(original, changed)
        _, sources = library.collect(ROOT)
        try:
            target.write_text(changed)
            with self.assertRaisesRegex(ValueError, 'source listing changed text'):
                library.verify(self.destination, self.pages, self.modules, render_html, sources)
        finally:
            target.write_text(original)

    def test_search_is_local_and_handles_no_script_readers(self):
        text = (self.destination / 'library-core-io.html').read_text()
        self.assertIn('type="application/json" id="api-search-data"', text)
        self.assertIn('<noscript>', text)
        self.assertIn('aria-controls="api-results"', text)
        self.assertNotIn('fetch(', library.SEARCH)
        self.assertIn('textContent=item.name', library.SEARCH)


if __name__ == '__main__':
    unittest.main()
