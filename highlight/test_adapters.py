#!/usr/bin/env python3
"""Cheap, dependency-free validation of the shipped editor adapters."""

from __future__ import annotations

import json
import plistlib
import re
import tomllib
import xml.etree.ElementTree as ET
from pathlib import Path

from landin_highlight import BUILTIN_MODULES, CONSTANTS, KEYWORDS, TYPES, Scanner


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
    assert has("b", "compiler")
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
    for word in KEYWORDS | TYPES | CONSTANTS:
        assert f'"{word}"' in emacs, f"Emacs vocabulary omits {word}"
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
