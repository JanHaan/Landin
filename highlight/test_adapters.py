#!/usr/bin/env python3
"""Cheap, dependency-free validation of the shipped editor adapters."""

from __future__ import annotations

import json
import plistlib
import re
import subprocess
import sys
import tomllib
import xml.etree.ElementTree as ET
from pathlib import Path

from grammar_pin import PATHS, last_grammar_commit, uncommitted_grammar
from landin_highlight import (BUILTIN_MODULES, CONSTANTS, KEYWORDS,
                              POSITIONAL_KEYWORDS, TYPES, Scanner,
                              collect_symbols, source_lines)


ROOT = Path(__file__).resolve().parent


def balanced_lisp(text: str) -> bool:
    """Check delimiters while ignoring Lisp strings and line comments."""
    depth = 0
    string = False
    escape = False
    comment = False
    for character in text:
        if comment:
            if character == "\n":
                comment = False
            continue
        if string:
            if escape:
                escape = False
            elif character == "\\":
                escape = True
            elif character == '"':
                string = False
            continue
        if character == ";":
            comment = True
        elif character == '"':
            string = True
        elif character == "(":
            depth += 1
        elif character == ")":
            depth -= 1
            if depth < 0:
                return False
    return depth == 0 and not string


def load_json(relative: str) -> object:
    return json.loads((ROOT / relative).read_text(encoding="utf-8"))


def load_toml(relative: str) -> object:
    return tomllib.loads((ROOT / relative).read_text(encoding="utf-8"))


def check_grammar_revision(helix: dict, zed: dict, emacs: str) -> str | None:
    """Keep fetched grammar and local queries at the same checked-in revision.

    Returns None when the shipped grammar and queries were compared with
    the pinned commit, and otherwise why they were not: a source archive
    has no history, and a shallow checkout may lack the commit.  A
    checkout that git cannot read is neither.  It is a failure, with git's
    own words: returning in silence there let a caller say the pins name
    the committed grammar when nothing had been compared.
    """
    helix_source = helix["grammar"][0]["source"]
    zed_source = zed["grammars"]["landin"]
    assert helix_source["subpath"] == zed_source["path"] == "highlight/tree-sitter"
    assert helix_source["git"] == zed_source["repository"]
    match = re.search(r'\(defcustom landin-treesit-revision "([^"]+)"', emacs)
    assert match, "Emacs grammar revision is missing"
    revisions = (helix_source["rev"], zed_source["rev"], match.group(1))
    assert len(set(revisions)) == 1, "editor grammar revisions differ"
    revision = revisions[0]
    assert re.fullmatch(r"[0-9a-f]{40}", revision), "editor grammar revision must be a full commit ID"

    # Source archives have no history. In a checkout with the pinned object,
    # also compare the files that determine parsing and the shipped queries.
    checkout = ROOT.parent
    if not (checkout / ".git").exists():
        return "this is not a git checkout, so there is no pinned commit to read"
    try:
        top = subprocess.run(["git", "rev-parse", "--show-toplevel"], cwd=checkout,
                             capture_output=True, text=True, check=False)
    except FileNotFoundError:
        raise AssertionError(
            "this is a git checkout and git is not on PATH, so the shipped "
            "grammar and queries cannot be compared with the pinned "
            "revision") from None
    assert top.returncode == 0, (
        "git cannot read this checkout, so the shipped grammar and queries "
        "cannot be compared with the pinned revision: "
        + (top.stderr.strip() or "git rev-parse failed"))
    assert Path(top.stdout.strip()).resolve() == checkout.resolve(), (
        f"git reads {top.stdout.strip()} as the checkout, not {checkout}")
    pinned = subprocess.run(["git", "cat-file", "-e", f"{revision}^{{commit}}"],
                            cwd=checkout, capture_output=True, text=True,
                            check=False)
    if pinned.returncode != 0:
        shallow = subprocess.run(["git", "rev-parse", "--is-shallow-repository"],
                                 cwd=checkout, capture_output=True, text=True,
                                 check=False)
        if shallow.returncode == 0 and shallow.stdout.strip() == "true":
            print("pinned grammar commit unavailable in shallow checkout; "
                  "grammar/query comparison skipped", file=sys.stderr)
            return "the pinned commit is not in this shallow checkout"
        raise AssertionError(
            f"pinned grammar commit {revision} is unavailable; fetch it to "
            "compare the shipped grammar and queries, or, if a rebase "
            "rewrote it, " + _repair(checkout))
    diff = subprocess.run(["git", "diff", "--quiet", revision, "--", *PATHS],
                          cwd=checkout, capture_output=True, text=True,
                          check=False)
    assert diff.returncode == 0, (
        "shipped grammar or queries differ from the pinned revision; "
        "commit them, then " + _repair(checkout)
        if diff.returncode == 1 else diff.stderr.strip())
    #  The same content at a commit that is not on this branch is a pin a
    #  rebase left behind: the editors fetch the commit, and once the branch
    #  is pushed its old commits are not there to fetch.
    ancestor = subprocess.run(["git", "merge-base", "--is-ancestor", revision,
                               "HEAD"], cwd=checkout, capture_output=True,
                              text=True, check=False)
    assert ancestor.returncode == 0, (
        f"pinned grammar commit {revision} is not on this branch, as a "
        "rebase leaves it; " + _repair(checkout)
        if ancestor.returncode == 1 else ancestor.stderr.strip())
    return None


def _repair(checkout: Path) -> str:
    """Say how to move the pins, and where to, when HEAD already says."""
    if uncommitted_grammar(checkout):
        return ("`python3 highlight/grammar_pin.py` moves all three editor "
                "revisions to the commit that holds them")
    target = last_grammar_commit(checkout)
    where = f" to {target}" if target else ""
    return ("`python3 highlight/grammar_pin.py` moves all three editor "
            f"revisions{where}, the last commit on HEAD that changed them")


def textmate_pattern(grammar: dict[str, object], scope: str) -> str:
    for pattern in grammar["patterns"]:
        if pattern.get("name") == scope:
            return pattern["match"]
    raise AssertionError(f"TextMate scope is missing: {scope}")


def scanner_smoke(source: str) -> None:
    scanner = Scanner()
    tokens: list[tuple[str | None, str]] = []
    for line in source.splitlines(keepends=True):
        scanned = list(scanner.scan(line))
        assert "".join(text for _, text in scanned) == line
        tokens.extend(scanned)

    def has(token_class: str, fragment: str) -> bool:
        return any(kind == token_class and fragment in text for kind, text in tokens)

    assert has("cd", "documentation comment")
    assert has("c", "nested block comment")
    assert has("q", "escaped")
    assert has("q", "this is part of the raw literal")
    assert has("k", "public")
    assert has("t", "u23")
    for module in BUILTIN_MODULES:
        assert has("b", module), f"scanner omits builtin module {module}"
    assert has("s", "member")
    assert has("k", "through")
    assert has("s", "runs")
    assert not any(kind == "k" and text == "through" and index + 1 < len(tokens)
                   and tokens[index + 1][1] == ":"
                   for index, (kind, text) in enumerate(tokens))
    assert has("k", "held")
    assert not any(kind == "k" and text == "held" and index + 1 < len(tokens)
                   and tokens[index + 1][1] in (":", ")", ".")
                   for index, (kind, text) in enumerate(tokens))
    assert has("n", "0x2a")


def scanner_unterminated_string_smoke() -> None:
    #  One token, however long: scanned on from each quote in turn, this
    #  line took a quarter of its length squared in regex steps, a second at
    #  8 kB and minutes at 100 kB, in the site build and in any Pygments
    #  host that highlights files it did not write.
    line = '"' + '\\"' * 200_000
    assert list(Scanner().scan(line)) == [("q", line)]
    assert list(Scanner().scan('x = "open')) == [
        (None, "x"), (None, " "), ("o", "="), (None, " "), ("q", '"open')]
    assert list(Scanner().scan('"closed" "open\\')) == [
        ("q", '"closed"'), (None, " "), ("q", '"open'), ("o", "\\")]


def scanner_declaration_smoke() -> None:
    names = [f"x{i}" for i in range(2000)]
    name_set = set(names)
    line = ", ".join(names) + ": u32"
    scanned = list(Scanner().scan(line))
    assert "".join(piece for _, piece in scanned) == line
    assert [(kind, piece) for kind, piece in scanned if piece in name_set] == [
        ("d" if index == 0 else None, name)
        for index, name in enumerate(names)
    ]
    assert ("t", "u32") in scanned
    assert ("d", "value") in Scanner().scan("value := zeroed")
    assert ("d", "value") not in Scanner().scan("other; value: u32")


def symbol_collection_smoke() -> None:
    lines = [
        "before: type = struct",
        "--( outer block",
        "hidden_type: type = struct",
        "--( nested block",
        "hidden_atom: atom",
        ")--",
        "still_hidden: type = struct",
        ")-- after: type = struct",
        'raw: utf8 = """"',
        "raw_type: type = struct",
        '"""',  # A shorter delimiter cannot close the raw literal.
        "raw_atom: atom",
        '"""" after_raw: atom',
        "colors: type = red | blue --( false_atom = 9 )--",
        "-- line_type: type = struct",
        "--- doc_atom: atom",
        '"quoted_type: type = struct"',
        "local_before: atom --( another block",
        ")-- local_after: type = struct",
        'raw3: utf8 = """',
        "raw3_type: type = struct",
        '""" raw3_after: type = struct',
        "use: before = 0",
        "use: after = 0",
        "use: hidden_type = 0",
        "use: raw_type = 0",
        "use: raw_atom = 0",
    ]
    types, atoms = collect_symbols(lines)
    assert types == {"before", "after", "colors", "local_after",
                     "raw3_after"}, types
    assert atoms == {"after_raw", "local_before", "red", "blue"}, atoms

    scanner = Scanner(types, atoms)
    scanned = [list(scanner.scan(line)) for line in lines]
    assert ("c", "hidden_type: type = struct") in scanned[2]
    assert ("q", "raw_type: type = struct") in scanned[9]
    assert ("t", "before") in scanned[22]
    assert ("t", "after") in scanned[23]
    assert (None, "hidden_type") in scanned[24]
    assert (None, "raw_type") in scanned[25]
    assert (None, "raw_atom") in scanned[26]


def withdrawn_word_smoke(grammar: dict[str, object], emacs: str) -> None:
    """`arena` is a name, not a keyword, in every lexical rendering.

    D212 withdrew [0820]'s lexical `arena` block, and `core/arena` is an
    ordinary module, so `arena.over(...)` must read as the name it is. A
    highlighter that kept the word would colour every use of the module as
    syntax.
    """
    assert "arena" not in KEYWORDS, "the scanner lists arena as a keyword"
    scanned = list(Scanner().scan("pool := arena.over(backing)"))
    assert ("k", "arena") not in scanned, scanned
    assert (None, "arena") in scanned, scanned
    keywords = textmate_pattern(grammar, "keyword.control.landin")
    assert not re.search(keywords, "arena"), "TextMate colours arena"
    assert re.search(keywords, "uninit"), "TextMate keyword rule is wrong"
    assert '"arena"' not in emacs, "Emacs colours arena"
    for relative in ("vim/syntax/landin.vim", "nano/landin.nanorc",
                     "kate/landin.xml", "notepad-plus-plus/Landin.xml",
                     "sublime/Landin.tmLanguage"):
        text = (ROOT / relative).read_text(encoding="utf-8")
        assert not re.search(r"\barena\b", text), f"{relative} colours arena"
    try:
        from pygments.token import Keyword
        from landin_pygments import LandinLexer
    except ModuleNotFoundError:
        return
    assert not any(token in Keyword and text == "arena" for token, text
                   in LandinLexer().get_tokens("pool := arena.over(backing)\n"))


#  A conformance's `through` and the field after it, as they end a line, and
#  `through` as the ordinary name the corpus already uses it as.
THROUGH_FIELDS = [
    ("host is io.environment through services", "services"),
    ("host is io.files (close: events_close) through services -- note",
     "services"),
    ("view is indexable (idx: usize, item_type: u32) through inner", "inner"),
    (") through inner", "inner"),
]
THROUGH_NAMES = [
    "through: (flag: bool) -> none ! refused = attempt",
    "    through(flag) else none",
    "mut through: [3]u16 = typed",
    "      and through[0] == 0x123456789ABCDEF0",
    "    item.kind = values(row: through.val)",
    "    through := through + 1",
    "end through",
    "end through -- done",
]


def contextual_through_smoke(grammar: dict[str, object], emacs: str,
                             kate: ET.ElementTree) -> None:
    """`through` is a keyword only before the field that ends a conformance.

    Everywhere else it is a name: existing programs have a local, a
    function, a field and a module binding called `through`, and colouring
    them as syntax would be the regression `arena` was.  Nano and
    Notepad++ have no look-ahead and colour it as they colour `is`.
    """
    assert "through" in POSITIONAL_KEYWORDS and "through" not in KEYWORDS
    for line, field in THROUGH_FIELDS:
        scanned = list(Scanner().scan(line))
        assert ("k", "through") in scanned, scanned
        assert ("s", field) in scanned, scanned
    for line in THROUGH_NAMES:
        scanned = list(Scanner().scan(line))
        assert ("k", "through") not in scanned, scanned
        assert ("s", "through") not in scanned, scanned

    (pattern,) = [entry["match"] for entry in grammar["patterns"]
                  if "through" in entry.get("match", "")]
    for line, field in THROUGH_FIELDS:
        found = re.search(pattern, line)
        assert found and found.group(1) == "through" and found.group(2) == field, line
    for line in THROUGH_NAMES:
        assert not re.search(pattern, line), f"TextMate colours {line!r}"

    (rule,) = [rule for rule in kate.iter("RegExpr")
               if "through" in rule.attrib["String"]]
    assert rule.attrib["attribute"] == "Keyword"
    for line, _ in THROUGH_FIELDS:
        assert re.search(rule.attrib["String"], line), f"Kate misses {line!r}"
    for line in THROUGH_NAMES:
        assert not re.search(rule.attrib["String"], line), f"Kate colours {line!r}"

    keywords = re.search(r"\(defconst landin-mode-keywords\s+'\(([^)]*)\)\)",
                         emacs, re.S)
    assert keywords and '"through"' not in keywords.group(1), (
        "Emacs colours every through as a keyword")
    assert '"\\\\_<\\\\(through\\\\)' in emacs, "Emacs has no rule for through"
    vim = (ROOT / "vim/syntax/landin.vim").read_text(encoding="utf-8")
    assert r"syntax match landinKeyword /\<through\ze" in vim
    assert not re.search(r"syntax keyword landinKeyword .*\bthrough\b", vim)
    for relative in ("nano/landin.nanorc", "notepad-plus-plus/Landin.xml"):
        text = (ROOT / relative).read_text(encoding="utf-8")
        assert re.search(r"\bthrough\b", text), f"{relative} omits through"

    try:
        from pygments.token import Keyword, Name
        from landin_pygments import LandinLexer
    except ModuleNotFoundError:
        return
    tokens = list(LandinLexer().get_tokens(
        "host is io.files () through services\nthrough: () -> none = end through\n"))
    assert sum(token in Keyword and text == "through" for token, text in tokens) == 1
    assert any(token in Name.Attribute and text == "services" for token, text in tokens)


#  A named return's `held` before its source (D1369), and `held` as the
#  ordinary name the library and the corpus already use it as.
HELD_SOURCES = [
    "-> (result: item from held value) ! mem.out_of_bounds =",
    "-> (r: ptr u8 from a, held b)",
    "-> (r: item from held held, s: u8) =",
    "            -> (result: entry(key, item) from held value,",
]
HELD_NAMES = [
    "-> (r: ptr u8 from held)",
    "-> (r: ptr u8 from held, other) =",
    "attempt: (host: events.host, at: net.address, inout held: kept)",
    "    held.files[held.count] = made",
    "    grown = ends <= where.held or extend_mapping(where, ends)",
    "    return when text.length(line) <> held",
    "    for at in usize(0)..<held + 5 do",
    "held: (other: items) -> none =",
    "end held",
    "    x := f(held)",
]


def contextual_held_smoke(grammar: dict[str, object], emacs: str,
                          kate: ET.ElementTree) -> None:
    """`held` is a keyword only before a source of a named return.

    Everywhere else it is a name: the library and the corpus have locals,
    parameters and fields called `held`, and a named return may still say
    `from held` of a parameter of that name.  Nano and Notepad++ have no
    look-ahead and colour it as they colour `is`.
    """
    assert "held" in POSITIONAL_KEYWORDS and "held" not in KEYWORDS
    for line in HELD_SOURCES:
        scanned = list(Scanner().scan(line))
        assert ("k", "held") in scanned, scanned
    for line in HELD_NAMES:
        scanned = list(Scanner().scan(line))
        assert ("k", "held") not in scanned, scanned

    (pattern,) = [entry["match"] for entry in grammar["patterns"]
                  if "held" in entry.get("match", "")]
    for line in HELD_SOURCES:
        assert re.search(pattern, line), f"TextMate misses {line!r}"
    for line in HELD_NAMES:
        assert not re.search(pattern, line), f"TextMate colours {line!r}"

    (rule,) = [rule for rule in kate.iter("RegExpr")
               if "held" in rule.attrib["String"]]
    assert rule.attrib["attribute"] == "Keyword"
    for line in HELD_SOURCES:
        assert re.search(rule.attrib["String"], line), f"Kate misses {line!r}"
    for line in HELD_NAMES:
        assert not re.search(rule.attrib["String"], line), f"Kate colours {line!r}"

    keywords = re.search(r"\(defconst landin-mode-keywords\s+'\(([^)]*)\)\)",
                         emacs, re.S)
    assert keywords and '"held"' not in keywords.group(1), (
        "Emacs colours every held as a keyword")
    assert '"\\\\_<\\\\(held\\\\)' in emacs, "Emacs has no rule for held"
    vim = (ROOT / "vim/syntax/landin.vim").read_text(encoding="utf-8")
    assert r"syntax match landinKeyword /\.\@<!\<held\ze" in vim
    assert not re.search(r"syntax keyword landinKeyword .*\bheld\b", vim)
    for relative in ("nano/landin.nanorc", "notepad-plus-plus/Landin.xml"):
        text = (ROOT / relative).read_text(encoding="utf-8")
        assert re.search(r"\bheld\b", text), f"{relative} omits held"

    try:
        from pygments.token import Keyword
        from landin_pygments import LandinLexer
    except ModuleNotFoundError:
        return
    tokens = list(LandinLexer().get_tokens(
        "get: (held: list) -> (r: item from held held, s: item from held) =\n"
        "    r = held.val\nend get\n"))
    assert sum(token in Keyword and text == "held" for token, text in tokens) == 1


def pygments_smoke(source: str) -> None:
    try:
        from pygments.token import Comment, Keyword, Name, Number, String
        from landin_pygments import LandinLexer
    except ModuleNotFoundError:
        print("Pygments absent; lexer smoke skipped")
        return
    tokens = list(LandinLexer().get_tokens(source))
    assert any(token in Keyword and text == "public" for token, text in tokens)
    assert any(token in Number and text == "0x2a" for token, text in tokens)
    assert any(token in String and "escaped" in text for token, text in tokens)
    assert any(token in Comment and "nested block comment" in text for token, text in tokens)
    assert any(token in Name.Builtin and text == "compiler" for token, text in tokens)

    #  Unicode separators remain inside a Landin line comment. A false split
    #  would also invent a type declaration and colour its later use.
    source = "-- comment\u2028x: type\ny: x"
    spans = list(LandinLexer().get_tokens_unprocessed(source))
    assert "".join(piece for _, _, piece in spans) == source
    assert any(token in Comment and piece == "-- comment\u2028x: type"
               for _, token, piece in spans)
    assert not any(token in Keyword.Type and piece == "x"
                   for _, token, piece in spans)


def kate_raw_smoke(kate: ET.ElementTree) -> None:
    contexts = {
        context.attrib["name"]: context
        for context in kate.findall("./highlighting/contexts/context")
    }
    normal_rules = list(contexts["Normal"])
    opener = next(rule for rule in normal_rules
                  if rule.attrib.get("context") == "Raw String")
    ordinary = next(rule for rule in normal_rules
                    if rule.tag == "DetectChar" and rule.attrib.get("char") == '"')
    assert opener.tag == "RegExpr" and normal_rules.index(opener) < normal_rules.index(ordinary)
    assert opener.attrib["attribute"] == "String"

    raw = contexts["Raw String"]
    assert raw.attrib["attribute"] == "String"
    assert raw.attrib["lineEndContext"] == "#stay"
    (closer,) = list(raw)
    assert closer.tag == "StringDetect"
    assert closer.attrib == {"String": "%1", "dynamic": "true",
                             "attribute": "String", "context": "#pop"}

    opening = re.compile(opener.attrib["String"])
    assert opening.match('"ordinary"') is None
    for delimiter, body in (
        ('"""', 'raw\n-- this is part of the raw literal\n'),
        ('""""', 'raw\n""" -- still raw\n'),
    ):
        source = delimiter + body + delimiter + " public"
        match = opening.match(source)
        assert match is not None and match.group(1) == delimiter
        closing = closer.attrib["String"].replace("%1", match.group(1))
        assert source.find(closing, match.end()) == len(delimiter + body)


def main(argv: list[str]) -> int:
    #  test.sh defers the pin check to its end, so that the structural and
    #  corpus passes still run, and report, on an uncommitted grammar.
    if argv not in ([], ["--without-grammar-pin"]):
        print(f"usage: {sys.argv[0]} [--without-grammar-pin]", file=sys.stderr)
        return 2
    grammar = load_json("textmate/syntaxes/landin.tmLanguage.json")
    package = load_json("textmate/package.json")
    load_json("textmate/language-configuration.json")
    tree_sitter = load_json("tree-sitter/tree-sitter.json")
    load_json("tree-sitter/src/node-types.json")
    helix = load_toml("helix/languages.toml")
    zed = load_toml("zed/extension.toml")
    zed_language = load_toml("zed/languages/landin/config.toml")
    kate = ET.parse(ROOT / "kate/landin.xml")
    notepad = ET.parse(ROOT / "notepad-plus-plus/Landin.xml")
    with (ROOT / "sublime/Comments.tmPreferences").open("rb") as stream:
        plistlib.load(stream)
    #  A `.tmLanguage` file is a property list, and holds the one grammar.
    with (ROOT / "sublime/Landin.tmLanguage").open("rb") as stream:
        assert plistlib.load(stream) == grammar, (
            "the Sublime Text grammar is not the TextMate grammar")

    assert grammar["scopeName"] == "source.landin"
    assert grammar["fileTypes"] == ["ldn"]
    assert package["contributes"]["languages"][0]["extensions"] == [".ldn"]
    assert package["contributes"]["grammars"][0]["scopeName"] == "source.landin"
    #  Which program the extension starts is the user's choice, never a
    #  workspace's, and Restricted Mode keeps the highlighting.
    settings = package["contributes"]["configuration"]["properties"]
    assert settings["landin.server.path"]["scope"] == "machine"
    untrusted = package["capabilities"]["untrustedWorkspaces"]
    assert untrusted["supported"] == "limited"
    assert untrusted["restrictedConfigurations"] == ["landin.server.path"]
    extension = (ROOT / "textmate/extension.js").read_text(encoding="utf-8")
    assert "vscode.workspace.isTrusted === false" in extension
    assert tree_sitter["grammars"][0]["file-types"] == ["ldn"]
    assert helix["language"][0]["file-types"] == ["ldn"]
    assert zed["grammars"]["landin"]["path"] == "highlight/tree-sitter"
    assert zed_language["path_suffixes"] == ["ldn"]
    assert kate.getroot().attrib["extensions"] == "*.ldn"
    kate_raw_smoke(kate)
    assert notepad.getroot().find("UserLang").attrib["ext"] == "ldn"

    lexical = (ROOT / "tests/lexical.ldn").read_text(encoding="utf-8")
    separators = "\v\f\x1c\x1d\x1e\x85\u2028\u2029"
    comment = "-- comment" + separators + "x: type"
    assert list(source_lines(comment + "\r\ny: x\rz: x\n")) == [
        "-- comment" + separators + "x: type\r\n", "y: x\r", "z: x\n"]
    assert "x" not in collect_symbols([comment])[0]
    assert list(Scanner(*collect_symbols([comment])).scan(comment)) == [
        ("c", comment)]
    scanner_smoke(lexical)
    scanner_declaration_smoke()
    scanner_unterminated_string_smoke()
    symbol_collection_smoke()
    pygments_smoke(lexical)
    samples = {
        "storage.type.builtin.landin": "u23",
        "constant.language.landin": "true",
        "support.module.landin": "compiler",
        "keyword.control.landin": "public",
        "entity.name.type.landin": "sample: type",
        "entity.name.function.landin": "sample: () ->",
        "entity.name.function.call.landin": "sample(",
        "variable.other.member.landin": ".member",
        "keyword.operator.landin": ":=",
    }
    for scope, sample in samples.items():
        assert re.search(textmate_pattern(grammar, scope), sample), scope

    emacs = (ROOT / "emacs/landin-mode.el").read_text(encoding="utf-8")
    assert balanced_lisp(emacs), "unbalanced Emacs Lisp"
    if not argv:
        check_grammar_revision(helix, zed, emacs)
    withdrawn_word_smoke(grammar, emacs)
    contextual_through_smoke(grammar, emacs, kate)
    contextual_held_smoke(grammar, emacs, kate)
    for word in KEYWORDS | TYPES | CONSTANTS:
        assert f'"{word}"' in emacs, f"Emacs vocabulary omits {word}"
    modules = re.search(
        r"\(defconst landin-mode-builtin-modules\s+'\(([^)]*)\)\)", emacs, re.S)
    assert modules, "Emacs builtin module vocabulary is missing"
    assert set(re.findall(r'"([^"]+)"', modules.group(1))) == BUILTIN_MODULES, (
        "Emacs builtin modules differ from the scanner")
    assert re.search(
        r"\(,\(regexp-opt landin-mode-builtin-modules 'symbols\)"
        r"\s*\.\s*font-lock-builtin-face\)", emacs), (
        "Emacs builtin modules have no font-lock rule")
    textmate = json.dumps(grammar)
    for word in BUILTIN_MODULES:
        assert word in textmate, f"TextMate vocabulary omits {word}"

    #  Every editor that starts the language server starts `refine lsp`,
    #  for Landin and nothing else.
    assert helix["language"][0]["language-servers"] == ["refine"]
    assert helix["language-server"]["refine"] == {
        "command": "refine", "args": ["lsp"]}
    assert zed["language_servers"]["refine"]["languages"] == ["Landin"]
    assert zed_language["name"] == "Landin"
    zed_source = (ROOT / "zed/src/landin.rs").read_text(encoding="utf-8")
    assert 'which("refine")' in zed_source and '"lsp"' in zed_source
    nvim = (ROOT / "nvim/lsp/refine.lua").read_text(encoding="utf-8")
    assert 'cmd = { "refine", "lsp" }' in nvim
    assert 'filetypes = { "landin" }' in nvim
    assert '"refine" "lsp"' in emacs and "eglot-server-programs" in emacs
    vim_lsp = (ROOT / "vim/plugin/landin_lsp.vim").read_text(encoding="utf-8")
    assert "['refine', 'lsp']" in vim_lsp
    assert "'allowlist': ['landin']" in vim_lsp
    sublime = json.loads("\n".join(
        line for line in (ROOT / "sublime/LSP-refine.sublime-settings")
        .read_text(encoding="utf-8").splitlines()
        if not line.lstrip().startswith("//")))
    assert sublime["clients"]["refine"]["command"] == ["refine", "lsp"]
    assert sublime["clients"]["refine"]["selector"] == grammar["scopeName"]
    kate_lsp = load_json("kate/lsp-client.json")
    assert kate_lsp["servers"]["landin"]["command"] == ["refine", "lsp"]
    assert kate.getroot().attrib["name"] == "Landin"
    client = (ROOT / "textmate/extension.js").read_text(encoding="utf-8")
    assert 'args: ["lsp"]' in client and 'language: "landin"' in client
    assert package["main"] == "./extension.js"
    assert "vscode-languageclient" in package["dependencies"]

    required = [
        "emacs/landin-mode.el",
        "eclipse/README.md",
        "helix/runtime/queries/landin/highlights.scm",
        "jetbrains/README.md",
        "kate/landin.xml",
        "kate/lsp-client.json",
        "nano/landin.nanorc",
        "nvim/lsp/refine.lua",
        "nvim/parser/.gitkeep",
        "notepad-plus-plus/Landin.xml",
        "nvim/queries/landin/highlights.scm",
        "sublime/Landin.tmLanguage",
        "sublime/LSP-refine.sublime-settings",
        "textmate/extension.js",
        "textmate/package.json",
        "textmate/package-lock.json",
        "textmate/LICENSE",
        "tree-sitter/grammar.js",
        "tree-sitter/src/parser.c",
        "tests/lexical.ldn",
        "tests/emacs-lsp-smoke.el",
        "tests/emacs-treesit-smoke.el",
        "tests/nvim-lsp-smoke.lua",
        "tests/nvim-smoke.lua",
        "tests/structural.ldn",
        "tests/textmate-smoke.mjs",
        "tests/textmate-client.mjs",
        "vim/ftdetect/landin.vim",
        "vim/ftplugin/landin.vim",
        "vim/indent/landin.vim",
        "vim/plugin/landin_lsp.vim",
        "vim/syntax/landin.vim",
        "visual-studio/install.ps1",
        "zed/languages/landin/highlights.scm",
        "zed/src/landin.rs",
        "zed/Cargo.toml",
        "zed/Cargo.lock",
    ]
    missing = [relative for relative in required if not (ROOT / relative).is_file()]
    assert not missing, "missing editor artifacts: " + ", ".join(missing)
    print("editor manifests, server configurations and package inventory clean")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
