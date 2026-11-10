#!/usr/bin/env python3
"""The faces the pages are set in, and the one place they are declared.

Two families set the pages, each as the subset webfont package its source
delivers: `Nunito Sans` for prose and `MonoLisaCode` for code.  Every
rendering of them goes through here -- the `@font-face` block a page
carries, the stacks its `--ui` and `--mono` hold, and the list of files
the site build copies beside the pages -- so a family can be replaced in
one place and no consumer can name a face the repository does not ship.

They do not live in the same place.  Nunito Sans is under the OFL and is
vendored under `fonts/`.  MonoLisa is under a EULA that licenses it to
one licensee and forbids supplying the font data to anyone else, so its
package lives in a private repository -- `landin-fonts`, found through
`LANDIN_FONTS` or beside this one -- and a checkout without it renders
the pages in the stack behind the family.  `missing()` says when that
happened, and the publishing workflow refuses to publish that way.

The `@font-face` rules are not written here either.  Each family keeps
its source's own stylesheet, which is what states the weight axis and
the unicode ranges; this file reads those, rewrites the `src` urls to the
files beside the pages, and adds `font-display` to a face that came
without one.  Transcribing thirty unicode ranges into Python would be
thirty chances to mistype one, and the subsetting is the reason a reader
of an English page fetches one subset of a family instead of all of it.

A stylesheet is read, not trusted.  What it says ends up inside a
`<style>` element on every page, and the licensed one is fetched at
publish time from storage outside the repository, so nothing of it is
copied through as text: a rule is rebuilt from the descriptors named in
`DESCRIPTORS`, each value held to `VALUE`, a face's file name to `FILE`,
and a licence header that could end the element is refused.  Anything
else stops the build.  `licensed.sha256` beside the vendored family pins
the licensed family's stylesheet and faces by SHA-256 once it exists;
`--pin` writes it from a checkout the maintainer trusts.

    python3 fonts.py            what is available, and what it covers
    python3 fonts.py --require  exit 1 naming any family that is not
    python3 fonts.py --pin      record the licensed family's digests
    python3 fonts.py --fetch BASE DEST
                                fetch the licensed family from BASE into
                                the new directory DEST, and verify it

Standard library only, like everything else the site build reads.
"""

from __future__ import annotations

import hashlib
import os
import re
import sys
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
VENDOR = HERE / "fonts"

#  Where a licensed family is looked for: the variable first, then a
#  checkout of landin-fonts beside this repository, which is where a
#  developer's own copy sits.  pages.yml fetches the faces from object
#  storage and names the directory through the variable.
LICENSED_VAR = "LANDIN_FONTS"
LICENSED_DEFAULT = HERE.parent.parent / "landin-fonts"

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
         css="nunito-sans/nunito-sans.css", licensed=False,
         fallback=('-apple-system', 'BlinkMacSystemFont', '"Segoe UI"',
                   'Inter', 'Roboto', '"Helvetica Neue"', 'sans-serif')),
    dict(role="mono", family="MonoLisaCode",
         css="monolisa/monolisa.css", licensed=True,
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

#  What a face may declare besides its `src`, and what a value may be
#  made of: names, numbers, quotes, and the punctuation of a weight
#  range, a percentage and a unicode range.  No `<`, no `\`, no `(`, no
#  `;`, no `}` and no `/`, so a value cannot leave its declaration, its
#  rule or the page's `<style>` element.
DESCRIPTORS = frozenset((
    "font-family", "font-style", "font-weight", "font-stretch",
    "font-display", "unicode-range", "font-feature-settings",
    "font-variation-settings", "ascent-override", "descent-override",
    "line-gap-override", "size-adjust"))
VALUE = re.compile(r"[A-Za-z0-9 ,.+%?'\"-]+")
#  A face's file, as a name with no directory in it.
FILE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*\.woff2")

#  The licensed family's stylesheet and faces by SHA-256, one
#  `DIGEST  PATH` line each as sha256sum writes them, the path relative
#  to the licensed root.  The files are not in the repository; what they
#  must be is.
PINS = VENDOR / "licensed.sha256"
#  What the publishing workflow fetches besides the stylesheet and the
#  faces it names.
FETCHED_BESIDE = ("README.md", "monolisa/LICENSE.md")


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
        as the sources write it, thirty faces are kilobytes a page, for
        whitespace.
        """
        parts = [f"src:url({prefix}{self.name}) format(\"woff2\")"]
        parts += [f"{k}:{v}" for k, v in self.decls.items()]
        return "@font-face{%s}" % ";".join(parts)


def licensed_root() -> Path:
    """Where the licensed families are looked for on this host."""
    return Path(os.environ.get(LICENSED_VAR) or LICENSED_DEFAULT)


def stylesheet(spec) -> Path:
    """The path of a family's own stylesheet on this host."""
    root = licensed_root() if spec["licensed"] else VENDOR
    return root / spec["css"]


def available(spec) -> bool:
    """Whether a family's package is on this host at all."""
    return stylesheet(spec).is_file()


def missing() -> list[str]:
    """The families this host cannot set the pages in, by name."""
    return [spec["family"] for spec in FAMILIES if not available(spec)]


def pins() -> dict[str, str] | None:
    """The pinned digests by path, or None while nothing is pinned."""
    if not PINS.is_file():
        return None
    out = {}
    for number, line in enumerate(
            PINS.read_text(encoding="utf-8").splitlines(), 1):
        found = re.fullmatch(r"([0-9a-f]{64})  (\S+)", line)
        if not found:
            raise ValueError(f"{PINS.name}:{number}: not a DIGEST  PATH line")
        out[found.group(2)] = found.group(1)
    if not out:
        raise ValueError(f"{PINS.name}: pins nothing")
    return out


def _digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _hold_to_pins(spec, paths) -> None:
    """Refuse a licensed file that is not the one pinned."""
    pinned = pins()
    if pinned is None or not spec["licensed"]:
        return
    root = licensed_root()
    for path in paths:
        relative = path.relative_to(root).as_posix()
        if relative not in pinned:
            raise ValueError(f"{relative} is not pinned in {PINS.name}")
        if _digest(path) != pinned[relative]:
            raise ValueError(
                f"{relative} is not the file {PINS.name} pins")


def _read(spec) -> tuple[str, list[Face]]:
    """Read a family's own stylesheet into its license and its faces."""
    source = stylesheet(spec)
    _hold_to_pins(spec, [source])
    text = source.read_text(encoding="utf-8")
    header = "".join(m.group(0) for m in PRESERVED.finditer(text))
    #  The header is the one piece of text carried into the page as it
    #  was written, inside `<style>`, which only `</style` ends.
    if "<" in header:
        raise ValueError(
            f"{spec['css']}: its preserved header holds a '<', which a "
            "page's <style> element cannot carry")

    faces = []
    for body in FACE.findall(text):
        decls = {}
        src = None
        for key, value in DECL.findall(body):
            value = " ".join(value.split())
            if key == "src":
                src = value
            elif key not in DESCRIPTORS:
                raise ValueError(
                    f"{spec['css']}: an @font-face declares {key}, which "
                    "is not a descriptor the pages carry")
            elif not VALUE.fullmatch(value):
                raise ValueError(
                    f"{spec['css']}: {key} is {value!r}, which is more "
                    "than a descriptor's value")
            else:
                decls[key] = value

        found = URL.search(src or "")
        if not found:
            raise ValueError(f"{spec['css']}: an @font-face with no src url")
        #  Only the file name is taken: a source may write an absolute
        #  path (MonoLisa's does, `/woff2/0-...`) that means nothing here.
        name = found.group(1).rsplit("/", 1)[-1]
        if not FILE.fullmatch(name):
            raise ValueError(
                f"{spec['css']}: a face's file is named {name!r}")
        path = source.parent / "woff2" / name
        if not path.is_file():
            raise FileNotFoundError(
                f"{spec['css']} asks for {path.name}, which is not there")

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
    _hold_to_pins(spec, sorted({face.path for face in faces}))
    return header, faces


def _present(role: str | None = None):
    """The families this host has, or those of one role.

    A vendored family that is not there is a broken checkout and raises;
    a licensed one that is not there is an ordinary host and is skipped.
    """
    for spec in FAMILIES:
        if role not in (None, spec["role"]):
            continue
        if spec["licensed"] and not available(spec):
            continue
        yield spec


def faces(role: str | None = None) -> list[Face]:
    """Every available subset, or every subset of one role."""
    out = []
    for spec in _present(role):
        out += _read(spec)[1]
    return out


def css(prefix: str = OUT_DIR + "/") -> str:
    """The `@font-face` block a page carries, urls under `prefix`."""
    out = []
    for spec in _present():
        header, group = _read(spec)
        if header:
            out.append(header)
        out += [face.rule(prefix) for face in group]
    return "\n".join(out) + "\n"


def preload(role: str = "ui", char: str = "A") -> list[str]:
    """The upright faces of a role that set `char`, as names beside the
    pages: what a page asks for before its stylesheet has been read, so
    the text does not reflow under a reader once the face arrives.

    Only the upright subset that carries the Latin letters is worth it --
    every page sets its prose in it -- and the rest are left for the
    browser to fetch by `unicode-range` when a page needs them.
    """
    point = ord(char)
    return [face.name for face in faces(role)
            if face.decls.get("font-style", "normal") == "normal"
            and any(low <= point <= high for low, high in face.ranges)]


def stack(role: str) -> str:
    """What `--ui` or `--mono` holds: the family, then the fallbacks.

    The family is named whether or not this host has it: a page rendered
    without the faces still says what it wants to be set in, and a reader
    who has the family installed sees it.
    """
    for spec in FAMILIES:
        if spec["role"] == role:
            quoted = spec["family"]
            if " " in quoted:
                quoted = f'"{quoted}"'
            return ",".join((quoted,) + spec["fallback"])
    raise KeyError(role)


def family(role: str) -> str:
    """The family a role is set in, unquoted."""
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
    """The characters in `text` that no available subset carries.

    A page whose prose has drifted outside the subsets that were vendored
    for it renders those characters in a fallback face, or in the last
    resort font, and nothing about the build says so.  This is how the
    build says so.  A family this host does not have covers nothing and
    is not consulted; `missing()` is what reports that.
    """
    spans = {}
    for spec in _present(role):
        spans[spec["role"]] = [
            pair for face in _read(spec)[1] for pair in face.ranges]

    found = set()
    for char in set(text):
        if char in "\n\r\t":
            continue
        point = ord(char)
        for pairs in spans.values():
            if not any(low <= point <= high for low, high in pairs):
                found.add(char)
                break
    return found


def pin() -> int:
    """Write PINS from the licensed families this host has."""
    root = licensed_root()
    lines = []
    for spec in FAMILIES:
        if not spec["licensed"]:
            continue
        if not available(spec):
            print(f"fonts: {spec['family']} is not available; nothing pinned")
            return 1
        if PINS.exists():
            PINS.unlink()
        paths = [stylesheet(spec)] + sorted(
            {face.path for face in _read(spec)[1]})
        lines += [f"{_digest(path)}  {path.relative_to(root).as_posix()}"
                  for path in paths]
    PINS.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"fonts: pinned {len(lines)} files in {PINS}")
    return 0


def _download(url: str, into: Path) -> None:
    request = urllib.request.Request(
        url, headers={"User-Agent": "landin-site-build"})
    with urllib.request.urlopen(request, timeout=120) as answer:
        data = answer.read()
    into.parent.mkdir(parents=True, exist_ok=True)
    into.write_bytes(data)


def fetch(base: str, dest: Path) -> int:
    """Fetch the licensed families from `base` into the new `dest`.

    The stylesheet is the list of faces, so a subset added at the source
    arrives without editing the workflow.  It is also text from outside
    the repository, so a face is fetched only under the name `woff2/FILE`
    and written only as that file, and what arrived is then read exactly
    as a render reads it, pins included, before anything uses it.
    """
    base = base.rstrip("/")
    if dest.exists():
        print(f"fonts: {dest} exists; --fetch wants a new directory")
        return 1
    try:
        for relative in FETCHED_BESIDE:
            _download(f"{base}/{relative}", dest / relative)
        for spec in FAMILIES:
            if not spec["licensed"]:
                continue
            sheet = dest / spec["css"]
            _download(f"{base}/{spec['css']}", sheet)
            names = set()
            for target in URL.findall(sheet.read_text(encoding="utf-8")):
                found = re.fullmatch(r"/?woff2/(.+)", target)
                if not found or not FILE.fullmatch(found.group(1)):
                    raise ValueError(
                        f"{spec['css']} names a face {target!r}, which is "
                        "not woff2/FILE.woff2")
                names.add(found.group(1))
            folder = spec["css"].rsplit("/", 1)[0]
            for name in sorted(names):
                _download(f"{base}/{folder}/woff2/{name}",
                          sheet.parent / "woff2" / name)
        os.environ[LICENSED_VAR] = str(dest)
        for spec in FAMILIES:
            if spec["licensed"]:
                _read(spec)
    except (OSError, ValueError) as error:
        print(f"fonts: the licensed family was not fetched: {error}")
        return 1
    if pins() is None:
        #  GitHub Actions shows this line on the run's summary.
        print(f"::warning::the licensed face is not pinned: {PINS.name} "
              "does not exist, so its files are checked for form only. "
              "python3 assets/fonts.py --pin writes it.")
    print(f"fonts: fetched into {dest}")
    return 0


def main(argv) -> int:
    if argv[:1] == ["--pin"] and len(argv) == 1:
        return pin()
    if argv[:1] == ["--fetch"] and len(argv) == 3:
        return fetch(argv[1], Path(argv[2]))
    if argv and argv != ["--require"]:
        print(__doc__)
        return 2
    absent = missing()
    if "--require" in argv:
        for name in absent:
            print(f"fonts: {name} is not available; set {LICENSED_VAR} or "
                  f"check out landin-fonts at {LICENSED_DEFAULT}")
        return 1 if absent else 0

    for spec in FAMILIES:
        if not available(spec):
            print(f"{spec['role']:>5}  {spec['family']}: not available "
                  f"(looked in {stylesheet(spec).parent})")
            print(f"       {stack(spec['role'])}")
            continue
        header, group = _read(spec)
        total = sum(face.path.stat().st_size for face in group)
        where = "licensed" if spec["licensed"] else "vendored"
        print(f"{spec['role']:>5}  {spec['family']}: "
              f"{len(group)} subsets, {total // 1024} KiB {where}")
        print(f"       {stack(spec['role'])}")
    block = css()
    print(f"\n{len(block)} bytes of @font-face, "
          f"{len(files())} files beside the pages")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
