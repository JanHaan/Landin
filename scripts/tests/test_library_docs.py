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


def html_text(fragment):
    import html
    return html.unescape(re.sub(r'<[^>]*>', '', fragment))


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

    def test_c_routines_end_at_their_signature(self):
        text = '''--- Imported.
public extern(c) read: (descriptor: i32, data: ptr mut u8, length: usize)
                       -> (count: isize)
--- Renamed.
public extern(c) link(symbol: "__error") errno_cell:
    () -> (cell: ptr mut i32)
--- Defined.
public extern(c) start:
    (count: i32, values: ptr ptr u8) -> none =
    result = count
end start
--- After.
public value: i32 = 1
'''
        result = self.read(text)
        self.assertEqual([i.name for i in result], ['read', 'errno_cell', 'start', 'value'])
        self.assertEqual([i.kind for i in result], ['function'] * 3 + ['value'])
        self.assertTrue(result[0].signature.endswith('-> (count: isize)'))
        self.assertIn('link(symbol: "__error")', result[1].signature)
        self.assertTrue(result[1].signature.endswith('() -> (cell: ptr mut i32)'))
        self.assertTrue(result[2].signature.endswith('-> none'))
        self.assertNotIn('result =', result[2].signature)

    def test_attributes_alone_above_the_name_are_read(self):
        # The layout puts a declaration below its own attributes
        # when they would make its first line long.
        text = '''--- Renamed.
public extern(c) link(symbol: "__error")
errno_cell: () -> (cell: ptr mut i32)
--- Exported.
public link(symbol: "landin_checksum")
checksum: (data: []u8)
          -> (sum: u32) =
    sum = 0
end checksum
--- A constant.
public
limit: u32 = 4
--- After.
public value: i32 = 1
'''
        result = self.read(text)
        self.assertEqual([i.name for i in result],
                         ['errno_cell', 'checksum', 'limit', 'value'])
        self.assertEqual([i.kind for i in result],
                         ['function', 'function', 'value', 'value'])
        self.assertEqual(result[0].signature,
                         'public extern(c) link(symbol: "__error")\n'
                         'errno_cell: () -> (cell: ptr mut i32)')
        self.assertTrue(result[1].signature.endswith('-> (sum: u32)'))
        self.assertIn('link(symbol: "landin_checksum")\nchecksum:',
                      result[1].signature)
        self.assertNotIn('sum = 0', result[1].signature)
        self.assertEqual(result[2].signature, 'public\nlimit: u32 = 4')
        self.assertEqual(result[0].line, 2)

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

    def test_value_may_begin_on_the_next_line(self):
        """`refine fmt --check` accepts each of these layouts."""
        text = '''--- Next line.
public limit: i64 =
    4096
--- Continued.
public sum: i64 = 4096
                + 1
--- Bracketed.
public table: [3]i64 =
    [1, 2,
     3]
--- After.
public after: atom
'''
        result = self.read(text)
        self.assertEqual([i.name for i in result], ['limit', 'sum', 'table', 'after'])
        self.assertEqual([i.kind for i in result], ['value'] * 3 + ['atom'])
        self.assertEqual(result[0].signature, 'public limit: i64 =\n    4096')
        self.assertEqual(result[1].signature, 'public sum: i64 = 4096\n                + 1')
        self.assertEqual(result[2].signature,
                         'public table: [3]i64 =\n    [1, 2,\n     3]')
        with self.assertRaisesRegex(ValueError, 'unsupported public value'):
            self.read('--- Nothing.\npublic empty: i64 =\n--- After.\npublic after: atom\n')

    def test_alias_continued_on_indented_lines_is_whole(self):
        """core/failure's `reason` lost all but its first line of atoms."""
        text = '''--- Every reason.
public reason: type = mem.empty | mem.full
    | io.not_found
    | text.no_space
--- Next line.
public kind: type =
    one | two
    | three
--- After.
public after: atom
'''
        result = self.read(text)
        self.assertEqual([i.name for i in result], ['reason', 'kind', 'after'])
        self.assertEqual(result[0].signature,
                         'public reason: type = mem.empty | mem.full\n'
                         '    | io.not_found\n    | text.no_space')
        self.assertEqual(result[1].signature,
                         'public kind: type =\n    one | two\n    | three')

    def test_layout_qualified_struct_is_whole(self):
        """platform/kqueue's `layout(c) struct` read as a one-line alias."""
        text = '''--- A C record.
public record: type = layout(c) struct
    first: u32
    second: u64
end record
--- A packed one.
public packed: type = layout(c, packed) struct
    events: u32
end packed
--- After.
public after: atom
'''
        result = self.read(text)
        self.assertEqual([i.name for i in result], ['record', 'packed', 'after'])
        self.assertEqual([i.kind for i in result], ['type', 'type', 'atom'])
        self.assertTrue(result[0].signature.endswith('end record'))
        self.assertTrue(result[1].signature.endswith('end packed'))

    def test_live_failure_reason_lists_every_atom(self):
        source = ROOT / 'core/failure/failure.ldn'
        item = next(i for i in library.read_items(source.read_text(),
                                                  'core/failure/failure.ldn')
                    if i.name == 'reason')
        self.assertIn('text.invalid_format', item.signature)
        self.assertEqual(item.signature.count('|') + 1, 32)

    def test_unknown_public_form_and_unclosed_type_fail(self):
        with self.assertRaisesRegex(ValueError, 'unsupported public'):
            self.read('--- Forward.\npublic import core/mem\n')
        with self.assertRaisesRegex(ValueError, 'unsupported public'):
            self.read('fixed if compiler.hosted then public hidden: atom\n')
        with self.assertRaisesRegex(ValueError, 'unsupported multiline'):
            self.read('--- Union.\npublic choice: type = one |\n--- After.\npublic after: atom\n')
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
                self.assertRegex(sources[item.source].splitlines()[item.line-1],
                                 r'public (?:extern\((?:c|naked)\) )?'
                                 r'(?:link\(symbol: "[^"]*"\) )?'
                                 + re.escape(item.name) + ':')


class PagePrograms(unittest.TestCase):
    """The reference's `landin` blocks are fixture sources (check.py).

    The common-tasks recipes were once table cells that failed when pasted
    into `main`; nothing compiled them.  A block is now a linked fixture's
    whole text, or whole lines of it.
    """
    SOURCE = 'compiler/tests/fixtures/runtime/demo/main.ldn'
    TEXT = 'a: i32 = 1\n\nb: i32 = 2\nc: i32 = 3\n'

    @classmethod
    def setUpClass(cls):
        import importlib.util
        spec = importlib.util.spec_from_file_location('landin_check', ROOT / 'check.py')
        cls.check = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.check)

    def faults(self, page):
        texts = {self.SOURCE: self.TEXT}
        return self.check.library_block_faults(page.split('\n'), texts.get)

    def page(self, block, link=True):
        cited = f'[Executable example](../{self.SOURCE})\n' if link else ''
        return f'## core/demo\n\nWords.\n\n```landin\n{block}```\n\n{cited}'

    def test_a_whole_file_or_whole_lines_of_one_pass(self):
        self.assertEqual(self.faults(self.page(self.TEXT)), [])
        self.assertEqual(self.faults(self.page('b: i32 = 2\nc: i32 = 3\n')), [])

    def test_a_changed_or_partial_line_fails(self):
        for block in ('a: i32 = 9\n', ': i32 = 2\n', 'b: i32 = 2\nc: i32 = \n'):
            with self.subTest(block=block):
                self.assertEqual(len(self.faults(self.page(block))), 1)

    def test_a_block_whose_section_links_no_fixture_fails(self):
        self.assertRegex(self.faults(self.page(self.TEXT, link=False))[0][1],
                         'links no fixture')

    def test_the_live_page_holds_its_programs(self):
        lines = (ROOT / 'docs/library.md').read_text().split('\n')
        self.assertIn('```landin', lines)
        def read(path):
            target = ROOT / path
            return target.read_text() if target.is_file() else None
        self.assertEqual(self.check.library_block_faults(lines, read), [])


class ValueTables(unittest.TestCase):
    """A value declared once per target is one row, a column each."""
    SOURCE = '''fixed if compiler.arch == x86_64 then
    --- `read`'s number on x86-64.
    public read_number: i64 = 0
    --- `write`'s number on x86-64.
    public write_number: i64 = 1
    --- `fork`'s number on x86-64.
    public fork_number: i64 = 57
    --- Only here.
    public odd: i64 = 1
elsif compiler.arch == arm64 then
    --- `read`'s number on arm64.
    public read_number: i64 = 63
    --- `write`'s number on arm64.
    public write_number: i64 = 64
else
    --- `read`'s number on RV64.
    public read_number: i64 = 63
    --- `write`'s number on RV64.
    public write_number: i64 = 64
end if
fixed if compiler.hosted then
    --- Elsewhere.
    public odd: i64 = 2
end if
'''

    def grouped(self, text):
        grouped = {}
        for item in library.read_items(text, 'platform/demo/demo.ldn'):
            grouped.setdefault(item.name, []).append(item)
        return grouped

    def test_rows_columns_and_labels(self):
        table = library.value_table(self.grouped(self.SOURCE))
        self.assertEqual(list(table.rows), ['read_number', 'write_number', 'fork_number'])
        self.assertEqual(table.labels, ['compiler.arch == x86_64',
                                        'compiler.arch == arm64', 'otherwise'])
        self.assertEqual(table.columns[1],
                         'not (compiler.arch == x86_64) and (compiler.arch == arm64)')
        kind, items, values = table.rows['read_number']
        self.assertEqual(kind, 'i64')
        self.assertEqual(list(values.values()), ['0', '63', '63'])
        self.assertEqual(list(table.rows['fork_number'][2]), [table.columns[0]])
        self.assertEqual(table.documentation('read_number'),
                         "`read`'s number on x86-64 / arm64 / RV64.")

    def test_no_table_without_a_repeated_name(self):
        self.assertIsNone(library.value_table(self.grouped(
            '--- A.\npublic a: i64 = 1\n--- B.\npublic b: i64 = 2\n')))

    def test_documentation_that_differs_in_more_than_a_label_is_kept_whole(self):
        texts = ['Counts the open files.', 'Says which processes are running now.']
        self.assertEqual(library.merged_documentation(texts), ' / '.join(texts))
        self.assertEqual(library.merged_documentation(['Same.', 'Same.']), 'Same.')


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

    def test_module_summaries_render_code_and_module_links(self):
        # The index once showed a summary's backticks as written.
        page = (self.destination / 'library.html').read_text()
        index = page[page.index('<li id="core-io">'):]
        index = index[:index.index('</li>')]
        self.assertIn('<code>core/time</code>', index)
        self.assertNotIn('`', index)
        # A link to a module's directory is its page.
        self.assertIn('href="library-core-failure.html" '
                      'data-source-href="../core/failure"', page)
        self.assertNotIn('blob/main/core/', page)

    def test_front_page_reaches_installation(self):
        # The front page once linked no installation steps.
        anchor = render_html.INSTALL_ANCHOR
        self.assertIn(f'href="readme.html#{anchor}"',
                      (self.destination / 'index.html').read_text())
        readme = (self.destination / 'readme.html').read_text()
        self.assertIn(f'id="{anchor}"', readme)
        section = readme[readme.index(f'id="{anchor}"'):]
        section = section[:section.index('id="your-first-program"')]
        for said in ('no top-level directory', 'lib/landin',
                     'refine version', 'library: '):
            self.assertIn(said, section)

    def test_missing_item_prose_is_detected_despite_search_and_source_copies(self):
        target = self.destination / 'library-core-vec.html'
        original = target.read_text()
        # The search index also holds the summary: remove only the visible text.
        start = original.index('<section class="api-item" id="item-new"')
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
        self.assertIn(f'data-index="{library.SEARCH_SCRIPT}"', text)
        self.assertIn('<noscript>', text)
        self.assertIn('aria-controls="api-results"', text)
        self.assertNotIn('fetch(', library.SEARCH)
        self.assertIn("createElement('script')", library.SEARCH)
        self.assertIn('textContent=item.name', library.SEARCH)
        script = (self.destination / library.SEARCH_SCRIPT).read_text()
        prefix = 'window.landinLibraryIndex='
        self.assertTrue(script.startswith(prefix))
        index = json.loads(script[len(prefix):].rstrip().removesuffix(';'))
        self.assertEqual(index, json.loads(
            (self.destination / 'library-index.json').read_text()))

    def test_pages_carry_their_content_and_not_the_index(self):
        """A page once carried a 400 KB copy of the whole search index.

        The index is one script beside the pages, loaded on first search.
        What a page carries beyond its own items and listing is the shell,
        bounded here; a module's size is then its declarations'.
        """
        index = (self.destination / library.SEARCH_SCRIPT).read_text()
        probe = index[len('window.landinLibraryIndex='):][:200]
        for name in self.pages:
            text = (self.destination / name).read_text()
            with self.subTest(page=name):
                self.assertNotIn(probe, text)
                self.assertNotIn('api-search-data', text)
                content = sum(len(m) for m in re.findall(
                    r'<section class="api-item".*?</section>'
                    r'|<section class="api-values".*?</section>'
                    r'|<pre class="api-signature">.*?</pre>'
                    r'|<section class="api-example".*?</section>', text, re.S))
                self.assertLess(len(text) - content, 96 * 1024)
        self.assertLess(max((self.destination / n).stat().st_size
                            for n in self.pages), 1024 * 1024)

    def test_a_page_read_as_text_reads_in_order(self):
        """An outside reader fetched a module page as text and met 28 KB of
        style and script, then every module's name, before the module; its
        signatures, source lines and table cells then ran together."""
        import html
        text = (self.destination / 'library-core-io.html').read_text()
        self.assertNotIn('<style', text)
        self.assertIsNone(re.search(r'<script(?![^>]*\b(?:src|type)=)[^>]*>', text))
        for name in ('library.css', 'library-theme.js', 'library.js'):
            self.assertTrue((self.destination / name).is_file(), name)
        read = html.unescape(re.sub(r'<[^>]*>', '', text))
        summary = read.index('Reader, writer, file and process capabilities')
        self.assertLess(summary, 2048)
        self.assertLess(summary, read.index('platform/linux/numbers'))
        # A signature, its source line and its documentation are lines of
        # their own, as are a table's rows and a list's items.
        self.assertNotRegex(read, r'\)core/io/\w+\.ldn:\d+')
        self.assertNotRegex(read, r'\.ldn:\d+[^\d\s]')
        self.assertIn('\nreader, writer\tread, write, write_some\tyes\n', read)

    def test_headings_descend_a_level_at_a_time(self):
        """A module page went h1, nine h3, then an h2 per item."""
        for name in ('library.html', 'library-core-io.html', 'library-core-text.html',
                     library.page_name('platform/linux/numbers')):
            text = (self.destination / name).read_text()
            levels = [int(h) for h in re.findall(r'<h([1-6])\b', text)]
            with self.subTest(page=name):
                self.assertEqual(levels[0], 1)
                self.assertEqual([(a, b) for a, b in zip(levels, levels[1:]) if b > a + 1], [])
        text = (self.destination / 'library-core-io.html').read_text()
        self.assertIn('<h2 class="api-h">Items</h2>', text)
        self.assertIn('data-title="Providers"><h2>', text.replace('\n', ''))

    def test_an_item_is_named_in_code_and_leads_back_to_the_index(self):
        text = (self.destination / 'library-core-io.html').read_text()
        item = text[text.index('<section class="api-item" id="item-open_read"'):]
        item = item[:item.index('</section>')]
        self.assertIn('data-title="open_read"', item)
        self.assertIn('<h3 class="api-name"><code>open_read</code></h3>', item)
        self.assertIn('href="#items-function"', item)
        self.assertIn('id="items-function"', text)
        self.assertRegex(item, r'<a class="api-source" href="[^"]+#L\d+">core/io/io\.ldn:\d+</a>')
        # The sidebar holds the module's own contents under its link.
        side = text[text.index('<nav class="side"'):]
        self.assertLess(side.index('aria-current="page" href="library-core-io.html"'),
                        side.index('id="api-toc"'))
        self.assertIn('<a class="sect" href="#providers">', side)

    def test_the_sidebar_reaches_the_site_and_the_items(self):
        """From a module page the tour and the examples were out of reach,
        and halfway down it the sidebar named the kinds but not the items."""
        text = (self.destination / 'library-core-io.html').read_text()
        side = text[text.index('<nav class="side"'):text.index('</nav>', text.index('<nav class="side"'))]
        for _, name, members in render_html.nav_groups(render_html.DOCS + render_html.GUIDES):
            members = [d for d in members if d['out'] != 'library.html']
            with self.subTest(group=name):
                self.assertIn(f'{name}<span class="count">{len(members)}</span>', side)
        self.assertIn('href="tour.html"', side)
        self.assertEqual(side.count('href="library.html"'), 1)
        self.assertNotIn('<details class="api-docs" open', side)
        group = re.search(r'<details class="api-toc-group" data-kind="function">(.*?)</details>', side, re.S)
        self.assertIsNotNone(group)
        self.assertIn('<a class="api-toc-item" href="#item-open_read">open_read</a>', group[1])
        self.assertNotRegex(side, r'<details class="api-toc-group"[^>]* open')

    def test_controls_are_buttons_a_keyboard_reaches(self):
        text = (self.destination / 'library-core-io.html').read_text()
        self.assertIn('<button type="button" class="api-onpage" id="api-onpage" '
                      'aria-controls="side" aria-expanded="false">', text)
        self.assertIn('href="#side">skip to the library navigation</a>', text)
        self.assertRegex(text, r'<input type="search" id="api-search"[^>]*aria-expanded="false"')
        self.assertIn('<label for="api-search">search all library APIs</label>', text)
        # The compact field follows the module's opening paragraph.
        self.assertLess(text.index('Reader, writer, file and process capabilities'),
                        text.index('id="api-search"'))
        # Without a script the field and the button are hidden.
        theme = (self.destination / 'library-theme.js').read_text()
        self.assertIn(library.SCRIPTED, theme)
        self.assertIn(":root:not(.api-js) .api-tools input", library.CSS)

    def test_an_item_heading_separates_its_source_and_the_way_back(self):
        text = (self.destination / 'library-core-io.html').read_text()
        item = text[text.index('<section class="api-item" id="item-open_read"'):]
        item = item[:item.index('</section>')]
        self.assertRegex(item, r'<span class="api-where">\n<a class="api-source"[^>]*>[^<]+</a>\n'
                               r'<a class="api-back" href="#items-function" '
                               r'aria-label="back to the item index">↑ index</a>')
        # One region scrolls per declaration, the shared fade's own class.
        self.assertIn('<div class="api-decl"><div class="scroller">', item)

    def test_search_ranks_names_before_summaries(self):
        for said in ('function tier(e,t)', "e.leaf.startsWith(t)", 'ArrowDown', 'ArrowUp',
                     "setAttribute('aria-expanded'"):
            self.assertIn(said, library.SEARCH)

    def test_only_tables_that_cannot_share_a_phone_stack(self):
        io = (self.destination / 'library-core-io.html').read_text()
        tables = re.findall(r'<table class="([^"]*)">.*?<th scope="col">(.*?)</th>', io, re.S)
        classes = {head: cls for cls, head in tables}
        self.assertIn('api-stack', classes['Task'])        # long calls
        self.assertIn('api-stack', classes['Concept'])     # three columns
        self.assertNotIn('api-stack', classes['Call'])     # two, short calls
        self.assertIn('<td class="api-flag" data-label="Part of world">yes</td>', io)

    def test_overview_tables_link_the_calls_they_name(self):
        index = (self.destination / 'library.html').read_text()
        self.assertIn('<a href="library-core-io.html#item-open_read">'
                      '<code>io.open_read(host, path)</code></a>', index)
        page = (self.destination / 'library-core-io.html').read_text()
        self.assertIn('<a href="#item-open_read"><code>open_read</code></a>', page)

    def test_member_documentation_is_prose_beside_the_code(self):
        text = (self.destination / 'library-core-io.html').read_text()
        item = text[text.index('<section class="api-item" id="item-writer"'):]
        item = item[:item.index('</section>')]
        self.assertIn('<div class="api-doc"', item)
        for code in re.findall(r'<pre class="api-signature">(.*?)</pre>', item, re.S):
            self.assertNotIn('---', html_text(code))

    def test_the_example_is_a_program_panel(self):
        text = (self.destination / 'library-core-text.html').read_text()
        example = text[text.index('<section class="api-example"'):]
        self.assertIn('<figure class="panel api-program">', example)
        self.assertIn('<span>in a terminal</span>', example)
        self.assertIn('$ refine compile main.ldn -o text-columns', example)

    def test_linux_numbers_are_one_row_per_name(self):
        """The page was 758 KB, every name repeated per architecture."""
        module = 'platform/linux/numbers'
        names = {item.name for item in self.modules[module]}
        text = (self.destination / library.page_name(module)).read_text()
        rows = re.findall(r'<tr class="api-item" id="item-(\w+)">', text)
        self.assertEqual(sorted(rows), sorted(names))
        self.assertNotIn('<section class="api-item"', text)
        head = re.search(r'<table class="api-table"><thead>(.*?)</thead>', text, re.S)[1]
        for arch in ('x86_64', 'arm64', 'rv64'):
            self.assertIn(f'compiler.arch == {arch}', head)
        self.assertLess(len(text.encode()), 384 * 1024)

    def test_changed_value_cell_is_detected(self):
        target = self.destination / library.page_name('platform/linux/numbers')
        original = target.read_text()
        row = original.index('<tr class="api-item" id="item-read_number">')
        changed = original[:row] + re.sub(r'<code>0</code>', '<code>1</code>',
                                          original[row:], count=1)
        self.assertNotEqual(original, changed)
        try:
            target.write_text(changed)
            with self.assertRaisesRegex(ValueError, 'value table row changed'):
                library.verify(self.destination, self.pages, self.modules, render_html)
        finally:
            target.write_text(original)

    def test_lost_row_documentation_is_detected(self):
        target = self.destination / library.page_name('platform/linux/numbers')
        original = target.read_text()
        row = original.index('<tr class="api-item" id="item-read_number">')
        changed = original[:row] + original[row:].replace('system-call', 'call', 1)
        try:
            target.write_text(changed)
            with self.assertRaisesRegex(ValueError, 'lost words'):
                library.verify(self.destination, self.pages, self.modules, render_html)
        finally:
            target.write_text(original)


if __name__ == '__main__':
    unittest.main()
