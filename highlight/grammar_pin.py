#!/usr/bin/env python3
"""Move the editors' grammar pin to the commit on this branch that holds it.

Helix, Zed and Emacs fetch the tree-sitter grammar from Git at a full commit
ID, because that is what each of them can fetch.  A commit ID does not
survive a rebase: the grammar commit is rewritten and the pins name a commit
that is no longer on the branch.  The pin's meaning does survive -- "the
commit that last changed the grammar and the shipped queries" -- so this
tool recomputes it from the current branch and writes it into all three
manifests:

    python3 highlight/grammar_pin.py           # move the pins
    python3 highlight/grammar_pin.py --check   # only check them

It refuses while the grammar or the queries have uncommitted changes, since
no commit holds them yet.  `--check` is the pin check `test_adapters.py`
makes, on its own.
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent

#  What a fetched grammar must agree with: the files that decide parsing,
#  and the queries this checkout ships beside the fetched parser.
PATHS = (
    "highlight/tree-sitter/grammar.js",
    "highlight/tree-sitter/src/parser.c",
    "highlight/tree-sitter/src/scanner.c",
    "highlight/tree-sitter/src/node-types.json",
    "highlight/tree-sitter/queries",
    "highlight/helix/runtime/queries/landin",
    "highlight/zed/languages/landin",
)

#  Where each editor names the revision, as a pattern whose one group is it.
MANIFESTS = (
    ("helix/languages.toml", r'^source = \{[^\n]*\brev = "([0-9a-f]{40})"'),
    ("zed/extension.toml", r'^\[grammars\.landin\][^\[]*?^rev = "([0-9a-f]{40})"'),
    ("emacs/landin-mode.el", r'\(defcustom landin-treesit-revision "([0-9a-f]{40})"'),
)


def git(checkout: Path, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(["git", *args], cwd=checkout, capture_output=True,
                          text=True, check=False)


def last_grammar_commit(checkout: Path) -> str | None:
    """The newest commit on HEAD that changed the grammar or its queries."""
    found = git(checkout, "log", "-1", "--format=%H", "HEAD", "--", *PATHS)
    if found.returncode != 0:
        return None
    return found.stdout.strip() or None


def uncommitted_grammar(checkout: Path) -> str:
    """`git status` of the grammar and queries: empty when HEAD holds them."""
    return git(checkout, "status", "--porcelain", "--", *PATHS).stdout.strip()


def pins(root: Path = ROOT) -> dict[str, str]:
    out = {}
    for relative, pattern in MANIFESTS:
        match = re.search(pattern, (root / relative).read_text(encoding="utf-8"),
                          re.M | re.S)
        if not match:
            raise SystemExit(f"grammar_pin: no grammar revision found in "
                             f"highlight/{relative}")
        out[relative] = match.group(1)
    return out


def move(root: Path = ROOT) -> int:
    checkout = root.parent
    dirty = git(checkout, "status", "--porcelain", "--", *PATHS)
    if dirty.returncode != 0:
        print(f"grammar_pin: not a Git checkout: {dirty.stderr.strip()}",
              file=sys.stderr)
        return 1
    if dirty.stdout.strip():
        print("grammar_pin: the grammar or its queries have uncommitted "
              "changes, and no commit holds them yet; commit them, then "
              "run this again:\n" + dirty.stdout.rstrip(), file=sys.stderr)
        return 1
    target = last_grammar_commit(checkout)
    if target is None:
        print("grammar_pin: no commit on HEAD changed the grammar; a shallow "
              "clone needs `git fetch --unshallow`", file=sys.stderr)
        return 1
    current = pins(root)
    if set(current.values()) == {target}:
        print(f"editor grammar pins already name {target}")
        return 0
    for relative, pattern in MANIFESTS:
        path = root / relative
        text = path.read_text(encoding="utf-8")
        match = re.search(pattern, text, re.M | re.S)
        start, end = match.span(1)
        path.write_text(text[:start] + target + text[end:], encoding="utf-8")
    old = ", ".join(sorted(set(current.values())))
    print(f"editor grammar pins moved from {old} to {target}; "
          "commit the three manifests")
    return 0


def check() -> int:
    sys.path.insert(0, str(ROOT))
    import test_adapters
    try:
        test_adapters.check_grammar_revision(
            test_adapters.load_toml("helix/languages.toml"),
            test_adapters.load_toml("zed/extension.toml"),
            (ROOT / "emacs/landin-mode.el").read_text(encoding="utf-8"))
    except AssertionError as failure:
        print(f"editor grammar pin: {failure}", file=sys.stderr)
        return 1
    print("editor grammar pins name the committed grammar and queries")
    return 0


def main(argv: list[str]) -> int:
    if argv == ["--check"]:
        return check()
    if argv:
        print(f"usage: {sys.argv[0]} [--check]", file=sys.stderr)
        return 2
    return move()


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
