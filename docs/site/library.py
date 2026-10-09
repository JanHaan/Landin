"""Source-derived reference pages for the repository's library.

A bounded declaration reader, not a type checker. The shared scanner excludes
comments and literals from structural decisions. Unsupported public forms,
missing documentation, orphan overviews and ambiguous anchors stop the build.
Compiler tests remain the authority for legality and runtime behavior.
"""
from __future__ import annotations

from dataclasses import dataclass
import html
import json
from pathlib import Path
import re
import sys
import textwrap

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'highlight'))
from landin_highlight import Scanner

ROOTS = ('core', 'hosted', 'platform')
PUBLIC = re.compile(r'^(\s*)public (\w+):\s*(.*)')
DOC = re.compile(r'^\s*---(?: ?)(.*)$')


@dataclass
class Item:
    module: str
    name: str
    kind: str
    signature: str
    documentation: str
    source: str
    line: int
    condition: str = ''

    @property
    def anchor(self):
        return 'item-' + self.name


def page_name(module):
    return 'library-' + module.replace('/', '-') + '.html'


def source_name(path):
    return 'library-source-' + path.replace('/', '-').replace('.', '-') + '.html'


def code_lines(text):
    """Keep offsets, but blank comments and string contents for structure."""
    scanner = Scanner()
    result = []
    for line in text.splitlines():
        result.append(''.join(' ' * len(part) if cls in ('c', 'cd', 'q') else part
                              for cls, part in scanner.scan(line)))
    if scanner.depth or scanner.raw is not None:
        raise ValueError('unterminated comment or string in library source')
    return result


def attached_docs(lines, index):
    result = []
    for line in reversed(lines[:index]):
        match = DOC.fullmatch(line)
        if not match:
            break
        result.append(match[1])
    return '\n'.join(reversed(result)).strip()


def read_items(text, source):
    lines, codes = text.splitlines(), code_lines(text)
    module = str(Path(source).parent)
    items = []
    conditions = []
    for i, code in enumerate(codes):
        stripped = code.strip()
        indent = len(code) - len(code.lstrip())
        if stripped.startswith('fixed if '):
            conditions.append([indent, stripped[9:].removesuffix(' then'), []])
        elif conditions and indent == conditions[-1][0]:
            if stripped.startswith('elsif '):
                conditions[-1][2].append(conditions[-1][1])
                conditions[-1][1] = stripped[6:].removesuffix(' then')
            elif stripped == 'else':
                conditions[-1][2].append(conditions[-1][1])
                conditions[-1][1] = 'otherwise'
            elif stripped == 'end if':
                conditions.pop()
        match = PUBLIC.match(code)
        if not match:
            if re.search(r'\bpublic\b', code):
                raise ValueError(f'{source}:{i+1}: unsupported public declaration')
            continue
        prefix, name, after = match.groups()
        after = after.strip()
        documentation = attached_docs(lines, i)
        if not documentation:
            raise ValueError(f'{source}:{i+1}: undocumented public {name}')
        condition = '; '.join(
            ('not (' + ' or '.join(c[2]) + ')'
             + ('' if c[1] == 'otherwise' else ' and (' + c[1] + ')'))
            if c[2] else c[1] for c in conditions)
        if after.startswith('('):
            # The implementation separator is the first standalone '=' at
            # delimiter depth zero. '=' inside defaults is not a separator.
            depth = 0
            end = None
            for j in range(i, len(codes)):
                for col, char in enumerate(codes[j]):
                    if char in '([':
                        depth += 1
                    elif char in ')]':
                        depth -= 1
                    elif char == '=' and depth == 0:
                        end = (j, col)
                        break
                if end:
                    break
            if not end:
                raise ValueError(f'{source}:{i+1}: routine has no body separator')
            j, col = end
            signature = '\n'.join(lines[i:j] + [lines[j][:col]]).rstrip()
            kind = 'function'
        elif re.match(r'type(?:\s|$)', after):
            block = re.search(r'=\s*(struct|concept)\b', code)
            if block:
                end_marker = prefix + 'end ' + name
                j = next((n for n in range(i+1, len(codes))
                          if codes[n].rstrip() == end_marker), None)
                if j is None:
                    raise ValueError(f'{source}:{i+1}: unclosed public type')
                # Keep public fields and documented concept entries together.
                signature = '\n'.join(lines[i:j+1])
                kind = 'concept' if block[1] == 'concept' else 'type'
            else:
                if '=' not in code or not code.split('=', 1)[1].strip():
                    raise ValueError(f'{source}:{i+1}: unsupported type alias')
                rhs = code.split('=', 1)[1].strip()
                if (re.search(r'\b(?:struct|concept|variant)\b', rhs)
                        or rhs.endswith('|')
                        or rhs.count('(') != rhs.count(')')
                        or rhs.count('[') != rhs.count(']')):
                    raise ValueError(f'{source}:{i+1}: unsupported multiline type')
                signature = lines[i]
                kind = 'type'
        elif after == 'atom':
            signature, kind = lines[i], 'atom'
        else:
            if '=' not in code or not lines[i].split('=', 1)[1].strip():
                raise ValueError(f'{source}:{i+1}: unsupported public value')
            signature, kind = lines[i], 'value'
        signature = textwrap.dedent(signature).strip()
        items.append(Item(module, name, kind, signature, documentation,
                          source, i+1, condition))
    return items


def collect(root):
    files = {str(p.relative_to(root)): p.read_text()
             for base in ROOTS for p in sorted((root / base).rglob('*.ldn'))}
    modules = {}
    for path, text in files.items():
        modules.setdefault(str(Path(path).parent), []).extend(read_items(text, path))
    for module, items in modules.items():
        if not items:
            raise ValueError(f'{module}: no public library declarations')
        names = {}
        for item in items:
            previous = names.get(item.name)
            if previous and (not previous.condition or not item.condition
                             or previous.condition == item.condition):
                raise ValueError(f'{module}: ambiguous declaration {item.name}')
            names[item.name] = item
    return modules, files


def overviews(root, modules):
    text = (root / 'docs/library.md').read_text()
    parts = re.split(r'^## ((?:core|hosted|platform)/\w+)\s*$', text, flags=re.M)
    result = {}
    for module, body in zip(parts[1::2], parts[2::2]):
        example = re.search(r'^\[Executable example\]\(\.\./([^\n)]+)\)\s*$', body, re.M)
        if not example:
            raise ValueError(f'{module}: missing executable example')
        path = example[1]
        target = root / path
        if not (path.startswith('compiler/tests/fixtures/') or path == 'environments/cortex-m/probes/core-cpu.ldn') or not target.is_file():
            raise ValueError(f'{module}: invalid example {path}')
        if path.startswith('compiler/tests/fixtures/') and not target.with_name('fixture.meta').is_file():
            raise ValueError(f'{module}: example has no fixture metadata')
        if module in result:
            raise ValueError(f'duplicate overview: {module}')
        result[module] = (body[:example.start()].strip(), path)
    if set(result) != set(modules):
        raise ValueError('library overviews and source modules differ: '
                         + ', '.join(sorted(set(result) ^ set(modules))))
    return parts[0], result


CSS = '''
.api-tools {margin:1.5rem 0} .api-tools input {width:100%; padding:.7rem;
font:inherit; color:var(--ink); background:var(--bg); border:1px solid var(--rule)}
.api-results {max-height:24rem; overflow:auto} .api-results a {display:block; padding:.4rem}
.api-item {scroll-margin-top:5rem; padding:1.5rem 0; border-top:1px solid var(--rule)}
.api-item h2 {margin-top:0} .api-kind {font-size:.8rem; font-weight:normal}
.api-prose .guide {margin:0;padding:0;border:0}
.api-signature code {padding:0;background:none;border:0}
.api-source {font-size:.85rem} .api-signature {overflow:auto; padding:1rem;
background:var(--panel); border:1px solid var(--rule); white-space:pre}
.api-signature a {text-decoration:underline; text-decoration-style:dotted}
.api-index {columns:2; padding-left:1.2rem} .api-source-line {display:block;scroll-margin-top:5rem}
.api-source-line:target {background:var(--panel)} .api-line-number {display:inline-block;
min-width:4ch;margin-right:1.2em;color:var(--ink-faint);user-select:none}
.api-condition {font-size:.9rem} @media(max-width:600px){.api-index{columns:1}}
'''

SEARCH = '''
(() => {
 const field=document.getElementById('api-search');
 const results=document.getElementById('api-results');
 const items=JSON.parse(document.getElementById('api-search-data').textContent);
 const normalize=s=>s.toLowerCase().replaceAll('::','.');
 field.addEventListener('input',()=>{
  const terms=normalize(field.value).trim().split(/\\s+/).filter(Boolean);
  results.replaceChildren();
  if(!terms.length){results.hidden=true;return;}
  const matches=items.filter(i=>terms.every(t=>normalize(i.name+' '+i.summary+' '+i.kind).includes(t)));
  results.hidden=false;
  const count=document.createElement('p');count.textContent=matches.length+(matches.length===1?' result':' results');results.append(count);
  for(const item of matches.slice(0,80)){
   const a=document.createElement('a');a.href=item.url;
   a.textContent=item.name+' — '+item.summary;results.append(a);
  }
  if(matches.length>80){const p=document.createElement('p');p.textContent='Showing the first 80; refine your search.';results.append(p);}
 });
})();
'''


# Font swapping can move a deep source line after the browser's first hash
# scroll. Align again after layout settles, unless the reader has interacted.
ANCHORS = """
(() => {
 let latest=0;
 function settle(){
  const fragment=location.hash, attempt=++latest;
  if(!fragment)return;
  let cancelled=false;
  const cancel=()=>{cancelled=true;};
  const events=['wheel','touchstart','pointerdown','keydown'];
  events.forEach(name=>addEventListener(name,cancel,{passive:true}));
  const ready=document.fonts ? document.fonts.ready : Promise.resolve();
  ready.then(()=>requestAnimationFrame(()=>requestAnimationFrame(()=>{
   events.forEach(name=>removeEventListener(name,cancel));
   if(cancelled || latest!==attempt || location.hash!==fragment)return;
   let id;try{id=decodeURIComponent(fragment.slice(1));}catch{return;}
   const target=document.getElementById(id);
   if(target)target.scrollIntoView({block:'start',behavior:'instant'});
  })));
 }
 if(document.readyState==='loading')addEventListener('DOMContentLoaded',settle,{once:true});
 else settle();
 addEventListener('hashchange',settle);
})();
"""


def search_box(index):
    data = json.dumps(index, ensure_ascii=True).replace('<', '\\u003c')
    return ('<div class="api-tools"><label for="api-search">Search library APIs</label>'
            '<input type="search" id="api-search" placeholder="Name, module or purpose" '
            'aria-controls="api-results" autocomplete="off">'
            '<div id="api-results" class="api-results" aria-live="polite" hidden></div>'
            '<noscript>Browse the module and item indexes below; search needs JavaScript.</noscript>'
            f'</div><script type="application/json" id="api-search-data">{data}</script>'
            f'<script>{SEARCH}{ANCHORS}</script>')


def write(root, destination, render):
    """Render with the site's shell, Markdown reader, fonts and highlighter."""
    modules, sources = collect(root)
    anchors = {ref: d['out'] + '#' + ref for d in render.DOCS
               for ref in re.findall(r'^### \[(\d{4})\]', (root / d['src']).read_text(), re.M)}
    intro, descriptions = overviews(root, modules)
    exports = {module: {i.name for i in items} for module, items in modules.items()}
    index = []
    for module, items in modules.items():
        seen = set()
        for item in items:
            if item.name in seen:
                continue
            seen.add(item.name)
            index.append(dict(name=module + '.' + item.name, kind=item.kind,
                              summary=' '.join(item.documentation.split('\n\n')[0].split()).replace('`', ''),
                              url=page_name(module) + '#' + item.anchor))
    index.sort(key=lambda i: i['name'])
    search = search_box(index)
    pages = []
    def nav(current):
        out = ['<a class="doc" href="index.html">the front page</a>',
               '<a class="doc" href="library.html">library reference</a>',
               '<a class="doc" href="core.html">library guide</a>']
        for base in ROOTS:
            out.append('<details open><summary>' + base + '</summary>')
            for module in modules:
                if module.startswith(base + '/'):
                    here = ' aria-current="page"' if module == current else ''
                    cls = 'doc here' if here else 'doc'
                    out.append(f'<a class="{cls}"{here} href="{page_name(module)}">{module}</a>')
            out.append('</details>')
        return '\n'.join(out)
    def prose(text, source='docs/library.md'):
        _, hero, body, _ = render.render_guide(text, lambda ref: anchors.get(ref),
                    render.guide_targets(render.DOCS + render.GUIDES, source), render.Highlighter())
        return '<div class="api-prose">' + (hero + body).replace(' id="top"', '') + '</div>'
    def emit(filename, title, body, source, current='', description=''):
        out = render.page(title + ' — Landin', 'library reference', title, search,
                          body, nav(current), source, out=filename,
                          description=description, extra='<style>' + CSS + '</style>',
                          source_note='API reference derived from library sources. The specification defines language rules.')
        (destination / filename).write_text(out)
        pages.append(filename)
    body = prose(intro.replace('# Library reference', '', 1))
    for base in ROOTS:
        body += f'<h2>{base}</h2><ul>'
        for module in modules:
            if module.startswith(base + '/'):
                summary = descriptions[module][0].split('\n\n')[0]
                body += f'<li id="{module.replace("/", "-")}"><a href="{page_name(module)}"><code>{module}</code></a> — {html.escape(" ".join(summary.split()))}</li>'
        body += '</ul>'
    emit('library.html', 'Library reference', body, 'docs/library.md and core, hosted, platform sources')
    for module, items in modules.items():
        overview, example_path = descriptions[module]
        aliases = {}
        for path, text in sources.items():
            if str(Path(path).parent) == module:
                for match in re.finditer(r'^import ((?:core|hosted|platform)/\w+)(?: as (\w+))?\s*$', text, re.M):
                    aliases[match[2] or match[1].split('/')[-1]] = match[1]
        def reference(name):
            if '.' in name:
                qualifier, leaf = name.split('.', 1)
                target = aliases.get(qualifier)
                if target and leaf in exports[target]:
                    return page_name(target) + '#item-' + leaf
            elif name in exports[module]:
                return '#item-' + name
            return None
        def signature(text):
            scanner = Scanner()
            rows = []
            for line in text.splitlines():
                tokens = list(scanner.scan(line))
                spans, at = [], 0
                while at < len(tokens):
                    cls, part = tokens[at]
                    if (cls not in ('c', 'cd', 'q') and at + 2 < len(tokens)
                            and tokens[at+1][1] == '.'
                            and re.fullmatch(r'\w+', part)
                            and re.fullmatch(r'\w+', tokens[at+2][1])):
                        part += '.' + tokens[at+2][1]
                        at += 2
                    escaped = html.escape(part)
                    marked = f'<span class="{cls}">{escaped}</span>' if cls else escaped
                    target = reference(part) if cls not in ('c', 'cd', 'q') else None
                    spans.append(f'<a href="{target}">{marked}</a>' if target else marked)
                    at += 1
                rows.append(''.join(spans))
            return '<pre class="api-signature"><code>' + '\n'.join(rows) + '</code></pre>'
        availability = ('Shared: available on every enabled target.' if module.startswith('core/')
                        else 'Hosted targets only.' if module.startswith('hosted/')
                        else 'Target scope is enforced by the module assertion below.')
        body = '<p class="api-condition">' + availability + '</p>' + prose(overview)
        if module.startswith('platform/'):
            for path, text in sources.items():
                if str(Path(path).parent) == module:
                    assertion = re.search(r'compiler\.assert\([\s\S]*?\)\s*', text)
                    if not assertion:
                        raise ValueError(f'{module}: no target assertion')
                    body += signature(assertion[0].strip())
        body += '<h2>Items</h2><ul class="api-index">'
        grouped = {}
        for item in items:
            grouped.setdefault(item.name, []).append(item)
        kinds = ('concept', 'type', 'atom', 'value', 'function')
        grouped = dict(sorted(grouped.items(), key=lambda entry:
                              (kinds.index(entry[1][0].kind), entry[0])))
        for kind in kinds:
            for name, variants in grouped.items():
                if variants[0].kind == kind:
                    body += f'<li><a href="#item-{name}">{name}</a> <span class="api-kind">{kind}</span></li>'
        body += '</ul><details id="example"><summary>Executable example</summary><p>This complete program is maintained in the repository runtime tests. '
        body += f'<a href="{source_name(example_path)}#L1">View source</a>.</p>'
        example = (root / example_path).read_text()
        sources[example_path] = example
        body += render.listing_of(render.render_landin(example.splitlines(), render.Highlighter())) + '</details>'
        for name, variants in grouped.items():
            item = variants[0]
            body += f'<section class="api-item" id="{item.anchor}"><h2>{name} <span class="api-kind">{item.kind}</span></h2>'
            for variant in variants:
                if variant.condition:
                    body += '<p class="api-condition">When <code>' + html.escape(variant.condition) + '</code></p>'
                body += signature(variant.signature)
                body += f'<p class="api-source"><a href="{source_name(variant.source)}#L{variant.line}">{variant.source}:{variant.line}</a></p>'
                body += prose(variant.documentation, variant.source)
            body += '</section>'
        emit(page_name(module), module, body, module + '/*.ldn', module, overview.split('\n\n')[0])
    for path, text in sources.items():
        hl = render.Highlighter()
        body = '<pre class="api-signature"><code>' + '\n'.join(
            f'<span class="api-source-line" id="L{i}"><a class="api-line-number" href="#L{i}">{i}</a>{hl.line(line)}</span>'
            for i, line in enumerate(text.splitlines(), 1)) + '</code></pre>'
        emit(source_name(path), path, body, path, str(Path(path).parent))
    (destination / 'library-index.json').write_text(json.dumps(index, indent=2) + '\n')
    verify(destination, pages, modules, render, sources)
    return pages


def verify(destination, pages, modules, render, sources=None):
    """Check every local destination and each item's own visible content."""
    from collections import Counter
    from html.parser import HTMLParser
    from urllib.parse import unquote, urlsplit

    class Page(HTMLParser):
        def __init__(self, text):
            super().__init__(convert_charrefs=True)
            self.ids, self.links, self.items = set(), [], {}
            self.current, self.depth, self.hidden, self.pre = None, 0, 0, 0
            self.source_lines, self.source_line, self.span_depth = {}, None, 0
            self.feed(text)

        def handle_starttag(self, tag, attributes):
            attrs = dict(attributes)
            if tag == 'span':
                if self.source_line is not None:
                    self.span_depth += 1
                elif attrs.get('class') == 'api-source-line':
                    self.source_line, self.span_depth = attrs['id'], 1
                    self.source_lines[self.source_line] = []
            if tag == 'pre':
                self.pre += 1
            if self.current and tag == 'code' and not self.pre:
                self.items[self.current].append(' ')
            if self.current and tag in ('p', 'pre', 'h2', 'h3', 'li', 'section'):
                self.items[self.current].append('\n')
            if 'id' in attrs:
                if attrs['id'] in self.ids:
                    raise ValueError('duplicate HTML anchor: ' + attrs['id'])
                self.ids.add(attrs['id'])
            if tag == 'a' and 'href' in attrs:
                self.links.append(attrs['href'])
            if tag == 'section':
                if self.current:
                    self.depth += 1
                elif attrs.get('class') == 'api-item':
                    self.current, self.depth = attrs['id'], 1
                    self.items[self.current] = []
            if tag in ('script', 'style'):
                self.hidden += 1

        def handle_endtag(self, tag):
            if tag == 'span' and self.source_line is not None:
                self.span_depth -= 1
                if not self.span_depth:
                    self.source_line = None
            if self.current and tag == 'code' and not self.pre:
                self.items[self.current].append(' ')
            if tag == 'pre':
                self.pre -= 1
            if self.current and tag in ('p', 'pre', 'h2', 'h3', 'li', 'section'):
                self.items[self.current].append('\n')
            if tag == 'section' and self.current:
                self.depth -= 1
                if not self.depth:
                    self.current = None
            if tag in ('script', 'style'):
                self.hidden -= 1

        def handle_data(self, data):
            if self.source_line is not None:
                self.source_lines[self.source_line].append(data)
            if self.current and not self.hidden:
                self.items[self.current].append(data)

    parsed = {name: Page((destination / name).read_text()) for name in pages}
    for name, page in list(parsed.items()):
        for href in page.links:
            url = urlsplit(href)
            if url.scheme or url.netloc:
                continue
            target_name = unquote(url.path) or name
            target = destination / target_name
            if not target.is_file():
                raise ValueError(f'{name}: missing local link {href}')
            if url.fragment:
                other = parsed.get(target_name)
                if other is None:
                    other = Page(target.read_text())
                    parsed[target_name] = other
                if unquote(url.fragment) not in other.ids:
                    raise ValueError(f'{name}: missing link anchor {href}')
    for module, items in modules.items():
        page = parsed[page_name(module)]
        grouped = {}
        for item in items:
            grouped.setdefault(item.anchor, []).append(item)
        for anchor, variants in grouped.items():
            if anchor not in page.items:
                raise ValueError(f'{module}: missing rendered declaration {anchor}')
            want = Counter(render.WORD.findall('\n'.join(
                item.signature + '\n' + re.sub(r'\[([^\]]+)\]\([^)]+\)', r'\1',
                                               item.documentation) for item in variants)))
            got = Counter(render.WORD.findall(''.join(page.items[anchor])))
            missing = want - got
            if missing:
                raise ValueError(f'{module}.{anchor}: documentation lost words: {sorted(missing)}')

    for source, text in (sources or {}).items():
        held = parsed[source_name(source)].source_lines
        expected = text.splitlines()
        if len(held) != len(expected):
            raise ValueError(f'{source}: source listing lost lines')
        for line, code in enumerate(expected, 1):
            actual = ''.join(held.get(f'L{line}', []))
            if actual != str(line) + code:
                raise ValueError(f'{source}:{line}: source listing changed text')
