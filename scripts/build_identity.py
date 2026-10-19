#!/usr/bin/env python3
"""Generate compiler provenance without checkout paths or wall-clock time."""
import argparse
import hashlib
import os
import re
from pathlib import Path
import subprocess


BUILD_SCRIPTS = (
    'scripts/build.sh', 'scripts/env.sh', 'scripts/build_lock.py',
    'scripts/build_config.py', 'scripts/build_identity.py',
    'scripts/build_link.py', 'scripts/toolchain.sh', 'environments/pins.sh',
)

#  The projects scripts/build.sh builds.  Everything else that reaches an
#  object is found from them, so a new kind of input -- a configuration
#  pragmas file, a source directory -- is counted the moment a project names
#  it, rather than when this script is taught it.
PROJECTS = ('compiler/ada/refine.gpr', 'compiler/ada/landin_tests.gpr')

SUFFIXES = {'ada': ('.ads', '.adb'), 'c': ('.c', '.h')}


class ProjectError(ValueError):
    pass


def _project_text(path):
    lines = (line.split('--', 1)[0] for line in path.read_text().splitlines())
    return '\n'.join(lines)


def _literals(text):
    return re.findall(r'"((?:[^"\n]|"")*)"', text)


def project_inputs(root):
    """(projects, sources, files) every built project reaches.

    Projects are followed through their `with` clauses.  A source directory
    is each literal in Source_Dirs, `/**` meaning its subtree; an element
    computed from the build directory is generated, and counted by the
    identity row instead.  Any other literal a project names that is a file
    beside it -- `landin.adc` -- is an input too.  Paths are relative to ROOT.
    """
    projects, sources, files = set(), set(), set()
    pending = [root / name for name in PROJECTS]
    while pending:
        path = pending.pop()
        relative = path.relative_to(root).as_posix()
        if relative in projects:
            continue
        if not path.is_file():
            raise ProjectError(f'{relative} does not exist')
        projects.add(relative)
        text = _project_text(path)
        for name in re.findall(r'^\s*(?:limited\s+)?with\s+"([^"]+)"', text,
                               re.MULTILINE | re.IGNORECASE):
            pending.append(Path(os.path.normpath(path.parent / name)))
        for literal in _literals(text):
            candidate = path.parent / literal
            if (literal and not literal.endswith('.gpr')
                    and '/' not in literal and candidate.is_file()):
                files.add(candidate.relative_to(root).as_posix())
        if re.search(r'^\s*abstract\s+project\b', text,
                     re.MULTILINE | re.IGNORECASE):
            continue
        languages = re.search(r'for\s+Languages\s+use\s*\(([^)]*)\)', text,
                              re.IGNORECASE)
        names = ([name.lower() for name in _literals(languages.group(1))]
                 if languages else ['ada'])
        unknown = [name for name in names if name not in SUFFIXES]
        if unknown:
            raise ProjectError(
                f'{relative} uses {", ".join(unknown)}, whose sources'
                ' scripts/build_identity.py does not know')
        suffixes = tuple(s for name in names for s in SUFFIXES[name])
        declared = re.search(r'for\s+Source_Dirs\s+use\s*\(([^)]*)\)', text,
                             re.IGNORECASE | re.DOTALL)
        elements = ([element.strip() for element in declared.group(1).split(',')
                     if element.strip()]
                    if declared else ['"."'])
        for element in elements:
            literal = re.fullmatch(r'"((?:[^"\n]|"")*)"', element)
            if literal is None:
                if element.startswith('Landin_Common.Build_Dir'):
                    continue
                raise ProjectError(
                    f'{relative} names a source directory {element} that'
                    ' scripts/build_identity.py cannot read')
            directory = literal.group(1)
            recursive = directory.endswith('/**')
            directory = path.parent / directory.removesuffix('/**')
            found = directory.rglob('*') if recursive else directory.glob('*')
            sources.update(p.relative_to(root).as_posix() for p in found
                           if p.is_file() and p.suffix in suffixes)
    return sorted(projects), sorted(sources), sorted(files)


def inputs(root):
    """Compiler sources, test sources and native build policy; never prose."""
    projects, sources, files = project_inputs(root)
    paths = set(BUILD_SCRIPTS) | set(projects) | set(sources) | set(files)
    return sorted(path for path in paths if (root / path).is_file())


def git(root, *args):
    try:
        result = subprocess.run(['git', '-C', str(root), *args],
                                capture_output=True, check=False)
    except FileNotFoundError:
        return None
    return result.stdout if result.returncode == 0 else None


def identity(root, mode):
    paths = inputs(root)
    digest = hashlib.sha256()
    for name in paths:
        content = (root / name).read_bytes()
        digest.update(name.encode() + b'\0')
        digest.update(str(len(content)).encode() + b'\0' + content)
    head = git(root, 'rev-parse', '--show-toplevel')
    # Do not borrow the containing repository's identity for an archive.
    repository = head is not None and Path(head.decode().strip()).resolve() == root.resolve()
    revision = git(root, 'rev-parse', '--verify', 'HEAD') if repository else None
    dirty = False
    version = ''
    if revision is not None:
        tracked = git(root, 'ls-files', '-z')
        if tracked is None:
            raise RuntimeError('cannot inspect compiler input inventory')
        tracked_paths = {name.decode() for name in tracked.split(b'\0') if name}
        # Every tracked edit marks the checkout dirty; the digest remains
        # restricted to compiler inputs. Untracked/ignored build outputs do not.
        status = git(root, 'status', '--porcelain=v1', '-z',
                     '--untracked-files=no')
        if status is None:
            raise RuntimeError('cannot inspect checkout status')
        tags = git(root, 'tag', '--points-at', 'HEAD')
        if tags is None:
            raise RuntimeError('cannot inspect exact release tags')
        versions = [tag[1:] for tag in tags.decode().splitlines()
                    if re.fullmatch(r'v[0-9]+(?:\.[0-9]+)+', tag)]
        if len(versions) > 1:
            raise RuntimeError('multiple release tags identify HEAD: '
                               + ', '.join(versions))
        version = versions[0] if versions else ''
        dirty = bool(status) or not set(paths).issubset(tracked_paths)
    return (revision.decode().strip() if revision else 'unknown',
            digest.hexdigest(), dirty, mode, version)


def render(root, mode, known=None):
    revision, digest, dirty, mode, version = known or identity(root, mode)
    return ('--  Generated by scripts/build_identity.py; do not edit.\n'
            'with Landin.Targets.Selection;\n\n'
            'package Landin.Build_Identity is\n'
            f'   Release_Version : constant String := "{version}";\n'
            f'   Revision : constant String := "{revision}";\n'
            '   Source_Digest : constant String :=\n'
            f'     "{digest}";\n'
            f'   Dirty : constant Boolean := {str(dirty)};\n'
            f'   Mode : constant String := "{mode}";\n'
            '   Host_Triplet : constant String :=\n'
            '     Landin.Targets.Selection.Build_Triplet;\n'
            'end Landin.Build_Identity;\n')


def generate(root, mode, output):
    text = render(root, mode)
    output.parent.mkdir(parents=True, exist_ok=True)
    if not output.exists() or output.read_text() != text:
        temporary = output.with_suffix('.tmp')
        temporary.write_text(text)
        temporary.replace(output)


def file_digest(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b''):
            digest.update(chunk)
    return digest.hexdigest()


def manifest(root, mode, output):
    """The rows of the build manifest this script owns.

    `project` rows are the project files and the files they name, and a
    change to one rebuilds from clean; `source` rows are the sources, which
    the checksum mode recompiles; the `identity` row is the generated
    provenance unit, with the revision and dirty state that went into it so
    a refusal can say which of them moved.  The scripts that run the build
    are not rows: what they decide reaches the objects through the identity
    unit's digest, the configuration rows and the switches row build.sh
    writes, and a change to them alone recompiles only what it changed.
    """
    projects, sources, files = project_inputs(root)
    rows = [f'project {file_digest(root / name)} {name}'
            for name in sorted(set(projects) | set(files))]
    rows += [f'source {file_digest(root / name)} {name}' for name in sources]
    known = identity(root, mode)
    revision, dirty = known[0], known[2]
    checksum = hashlib.sha256(render(root, mode, known).encode()).hexdigest()
    rows.append(f'identity {checksum} {revision} '
                + ('dirty' if dirty else 'clean'))
    return '\n'.join(rows) + '\n'


def changed(old, new):
    """Say, one line each, what differs between two manifests' texts."""
    def keyed(text):
        table = {}
        for row in text.splitlines():
            words = row.split(' ', 2)
            if len(words) == 3 and words[0] in ('project', 'source'):
                table[words[2]] = (words[0], words[1])
            elif words and words[0] == 'identity':
                table['identity'] = row
            elif row.strip():
                table[row.split(' ', 1)[0] + ' ' + row] = row
        return table
    before, after = keyed(old), keyed(new)
    said = []
    for key in sorted(set(before) | set(after)):
        if before.get(key) == after.get(key):
            continue
        if key == 'identity':
            was = before.get(key, 'identity - none none').split()
            now = after.get(key, 'identity - none none').split()
            if was[2:3] != now[2:3]:
                said.append(f'HEAD moved from {was[2]} to {now[2]}')
            elif was[3:4] != now[3:4]:
                said.append(
                    f'the checkout went from {was[3]} to {now[3]}: a tracked'
                    ' file the compiler does not build from was edited or'
                    ' restored, which changes only the provenance'
                    ' `refine --version` reports')
            elif not any(key != 'identity' and before.get(key) != after.get(key)
                         for key in set(before) | set(after)):
                said.append('a build script changed, which the provenance'
                            ' `refine --version` reports covers')
        elif key in before and key in after:
            said.append(f'{key} changed')
        elif key in after:
            said.append(f'{key} appeared' if after[key][0] in
                        ('project', 'source') else f'now: {after[key]}')
        else:
            said.append(f'{key} disappeared' if before[key][0] in
                        ('project', 'source') else f'was: {before[key]}')
    return said


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path)
    parser.add_argument('--mode', choices=('debug', 'release'))
    parser.add_argument('--output', type=Path)
    parser.add_argument('--manifest', action='store_true')
    parser.add_argument('--changed', nargs=2, metavar=('BEFORE', 'AFTER'),
                        type=Path, help='say what differs between two'
                        ' manifest files')
    args = parser.parse_args()
    if args.changed:
        for line in changed(*(path.read_text() for path in args.changed)):
            print(line)
        return
    if args.root is None or args.mode is None or args.output is None:
        parser.error('--root, --mode and --output are required')
    try:
        if args.manifest:
            print(manifest(args.root, args.mode, args.output), end='')
        else:
            generate(args.root, args.mode, args.output)
    except ProjectError as error:
        parser.exit(2, f'landin: build inputs: {error}\n')


if __name__ == '__main__':
    main()
