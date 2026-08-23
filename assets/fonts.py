#!/usr/bin/env python3
"""The faces the pages are set in, and the one place they are declared.

Two families are vendored under `fonts/`, each as the subset webfont
package its source delivers: `Nunito Sans` for prose and `MonoLisaCode`
for code.  Every rendering of them goes through here -- the `@font-face`
block a page carries, the stacks its `--ui` and `--mono` hold, and the
list of files the site build copies beside the pages -- so a family can
be replaced in one place and no consumer can name a face the repository
does not ship.

The `@font-face` rules are not written here either.  Each family keeps
its source's own stylesheet, which is what states the weight axis and
the unicode ranges; this file reads those, rewrites the `src` urls to the
files beside the pages, and adds `font-display` to a face that came
without one.  Transcribing 80 unicode ranges into Python would be 80
chances to mistype one, and the subsetting is the reason a reader of an
English page fetches 50 KB of monospace instead of 660 KB.

    python3 fonts.py            what is vendored, and what it covers

Standard library only, like everything else the site build reads.
"""

from __future__ import annotations

import re
from pathlib import Path

HERE = Path(__file__).resolve().parent
VENDOR = HERE / "fonts"

#  Where the faces go beside the pages, and how a page asks for them.
#  Flat, because the pages are flat: one directory of woff2 files next to
#  sixteen html files, reached by a relative url so a site copied to a
#  directory or served from a subpath keeps its faces.
OUT_DIR = "fonts"

#  The fallbacks are the stacks the pages used before the faces were
#  vendored, kept behind them rather than replaced by them.  A woff2 is a
#  request, and a request can fail or be blocked; the page it fails on
#  should look like it did last year, not like Times.
FAMILIES = (
    dict(role="ui", family="Nunito Sans",
         css="nunito-sans/nunito-sans.css",
         fallback=('-apple-system', 'BlinkMacSystemFont', '"Segoe UI"',
                   'Inter', 'Roboto', '"Helvetica Neue"', 'sans-serif')),
    dict(role="mono", family="MonoLisaCode",
         css="monolisa-code/monolisa-code.css",
         fallback=('ui-monospace', 'SFMono-Regular', '"SF Mono"', 'Menlo',
                   'Consolas', '"Liberation Mono"', 'monospace')),
)

FACE = re.compile(r"@font-face\s*\{(.*?)\}", re.S)
#  A `/*! ... */` block is the license header a foundry asks to be kept.
#  It is the one comment that survives into the page; the rest are the
#  subset names, which are of no use to a reader of the page.
PRESERVED = re.compile(r"/\*!.*?\*/", re.S)
URL = re.compile(r"url\(\s*['\"]?([^'\")]+?)['\"]?\s*\)")
DECL = re.compile(r"([a-z-]+)\s*:\s*([^;]+?)\s*(?:;|$)", re.S)
RANGE = re.compile(r"U\+([0-9A-Fa-f]+)(?:-([0-9A-Fa-f]+))?")


class Face:
    """One subset of one family: the file, and what it is for."""

    __slots__ = ("role", "family", "path", "decls")

    def __init__(self, role, family, path, decls):
        self.role = role
        self.family = family
        self.path = path
        self.decls = decls

    @property
    def name(self) -> str:
        return self.path.name

    @property
    def ranges(self):
        """The codepoints this subset carries, as (low, high) pairs."""
        text = self.decls.get("unicode-range", "U+0-10FFFF")
        return [(int(a, 16), int(b or a, 16))
                for a, b in RANGE.findall(text)]

    def rule(self, prefix: str) -> str:
        """The `@font-face` rule, on one line, pointing at `prefix`.

        One line per face because the block is inlined into every page:
        as the sources write it, eighty faces come to 16 KB a page and
        260 KB across the site, for whitespace.
        """
        parts = [f"src:url({prefix}{self.name}) format(\"woff2\")"]
        parts += [f"{k}:{v}" for k, v in self.decls.items() if k != "src"]
        return "@font-face{%s}" % ";".join(parts)


def _read(spec) -> tuple[str, list[Face]]:
    """Read a family's own stylesheet into its license and its faces."""
    source = VENDOR / spec["css"]
    text = source.read_text(encoding="utf-8")
    header = "".join(m.group(0) for m in PRESERVED.finditer(text))

    faces = []
    for body in FACE.findall(text):
        decls = {}
        for key, value in DECL.findall(body):
            decls[key] = " ".join(value.split())

        found = URL.search(decls.get("src", ""))
        if not found:
            raise ValueError(f"{spec['css']}: an @font-face with no src url")
        #  Only the file name is taken: a source may write an absolute
        #  path (MonoLisa's does, `/woff2/0-...`) that means nothing here.
        path = source.parent / "woff2" / Path(found.group(1)).name
        if not path.is_file():
            raise FileNotFoundError(
                f"{spec['css']} asks for {path.name}, which is not vendored")

        family = decls.get("font-family", "").strip("'\"")
        if family != spec["family"]:
            raise ValueError(
                f"{spec['css']}: a face of {family!r}, not {spec['family']!r}")
        #  Without this a page holds its text invisible for up to three
        #  seconds while a face loads, which is the fallback stack's whole
        #  purpose going unused.
        decls.setdefault("font-display", "swap")
        faces.append(Face(spec["role"], family, path, decls))

    if not faces:
        raise ValueError(f"{spec['css']}: no @font-face in it")
    return header, faces


def faces(role: str | None = None) -> list[Face]:
    """Every vendored subset, or every subset of one role."""
    out = []
    for spec in FAMILIES:
        if role in (None, spec["role"]):
            out += _read(spec)[1]
    return out


def css(prefix: str = OUT_DIR + "/") -> str:
    """The `@font-face` block a page carries, urls under `prefix`."""
    out = []
    for spec in FAMILIES:
        header, group = _read(spec)
        if header:
            out.append(header)
        out += [face.rule(prefix) for face in group]
    return "\n".join(out) + "\n"


def stack(role: str) -> str:
    """What `--ui` or `--mono` holds: the family, then the fallbacks."""
    for spec in FAMILIES:
        if spec["role"] == role:
            quoted = spec["family"]
            if " " in quoted:
                quoted = f'"{quoted}"'
            return ",".join((quoted,) + spec["fallback"])
    raise KeyError(role)


def family(role: str) -> str:
    """The vendored family a role is set in, unquoted."""
    for spec in FAMILIES:
        if spec["role"] == role:
            return spec["family"]
    raise KeyError(role)


def files() -> list[tuple[str, Path]]:
    """The faces the site build copies, as (name beside the pages, source).

    The names are flat, so a collision between two families would be one
    family silently wearing the other's glyphs.
    """
    out = {}
    for face in faces():
        if face.name in out and out[face.name] != face.path:
            raise ValueError(f"two families vendor a {face.name}")
        out[face.name] = face.path
    return sorted(out.items())


def uncovered(text: str, role: str | None = None) -> set[str]:
    """The characters in `text` that no vendored subset carries.

    A page whose prose has drifted outside the subsets that were vendored
    for it renders those characters in a fallback face, or in the last
    resort font, and nothing about the build says so.  This is how the
    build says so.
    """
    spans = {}
    for spec in FAMILIES:
        if role in (None, spec["role"]):
            spans[spec["role"]] = [
                pair for face in _read(spec)[1] for pair in face.ranges]

    missing = set()
    for char in set(text):
        if char in "\n\r\t":
            continue
        point = ord(char)
        for pairs in spans.values():
            if not any(low <= point <= high for low, high in pairs):
                missing.add(char)
                break
    return missing


def main() -> int:
    for spec in FAMILIES:
        header, group = _read(spec)
        total = sum(face.path.stat().st_size for face in group)
        print(f"{spec['role']:>5}  {spec['family']}: "
              f"{len(group)} subsets, {total // 1024} KiB vendored")
        print(f"       {stack(spec['role'])}")
    block = css()
    print(f"\n{len(block)} bytes of @font-face, "
          f"{len(files())} files beside the pages")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
