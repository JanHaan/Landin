#!/usr/bin/env python3
"""Say when a `refine` is not the one its checkout builds.

    python3 scripts/refine_revision.py --refine PATH [--root CHECKOUT]

`refine version --json` names the revision a binary was built from, whether
that tree was dirty, and the digest of the compiler sources it was built
from (scripts/build_identity.py).  refine itself never reads git; this
compares those with the checkout, and prints one `landin: warning:` line
on standard error when they part, so a binary taken from a sibling
checkout or left from an older build is not mistaken for the tree's.

The digest decides.  A binary whose source digest is the checkout's was
built from these compiler sources, whatever its revision or dirtiness say:
a build made before a commit of documents, or of the very edits it was
built with, is current, and nothing is said.  Otherwise the warning says
how it parts, by the revision it names:

- an ancestor of the checkout's HEAD: it is older, and the warning
  counts the commits between;
- HEAD itself, built from a clean tree: it is older than the tree, whose
  uncommitted edits have changed compiler sources since; built from a
  dirty tree, its edits are not the tree's now, which is neither;
- a descendant of HEAD: it is newer, built after a commit this checkout
  has not reached;
- a commit neither contains, or one this checkout does not have: it is
  from another line of history, and is neither older nor newer;
- `unknown`, a build outside a git checkout: its sources are other ones.

Only a binary that answers `refine version --json` is judged: one that
does not, a stand-in or a program that is no refine, is the lane's to
refuse, and nothing is said.  dev-build.sh and dev-test.sh run this after
their build, and every lane that takes `--refine` calls `warn` with it; a
warning never changes a status.
"""
import argparse
import json
from pathlib import Path
import subprocess
import sys

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(HERE))

import build_identity  # noqa: E402


def binary_identity(refine, timeout=60):
    """What REFINE says it was built from: (revision, digest, dirty), or
    None when it does not answer `version --json` as refine does."""
    try:
        ran = subprocess.run([str(refine), 'version', '--json'],
                             capture_output=True, timeout=timeout,
                             stdin=subprocess.DEVNULL, check=False)
        out = ran.stdout
        said = json.loads(out.decode('utf-8') if isinstance(out, bytes)
                          else out)
    except (OSError, ValueError, TypeError, AttributeError,
            subprocess.SubprocessError):
        #  Not a refine's answer; a lane's own stand-in among them.
        return None
    if (ran.returncode != 0 or not isinstance(said, dict)
            or said.get('compiler') != 'refine'
            or not isinstance(said.get('revision'), str)
            or not isinstance(said.get('source_digest'), str)
            or not isinstance(said.get('dirty'), bool)):
        return None
    return said['revision'], said['source_digest'], said['dirty']


def _git(root, *words):
    ran = subprocess.run(['git', '-C', str(root), *words],
                         capture_output=True, check=False)
    return ran.stdout.decode().strip() if ran.returncode == 0 else None


def _between(root, older, newer):
    counted = _git(root, 'rev-list', '--count', older + '..' + newer)
    return int(counted) if counted and counted.isdigit() else None


def _commits(count):
    return '%d commit%s' % (count, '' if count == 1 else 's')


def judgement(binary, checkout, root):
    """How BINARY, (revision, digest, dirty), parts from CHECKOUT, the
    identity build_identity gives ROOT; None when it does not."""
    revision, digest, dirty = binary
    head, current = checkout[0], checkout[1]
    if digest == current:
        return None
    built = revision[:12] + (' (dirty)' if dirty else '')
    if revision == 'unknown':
        return ('was built outside a git checkout, from compiler sources'
                ' other than this checkout\'s')
    if head == 'unknown':
        return ('was built from %s, and its compiler sources are not this'
                ' checkout\'s, which has no git revision to compare' % built)
    if revision == head and dirty:
        return ('is not this checkout\'s tree: built from its HEAD %s with'
                ' uncommitted edits other than the tree\'s now' % built)
    if revision == head:
        return ('is older than this checkout\'s tree: built from its HEAD'
                ' %s, which the tree\'s uncommitted edits to compiler'
                ' sources have changed since' % built)
    if _git(root, 'cat-file', '-e', revision + '^{commit}') is None:
        return ('was built from %s, a revision this checkout does not'
                ' have' % built)
    if _git(root, 'merge-base', '--is-ancestor', revision, head) is not None:
        count = _between(root, revision, head)
        return ('is older than this checkout: built from %s, %s before its'
                ' HEAD %s' % (built, _commits(count) if count else 'commits',
                              head[:12]))
    if _git(root, 'merge-base', '--is-ancestor', head, revision) is not None:
        count = _between(root, head, revision)
        return ('is newer than this checkout: built from %s, %s after its'
                ' HEAD %s' % (built, _commits(count) if count else 'commits',
                              head[:12]))
    base = _git(root, 'merge-base', revision, head)
    return ('was built from %s, on another line of history than this'
            ' checkout\'s HEAD %s%s' % (
                built, head[:12],
                ' (they part at %s)' % base[:12] if base else ''))


def staleness(refine, root=ROOT):
    """The warning for REFINE beside ROOT, or None."""
    binary = binary_identity(refine)
    if binary is None:
        return None
    try:
        checkout = build_identity.identity(Path(root), 'debug')
    except (OSError, RuntimeError, build_identity.ProjectError):
        return None
    found = judgement(binary, checkout, root)
    if found is None:
        return None
    return ('landin: warning: %s %s; rebuild it with ./scripts/dev-build.sh,'
            ' or name the refine this checkout builds' % (refine, found))


def warn(refine, root=ROOT, stream=None):
    """Write REFINE's warning to STREAM, standard error by default; return
    it, or None when there is none."""
    said = staleness(refine, root) if refine else None
    if said:
        print(said, file=stream or sys.stderr, flush=True)
    return said


def main(argv=None):
    parser = argparse.ArgumentParser(
        description='Warn when a refine was not built from this checkout.')
    parser.add_argument('--refine', type=Path, required=True)
    parser.add_argument('--root', type=Path, default=ROOT)
    args = parser.parse_args(argv)
    warn(args.refine, args.root)
    return 0


if __name__ == '__main__':
    sys.exit(main())
