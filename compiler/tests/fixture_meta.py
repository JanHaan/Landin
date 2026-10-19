"""The fixture format, read once for every Python consumer.

`compiler/tests/README.md` says what a `fixture.meta` holds.  Two programs
read it: the Ada test program (`Landin.Testing.Fixtures`) and this module,
which every Python lane, manifest and check imports rather than splitting
lines of its own.  The two are held to each other by
`compiler/tests/fixture-meta.cases`: a table of metadata texts with the
faults and the values each must give, which `fixtures/the metadata readers
agree` reads through the Ada reader and `scripts/tests/test_fixture_meta.py`
through this one.  Change the format here, in the Ada reader and in that
table together, and both say which one disagrees.

Standard library only, so `check.py` and the site build can import it.

    meta = fixture_meta.read(directory)        # strict: FixtureError
    meta.get("program"), meta.targets, meta.status
    meta.source_arguments(base)                # what `refine` is run with
    meta.program_arguments(base, shared)       # what the program is run with
    meta.levels_for("linux-arm64")             # the lane's own levels
    for meta in fixture_meta.discover(): ...

`base` is the fixture directory as the caller spells it for the process it
starts, so a lane that copies the corpus elsewhere passes its own spelling.
"""

import os
import re
from pathlib import Path

HERE = Path(__file__).resolve().parent
FIXTURES = HERE / "fixtures"
NAME = "fixture.meta"

#  Ordered as `Landin.Testing.Fixtures.Fixture_Class`, which is the order a
#  run reports them in.
CLASSES = ("unit", "positive", "negative", "runtime", "abi", "debugger",
           "end-to-end")

#  The names a fixture's `targets:` may hold: `refine --target=`'s own.
TARGETS = ("linux-x86-64", "linux-arm64", "linux-rv64", "darwin-arm64",
           "cortex-m0", "freebsd-x86-64", "freebsd-arm64", "synthetic-32")

#  Each target's CPU feature levels (D255), as `Landin.Targets.Levels`
#  spells them; the first is the default.  A lane runs only its own
#  family's, so a fixture naming an arm64 level is never built at it on
#  RV64.  `fixture-meta.cases` holds both readers to the same selection.
FAMILIES = {
    "x86-64": ("x86-64-v1", "x86-64-v2", "x86-64-v3", "x86-64-v4"),
    "arm64": ("armv8-a", "armv8.1-a"),
    "rv64": ("rv64gc", "rv64gc_zba", "rv64gc_xtheadba",
             "rv64gc_zba_xtheadba"),
    "m-profile": ("armv6-m", "armv7-m", "armv7e-m"),
    "none": (),
}
FAMILY_OF = {
    "linux-x86-64": "x86-64", "freebsd-x86-64": "x86-64",
    "linux-arm64": "arm64", "darwin-arm64": "arm64",
    "freebsd-arm64": "arm64", "linux-rv64": "rv64",
    "cortex-m0": "m-profile", "synthetic-32": "none",
}
PRODUCT_LEVELS = frozenset(level for levels in FAMILIES.values()
                           for level in levels)


class FixtureError(ValueError):
    """A fixture whose metadata the harness would refuse, with each fault."""

    def __init__(self, where, problems):
        self.where = where
        self.problems = list(problems)
        super().__init__("\n".join("%s: %s" % (where, one)
                                   for one in self.problems))


def _trimmed(text):
    #  As the Ada reader's Trimmed: leading spaces, trailing spaces and CRs.
    return text.lstrip(" ").rstrip(" \r")


def _items(text):
    return [_trimmed(one) for one in text.split(",")]


def _integer(text):
    #  Ada's Integer'Value over a decimal literal: an optional sign, digits
    #  with single underscores between them, an optional positive exponent,
    #  and surrounding spaces.
    match = re.fullmatch(r"\s*([+-]?)(\d(?:_?\d)*)(?:[eE]\+?(\d+))?\s*",
                         text)
    if not match:
        raise ValueError(text)
    value = int(match.group(2).replace("_", ""))
    if match.group(3):
        value *= 10 ** int(match.group(3))
    return -value if match.group(1) == "-" else value


def is_below_directory(name):
    """A slash-separated relative path that stays below its directory."""
    if not name or name[0] in "/\\" or "\\" in name or ":" in name:
        return False
    return all(part not in ("", ".", "..") for part in name.split("/"))


def _relative_c_source(name):
    return len(name) >= 3 and name.endswith(".c") and is_below_directory(name)


def shared_stem(source):
    """The stem naming a `c-shared` source's object: `plugin` for
    `plugins/plugin.c`."""
    return source.rsplit("/", 1)[-1][:-2]


def _below(base, name):
    """NAME below BASE as a process would be handed it: a base of `.`, a
    process run in the fixture directory, names it bare."""
    return name if base == "." else base + "/" + name


class Metadata(dict):
    """One fixture's metadata: its keys as written, and what they mean.

    Being a dict, `meta["targets"]` and `meta.get("run_args", "")` read a
    key as the file spells it; the properties and methods are what the
    harness makes of them.
    """

    cls = ""
    name = ""
    directory = None

    @classmethod
    def of(cls_, mapping, label):
        """MAPPING, a fixture's keys as a plain dict -- one a lane carried
        through JSON, or overlaid with a lane's own differences -- read as
        fixture LABEL's metadata, `CLASS/NAME`."""
        meta = cls_(mapping)
        meta.cls, _, meta.name = label.partition("/")
        return meta

    @property
    def label(self):
        return self.cls + "/" + self.name

    @property
    def targets(self):
        return [one for one in _items(self.get("targets", "")) if one]

    def applies_to(self, target):
        return target in self.targets

    @property
    def codes(self):
        return [one for one in _items(self.get("codes", "")) if one]

    @property
    def status(self):
        if "status" in self:
            return _integer(self["status"])
        return 1 if self.cls == "negative" else 0

    @property
    def traps(self):
        return self.get("traps") == "yes"

    @property
    def stream(self):
        return self.get("stream", "merged")

    @property
    def profile_count(self):
        return 6 if self.get("profiles") == "specialization" else 4

    def _list(self, key):
        return [one for one in _items(self.get(key, "")) if one]

    @property
    def with_sources(self):
        return self._list("with")

    @property
    def c_sources(self):
        return self._list("c-sources")

    @property
    def c_shared(self):
        return self._list("c-shared")

    @property
    def run_files(self):
        return self._list("run_files")

    @property
    def levels(self):
        return self._list("levels")

    def levels_for(self, target):
        """The levels `levels:` names that are TARGET's family's: the ones
        that target's lane also builds and runs the fixture at."""
        family = FAMILIES[FAMILY_OF[target]]
        return [one for one in self.levels if one in family]

    def status_at(self, level):
        """The status the program returns built at LEVEL: its
        `level_status:` entry, or `status`."""
        if level:
            for entry in _items(self.get("level_status", "")):
                named, equals, value = entry.partition("=")
                if equals and _trimmed(named) == level:
                    return _integer(value)
        return self.status

    @property
    def args(self):
        return self.get("args", "").split()

    @property
    def run_args(self):
        return self.get("run_args", "").split()

    @property
    def rooted(self):
        """Whether the fixture is compiled as a directory module under an
        import root, by its `root:` or by a `--root=` its `args` name."""
        return bool(self.get("root")) or any(
            word.startswith("--root=") for word in self.args)

    def module_arguments(self, base):
        """The source operands `refine` is given: `--root=` and the fixture
        directory for a rooted fixture, otherwise its program and `with`
        files, each below BASE, the fixture directory as the caller
        spells it.  As `Append_Module_Arguments`."""
        base = str(base)
        root = self.get("root", "")
        if root == ".":
            return ["--root=" + base, base]
        if root:
            return ["--root=" + _below(base, root), base]
        return ([_below(base, self.get("program", ""))]
                + [_below(base, one) for one in self.with_sources])

    def source_arguments(self, base):
        """What `refine` is run with for this fixture's verdict: a rooted
        fixture's `args` and then its module; a recorded one's `args` as
        written, which name their files from `compiler/ada`; otherwise its
        program and `with` files.  Lanes add their own target."""
        if self.get("root"):
            return self.args + self.module_arguments(base)
        if "args" in self:
            return self.args
        return self.module_arguments(base)

    def program_arguments(self, base, shared=()):
        """What a compiled runtime or ABI program is run with: its shared
        objects' paths, `run_args` as written, then each `run_files` file
        below BASE."""
        base = str(base)
        return ([str(one) for one in shared] + self.run_args
                + [_below(base, one) for one in self.run_files])

    def standard_input(self, base):
        """The file a program reads as its standard input: `stdin:` below
        BASE, or the empty `/dev/null` (`os.devnull`)."""
        if self.get("stdin"):
            return _below(str(base), self["stdin"])
        return os.devnull

    def run_expected(self, base):
        """The bytes `run_expect` names, or None."""
        if self.get("run_expect"):
            return Path(str(base), self["run_expect"]).read_bytes()
        return None


def as_metadata(mapping, label=""):
    """MAPPING as metadata: itself when it is, else a plain dict -- a lane's
    own case, an overlay, a manifest's copy -- read as fixture LABEL's, or as
    its `class:` says when LABEL is empty."""
    if isinstance(mapping, Metadata):
        return mapping
    return Metadata.of(mapping, label or mapping.get("class", "runtime") + "/")


def parse(text, cls, name=""):
    """Read metadata TEXT for a fixture of class CLS, as the Ada reader
    does.  Returns (Metadata, problems); the fixture is accepted only when
    problems is empty.  Each problem is the reader's text without the
    path the harness puts before it."""
    problems = []
    meta = Metadata()
    meta.cls, meta.name = cls, name
    complain = problems.append

    def once(key):
        if key in meta:
            complain("duplicate key: " + key)
            return False
        return True

    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    for number, line in enumerate(lines, 1):
        body = _trimmed(line)
        if body == "" or body.startswith("#"):
            continue
        if ":" not in body:
            complain("line %d is not `key: value`" % number)
            continue
        key, _, value = body.partition(":")
        key, value = _trimmed(key), _trimmed(value)
        if key not in KEYS:
            complain("unknown key: " + key)
            continue
        if not once(key):
            continue
        meta[key] = value
        KEYS[key](meta, value, cls, complain)

    _whole(meta, cls, complain)
    return meta, problems


def _class(meta, value, cls, complain):
    if value not in CLASSES:
        complain("unknown class: " + value)
    elif value != cls:
        complain("class %s does not match directory %s" % (value, cls))


def _summary(meta, value, cls, complain):
    if value == "":
        complain("summary is empty")


def _targets(meta, value, cls, complain):
    for one in _items(value):
        if one and one not in TARGETS:
            complain("unknown target: " + one)


def _codes(meta, value, cls, complain):
    ok = value != "" and not value.endswith(",")
    for one in _items(value):
        if not re.fullmatch(r"L[0-9]{4}", one):
            ok = False
    if cls not in ("unit", "negative", "positive", "runtime", "abi"):
        complain("codes belong only to a fixture that compiles a program,"
                 " or a unit note")
    elif not ok:
        complain("a code is L and four digits: " + value)


def _stdin(meta, value, cls, complain):
    if not is_below_directory(value):
        complain("stdin is not a file below the fixture directory: "
                 + (value or "<empty>"))


def _run_files(meta, value, cls, complain):
    seen = []
    for one in _items(value):
        if not is_below_directory(one):
            complain("run_files path is not a file below the fixture"
                     " directory: " + (one or "<empty>"))
        elif one in seen:
            complain("duplicate run_files path: " + one)
        else:
            seen.append(one)


def _profiles(meta, value, cls, complain):
    if value not in ("standard", "specialization"):
        complain("profiles is not standard or specialization: " + value)


def _level_status(meta, value, cls, complain):
    #  The Ada reader's loop: a trailing comma ends the list.
    entries = value.split(",") if value else []
    if len(entries) > 1 and entries[-1] == "":
        entries.pop()
    for entry in entries:
        entry = entry.strip(" ")
        named, equals, status = entry.partition("=")
        if not equals:
            complain("level_status entry is not LEVEL=STATUS: " + entry)
            return
        try:
            _integer(status)
        except ValueError:
            complain("level_status is not an integer: " + entry)
            return


def _stream(meta, value, cls, complain):
    if value not in ("output", "merged"):
        complain("stream is not output or merged: " + value)


def _nonempty(message):
    def check(meta, value, cls, complain):
        if value == "":
            complain(message)
    return check


def _c_files(key, belongs, message):
    def check(meta, value, cls, complain):
        if cls not in belongs:
            complain(message)
        seen, stems = [], []
        for one in _items(value):
            if not _relative_c_source(one):
                complain("%s path is not a relative .c file: %s"
                         % (key, one or "<empty>"))
            elif one in seen:
                complain("duplicate %s path: %s" % (key, one))
            elif key == "c-shared" and shared_stem(one) in stems:
                complain("two c-shared sources would build one object: "
                         + one)
            else:
                seen.append(one)
                stems.append(shared_stem(one))
    return check


def _c_args(meta, value, cls, complain):
    if cls != "abi":
        complain("c-args belong only to an ABI fixture")
    if not value.strip(" \t"):
        complain("c-args names no argument")


def _link(meta, value, cls, complain):
    if cls != "runtime":
        complain("link belongs only to a runtime fixture")
    elif value not in ("static", "libc"):
        complain("link is not static or libc: " + value)


def _constructs(meta, value, cls, complain):
    ok = value != "" and not value.endswith(",")
    for one in value.split(","):
        if not re.fullmatch(r"[0-9]{4}", one.strip(" ")):
            ok = False
    if not ok:
        complain("a construct is four digits, and this is not: " + value)


def _traps(meta, value, cls, complain):
    if value not in ("yes", "no"):
        complain("traps is not yes or no: " + value)


def _status(meta, value, cls, complain):
    try:
        _integer(value)
    except ValueError:
        complain("status is not a number: " + value)


def _nothing(meta, value, cls, complain):
    pass


KEYS = {
    "class": _class,
    "summary": _summary,
    "program": _nothing,
    "expect": _nothing,
    "targets": _targets,
    "codes": _codes,
    "lex": _nothing,
    "args": _nothing,
    "run_args": _nothing,
    "run_files": _run_files,
    "stdin": _stdin,
    "run_expect": _nothing,
    "profiles": _profiles,
    "levels": _nothing,
    "level_status": _level_status,
    "stream": _stream,
    "with": _nonempty("with names no file"),
    "root": _nonempty("root names no directory"),
    "fixed": _nonempty("fixed names no file"),
    "c-sources": _c_files("c-sources", ("abi",),
                          "c-sources belong only to an ABI fixture"),
    "c-shared": _c_files("c-shared", ("runtime", "abi"),
                         "c-shared belongs only to a runtime or ABI fixture"),
    "c-args": _c_args,
    "link": _link,
    "constructs": _constructs,
    "traps": _traps,
    "trap_report": _nothing,
    "status": _status,
}


def _whole(meta, cls, complain):
    """The rules between keys, in the Ada reader's order."""
    has = meta.__contains__
    for key in ("class", "summary", "targets"):
        if not has(key):
            complain("missing required key: " + key)
    if has("expect") and not has("args") and not has("root"):
        complain("expect without args: nothing would produce it")
    if has("args") and not has("expect") and not (
            has("root") and has("class") and cls == "negative"):
        complain("args without expect: nothing would be compared")
    if has("args") and has("root"):
        for word in meta["args"].split(" "):
            if word and (not word.startswith("-")
                         or word.startswith("--root=")):
                complain("a rooted fixture's args are the options refine"
                         " takes before the module its root gives, so they"
                         " name no module: " + word)
    if has("levels"):
        if cls != "runtime":
            complain("levels belong to a runtime fixture")
        for one in _items(meta["levels"]):
            if one not in PRODUCT_LEVELS:
                complain("level is no product target's: " + one)
    if has("level_status"):
        listed = "," + meta.get("levels", "").replace(" ", ",") + ","
        for one in _items(meta["level_status"]):
            level = _trimmed(one.partition("=")[0]) if "=" in one else one
            if "," + level + "," not in listed:
                complain("level_status names a level levels does not: "
                         + level)
    hosted = has("class") and cls in ("runtime", "abi")
    if cls in ("runtime", "abi"):
        if not has("profiles"):
            complain("missing required key: profiles")
    elif has("profiles"):
        complain("profiles belong only to a runtime or ABI fixture")
    if has("run_args") and not hosted:
        complain("run_args belong only to a runtime or ABI fixture")
    if has("run_files") and not hosted:
        complain("run_files belong only to a runtime or ABI fixture")
    if has("stdin") and not hosted:
        complain("stdin belongs only to a runtime or ABI fixture")
    if has("run_expect") and not hosted:
        complain("run_expect belongs only to a runtime or ABI fixture")
    if hosted and not has("program"):
        complain(("a runtime" if cls == "runtime" else "an ABI")
                 + " fixture needs a program to run")
    if has("class") and cls == "abi" and not has("c-sources"):
        complain("an ABI fixture needs c-sources")
    if (has("class") and cls == "runtime" and has("c-shared")
            and meta.get("link") != "libc"):
        complain("a runtime fixture with c-shared needs link: libc")
    if has("with") and not has("program"):
        complain("with names the rest of a module and there is no program"
                 " to be the rest of")
    if has("with"):
        for one in _items(meta["with"]):
            if len(one) >= 2 and one.endswith(".c"):
                complain("C source belongs in c-sources, never with: " + one)
    if has("root") and not (has("class") and cls in (
            "positive", "negative", "runtime", "abi")):
        complain("root belongs only to a positive, negative, runtime or ABI"
                 " fixture")
    if (has("root") and has("class") and cls in ("positive", "negative")
            and not meta.get("program")):
        complain("a rooted positive or negative fixture needs a nonempty"
                 " program")
    if has("root") and has("with"):
        complain("a rooted fixture discovers its module files instead of"
                 " naming them with `with`")
    if has("fixed") and not (has("class") and cls == "negative"
                             and has("codes") and has("program")):
        complain("fixed belongs only to a negative fixture with a program"
                 " and codes")
    if has("program") and not has("constructs"):
        complain("a fixture with a program says which constructs it is"
                 " about")
    if meta.get("traps") == "yes" and has("status"):
        complain("a trapping fixture has no exit status to compare")
    if (meta.get("traps") == "yes" and has("class")
            and cls not in ("runtime", "abi")):
        complain("only a runtime or ABI fixture runs a program that could"
                 " trap")
    if has("trap_report") and meta.get("traps") != "yes":
        complain("trap_report is the line a trapping program writes, and"
                 " needs traps: yes")


def read(directory, strict=True):
    """The metadata of the fixture in DIRECTORY, whose parent names its
    class; FixtureError lists every fault the harness would report.  A
    reader that compares what refine does rather than holding the format,
    a manifest, passes strict=False and takes what the file says, as
    the test program's own discovery is what refuses a faulty fixture."""
    directory = Path(directory)
    path = directory / NAME
    meta, problems = parse(path.read_text(encoding="utf-8"),
                           directory.parent.name, directory.name)
    for key in ("run_files", "c-sources", "c-shared"):
        for one in meta._list(key) if not problems else ():
            if not (directory / one).is_file():
                problems.append("%s names %s, which is missing or not a"
                                " file" % (key, one))
    if problems and strict:
        raise FixtureError(str(path), problems)
    meta.directory = directory
    return meta


def discover(classes=CLASSES, root=FIXTURES):
    """Every fixture of CLASSES under ROOT, by class and then by name, as a
    run orders them.  Raises FixtureError on the first faulty one."""
    root = Path(root)
    for cls in classes:
        directory = root / cls
        if not directory.is_dir():
            continue
        for name in sorted(os.listdir(directory)):
            if name.startswith("."):
                continue
            yield read(directory / name)
