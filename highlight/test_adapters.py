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

from landin_highlight import (BUILTIN_MODULES, CONSTANTS, KEYWORDS, TYPES,
                              Scanner, collect_symbols)


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


def check_grammar_revision(helix: dict, zed: dict, emacs: str) -> None:
    """Keep fetched grammar and local queries at the same checked-in revision."""
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
    try:
        top = subprocess.run(["git", "rev-parse", "--show-toplevel"], cwd=checkout,
                             capture_output=True, text=True, check=False)
    except FileNotFoundError:
        return
    if top.returncode != 0 or Path(top.stdout.strip()).resolve() != checkout:
        return
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
            return
        raise AssertionError(f"pinned grammar commit {revision} is unavailable; "
                             "fetch it to compare the shipped grammar and queries")
    paths = [
        "highlight/tree-sitter/grammar.js",
        "highlight/tree-sitter/src/parser.c",
        "highlight/tree-sitter/src/scanner.c",
        "highlight/tree-sitter/src/node-types.json",
        "highlight/tree-sitter/queries",
        "highlight/helix/runtime/queries/landin",
        "highlight/zed/languages/landin",
    ]
    diff = subprocess.run(["git", "diff", "--quiet", revision, "--", *paths],
                          cwd=checkout, capture_output=True, text=True,
                          check=False)
    assert diff.returncode == 0, (
        "shipped grammar or queries differ from the pinned revision; "
        "commit them and update all three editor revisions"
        if diff.returncode == 1 else diff.stderr.strip())


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
    assert has("n", "0x2a")


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


def main() -> int:
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

    assert grammar["scopeName"] == "source.landin"
    assert grammar["fileTypes"] == ["ldn"]
    assert package["contributes"]["languages"][0]["extensions"] == [".ldn"]
    assert package["contributes"]["grammars"][0]["scopeName"] == "source.landin"
    assert tree_sitter["grammars"][0]["file-types"] == ["ldn"]
    assert helix["language"][0]["file-types"] == ["ldn"]
    assert zed["grammars"]["landin"]["path"] == "highlight/tree-sitter"
    assert zed_language["path_suffixes"] == ["ldn"]
    assert kate.getroot().attrib["extensions"] == "*.ldn"
    assert notepad.getroot().find("UserLang").attrib["ext"] == "ldn"

    lexical = (ROOT / "tests/lexical.ldn").read_text(encoding="utf-8")
    scanner_smoke(lexical)
    scanner_declaration_smoke()


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
    check_grammar_revision(helix, zed, emacs)
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
    raise SystemExit(main())
