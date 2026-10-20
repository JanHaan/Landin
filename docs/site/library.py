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
PUBLIC = re.compile(r'^(\s*)public ((?:extern\((?:c|naked)\)\s+)?'
                    r'(?:link\(symbol:[^)]*\)\s+)?)'
                    r'(\w+):\s*(.*)')
DOC = re.compile(r'^\s*---(?: ?)(.*)$')
#  `public` and a declaration's attributes alone on a line, which the layout
#  writes when they would make the declaration's first line long: the name
#  begins the next line, at the same indentation.
ATTRIBUTES = re.compile(r'^(\s*)public(?:\s+extern\((?:c|naked)\))?'
                        r'(?:\s+link\(symbol:[^)]*\))?\s*$')
NAMED = re.compile(r'\w+:')


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
    # Each enclosing `fixed if` branch's own test, outermost first, where
    # `condition` also says which earlier branches did not hold.
    chain: tuple = ()

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
        # The line the declaration's name is on: this one, or the next when
        # its attributes stand alone above it.
        last = i
        attributes = ATTRIBUTES.match(code)
        if (attributes and i + 1 < len(codes)
                and codes[i + 1].startswith(attributes[1])
                and NAMED.match(codes[i + 1][len(attributes[1]):])):
            last = i + 1
            code = code.rstrip() + ' ' + codes[last].lstrip()
        match = PUBLIC.match(code)
        if not match:
            if re.search(r'\bpublic\b', code):
                raise ValueError(f'{source}:{i+1}: unsupported public declaration')
            continue
        prefix, foreign, name, after = match.groups()
        after = after.strip()
        documentation = attached_docs(lines, i)
        if not documentation:
            raise ValueError(f'{source}:{i+1}: undocumented public {name}')
        condition = '; '.join(
            ('not (' + ' or '.join(c[2]) + ')'
             + ('' if c[1] == 'otherwise' else ' and (' + c[1] + ')'))
            if c[2] else c[1] for c in conditions)
        if foreign:
            # A C routine: its signature may continue on more deeply
            # indented lines, and a definition ends it with '=' at
            # delimiter depth zero where an import simply stops.
            depth = 0
            for char in ''.join(codes[i:last]):
                if char in '([':
                    depth += 1
                elif char in ')]':
                    depth -= 1
            j = last
            while True:
                for char in codes[j]:
                    if char in '([':
                        depth += 1
                    elif char in ')]':
                        depth -= 1
                stripped_end = codes[j].rstrip()
                following = codes[j + 1] if j + 1 < len(codes) else ''
                if depth == 0 and stripped_end.endswith('='):
                    signature = '\n'.join(
                        lines[i:j] + [lines[j][:len(stripped_end) - 1]]).rstrip()
                    break
                if depth == 0 and (not following.strip()
                                   or len(following) - len(following.lstrip())
                                   <= len(prefix)):
                    signature = '\n'.join(lines[i:j + 1]).rstrip()
                    break
                j += 1
                if j == len(codes):
                    raise ValueError(f'{source}:{i+1}: unterminated C routine')
            kind = 'function'
        elif after.startswith('(') or (
                not after and last + 1 < len(codes)
                and codes[last + 1].strip().startswith('(')):
            # A native routine, whose signature the layout may start on the
            # next line.  The implementation separator is the first standalone '=' at
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
                continued = (code.rstrip().endswith('=')
                             and last + 1 < len(codes)
                             and codes[last+1].startswith(prefix + '    ')
                             and codes[last+1].strip())
                if continued:
                    # An alias whose right side the layout put on the next line.
                    code = code.rstrip() + ' ' + codes[last+1].strip()
                if '=' not in code or not code.split('=', 1)[1].strip():
                    raise ValueError(f'{source}:{i+1}: unsupported type alias')
                rhs = code.split('=', 1)[1].strip()
                if (re.search(r'\b(?:struct|concept|variant)\b', rhs)
                        or rhs.endswith('|')
                        or rhs.count('(') != rhs.count(')')
                        or rhs.count('[') != rhs.count(']')):
                    raise ValueError(f'{source}:{i+1}: unsupported multiline type')
                signature = '\n'.join(lines[i:last + (2 if continued else 1)])
                kind = 'type'
        elif after == 'atom':
            signature, kind = '\n'.join(lines[i:last+1]), 'atom'
        else:
            # A value, whose expression the layout may begin on the next
            # line or continue on more deeply indented ones; open brackets
            # carry it on whatever the indentation.  Its name may itself be
            # on the line after its attributes.
            depth, j = 0, last
            while True:
                for char in codes[j]:
                    if char in '([':
                        depth += 1
                    elif char in ')]':
                        depth -= 1
                following = codes[j + 1] if j + 1 < len(codes) else ''
                if depth <= 0 and (not following.strip()
                                   or len(following) - len(following.lstrip())
                                   <= len(prefix)):
                    break
                j += 1
                if j == len(codes):
                    raise ValueError(f'{source}:{i+1}: unterminated public value')
            written = '\n'.join(lines[i:j + 1])
            if '=' not in code or not written.split('=', 1)[1].strip():
                raise ValueError(f'{source}:{i+1}: unsupported public value')
            signature, kind = written.rstrip(), 'value'
        signature = textwrap.dedent(signature).strip()
        items.append(Item(module, name, kind, signature, documentation,
                          source, i+1, condition,
                          tuple(c[1] for c in conditions)))
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
    parts = re.split(r'^## ((?:core|hosted|platform)(?:/\w+)+)\s*$', text, flags=re.M)
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


VALUE = re.compile(r'public (\w+):\s*([^=\n]*?)\s*=\s*(\S[^\n]*)')


@dataclass
class Table:
    """Values declared once per target, as one row per name.

    A module generated for several targets, platform/linux/numbers the
    first, declares each name once in every branch of a `fixed if`; as a
    section per declaration its page repeated 387 names three times.
    """
    columns: list        # each column's full condition, in source order
    labels: list         # what its header says
    rows: dict           # name -> (type, {condition: Item}, value by condition)

    def documentation(self, name):
        return merged_documentation([i.documentation
                                     for i in self.rows[name][1].values()])


def value_table(grouped):
    """The names `grouped` can show as one table, or None.

    A name qualifies when every declaration of it is a one-line value of
    one type under its own target condition and its documentation is one
    paragraph. The columns are the conditions more than half of the
    names declared more than once use, and a name joins the table when all
    its conditions are columns; the rest keep their sections, so one odd
    declaration does not widen every row.
    """
    candidates = {}
    for name, variants in grouped.items():
        found = [VALUE.fullmatch(v.signature) for v in variants]
        if (all(found) and len({m[2] for m in found}) == 1
                and all(v.kind == 'value' and v.condition
                        and '\n\n' not in v.documentation for v in variants)):
            candidates[name] = (found[0][2], {v.condition: v for v in variants},
                                {v.condition: m[3] for v, m in zip(variants, found)})
    repeated = [row[1] for row in candidates.values() if len(row[1]) > 1]
    uses = {}
    for items in repeated:
        for condition in items:
            uses[condition] = uses.get(condition, 0) + 1
    wanted = {c for c, n in uses.items() if 2 * n > len(repeated)}
    rows = {name: row for name, row in candidates.items() if set(row[1]) <= wanted}
    if (len(rows) < 2 or len(wanted) < 2
            or all(len(row[1]) == 1 for row in rows.values())):
        return None
    first = {}
    for _, items, _ in rows.values():
        for condition, item in items.items():
            first[condition] = min(first.get(condition, (item.source, item.line)),
                                   (item.source, item.line))
    columns = sorted(first, key=first.get)
    chains = [next(i.chain for _, items, _ in rows.values()
                   for c, i in items.items() if c == column) for column in columns]
    # A column is headed by its own branch's test when the columns are
    # branches under the same enclosing tests; the full condition is said
    # once above the table.
    labels = [chain[-1] for chain in chains]
    if len(set(labels)) != len(labels) or len({chain[:-1] for chain in chains}) != 1:
        labels = list(columns)
    return Table(columns, labels, rows)


TOKENS = re.compile(r'\s+|[^\s.,;:]+|[.,;:]')


def merged_documentation(texts):
    """One documentation for a row: shared, or its differing words joined.

    `read`'s number "on x86-64.", "on arm64." and "on RV64." become "on
    x86-64 / arm64 / RV64.", every variant's every word still present.
    """
    texts = [' '.join(t.split()) for t in texts]
    distinct = list(dict.fromkeys(texts))
    if len(distinct) == 1:
        return distinct[0]
    tokens = [TOKENS.findall(t) for t in distinct]
    start = 0
    while all(start < len(t) for t in tokens) and len({t[start] for t in tokens}) == 1:
        start += 1
    end = 0
    while (all(end < len(t) - start for t in tokens)
           and len({t[len(t) - 1 - end] for t in tokens}) == 1):
        end += 1
    prefix = ''.join(tokens[0][:start])
    suffix = ''.join(tokens[0][len(tokens[0]) - end:])
    middles = [''.join(t[start:len(t) - end]).strip() for t in tokens]
    balanced = all(part.count('`') % 2 == 0 and part.count('[') == part.count(']')
                   and part.count('(') == part.count(')')
                   for part in [prefix] + middles)
    if balanced and all(middles) and all(len(m.split()) <= 3 for m in middles):
        return (prefix.rstrip() + ' ' + ' / '.join(middles) + suffix).strip()
    return ' / '.join(distinct)


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
.api-table {border-collapse:collapse; font-size:.9rem}
.api-table th, .api-table td {text-align:left; padding:.25rem .8rem .25rem 0;
border-bottom:1px solid var(--rule); vertical-align:top}
.api-table th[scope=row] {font-weight:normal; font-family:var(--mono)}
.api-table tr:target {background:var(--panel)} .api-table tr {scroll-margin-top:5rem}
.api-table td code, .api-table th code {white-space:nowrap}
.api-condition {font-size:.9rem} @media(max-width:600px){.api-index{columns:1}}
'''

SEARCH_SCRIPT = 'library-search.js'

# The stylesheet and scripts every library page links rather than carries:
# LINKED.css, LINKED-theme.js and LINKED.js.  Inline, they were the first
# 28 KB a reader of a page as text met, before the module's first word.
LINKED = 'library'

# The index is one file beside the pages rather than a copy inside each: as
# a copy it was 400 KB of every one of 124 pages, most of what a reader of a
# small module downloaded. A classic script element, not fetch(), loads it,
# so a page opened from disk still searches; and only on first use, so a
# reader who never searches never downloads it.
SEARCH = '''
(() => {
 const field=document.getElementById('api-search');
 const results=document.getElementById('api-results');
 let items=null, loading=false;
 const normalize=s=>s.toLowerCase().replaceAll('::','.');
 function load(){
  if(items||loading)return;
  loading=true;
  const script=document.createElement('script');
  script.src=field.dataset.index;
  script.onload=()=>{items=window.landinLibraryIndex||[];show();};
  script.onerror=()=>{loading=false;results.hidden=false;
   results.textContent='The search index could not be loaded; browse the module and item indexes below.';};
  document.head.append(script);
 }
 function show(){
  const terms=normalize(field.value).trim().split(/\\s+/).filter(Boolean);
  results.replaceChildren();
  if(!terms.length){results.hidden=true;return;}
  if(!items){load();return;}
  const matches=items.filter(i=>terms.every(t=>normalize(i.name+' '+i.summary+' '+i.kind).includes(t)));
  results.hidden=false;
  const count=document.createElement('p');count.textContent=matches.length+(matches.length===1?' result':' results');results.append(count);
  for(const item of matches.slice(0,80)){
   const a=document.createElement('a');a.href=item.url;
   a.textContent=item.name+' — '+item.summary;results.append(a);
  }
  if(matches.length>80){const p=document.createElement('p');p.textContent='Showing the first 80; refine your search.';results.append(p);}
 }
 field.addEventListener('focus',load,{once:true});
 field.addEventListener('input',show);
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


def value_section(table, module, source_name, reference, render, links):
    """The table: a row per name, a column per target condition."""
    out = ['<section class="api-values" id="values"><h2>Values by target</h2>'
           '<p>Each name is declared once for each target condition below; '
           'a dash means the name is not declared there.</p><ul class="api-columns">']
    for label, column in zip(table.labels, table.columns):
        out.append(f'<li><code>{html.escape(label)}</code>: when '
                   f'<code>{html.escape(column)}</code></li>')
    out.append('</ul><div class="scroller"><table class="api-table"><thead><tr>'
               '<th scope="col">Name</th><th scope="col">Type</th>')
    out += [f'<th scope="col"><code>{html.escape(label)}</code></th>'
            for label in table.labels]
    out.append('<th scope="col">Documentation</th></tr></thead><tbody>')
    for name, (kind, items, values) in table.rows.items():
        anchor = 'item-' + name
        target = reference(kind)
        written = f'<code>{html.escape(kind)}</code>'
        out.append(f'<tr class="api-item" id="{anchor}"><th scope="row">{name}</th><td>'
                   + (f'<a href="{target}">{written}</a>' if target else written) + '</td>')
        for column in table.columns:
            item = items.get(column)
            if item is None:
                out.append('<td class="api-absent">\u2014</td>')
            else:
                out.append(f'<td><a href="{source_name(item.source)}#L{item.line}">'
                           f'<code>{html.escape(values[column])}</code></a></td>')
        first = next(iter(items.values()))
        out.append('<td>' + render.inline(
            table.documentation(name), links,
            render.guide_targets(render.DOCS + render.GUIDES, first.source))
            + '</td></tr>')
    out.append('</tbody></table></div></section>')
    # A line each, so the cells do not run together when read as text.
    return '\n'.join(out) + '\n'


def search_box():
    """The search field; its script is in the linked library.js."""
    return ('<div class="api-tools">\n<label for="api-search">Search library APIs</label>\n'
            '<input type="search" id="api-search" placeholder="Name, module or purpose" '
            f'data-index="{SEARCH_SCRIPT}" '
            'aria-controls="api-results" autocomplete="off">\n'
            '<div id="api-results" class="api-results" aria-live="polite" hidden></div>\n'
            '<noscript>Browse the module and item indexes below; search needs JavaScript.</noscript>\n'
            '</div>\n')


def search_index(index):
    """The script every page loads on first search: the index, once."""
    data = json.dumps(index, ensure_ascii=True, separators=(',', ':'))
    return 'window.landinLibraryIndex=' + data.replace('<', '\\u003c') + ';\n'


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
    search = search_box()
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
        return '<div class="api-prose">\n' + (hero + body).replace(' id="top"', '') + '</div>\n'
    def emit(filename, title, body, source, current='', description=''):
        out = render.page(title + ' — Landin', 'library reference', title, search,
                          body, nav(current), source, out=filename,
                          description=description, linked=LINKED,
                          source_note='API reference derived from library sources. The specification defines language rules.')
        (destination / filename).write_text(out)
        pages.append(filename)
    for name, text in render.linked_assets(LINKED, CSS, SEARCH + ANCHORS).items():
        (destination / name).write_text(text)
    body = prose(intro.replace('# Library reference', '', 1))
    for base in ROOTS:
        body += f'<h2>{base}</h2>\n<ul>\n'
        for module in modules:
            if module.startswith(base + '/'):
                summary = descriptions[module][0].split('\n\n')[0]
                body += f'<li id="{module.replace("/", "-")}"><a href="{page_name(module)}"><code>{module}</code></a> — {html.escape(" ".join(summary.split()))}</li>\n'
        body += '</ul>\n'
    emit('library.html', 'Library reference', body, 'docs/library.md and core, hosted, platform sources')
    for module, items in modules.items():
        overview, example_path = descriptions[module]
        aliases = {}
        for path, text in sources.items():
            if str(Path(path).parent) == module:
                for match in re.finditer(r'^import ((?:core|hosted|platform)(?:/\w+)+)(?: as (\w+))?\s*$', text, re.M):
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
        def signature(text, own=None):
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
                    if target is not None and target == own:
                        # The declaration's own name: the heading above
                        # already names it, and a link to where the reader
                        # already is was a thousand anchors on one page.
                        target = None
                    spans.append(f'<a href="{target}">{marked}</a>' if target else marked)
                    at += 1
                rows.append(''.join(spans))
            return '<pre class="api-signature"><code>' + '\n'.join(rows) + '</code></pre>\n'
        availability = ('Shared: available on every enabled target.' if module.startswith('core/')
                        else 'Hosted targets only.' if module.startswith('hosted/')
                        else 'Target scope is enforced by the module assertion below.')
        body = '<p class="api-condition">' + availability + '</p>\n' + prose(overview)
        if module.startswith('platform/'):
            # A module declares its scope once, in one of its files; a
            # generated file or one implementing a single system need not
            # repeat it.
            assertions = [found[0].strip()
                          for path, text in sorted(sources.items())
                          if str(Path(path).parent) == module
                          for found in [re.search(r'compiler\.assert\([\s\S]*?\)\s*', text)]
                          if found]
            if not assertions:
                raise ValueError(f'{module}: no target assertion')
            body += signature(assertions[0])
        body += '<h2>Items</h2>\n<ul class="api-index">\n'
        grouped = {}
        for item in items:
            grouped.setdefault(item.name, []).append(item)
        kinds = ('concept', 'type', 'atom', 'value', 'function')
        grouped = dict(sorted(grouped.items(), key=lambda entry:
                              (kinds.index(entry[1][0].kind), entry[0])))
        table = value_table(grouped)
        tabled = table.rows if table else {}
        for kind in kinds:
            for name, variants in grouped.items():
                if variants[0].kind == kind and name not in tabled:
                    body += f'<li><a href="#item-{name}">{name}</a> <span class="api-kind">{kind}</span></li>\n'
        if table:
            body += (f'<li><a href="#values">{len(tabled)} values by target</a> '
                     '<span class="api-kind">table</span></li>\n')
        body += ('</ul>\n<details id="example"><summary>Executable example</summary>\n'
                 '<p>This complete program is maintained in the repository runtime tests. ')
        body += f'<a href="{source_name(example_path)}#L1">View source</a>.</p>\n'
        example = (root / example_path).read_text()
        sources[example_path] = example
        body += render.listing_of(render.render_landin(example.splitlines(), render.Highlighter())) + '</details>\n'
        if table:
            body += value_section(table, module, source_name, reference, render,
                                  lambda ref: anchors.get(ref))
        for name, variants in grouped.items():
            if name in tabled:
                continue
            item = variants[0]
            body += f'<section class="api-item" id="{item.anchor}">\n<h2>{name} <span class="api-kind">{item.kind}</span></h2>\n'
            for variant in variants:
                if variant.condition:
                    body += '<p class="api-condition">When <code>' + html.escape(variant.condition) + '</code></p>\n'
                body += signature(variant.signature, '#' + item.anchor)
                body += f'<p class="api-source"><a href="{source_name(variant.source)}#L{variant.line}">{variant.source}:{variant.line}</a></p>\n'
                body += prose(variant.documentation, variant.source)
            body += '</section>\n'
        emit(page_name(module), module, body, module + '/*.ldn', module, overview.split('\n\n')[0])
    for path, text in sources.items():
        hl = render.Highlighter()
        body = '<pre class="api-signature"><code>' + '\n'.join(
            f'<span class="api-source-line" id="L{i}"><a class="api-line-number" href="#L{i}">{i}</a>{hl.line(line)}</span>'
            for i, line in enumerate(text.splitlines(), 1)) + '</code></pre>'
        emit(source_name(path), path, body, path, str(Path(path).parent))
    (destination / 'library-index.json').write_text(json.dumps(index, indent=2) + '\n')
    (destination / SEARCH_SCRIPT).write_text(search_index(index))
    verify(destination, pages, modules, render, sources,
           {module: text for module, (text, _) in descriptions.items()})
    return pages


def verify_table(module, page, table, render):
    """Every declaration a table holds is in its row, under its column."""
    from collections import Counter
    want = ['Name', 'Type'] + table.labels + ['Documentation']
    if [h.strip() for h in (page.headers[0] if page.headers else [])] != want:
        raise ValueError(f'{module}: value table columns changed')
    legend = [f'{label}: when {column}'
              for label, column in zip(table.labels, table.columns)]
    if [' '.join(entry.split()) for entry in page.legend] != legend:
        raise ValueError(f'{module}: value table legend changed')
    for name, (kind, items, values) in table.rows.items():
        anchor = 'item-' + name
        if anchor not in page.cells:
            raise ValueError(f'{module}: missing rendered declaration {anchor}')
        cells = [cell.strip() for cell in page.cells[anchor]]
        expected = [name, kind] + [values.get(c, '\u2014') for c in table.columns]
        if cells[:-1] != expected:
            raise ValueError(f'{module}.{anchor}: value table row changed: '
                             f'{cells[:-1]} for {expected}')
        # A merged documentation moves a sentence's full stop off the
        # word that differed, "x86-64." becoming "x86-64 / arm64.", so a
        # word is compared without the stop that ends it.
        def words(text):
            return Counter(render.WORD.findall(re.sub(r'\.(?=\s|$)', ' ', text)))
        got = words(''.join(page.items[anchor]))
        for item in items.values():
            missing = words(re.sub(r'\[([^\]]+)\]\([^)]+\)', r'\1',
                                   item.documentation)) - got
            if missing:
                raise ValueError(f'{module}.{anchor}: documentation lost words: '
                                 f'{sorted(missing)}')


def verify(destination, pages, modules, render, sources=None, overviews=None):
    """Check every local destination and each item's own visible content.

    With `overviews`, each module's prose from docs/library.md as well:
    every word of it must be in the page's overview, between the target
    line and the item index, so a table row or a paragraph the renderer
    dropped is caught here rather than by a reader.
    """
    from collections import Counter
    from html.parser import HTMLParser
    from urllib.parse import unquote, urlsplit

    class Page(HTMLParser):
        def __init__(self, text):
            super().__init__(convert_charrefs=True)
            self.ids, self.links, self.items = set(), [], {}
            self.current, self.depth, self.hidden, self.pre = None, 0, 0, 0
            # A table row is an item too, whose cells are kept one by one;
            # the table's header and its column legend likewise.
            self.item_tag, self.cells, self.heading = 'section', {}, None
            self.headers, self.legend, self.in_legend = [], [], 0
            self.in_table = False
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
            if self.current and tag in ('p', 'pre', 'h2', 'h3', 'li', 'section',
                                        'th', 'td'):
                self.items[self.current].append('\n')
            if self.current and tag in ('th', 'td'):
                self.cells[self.current].append('')
            if tag == 'table' and attrs.get('class') == 'api-table':
                self.in_table = True
            if tag == 'thead' and self.in_table:
                self.heading = []
            elif tag == 'th' and self.heading is not None:
                self.heading.append('')
            if tag == 'ul' and attrs.get('class') == 'api-columns':
                self.in_legend = 1
            elif tag == 'li' and self.in_legend:
                self.legend.append('')
            if 'id' in attrs:
                if attrs['id'] in self.ids:
                    raise ValueError('duplicate HTML anchor: ' + attrs['id'])
                self.ids.add(attrs['id'])
            if tag == 'a' and 'href' in attrs:
                self.links.append(attrs['href'])
            if tag == 'link' and attrs.get('rel') == 'stylesheet':
                self.links.append(attrs['href'])
            if tag == 'script' and 'src' in attrs:
                self.links.append(attrs['src'])
            if tag == 'input' and 'data-index' in attrs:
                # The search index the page loads is a local link too.
                self.links.append(attrs['data-index'])
            if self.current and tag == self.item_tag:
                self.depth += 1
            elif (not self.current and tag in ('section', 'tr')
                  and attrs.get('class') == 'api-item'):
                self.current, self.depth, self.item_tag = attrs['id'], 1, tag
                self.items[self.current], self.cells[self.current] = [], []
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
            if self.current and tag in ('p', 'pre', 'h2', 'h3', 'li', 'section',
                                        'th', 'td'):
                self.items[self.current].append('\n')
            if tag == 'thead' and self.heading is not None:
                self.headers.append(self.heading)
                self.heading = None
            if tag == 'table':
                self.in_table = False
            if tag == 'ul' and self.in_legend:
                self.in_legend = 0
            if tag == self.item_tag and self.current:
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
                if self.cells[self.current]:
                    self.cells[self.current][-1] += data
            if self.heading:
                self.heading[-1] += data
            if self.in_legend and self.legend:
                self.legend[-1] += data

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
    for module, text in (overviews or {}).items():
        written = (destination / page_name(module)).read_text()
        start = written.index('<p class="api-condition">')
        region = written[start:written.index('<h2>Items</h2>', start)]
        got = Counter(render.WORD.findall(html.unescape(re.sub(r'<[^>]+>', ' ', region))))
        want = Counter(render.WORD.findall(
            re.sub(r'\]\([^)]+\)', ']', text.replace('\\|', '|'))))
        missing = want - got
        if missing:
            raise ValueError(f'{module}: overview lost words: {sorted(missing)}')
    for module, items in modules.items():
        page = parsed[page_name(module)]
        grouped = {}
        for item in items:
            grouped.setdefault(item.anchor, []).append(item)
        by_name = {}
        for item in items:
            by_name.setdefault(item.name, []).append(item)
        table = value_table(by_name)
        if table:
            verify_table(module, page, table, render)
        for anchor, variants in grouped.items():
            if anchor not in page.items:
                raise ValueError(f'{module}: missing rendered declaration {anchor}')
            if table and variants[0].name in table.rows:
                continue
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
