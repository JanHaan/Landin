#!/usr/bin/env python3
"""Shared scaffolding for exercising check.py's checks.

A check that cannot fail is worse than none.  Renaming tour.md once made
four of check.py's checks vacuous while the run still said `all clean`,
which is why `absent()` exists; the lesson is general, and most of the
checks have never been shown to fire.

Two shapes cover them.  A check whose inputs are small gets a SYNTHETIC
tree written from scratch, which states exactly what the check needs.  A
check whose inputs are large or content-addressed -- a recorded sha256
cannot be invented -- gets the real files COPIED and then broken in one
place, so the control says which single change the check notices.

Both put cwd and check.py's ROOT on the same throwaway directory, because
the checks are written both ways: some join ROOT, some read a repository
path relative to the directory check.py changes into.
"""
from contextlib import contextmanager
import importlib.util
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]

_spec = importlib.util.spec_from_file_location(
    "landin_document_checker", ROOT / "check.py")
checker = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(checker)

#  The grammar corpus's verdicts, carried from tree to tree.  Every tree
#  starts without them, and deriving the corpus from nothing takes two
#  minutes, which seven controls paid one after another.  Seeded from the
#  checkout's own cache; a tree whose grammar is still the real one hands
#  its verdicts on.  A verdict is reused only for the same source bytes
#  under the same grammar and code, so a control that changes either is
#  derived afresh exactly as check.py itself would.
CORPUS_CACHE = ".scratch/check-grammar-corpus.json"
_corpus = {"verdicts": None, "identity": None}


def _real_identity():
    if _corpus["identity"] is None:
        rules, trees, _ = checker.read_grammar(str(ROOT / checker.SPEC_NAME))
        with patch.object(checker, "ROOT", str(ROOT)):
            _corpus["identity"] = checker.grammar_corpus_cache(rules, trees)[1]
    return _corpus["identity"]


def _cached_identity(path):
    try:
        return json.loads(path.read_text(encoding="utf-8")).get("identity")
    except (OSError, ValueError, AttributeError):
        return None


_ignored = None


def _git_ignored():
    """What Git ignores here, as paths relative to ROOT; once per run.

    A copy takes the repository, not what a build or a lane left in it:
    a cross lane once left 2300 sparse QEMU core files in compiler/ada,
    and copying compiler/ wrote them out whole, 19 GB a tree.
    """
    global _ignored
    if _ignored is None:
        import subprocess
        try:
            listed = subprocess.run(
                ["git", "ls-files", "-z", "--others", "--ignored",
                 "--exclude-standard", "--directory"], cwd=ROOT,
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                timeout=60).stdout
        except (OSError, subprocess.TimeoutExpired):
            listed = b""
        _ignored = {os.fsdecode(p).rstrip("/")
                    for p in listed.split(b"\0") if p}
    return _ignored


def _ignore(directory, names):
    """shutil's ignore: the generated trees, and whatever Git ignores."""
    out = set(shutil.ignore_patterns(
        "build", ".git", ".scratch", "node_modules", "__pycache__",
        "site")(directory, names))
    here = os.path.relpath(directory, ROOT)
    ignored = _git_ignored()
    return out | {name for name in names
                  if os.path.normpath(os.path.join(here, name)) in ignored}


@contextmanager
def tree(written=None, copied=()):
    """A throwaway repository: `written` from scratch, `copied` from here."""
    with tempfile.TemporaryDirectory() as raw:
        #  Resolved, because on macOS the temporary directory is reached
        #  through a symlink: /var is /private/var.  ROOT and the working
        #  directory would then disagree, and absent() would compute a
        #  relative path out of the tree and call every file missing.
        tmp = os.path.realpath(raw)
        root = Path(tmp)
        for relative in copied:
            target = root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            source = ROOT / relative
            if source.is_dir():
                #  Never the generated trees.  A build directory holds a
                #  fixture's deliberately recursive symlinks -- parent
                #  pointing at parent, thirty deep -- which is a test of
                #  the compiler's path handling and a trap for a copy.
                shutil.copytree(source, target, dirs_exist_ok=True,
                                symlinks=True, ignore=_ignore)
            else:
                shutil.copy2(source, target)
        for relative, content in (written or {}).items():
            target = root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            if isinstance(content, bytes):
                target.write_bytes(content)
            else:
                target.write_text(content, encoding="utf-8")
        cache = root / CORPUS_CACHE
        if checker.SPEC_NAME in copied and not cache.exists():
            seed = _corpus["verdicts"]
            real = ROOT / CORPUS_CACHE
            if seed is None and _cached_identity(real) == _real_identity():
                seed = real.read_text(encoding="utf-8")
            if seed is not None:
                cache.parent.mkdir(parents=True, exist_ok=True)
                cache.write_text(seed, encoding="utf-8")
        here = os.getcwd()
        os.chdir(tmp)
        #  On the path too: some checks import the repository's own
        #  modules by package, and would otherwise reach the real ones
        #  beside this file rather than the copies under test.
        sys.path.insert(0, tmp)
        try:
            with patch.object(checker, "ROOT", tmp):
                yield root
        finally:
            if _cached_identity(cache) == _real_identity():
                _corpus["verdicts"] = cache.read_text(encoding="utf-8")
            sys.path.remove(tmp)
            for name in [n for n in sys.modules
                         if n == "scripts" or n.startswith("scripts.")]:
                del sys.modules[name]
            os.chdir(here)


def faults(check, **kinds):
    """What `check` says about a tree, as a list of (path, line, why)."""
    with tree(**kinds):
        return list(check(True))


def reasons(check, **kinds):
    """Just the explanations, for asserting on what a check objected to."""
    return [why for _, _, why in faults(check, **kinds)]
