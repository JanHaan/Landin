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
                # An alias whose right side the layout put on the next line,
                # or continued on more deeply indented ones: a union of
                # atoms written one `| ...` line after another.
                j = last
                while (j + 1 < len(codes) and codes[j+1].strip()
                       and codes[j+1].startswith(prefix + '    ')):
                    j += 1
                    code = code.rstrip() + ' ' + codes[j].strip()
                if '=' not in code or not code.split('=', 1)[1].strip():
                    raise ValueError(f'{source}:{i+1}: unsupported type alias')
                rhs = code.split('=', 1)[1].strip()
                if (re.search(r'\b(?:struct|concept|variant)\b', rhs)
                        or rhs.endswith('|')
                        or rhs.count('(') != rhs.count(')')
                        or rhs.count('[') != rhs.count(']')):
                    raise ValueError(f'{source}:{i+1}: unsupported multiline type')
                signature = '\n'.join(lines[i:j + 1])
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
        # What follows the link describes the program, and the page puts
        # it with the program, at its end.
        result[module] = (body[:example.start()].strip(), path,
                          body[example.end():].strip())
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


#  The library's own rules, after the site's: the shared sheet styles every
#  guide's sections, prose, listings and program panels, and these only
#  what a reference has and a guide does not.
CSS = '''
/* ---- without a script: no field to type into, no button that waits for one ---- */
:root:not(.api-js) .api-tools label, :root:not(.api-js) .api-tools input,
:root:not(.api-js) button.api-onpage, :root.api-js label.api-onpage-plain{display:none !important}
/*  The sidebar is on the left but after the page in the source; the
    shared skip link's style, and only where there is a sidebar to reach.  */
@media (max-width:60rem){ a.api-skip-nav{display:none} }

/* ---- search: full on the index, a small field after a module's opening ---- */
.api-tools{position:relative; margin:1.5rem 0 0}
.api-tools label{display:block; margin:0 0 .35rem; font-size:.85rem; color:var(--ink-soft)}
.api-tools input{width:100%; padding:.65rem .8rem; font:inherit; color:var(--ink);
  background:var(--panel); border-radius:0; -webkit-appearance:none; appearance:none;
  border:1px solid var(--rule-strong, color-mix(in oklch, var(--ink-faint) 80%, var(--bg)))}
/*  The browser's own clear button was a blue disc; Escape clears.  */
.api-tools input::-webkit-search-cancel-button{-webkit-appearance:none; appearance:none; display:none}
/*  The browser's own placeholder is the ink at reduced opacity, about 4:1.  */
.api-tools input::placeholder{color:var(--ink-faint); opacity:1}
.api-tools.compact{margin:.25rem 0 1.25rem; max-width:22rem}
.api-tools.compact label{margin:0 0 .25rem; font-family:var(--mono); font-size:.72rem;
  color:var(--ink-faint)}
.api-tools.compact input{padding:.38rem .6rem; font-size:.85rem}
/*  A panel over the page under the field: in the flow, the results
    pushed the page down under the reader.  */
.api-results{position:absolute; z-index:30; top:calc(100% + .25rem); left:0;
  width:min(100%, 40rem); max-height:min(65vh, 34rem); overflow:auto;
  overscroll-behavior:contain; padding:0 .9rem;
  background:var(--panel); border:1px solid var(--rule); box-shadow:var(--sh)}
.api-tools.compact .api-results{width:min(calc(100vw - 2.3rem), 34rem)}
.api-results p{margin:.5rem 0; max-width:none; font-size:.85rem; line-height:1.5;
  color:var(--ink-soft)}
.api-results p.api-count{font-family:var(--mono); font-size:.72rem; color:var(--ink-faint)}
.api-results a.api-hit{display:block; padding:.45rem 0 .5rem; text-decoration:none;
  border-top:1px solid var(--rule-soft)}
.api-results a.api-hit:focus-visible{outline-offset:-2px; background:var(--accent-bg)}
.api-hit-name{font-family:var(--mono); font-size:.85rem; color:var(--accent)}
.api-hit-module{color:var(--ink-faint)}
.api-hit-kind, .api-kind{font-family:var(--mono); font-size:.72rem; font-weight:400;
  text-transform:none; letter-spacing:0; color:var(--ink-faint)}
.api-hit-kind{margin-left:.6rem}
.api-hit-summary{display:-webkit-box; -webkit-box-orient:vertical; -webkit-line-clamp:2;
  line-clamp:2; overflow:hidden; margin-top:.1rem; font-size:.86rem; line-height:1.45;
  color:var(--ink-soft)}
.api-results a.api-hit:hover .api-hit-name{text-decoration:underline}

/* ---- the page's own contents, in the sidebar and the phone's drawer ---- */
nav.side .api-toc-label{display:block; padding:.3rem .75rem .25rem .8rem;
  font-family:var(--mono); font-size:.68rem; color:var(--ink-faint)}
nav.side a.api-toc-kind, nav.side .api-toc-group > summary{
  padding:.14rem .75rem .14rem 1.6rem; margin-left:-1px;
  border-left:1px solid transparent; font-family:var(--ui); font-size:.8rem;
  line-height:1.35; color:var(--ink-faint)}
nav.side a.api-toc-kind:hover{color:var(--ink)}
nav.side a.api-toc-kind.here, nav.side .api-toc-group > summary.here{
  color:var(--ink); border-left-color:var(--accent)}
nav.side .api-toc .count{margin-left:.3rem; font-family:var(--mono); font-size:.66rem;
  color:var(--ink-faint)}
/*  A kind folds its names: the shared summary's chevron and hidden count
    are for the document groups; a kind keeps its count beside its name.  */
nav.side details.api-toc-group{margin:0}
nav.side .api-toc-group > summary{justify-content:flex-start; gap:0}
nav.side .api-toc-group > summary::after{margin-left:.5rem}
nav.side .api-toc-group[open] > summary .count{visibility:visible}
nav.side a.api-toc-item{padding:.1rem .75rem .1rem 2.35rem; margin-left:-1px;
  border-left:1px solid transparent; font-family:var(--mono); font-size:.72rem;
  color:var(--ink-faint); overflow-wrap:anywhere}
nav.side a.api-toc-item:hover{color:var(--ink)}
nav.side a.api-toc-item.here{color:var(--ink); border-left-color:var(--accent-soft)}
@media (max-width:60rem){
  nav.side a.api-toc-kind, nav.side .api-toc-group > summary,
  nav.side a.api-toc-item{padding-block:.45rem; min-height:24px}
}
.api-onpage{display:none}
@media (max-width:60rem){
  .api-onpage{display:inline-flex; align-items:center; margin:0 0 1rem;
    padding:.4rem .75rem; min-height:2.5rem; cursor:pointer;
    font:inherit; font-family:var(--mono); font-size:.75rem; color:var(--ink-soft);
    background:none; border-radius:0;
    border:1px solid var(--rule-strong, color-mix(in oklch, var(--ink-faint) 80%, var(--bg)))}
  .api-onpage:hover, .api-onpage[aria-expanded="true"]{color:var(--accent);
    border-color:var(--accent-soft)}
}

/* ---- headings: the overview's sections, the items, the example ---- */
/*  A module's title has nothing under it but the skip link: no rule and
    no band between it and the opening.  */
.hero:not(:has(.api-tools)){border-bottom:0; padding-bottom:0; margin-bottom:0}
.hero:not(:has(.api-tools)) h1{margin-bottom:.75rem}
.api-opening{padding-top:0}
.api-prose section.guide{margin:0; border:0}
.api-prose div.guide{margin:0; padding:0}
/*  The opening paragraph is the guide's lead, outside its .guide, and ran
    the page's whole width: about 120 characters a line.  */
.api-prose > p{max-width:42rem}
section > h2.api-h, .api-prose section.api-section > h2, .api-modules > h2{
  font-size:1.35rem; font-weight:650; line-height:1.3; letter-spacing:-.01em;
  text-transform:none}
.api-condition{font-size:.85rem; color:var(--ink-soft)}

/* ---- the indexes: items by kind, and the modules ---- */
.api-group-title{margin:1.5rem 0 .45rem; font-size:.85rem; font-weight:600;
  color:var(--ink-soft)}
.api-group-title .count{margin-left:.35rem; font-family:var(--mono); font-size:.7rem;
  font-weight:400; color:var(--ink-faint)}
.api-group-title code{background:none; padding:0}
ul.api-index{list-style:none; margin:0; padding:0; columns:12rem; column-gap:2rem;
  border-top:1px solid var(--rule)}
ul.api-index li{break-inside:avoid; border-bottom:1px solid var(--rule-soft)}
ul.api-index a{display:block; padding:.3rem 0; text-decoration:none; font-size:.9rem}
ul.api-index code{padding:0; background:none; font-size:.85rem; color:var(--accent)}
ul.api-index a:hover code{text-decoration:underline}
/*  A phone had one column of 127 names.  */
@media (max-width:35rem){
  ul.api-index{columns:2; column-gap:1rem}
  ul.api-index code{font-size:.78rem; overflow-wrap:anywhere}
}
ul.api-modules-list{list-style:none; margin:0; padding:0; border-top:1px solid var(--rule)}
ul.api-modules-list li{display:grid; grid-template-columns:12rem minmax(0,1fr); gap:1.25rem;
  padding:.55rem 0; border-bottom:1px solid var(--rule-soft); align-items:baseline}
ul.api-modules-list li > a{text-decoration:none}
ul.api-modules-list li > a code{padding:0; background:none; font-size:.85rem; color:var(--accent)}
ul.api-modules-list li > a:hover code{text-decoration:underline}
ul.api-modules-list li > span{color:var(--ink-soft); font-size:.9rem; line-height:1.5}
@media (max-width:35rem){
  ul.api-modules-list li{grid-template-columns:minmax(0,1fr); gap:.15rem}
}

/* ---- one declaration: a heading row, the code, the prose ---- */
/*  Clear of the bar, as the shared sheet will set every addressed
    element in main; until then, here.  */
section.api-item, .api-source-line, .api-table tr{scroll-margin-top:calc(var(--bar) + 1rem)}
section.api-item{padding:1.6rem 0 1rem; border-top:1px solid var(--rule)}
.api-head{display:flex; flex-wrap:wrap; align-items:baseline; gap:.25rem .8rem;
  margin:0 0 .7rem}
h3.api-name{margin:0; font-size:1.1rem; line-height:1.3; font-weight:600;
  text-transform:none; letter-spacing:0}
h3.api-name code{padding:0; background:none; font-size:1em; color:var(--ink);
  text-transform:none; letter-spacing:0}
/*  Where it is declared, then the way back, apart: run together at the
    same faint size they read as one link.  */
.api-where{display:flex; flex-wrap:wrap; align-items:baseline; gap:.25rem 1.5rem;
  margin-left:auto}
a.api-source, a.api-back{font-family:var(--mono); font-size:.75rem; color:var(--ink-faint);
  text-decoration:none; white-space:nowrap}
a.api-source:hover, a.api-back:hover, a.api-source:focus-visible, a.api-back:focus-visible{
  color:var(--accent); text-decoration:underline}
@media (max-width:35rem){
  .api-where{flex-basis:100%; margin-left:0; justify-content:space-between}
}
.api-condition a.api-source{margin-left:.6rem}
.api-item .api-prose p{max-width:42rem}

/*  A declaration is one region that scrolls sideways; its members' `---`
    documentation is commentary between its lines, at their indentation.  */
.api-decl{margin:.3rem 0 .9rem; background:var(--code-bg);
  border:1px solid var(--code-rule, var(--rule))}
.api-decl > .scroller{margin:0; padding:.75rem 0}
pre.api-signature{margin:0; white-space:pre; font-size:.82rem; line-height:1.6; tab-size:4}
.api-decl pre.api-signature{padding:.15rem 1rem; overflow:visible}
.api-signature code{padding:0; background:none; border:0; font-size:1em}
/*  A name the declaration uses, quiet like the site's other linked code:
    its own colour with an accent underline, the accent only under the
    pointer or the keyboard.  */
.api-signature a{color:inherit; text-decoration:underline; text-decoration-style:dotted;
  text-decoration-thickness:1px; text-underline-offset:.22em;
  text-decoration-color:var(--accent-soft)}
.api-signature a:is(:hover,:focus-visible), .api-signature a:is(:hover,:focus-visible) span{
  color:var(--accent); text-decoration-style:solid; text-decoration-color:currentColor}
/*  Clear of the fade at the region's right edge, which is for the code.  */
.api-doc{max-width:42rem; margin:.35rem 2.75rem .6rem calc(1rem + var(--indent, 0) * 1ch);
  padding:0 0 0 .75rem; border-left:2px solid var(--rule); white-space:normal}
.api-doc p{margin:0 0 .3rem; max-width:40rem; font-family:var(--ui); font-size:.9375rem;
  line-height:1.55; color:var(--ink-soft)}
.api-doc p:last-child{margin-bottom:0}
.api-doc code{font-size:.85em}
/*  A source page's whole file.  */
main > pre.api-signature{padding:1rem; overflow-x:auto; background:var(--code-bg);
  border:1px solid var(--rule)}
/*  Inline blocks, not blocks: the newline between two blocks in a <pre>
    is a line of its own, and every source page was double-spaced.  */
.api-source-line{display:inline-block; min-width:100%}
.api-source-line:target{background:var(--accent-bg)}
.api-signature a.api-line-number{display:inline-block; min-width:4ch; margin-right:1.2em;
  color:var(--ink-faint); text-decoration:none; user-select:none}

/* ---- the overview's tables ---- */
.api-prose table.api-shaped{table-layout:fixed}
.api-prose table.api-shaped.short{table-layout:auto; width:auto; min-width:min(100%, 28rem)}
.api-prose table.short th, .api-prose table.short td{padding-right:2.5rem}
.api-prose table.api-shaped th[scope=row]{font-weight:600; color:var(--ink);
  border-bottom:1px solid var(--rule-soft); padding:7px 10px 7px 0; vertical-align:top}
.api-prose table.api-shaped tr:last-child th{border-bottom:0}
.api-prose .guide td code, .api-prose .guide th code{white-space:normal; overflow-wrap:break-word}
@media (max-width:48rem){
  .api-prose .guide td code, .api-prose .guide th code{overflow-wrap:anywhere}
}
/*  A phone stacks only a table whose columns cannot share its width (the
    generator marks it): each row a block, each cell, the first too,
    under its column's title.  */
@media (max-width:35rem){
  .api-prose table.api-stack, .api-prose table.api-stack tbody,
  .api-prose table.api-stack tr, .api-prose table.api-stack th[scope=row],
  .api-prose table.api-stack td{display:block; width:auto}
  .api-prose table.api-stack colgroup{display:none}
  .api-prose table.api-stack thead{position:absolute; width:1px; height:1px;
    overflow:hidden; clip-path:inset(50%)}
  .api-prose table.api-stack tr{padding:.55rem 0; border-bottom:1px solid var(--rule-soft)}
  .api-prose table.api-stack tr:last-child{border-bottom:0}
  .api-prose table.api-stack th[scope=row], .api-prose table.api-stack td{
    border:0; padding:.05rem 0}
  .api-prose table.api-stack :is(th[scope=row], td)[data-label]:not([data-label=""])::before{
    content:attr(data-label); display:block;
    margin-top:.25rem; font-family:var(--mono); font-size:.68rem; font-weight:400;
    color:var(--ink-faint)}
  .api-prose table.api-stack th[scope=row]::before{margin-top:0}
  /*  A yes-or-no column is a small tag beside the row's name.  */
  .api-prose table.api-stack tr:has(td.api-flag){display:flex; flex-wrap:wrap;
    align-items:flex-end; column-gap:.6rem}
  .api-prose table.api-stack tr:has(td.api-flag) > *{flex:1 0 100%; order:2}
  .api-prose table.api-stack tr:has(td.api-flag) > th[scope=row]{flex:0 1 auto; order:0}
  .api-prose table.api-stack tr:has(td.api-flag) > td.api-flag{flex:0 0 auto; order:1; padding:0 .35rem;
    font-family:var(--mono); font-size:.7rem; color:var(--ink-soft);
    border:1px solid var(--rule)}
  .api-prose table.api-stack tr > td.api-flag[data-label]:not([data-label=""])::before{content:attr(data-label) ": ";
    display:inline; margin:0; font-size:1em}
}

/* ---- the values-by-target table ---- */
.api-table{border-collapse:collapse; font-size:.9rem}
.api-table th, .api-table td{text-align:left; padding:.25rem .8rem .25rem 0;
  border-bottom:1px solid var(--rule); vertical-align:top}
.api-table th[scope=row]{font-weight:600; font-family:var(--mono); font-size:.85rem}
.api-table tr:target{background:var(--accent-bg)}
.api-table td code, .api-table th code{white-space:nowrap}

/* ---- the example: the site's program panel ---- */
figure.panel.api-program{margin:1rem 0 0}
'''

SEARCH_SCRIPT = 'library-search.js'

#  Marks the page as one whose scripts run: without them the search field
#  and the "On this page" button are hidden, and the plain label and the
#  noscript line stand in.
SCRIPTED = "document.documentElement.classList.add('api-js');\n"

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
 if(!field)return;
 const tools=field.closest('.api-tools');
 const results=document.getElementById('api-results');
 let items=null, loading=false;
 const normalize=s=>s.toLowerCase().replaceAll('::','.');
 function entry(item){
  const name=normalize(item.name), cut=name.lastIndexOf('.');
  return {item,name,leaf:name.slice(cut+1),rest:normalize(item.summary+' '+item.kind)};
 }
 function load(){
  if(items||loading)return;
  loading=true;
  const script=document.createElement('script');
  script.src=field.dataset.index;
  script.onload=()=>{items=(window.landinLibraryIndex||[]).map(entry);show();};
  script.onerror=()=>{loading=false;open(true);
   results.textContent='The search index could not be loaded; browse the module and item indexes below.';};
  document.head.append(script);
 }
 function span(cls,text){const s=document.createElement('span');s.className=cls;s.textContent=text;return s;}
 /* How well a term names an entry, best first: the name itself, the
    start of the name, inside the name, the module, then the summary.
    By the summary alone, "read" led with every function whose summary
    says "reads". */
 function tier(e,t){
  if(e.leaf===t||e.name===t||e.name.endsWith('/'+t))return 0;
  if(e.leaf.startsWith(t))return 1;
  if(e.leaf.includes(t))return 2;
  if(e.name.includes(t))return 3;
  if(e.rest.includes(t))return 4;
  return -1;
 }
 function open(on){
  results.hidden=!on;
  field.setAttribute('aria-expanded',on?'true':'false');
 }
 function show(){
  const query=field.value.trim();
  const terms=normalize(query).split(/\\s+/).filter(Boolean);
  results.replaceChildren();
  if(!terms.length){open(false);return;}
  if(!items){load();return;}
  const ranked=[];
  for(const e of items){
   let score=0;
   for(const t of terms){const r=tier(e,t);if(r<0){score=-1;break;}score+=r;}
   if(score>=0)ranked.push([score,e]);
  }
  ranked.sort((a,b)=>a[0]-b[0]||a[1].leaf.length-b[1].leaf.length||(a[1].name<b[1].name?-1:1));
  const matches=ranked.map(r=>r[1].item);
  open(true);
  if(!matches.length){
   /* Nothing found says what to try next, not only that nothing was. */
   const p=document.createElement('p');
   const a=document.createElement('a');a.href='library.html#modules';a.textContent='the module index';
   p.append('Nothing matches "'+query+'". Try a shorter term, or a module name such as text or io, or browse ',a,'.');
   results.append(p);return;
  }
  const count=document.createElement('p');count.className='api-count';
  count.textContent=matches.length+(matches.length===1?' result':' results');results.append(count);
  for(const item of matches.slice(0,80)){
   /* The module, faint, then the name: core/io.open_read. */
   const a=document.createElement('a');a.href=item.url;a.className='api-hit';
   const cut=item.name.lastIndexOf('.')+1;
   const name=span('api-hit-name','');
   const module=span('api-hit-module','');module.textContent=item.name.slice(0,cut);
   name.append(module,item.name.slice(cut));
   a.append(name,span('api-hit-kind',item.kind),span('api-hit-summary',item.summary));
   results.append(a);
  }
  if(matches.length>80){const p=document.createElement('p');p.textContent='Showing the first 80; refine your search.';results.append(p);}
 }
 /* The keys a list of results answers: down and up move through them,
    up from the first and Escape go back to the field, and Escape in the
    field closes the panel before it clears the text. */
 const hits=()=>[].slice.call(results.querySelectorAll('a.api-hit'));
 field.addEventListener('keydown',e=>{
  if(e.key==='ArrowDown'){
   const h=hits();
   if(h.length){e.preventDefault();open(true);h[0].focus();}
  }else if(e.key==='Escape'&&!results.hidden){e.preventDefault();e.stopPropagation();open(false);}
 });
 results.addEventListener('keydown',e=>{
  const h=hits(), at=h.indexOf(document.activeElement);
  if(e.key==='ArrowDown'){e.preventDefault();if(at>=0&&at<h.length-1)h[at+1].focus();}
  else if(e.key==='ArrowUp'){e.preventDefault();if(at>0)h[at-1].focus();else field.focus();}
  else if(e.key==='Escape'){e.preventDefault();e.stopPropagation();field.focus();}
 });
 /* The panel lies over the page, so it goes when the reader leaves it:
    by a result followed, a click elsewhere or focus moved on. */
 results.addEventListener('click',e=>{if(e.target.closest('a'))open(false);});
 results.addEventListener('mousedown',e=>{if(e.target===results)e.preventDefault();});
 tools.addEventListener('focusout',e=>{if(!tools.contains(e.relatedTarget))open(false);});
 field.addEventListener('focus',()=>{if(results.childElementCount&&field.value.trim())open(true);});
 field.addEventListener('focus',load,{once:true});
 field.addEventListener('input',show);
})();
'''


#  The sidebar keeps the page's own contents in view: on a desktop, the
#  current module's entry scrolled up to where it can be seen, and in the
#  phone's drawer the same, each time it opens.  While an item is read,
#  its kind's list of names is open and its own name lit -- the shared bar
#  lights only sections the sidebar names, and the items are too many to
#  name there unfolded.  On a phone, "On this page" opens the drawer at
#  those contents, and focus goes with it: it never stays behind the
#  drawer, which closes when focus leaves it.
CONTENTS = """
(() => {
 const side=document.querySelector('nav.side');
 const toc=document.getElementById('api-toc');
 /* The skip link lands on the page's own entry, so the next Tab is its
    contents; followed as a plain fragment, focus stayed in the page. */
 const skip=document.querySelector('a.api-skip-nav');
 if(skip&&side)skip.addEventListener('click',e=>{
  const here=side.querySelector('a[aria-current]')||side.querySelector('a');
  if(here){e.preventDefault();here.focus();}
 });
 if(!side||!toc)return;
 const own=toc.previousElementSibling;
 let timer=0, lit=null, opened=null;
 /* The drawer opens at the name being read, or at the module's entry. */
 function reveal(always){
  const box=side.getBoundingClientRect(), at=(lit||own||toc).getBoundingClientRect();
  if(!always && at.top>=box.top && at.bottom<=box.top+box.height*0.6)return;
  side.scrollTop+=at.top-box.top-(lit?box.height/3:12);
 }
 if(getComputedStyle(side).position==='sticky')reveal(false);
 const menu=document.getElementById('menu');
 const bar=document.querySelector('header.bar');
 const onpage=document.getElementById('api-onpage');
 const drawer=()=>menu&&menu.checked&&getComputedStyle(side).position==='fixed';
 function sync(){if(onpage)onpage.setAttribute('aria-expanded',menu&&menu.checked?'true':'false');}
 function setMenu(on){
  if(!menu||menu.checked===on)return;
  menu.checked=on;menu.dispatchEvent(new Event('change'));
 }
 if(menu){
  menu.addEventListener('change',()=>{
   sync();
   if(menu.checked)requestAnimationFrame(()=>reveal(true));
  });
  /* The shared script closes the drawer on a followed link and on
     Escape without a change event; the button's state follows. */
  document.addEventListener('click',()=>setTimeout(sync,0));
 }
 let fromButton=false;
 if(onpage&&menu){
  onpage.addEventListener('click',()=>{
   const opening=!menu.checked;
   setMenu(opening);
   fromButton=opening;
   if(opening){
    const first=toc.querySelector('a.api-toc-item.here')||toc.querySelector('.here')
     ||toc.querySelector('a, summary');
    if(first)first.focus({preventScroll:true});
   }
  });
  document.addEventListener('keydown',e=>{
   if(e.key==='Escape'&&menu.checked&&fromButton)
    setTimeout(()=>{sync();onpage.focus();fromButton=false;},0);
  });
 }
 if(menu)document.addEventListener('focusin',e=>{
  if(!drawer())return;
  const t=e.target;
  if(side.contains(t)||t===menu||t===onpage||(bar&&bar.contains(t)))return;
  setMenu(false);fromButton=false;
 });
 const kinds={}, groups={}, names={};
 toc.querySelectorAll('a.api-toc-kind[href^="#items-"]').forEach(a=>{
  kinds[a.getAttribute('href').slice(7)]=a;
 });
 toc.querySelectorAll('details.api-toc-group').forEach(d=>{
  groups[d.dataset.kind]=d;
  /* A list the reader opened or closed is the reader's from then on. */
  d.querySelector('summary').addEventListener('click',()=>{d.dataset.held='1';});
 });
 toc.querySelectorAll('a.api-toc-item').forEach(a=>{names[a.getAttribute('href').slice(1)]=a;});
 const items=[].slice.call(document.querySelectorAll('main section.api-item'));
 if(!items.length)return;
 function mark(){
  /* Past the 1rem an item lands below the bar. */
  const line=(bar?bar.getBoundingClientRect().bottom:48)+24;
  let low=0, high=items.length-1, best=-1;
  while(low<=high){
   const middle=(low+high)>>1;
   if(items[middle].getBoundingClientRect().top<=line){best=middle;low=middle+1;}
   else high=middle-1;
  }
  const item=best>=0 && items[best].getBoundingClientRect().bottom>line ? items[best] : null;
  const now=item ? item.dataset.kind : null;
  for(const kind in kinds)kinds[kind].classList.toggle('here',kind===now);
  for(const kind in groups)groups[kind].querySelector('summary').classList.toggle('here',kind===now);
  const group=now&&groups[now];
  if(opened&&opened!==group&&!opened.dataset.held){opened.open=false;opened=null;}
  if(group&&!group.open&&!group.dataset.held){group.open=true;opened=group;}
  const name=item&&names[item.id];
  if(lit!==name){
   if(lit)lit.classList.remove('here');
   lit=name||null;
   if(lit){
    lit.classList.add('here');
    /* The lit name stays in the sidebar's view, unless the reader is
       using the sidebar. */
    if(!side.matches(':hover, :focus-within')){
     const box=side.getBoundingClientRect(), at=lit.getBoundingClientRect();
     if(at.top<box.top+24||at.bottom>box.bottom-24)side.scrollTop+=at.top-box.top-box.height/3;
    }
   }
  }
 }
 addEventListener('scroll',()=>{clearTimeout(timer);timer=setTimeout(mark,60);},{passive:true});
 addEventListener('hashchange',mark);
 mark();
})();
"""


def value_section(table, module, source_name, reference, render, links):
    """The table: a row per name, a column per target condition."""
    out = ['<section class="api-values" id="values" data-title="Values by target">'
           '<h2 class="api-h">Values by target</h2>'
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


def search_box(compact=False):
    """The search field; its script is in the linked library.js.

    Full width on the index, where finding a name is what the page is
    for; a small field under a module's opening paragraph, where the
    module is, with a short label that says it searches every module.
    The results are a panel over the page under the field, not a block
    that pushed the page down.
    """
    cls = 'api-tools compact' if compact else 'api-tools'
    label = 'search all library APIs' if compact else 'Search library APIs'
    return (f'<div class="{cls}">\n<label for="api-search">{label}</label>\n'
            '<input type="search" id="api-search" placeholder="Name, module or purpose" '
            f'data-index="{SEARCH_SCRIPT}" '
            'aria-controls="api-results" aria-expanded="false" autocomplete="off">\n'
            '<div id="api-results" class="api-results" aria-live="polite" hidden></div>\n'
            '<noscript>Browse the module and item indexes below; search needs JavaScript.</noscript>\n'
            '</div>\n')


def search_index(index):
    """The script every page loads on first search: the index, once."""
    data = json.dumps(index, ensure_ascii=True, separators=(',', ':'))
    return 'window.landinLibraryIndex=' + data.replace('<', '\\u003c') + ';\n'


KINDS = ('concept', 'type', 'atom', 'value', 'function')
KIND_TITLES = {'concept': 'Concepts', 'type': 'Types', 'atom': 'Atoms',
               'value': 'Values', 'function': 'Functions'}

#  A titled section of the guide renderer: what the sidebar lists under the
#  page being read.
TITLED = re.compile(r'<section class="guide" id="([^"]+)" data-title="([^"]*)">')


def untitled_lead(body):
    """The guide renderer's untitled lead as a <div>, not a <section>.

    The shared bar names the last <section> scrolled past, and an item's
    documentation renders through the same reader: as sections, each
    item's prose took the label back from the item's own name.
    """
    lead = '<section class="guide" id="top">'
    if body.startswith(lead):
        end = body.index('\n</section>')
        body = ('<div class="guide">' + body[len(lead):end] + '\n</div>'
                + body[end + len('\n</section>'):])
    return body


def toc_html(entries, label):
    """The page's own sections, nested under its link in the sidebar.

    `entries` are (href, title, cls) or (href, title, cls, names):
    `sect` links are the shared bar's, which follow the section being
    read; `api-toc-kind` ones are this page's script's, which follow the
    kind of the item being read.  An entry with names is a kind whose
    items the sidebar lists, folded: a reader halfway down a module could
    find the kinds there but not one of their names.
    """
    if not entries:
        return ''
    out = [f'<div class="toc api-toc" id="api-toc"><span class="api-toc-label">{label}</span>']
    for href, title, cls, *names in entries:
        if names:
            out.append(f'<details class="api-toc-group" data-kind="{href.removeprefix("#items-")}">'
                       f'<summary class="{cls}">{title}</summary>'
                       + ''.join(f'<a class="api-toc-item" href="#item-{name}">{name}</a>'
                                 for name in names[0])
                       + '</details>')
        else:
            out.append(f'<a class="{cls}" href="{href}">{title}</a>')
    out.append('</div>')
    return '\n'.join(out)


#  The shared renderer marks a table it stacks on a phone with a class
#  and its cells with labels; the library sets its own, so either form is read.
TABLE = re.compile(r'<table(?:\s[^>]*)?>(.*?)</table>', re.S)
ROW_HTML = re.compile(r'<tr>(.*?)</tr>', re.S)
CELL_HTML = re.compile(r'<td(?:\s[^>]*)?>(.*?)</td>', re.S)
TAGS = re.compile(r'<[^>]+>')
CODE_HTML = re.compile(r'<code>(.*?)</code>', re.S)
LINKED_HTML = re.compile(r'(<a\b[^>]*>.*?</a>)', re.S)
#  What a code span in a table names: a call, perhaps bound or tried --
#  `mut out := io.buffered_over(...)`, `try io.read_line(lines)` -- or a
#  name alone.
CALLED = re.compile(r'(?:(?:mut\s+)?\w+\s*:=\s*)?(?:try\s+)?(\w+(?:\.\w+)?)(?:\(.*\))?')


#  Below this many characters across its columns' typical cells, a table is
#  set at its own width.
SHORT_TABLE = 50

#  A phone stacks a table into records only when its columns cannot share
#  the width: three or more of them, which leave about seven rem each and
#  broke a header's code mid-word, or two with a code span this long.  A
#  table of short cells, set at its own width, never stacks.  Stacked
#  everywhere, a two-column table of short calls became twice as tall
#  and no easier to read.
STACK_COLUMNS = 3
STACK_CODE = 32
#  A column whose every cell is at most this long -- yes, no, a dash --
#  is a tag beside the row's name when the row is stacked.
FLAG = 3


def plain(cell):
    return ' '.join(html.unescape(TAGS.sub('', cell)).split())


def stacks(head, rows):
    """Does a table need its rows stacked on a phone?"""
    if len(head) >= STACK_COLUMNS:
        return True
    return max((len(plain(code)) for row in rows for cell in row
                for code in CODE_HTML.findall(cell)), default=0) >= STACK_CODE


def column_widths(head, rows):
    """Each column's share of a table, from what its cells hold.

    The browser's own sizing gave a long column everything and wrapped a
    short one to a word a line; a header's words count less than a
    cell's, so "Part of world" over yes and no stays narrow.
    """
    weights = []
    for i, title in enumerate(head):
        texts = [' '.join(html.unescape(TAGS.sub('', r[i])).split())
                 for r in rows if i < len(r)] or ['']
        average = sum(map(len, texts)) / len(texts)
        # A column is never narrower than its longest word, which would
        # otherwise be cut: hosted/system lost its last letter.
        longest = max(len(word) for text in texts for word in text.split() or [''])
        weights.append(min(60.0, max(5.0, average, longest, .6 * len(title))))
    total = sum(weights)
    return [round(100 * w / total) for w in weights], total


def shape_tables(text, link):
    """The overview's tables: widths, row headers, labels and links.

    Each cell carries its column's title for a phone, where a row is
    stacked into a block; the first cell of a row is its header; and a
    code span naming a library declaration links to it.
    """
    def one(match):
        inner = match[1]
        head = [' '.join(html.unescape(TAGS.sub('', h)).split())
                for h in re.findall(r'<th scope="col">(.*?)</th>', inner, re.S)]
        rows = [CELL_HTML.findall(r) for r in ROW_HTML.findall(inner.split('<tbody>', 1)[-1])]
        widths, total = column_widths(head, rows)
        # A table of short cells is as wide as they are, not the page:
        # stretched, two words sat half a page apart.
        if total < SHORT_TABLE:
            shaped, cols = 'api-shaped short', ''
        else:
            shaped = 'api-shaped'
            cols = '<colgroup>' + ''.join(f'<col style="width:{w}%">' for w in widths) + '</colgroup>'
        stacked = total >= SHORT_TABLE and stacks(head, rows)
        if stacked:
            shaped += ' api-stack'
        flags = {i for i in range(1, len(head)) if stacked
                 and all(i < len(r) and len(plain(r[i])) <= FLAG for r in rows)}

        def row(found):
            cells = CELL_HTML.findall(found[1])
            out = []
            for i, cell in enumerate(cells):
                label = html.escape(head[i]) if i < len(head) else ''
                cell = linked_code(cell, link)
                if i == 0:
                    out.append(f'<th scope="row" data-label="{label}">{cell}</th>')
                else:
                    flag = ' class="api-flag"' if i in flags else ''
                    out.append(f'<td{flag} data-label="{label}">{cell}</td>')
            return '<tr>' + '\t'.join(out) + '</tr>'
        head_part, _, body_part = inner.partition('<tbody>')
        return (f'<table class="{shaped}">{cols}'
                + head_part + '<tbody>' + ROW_HTML.sub(row, body_part) + '</table>')
    return TABLE.sub(one, text)


def linked_code(cell, link):
    """`cell` with each code span that names a declaration made a link."""
    parts = LINKED_HTML.split(cell)
    for i in range(0, len(parts), 2):
        def code(found):
            called = CALLED.fullmatch(' '.join(html.unescape(found[1]).split()))
            target = link(called[1]) if called else None
            return f'<a href="{target}">{found[0]}</a>' if target else found[0]
        parts[i] = CODE_HTML.sub(code, parts[i])
    return ''.join(parts)


def write(root, destination, render):
    """Render with the site's shell, Markdown reader, fonts and highlighter."""
    modules, sources = collect(root)
    anchors = {ref: d['out'] + '#' + ref for d in render.DOCS
               for ref in re.findall(r'^### \[(\d{4})\]', (root / d['src']).read_text(), re.M)}
    intro, descriptions = overviews(root, modules)
    exports = {module: {i.name for i in items} for module, items in modules.items()}
    leaves = {}
    for module in modules:
        leaves.setdefault(module.split('/')[-1], []).append(module)
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
    pages = []
    # The shared renderer's module, whose document groups the sidebar
    # lists after the modules rather than a copy of them.
    renderer = sys.modules[render.page.__module__]

    def resolver(current, aliases=None):
        """Where a name written in `current`'s prose is declared, or None."""
        def link(name):
            if '.' in name:
                qualifier, leaf = name.split('.', 1)
                target = (aliases or {}).get(qualifier)
                if target is None and current and current.split('/')[-1] == qualifier:
                    target = current
                if target is None and len(leaves.get(qualifier, [])) == 1:
                    target = leaves[qualifier][0]
                if target and leaf in exports[target]:
                    return ('' if target == current else page_name(target)) + '#item-' + leaf
            elif current and name in exports[current]:
                return '#item-' + name
            return None
        return link

    def nav(current, toc=''):
        here = ' aria-current="page"' if current == 'library.html' else ''
        out = ['<a class="doc" href="index.html">the front page</a>',
               f'<a class="doc{" here" if here else ""}"{here} href="library.html">library reference</a>',
               toc if here else '',
               '<a class="doc" href="core.html">library guide</a>']
        for base in ROOTS:
            out.append('<details open><summary>' + base + '</summary>')
            for module in modules:
                if module.startswith(base + '/'):
                    here = ' aria-current="page"' if module == current else ''
                    cls = 'doc here' if here else 'doc'
                    out.append(f'<a class="{cls}"{here} href="{page_name(module)}">{module}</a>')
                    if here:
                        out.append(toc)
            out.append('</details>')
        # The site's own documents, in the shared renderer's groups and
        # order, folded below the modules: from a module page the tour
        # and the examples were out of reach.
        for num, name, members in renderer.nav_groups(render.DOCS + render.GUIDES):
            out.append(f'<details class="api-docs"><summary>{num} · {html.escape(name)}'
                       f'<span class="count">{len(members)}</span></summary>')
            for d in members:
                cls = 'doc retired' if d['key'] in renderer.RETIRED else 'doc'
                out.append(f'<a class="{cls}" href="{d["out"]}">{html.escape(d["nav"])}</a>')
            out.append('</details>')
        return '\n'.join(part for part in out if part)

    def prose(text, source='docs/library.md', link=None, after_lead=''):
        # A link to a module's directory, `[core/io](../core/io)`, is its
        # page here, and the directory itself where the source is read.
        targets = render.guide_targets(render.DOCS + render.GUIDES, source)
        targets.pages.update({module: page_name(module) for module in modules})
        _, hero, body, _ = render.render_guide(text, lambda ref: anchors.get(ref),
                    targets, render.Highlighter())
        out = hero + after_lead + untitled_lead(body)
        if link is not None:
            out = shape_tables(out, link)
        return '<div class="api-prose">\n' + out + '</div>\n'

    def emit(filename, title, body, source, current='', description='',
             toc='', search=False):
        # The sidebar follows the page in the source, so a page read as
        # text opens with the module rather than with every module's name;
        # a keyboard reader skips to it from here rather than tabbing
        # through every link of the page first.
        hero = ('<a class="skip api-skip-nav" href="#side">skip to the library navigation</a>\n'
                + (search_box() if search else ''))
        out = render.page(title + ' — Landin', 'library reference', title,
                          hero, body, nav(current, toc), source,
                          out=filename, description=description, linked=LINKED,
                          source_note='API reference derived from library sources. The specification defines language rules.')
        (destination / filename).write_text(out)
        pages.append(filename)

    def on_this_page():
        # The drawer holds the module's own contents; on a phone this
        # opens it there rather than at the top of the module list, and
        # takes focus into it.  A button, so a keyboard reaches it; without
        # a script the drawer's own box is what opens it.
        return ('<button type="button" class="api-onpage" id="api-onpage" '
                'aria-controls="side" aria-expanded="false">On this page</button>\n'
                '<label for="menu" class="api-onpage api-onpage-plain">On this page</label>\n')

    for name, text in render.linked_assets(LINKED, CSS, SEARCH + CONTENTS).items():
        if name == LINKED + '-theme.js':
            # Run in the head, so the controls only a script can work are
            # shown or hidden before the first paint, not after the page.
            text += SCRIPTED
        (destination / name).write_text(text)
    body = prose(intro.replace('# Library reference', '', 1), link=resolver(''))
    body = '<section class="api-opening">\n' + body + '</section>\n'
    toc = [(f'#{sid}', title, 'sect') for sid, title in TITLED.findall(body)]
    body += ('<section class="api-modules" id="modules" data-title="Modules">\n'
             '<h2>Modules</h2>\n')
    toc.append(('#modules', 'Modules', 'sect'))
    for base in ROOTS:
        body += (f'<div class="api-group" id="modules-{base}">'
                 f'<h3 class="api-group-title">{base}</h3>\n<ul class="api-modules-list">\n')
        toc.append((f'#modules-{base}', base, 'api-toc-kind'))
        for module in modules:
            if module.startswith(base + '/'):
                summary = descriptions[module][0].split('\n\n')[0]
                # Through the inline formatter, as the module's own page
                # renders it: escaped, it showed its backticks literally.
                written = render.inline(" ".join(summary.split()),
                                        lambda ref: anchors.get(ref),
                                        render.guide_targets(render.DOCS + render.GUIDES,
                                                             'docs/library.md'))
                body += (f'<li id="{module.replace("/", "-")}"><a href="{page_name(module)}">'
                         f'<code>{module}</code></a>\n<span>{written}</span></li>\n')
        body += '</ul></div>\n'
    body += '</section>\n'
    emit('library.html', 'Library reference', body,
         'docs/library.md and core, hosted, platform sources', 'library.html',
         toc=toc_html(toc, 'On this page'), search=True)
    for module, items in modules.items():
        overview, example_path, example_prose = descriptions[module]
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
            """The declaration as code, its members' documentation as prose.

            A concept's entries and a struct's fields carry `---` lines; in
            the code panel they were lines no phone could wrap.
            """
            scanner = Scanner()
            blocks = []          # ('code', [rows]) or ('doc', indent, [text])
            for line in text.splitlines():
                tokens = list(scanner.scan(line))
                said = DOC.fullmatch(line)
                if said:
                    indent = len(line) - len(line.lstrip())
                    if blocks and blocks[-1][0] == 'doc' and blocks[-1][1] == indent:
                        blocks[-1][2].append(said[1])
                    else:
                        blocks.append(('doc', indent, [said[1]]))
                    continue
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
                if blocks and blocks[-1][0] == 'code':
                    blocks[-1][1].append(''.join(spans))
                else:
                    blocks.append(('code', [''.join(spans)]))
            # One region scrolls sideways, the declaration whole, and fades
            # at its edge through the shared script's `.scroller`: as a
            # region per run of code, one declaration was several.
            out = ['<div class="api-decl"><div class="scroller">']
            for block in blocks:
                if block[0] == 'code':
                    out.append('<pre class="api-signature"><code>' + '\n'.join(block[1])
                               + '</code></pre>')
                else:
                    paragraphs = '\n'.join(block[2]).strip().split('\n\n')
                    out.append(f'<div class="api-doc" style="--indent:{block[1]}">' + ''.join(
                        '<p>' + re.sub(r'`([^`]+)`', r'<code>\1</code>',
                                       html.escape(' '.join(p.split()), quote=False)) + '</p>'
                        for p in paragraphs if p.strip()) + '</div>')
            return '\n'.join(out) + '\n</div></div>\n'
        availability = ('Shared: available on every enabled target.' if module.startswith('core/')
                        else 'Hosted targets only.' if module.startswith('hosted/')
                        else 'Target scope is enforced by the module assertion below.')
        # The opening is a section of its own, untitled, so the bar says
        # what the page is until the reader reaches the overview's first
        # section: the shared script otherwise names the first one at once.
        body = ('<section class="api-opening">\n' + on_this_page()
                + '<p class="api-condition">' + availability + '</p>\n')
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
        body += '</section>\n'
        # A `###` of the overview is a section of the page, beside the
        # items and the example: under the h1 it was an h3 with no h2.
        # The compact search follows the module's opening paragraph: between
        # the title and the description it came before what the page is.
        written = prose(re.sub(r'^### ', '## ', overview, flags=re.M),
                        link=resolver(module, aliases), after_lead=search_box(True))
        written = written.replace('<section class="guide" id=',
                                  '<section class="guide api-section" id=')
        body += written
        toc = [(f'#{sid}', title, 'sect') for sid, title in
               re.findall(r'<section class="guide api-section" id="([^"]+)" data-title="([^"]*)">',
                          written)]
        grouped = {}
        for item in items:
            grouped.setdefault(item.name, []).append(item)
        grouped = dict(sorted(grouped.items(), key=lambda entry:
                              (KINDS.index(entry[1][0].kind), entry[0])))
        table = value_table(grouped)
        tabled = table.rows if table else {}
        body += ('<section class="api-items" id="items" data-title="Items">\n'
                 '<h2 class="api-h">Items</h2>\n<div class="api-groups">\n')
        toc.append(('#items', 'Items', 'sect'))
        for kind in KINDS:
            names = [name for name, variants in grouped.items()
                     if variants[0].kind == kind and name not in tabled]
            if not names:
                continue
            title = KIND_TITLES[kind]
            body += (f'<div class="api-group" id="items-{kind}">'
                     f'<h3 class="api-group-title">{title} '
                     f'<span class="count">{len(names)}</span></h3>\n<ul class="api-index">\n')
            body += ''.join(f'<li><a href="#item-{name}"><code>{name}</code></a></li>\n'
                            for name in names)
            body += '</ul></div>\n'
            toc.append((f'#items-{kind}', f'{title} <span class="count">{len(names)}</span>',
                        'api-toc-kind', names))
        body += ('<div class="api-group" id="items-other">'
                 '<h3 class="api-group-title">Also on this page</h3>\n<ul class="api-index">\n')
        if table:
            body += (f'<li><a href="#values">{len(tabled)} values by target</a></li>\n')
        body += '<li><a href="#example">The example program</a></li>\n</ul></div>\n'
        body += '</div>\n</section>\n'
        if table:
            body += value_section(table, module, source_name, reference, render,
                                  lambda ref: anchors.get(ref))
            toc.append(('#values', 'Values by target', 'sect'))
        for name, variants in grouped.items():
            if name in tabled:
                continue
            item = variants[0]
            # The source line beside the name when there is one; a name
            # declared once per target says each one's under its condition.
            only = variants[0] if len(variants) == 1 else None
            source = (f'<a class="api-source" href="{source_name(only.source)}#L{only.line}">'
                      f'{only.source}:{only.line}</a>\n') if only else ''
            # The name and kind, then where it is declared and the way back:
            # on a phone those two are a row of their own under the name.
            body += (f'<section class="api-item" id="{item.anchor}" data-title="{name}" '
                     f'data-kind="{item.kind}">\n<div class="api-head">\n'
                     f'<h3 class="api-name"><code>{name}</code></h3>\n'
                     f'<span class="api-kind">{item.kind}</span>\n'
                     f'<span class="api-where">\n{source}'
                     f'<a class="api-back" href="#items-{item.kind}" '
                     f'aria-label="back to the item index">↑ index</a>\n</span>\n</div>\n')
            for variant in variants:
                if variant.condition:
                    body += ('<p class="api-condition">When <code>' + html.escape(variant.condition)
                             + '</code>' + ('' if only else
                                            f'\n<a class="api-source" href="{source_name(variant.source)}'
                                            f'#L{variant.line}">{variant.source}:{variant.line}</a>\n')
                             + '</p>\n')
                body += signature(variant.signature, '#' + item.anchor)
                body += prose(variant.documentation, variant.source)
            body += '</section>\n'
        body += example_section(root, example_path, example_prose, prose, render)
        toc.append(('#example', 'Example program', 'sect'))
        sources[example_path] = (root / example_path).read_text()
        emit(page_name(module), module, body, module + '/*.ldn', module,
             overview.split('\n\n')[0], toc=toc_html(toc, 'In this module'))
    for path, text in sources.items():
        hl = render.Highlighter()
        body = '<pre class="api-signature"><code>' + '\n'.join(
            f'<span class="api-source-line" id="L{i}"><a class="api-line-number" href="#L{i}">{i}</a>{hl.line(line)}</span>'
            for i, line in enumerate(text.splitlines(), 1)) + '</code></pre>'
        emit(source_name(path), path, body, path, str(Path(path).parent))
    (destination / 'library-index.json').write_text(json.dumps(index, indent=2) + '\n')
    (destination / SEARCH_SCRIPT).write_text(search_index(index))
    verify(destination, pages, modules, render, sources,
           {module: text for module, (text, _, _) in descriptions.items()},
           {module: after for module, (_, _, after) in descriptions.items()})
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


def fixture_fields(directory):
    """A fixture.meta's keys, each its first value; {} where there is none."""
    meta = directory / 'fixture.meta'
    fields = {}
    if meta.is_file():
        for line in meta.read_text().splitlines():
            key, colon, value = line.partition(':')
            if colon and key.strip() not in fields:
                fields[key.strip()] = value.strip()
    return fields


def example_run(root, example_path):
    """The command that runs a module's program, the files it reads and
    what it prints, from its fixture's own metadata; None for one that
    prints nothing the fixture compares.

    The harness gives a `run_files` file as a path wherever its lane put
    the fixture, and the page writes the name; a program shown here
    prints no such path.
    """
    directory = (root / example_path).parent
    fields = fixture_fields(directory)
    expected = fields.get('run_expect')
    if not expected or fields.get('class') != 'runtime':
        return None
    name = directory.name.removeprefix('library-')
    words = fields.get('run_args', '').split()
    files = [f.strip() for f in fields.get('run_files', '').split(',') if f.strip()]
    command = f'refine compile main.ldn -o {name} && ./{name}'
    command += ''.join(' ' + w for w in words + files)
    stdin = fields.get('stdin')
    if stdin:
        command += ' < ' + stdin
    given = [(each, (directory / each).read_text().rstrip('\n'))
             for each in files + ([stdin] if stdin else [])]
    status = fields.get('status', '0')
    stream = ('standard output' if fields.get('stream') == 'output'
              else 'standard output and standard error')
    said = stream + ('' if status == '0' else f', exit status {status}')
    return dict(command=command, files=given, said=said,
                output=(directory / expected).read_text().rstrip('\n'))


def example_section(root, example_path, example_prose, prose, render):
    """The page's last section: the module's complete program, in the
    site's program panel -- its path and length above it, and below it
    what it reads and what running it prints."""
    body = ('<section class="api-example" id="example" data-title="Example program">\n'
            '<h2 class="api-h">Example program</h2>\n')
    if example_prose:
        body += prose(example_prose)
    body += ('<p>This complete program is one of the compiler\'s runtime tests. '
             f'<a href="{source_name(example_path)}#L1">View source</a>.</p>\n')
    run = example_run(root, example_path)
    example = (root / example_path).read_text()
    lines = example.splitlines()
    listing = render.listing_of(render.render_landin(lines, render.Highlighter()))
    figure = ('<figure class="panel api-program">\n'
              '<figcaption><span class="dot"></span>'
              f'<span class="path">{html.escape(example_path)}</span>'
              f'<span class="grow"></span><span>{len(lines)} lines</span></figcaption>\n'
              + listing + '\n')
    if run:
        for given, text in run['files']:
            figure += (f'<div class="foot"><span><span class="mono">{html.escape(given)}</span> holds</span></div>\n'
                       + render.listing_of('<pre>' + html.escape(text, quote=False) + '</pre>') + '\n')
        figure += ('<div class="foot"><span>in a terminal</span><span class="grow"></span>'
                   f'<span>prints on {run["said"]}</span></div>\n'
                   + render.listing_of('<pre>$ ' + html.escape(run['command'], quote=False)
                                       + '\n' + html.escape(run['output'], quote=False)
                                       + '</pre>') + '\n')
    figure += '</figure>\n'
    if example_prose or run:
        body += figure
    else:
        body += f'<details><summary>The program, {len(lines)} lines</summary>\n{figure}</details>\n'
    return body + '</section>\n'


def verify(destination, pages, modules, render, sources=None, overviews=None,
           examples=None):
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
        region = written[start:written.index('<section class="api-items" id="items"', start)]
        got = Counter(render.WORD.findall(html.unescape(re.sub(r'<[^>]+>', ' ', region))))
        # A fenced program's words are its highlighted tokens, split by
        # their markup; check.py holds each such block to a fixture's text.
        prose_only = re.sub(r'^```\w*\n.*?^```$', '', text, flags=re.M | re.S)
        want = Counter(render.WORD.findall(
            re.sub(r'\]\([^)]+\)', ']', prose_only.replace('\\|', '|'))))
        missing = want - got
        if missing:
            raise ValueError(f'{module}: overview lost words: {sorted(missing)}')
    for module, text in (examples or {}).items():
        written = (destination / page_name(module)).read_text()
        start = written.index('<section class="api-example" id="example"')
        region = written[start:written.index('</section>', start)]
        got = Counter(render.WORD.findall(html.unescape(re.sub(r'<[^>]+>', ' ', region))))
        want = Counter(render.WORD.findall(re.sub(r'\]\([^)]+\)', ']', text)))
        missing = want - got
        if missing:
            raise ValueError(f'{module}: example prose lost words: {sorted(missing)}')
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
