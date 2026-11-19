#!/usr/bin/env python3
"""Generate compiler provenance without checkout paths or wall-clock time."""
import argparse
import hashlib
import json
import os
import re
from pathlib import Path
import subprocess


BUILD_SCRIPTS = (
    'scripts/build.sh', 'scripts/env.sh', 'scripts/build_lock.py',
    'scripts/build_config.py', 'scripts/build_identity.py',
    'scripts/build_link.py', 'scripts/toolchain.sh', 'environments/pins.sh',
)

#  The projects scripts/build.sh builds: these two and every split command's
#  (SPLIT_COMMANDS).  Everything else that reaches an object is found from
#  them, so a new kind of input -- a configuration pragmas file, a source
#  directory -- is counted the moment a project names it, rather than when
#  this script is taught it.
PROJECTS = ('compiler/ada/refine.gpr', 'compiler/ada/landin_tests.gpr')

#  The one list of split commands, `refine-NAME` executables the `refine`
#  dispatcher runs, built, counted, packaged and installed in lockstep with
#  it.  Every consumer reads it through split_commands(): build.sh and
#  package.sh through --split-commands, the flake through builtins.fromJSON,
#  check.py, which also holds each entry's project to it, through runpy.
#  compiler/ada/README.md describes the format.
SPLIT_COMMANDS = 'compiler/ada/split-commands.json'
SPLIT_FORMAT = 'landin-split-commands-1'
SPLIT_NAME = re.compile(r'[a-z][a-z0-9-]*')

SUFFIXES = {'ada': ('.ads', '.adb'), 'c': ('.c', '.h')}


class ProjectError(ValueError):
    pass


def _project_text(path):
    lines = (line.split('--', 1)[0] for line in path.read_text().splitlines())
    return '\n'.join(lines)


def _literals(text):
    return re.findall(r'"((?:[^"\n]|"")*)"', text)


def split_commands(root):
    """[(name, project, main)] of the split commands ROOT lists, in order.

    PROJECT and MAIN are relative to compiler/ada.  A tree without the list
    has none: the synthetic checkouts the build's tests make hold only the
    files they exercise, and check.py refuses a repository without it.  A
    list this cannot read is a ProjectError naming what is wrong with it.
    """
    path = Path(root) / SPLIT_COMMANDS
    if not path.is_file():
        return []
    try:
        listed = json.loads(path.read_text(encoding='utf-8'))
    except (UnicodeDecodeError, ValueError) as error:
        raise ProjectError(f'{SPLIT_COMMANDS} is not JSON: {error}')
    if not isinstance(listed, dict) or listed.get('format') != SPLIT_FORMAT:
        raise ProjectError(f'{SPLIT_COMMANDS} does not say "format":'
                           f' "{SPLIT_FORMAT}"')
    commands = listed.get('commands')
    if not isinstance(commands, list):
        raise ProjectError(f'{SPLIT_COMMANDS} has no "commands" list')
    out, seen = [], set()
    for index, entry in enumerate(commands):
        fields = (entry.get(key) if isinstance(entry, dict) else None
                  for key in ('name', 'project', 'main'))
        name, project, main = fields
        if not all(isinstance(field, str) and field
                   for field in (name, project, main)) or set(entry) != {
                       'name', 'project', 'main'}:
            raise ProjectError(
                f'{SPLIT_COMMANDS}: command {index + 1} is not an object'
                ' with exactly the strings "name", "project" and "main"')
        if not SPLIT_NAME.fullmatch(name):
            raise ProjectError(
                f'{SPLIT_COMMANDS}: command name {name!r} is not lower-case'
                ' letters, digits and hyphens beginning with a letter')
        if name in seen:
            raise ProjectError(f'{SPLIT_COMMANDS} lists {name} twice')
        seen.add(name)
        for field in (project, main):
            if (field.startswith('/') or '..' in field.split('/')
                    or any(c.isspace() for c in field)):
                raise ProjectError(
                    f'{SPLIT_COMMANDS}: {name}\'s {field!r} is not a path'
                    ' inside compiler/ada without spaces')
        out.append((name, project, main))
    return out


def built_projects(root):
    """The projects build.sh builds, relative to ROOT: PROJECTS and every
    split command's, each of which must exist."""
    out = list(PROJECTS)
    for name, project, _ in split_commands(root):
        relative = 'compiler/ada/' + project
        if not (Path(root) / relative).is_file():
            raise ProjectError(
                f'{SPLIT_COMMANDS} lists the split command {name}, whose'
                f' project {relative} does not exist')
        out.append(relative)
    return out


def project_inputs(root):
    """(projects, sources, files) every built project reaches.

    Projects are followed through their `with` clauses.  A source directory
    is each literal in Source_Dirs, `/**` meaning its subtree; an element
    computed from the build directory is generated, and counted by the
    identity row instead.  Any other literal a project names that is a file
    beside it -- `landin.adc` -- is an input too.  Paths are relative to ROOT.
    """
    projects, sources, files = set(), set(), set()
    pending = [root / name for name in built_projects(root)]
    if (root / SPLIT_COMMANDS).is_file():
        files.add(SPLIT_COMMANDS)
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


def source_digest(root, paths=None):
    """The SHA-256 of the compiler's inputs under ROOT, in hexadecimal: the
    provenance unit's Source_Digest, which `refine version --json` reports
    and the citations file's source line names (D1357)."""
    digest = hashlib.sha256()
    for name in inputs(root) if paths is None else paths:
        content = (root / name).read_bytes()
        digest.update(name.encode() + b'\0')
        digest.update(str(len(content)).encode() + b'\0' + content)
    return digest.hexdigest()


def identity(root, mode):
    paths = inputs(root)
    digest = source_digest(root, paths)
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
            digest, dirty, mode, version)


def render(root, mode, known=None):
    revision, digest, dirty, mode, version = known or identity(root, mode)
    #  The names the dispatcher runs as `refine-NAME`, in list order, one
    #  space apart: lockstep means `refine` knows exactly the splits built,
    #  counted and shipped with it.
    names = ' '.join(name for name, _, _ in split_commands(root))
    #  Within the style check's 79 columns however many there are.
    chunks, line = [], ''
    for word in names.split(' '):
        if line and len(line) + 1 + len(word) > 60:
            chunks.append(line + ' ')
            line = word
        else:
            line = f'{line} {word}' if line else word
    chunks.append(line)
    literal = ' &\n     '.join(f'"{chunk}"' for chunk in chunks)
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
            '   Split_Commands : constant String :=\n'
            f'     {literal};\n'
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
    a refusal can say which of them moved, and the digest of the compiler's
    inputs, so two rows can be told to differ in the checkout's state alone
    (`provenance_only`).  The scripts that run the build
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
                + ('dirty' if dirty else 'clean') + f' {known[1]}')
    return '\n'.join(rows) + '\n'


def provenance_only(old, new):
    """Whether two manifests differ only in the checkout's state.

    The provenance unit records HEAD, whether any tracked file is edited
    and a release tag, beside the digest of what the compiler is built
    from.  When every other row is the same and the identity rows carry
    one digest, no input of the compiler differs: a document was edited or
    restored, or a commit was made, and what was built from the first
    manifest's tree is still what that manifest describes.  A build
    script's edit changes the digest, and is not this.
    """
    def split(text):
        rows = text.splitlines()
        return ([row.split() for row in rows if row.startswith('identity ')],
                [row for row in rows if not row.startswith('identity ')])
    (was, before), (now, after) = split(old), split(new)
    return (old != new and before == after
            and len(was) == 1 and len(now) == 1
            and len(was[0]) == 5 and len(now[0]) == 5
            and was[0][4] == now[0][4])


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
            elif was[3:4] != now[3:4] and any(
                    other != 'identity' and before.get(other) != after.get(other)
                    for other in set(before) | set(after)):
                said.append(f'the checkout went from {was[3]} to {now[3]}')
            elif was[3:4] != now[3:4]:
                said.append(
                    f'the checkout went from {was[3]} to {now[3]}: a tracked'
                    ' file the compiler does not build from was edited or'
                    ' restored, which changes only the provenance'
                    ' `refine --version` reports')
            elif len(was) == 5 and was[4:] == now[4:]:
                said.append('a release tag at HEAD appeared or went, which'
                            ' changes only the provenance `refine --version`'
                            ' reports')
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


def stale(old, new, build):
    """Remove the objects of every unit that depends on a changed source.

    GPRbuild's checksum mode recompiles a unit when a source it depends on
    changed in its tokens, and GNAT's checksum leaves out comments and
    spacing.  An edit to a spec's comments therefore recompiled nothing
    that depends on it, though those objects' debugging information names
    the spec's lines, which the edit moved, and the gate's comparison found
    the cached release build no longer the clean one.  Every ALI file under
    BUILD lists its unit's sources on `D` lines; a unit that names a source
    whose row changed loses its ALI and object, and is compiled again.
    Returns the units removed.
    """
    def sources(text):
        table = {}
        for row in text.splitlines():
            words = row.split(' ', 2)
            if len(words) == 3 and words[0] == 'source':
                table[words[2]] = words[1]
        return table
    before, after = sources(old), sources(new)
    names = {os.path.basename(path) for path, digest in after.items()
             if before.get(path) not in (None, digest)}
    removed = []
    if not names:
        return removed
    for directory, subdirectories, files in os.walk(build):
        subdirectories[:] = [name for name in subdirectories
                             if name not in ('bin', 'link')]
        for name in files:
            if not name.endswith('.ali'):
                continue
            path = os.path.join(directory, name)
            with open(path, encoding='latin-1') as ali:
                named = {line.split()[1] for line in ali
                         if line.startswith('D ') and len(line.split()) > 1}
            if named & names:
                os.remove(path)
                stem = path[:-len('.ali')]
                if os.path.exists(stem + '.o'):
                    os.remove(stem + '.o')
                removed.append(name[:-len('.ali')])
    return sorted(removed)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path)
    parser.add_argument('--mode', choices=('debug', 'release'))
    parser.add_argument('--output', type=Path)
    parser.add_argument('--manifest', action='store_true')
    parser.add_argument('--split-commands', action='store_true',
                        help='print each split command under --root as'
                        ' NAME PROJECT MAIN, one a line, in list order;'
                        ' PROJECT and MAIN are relative to compiler/ada')
    parser.add_argument('--changed', nargs=2, metavar=('BEFORE', 'AFTER'),
                        type=Path, help='say what differs between two'
                        ' manifest files')
    parser.add_argument('--provenance-only', nargs=2,
                        metavar=('BEFORE', 'AFTER'), type=Path,
                        help='succeed when two manifest files differ only'
                        ' in the checkout state the provenance reports')
    parser.add_argument('--stale', nargs=3,
                        metavar=('BEFORE', 'AFTER', 'BUILD'),
                        help='remove the objects of every unit under BUILD'
                        ' that depends on a source changed between two'
                        ' manifest files')
    args = parser.parse_args()
    if args.stale:
        before, after, build = args.stale
        removed = stale(Path(before).read_text(), Path(after).read_text(),
                        build)
        if removed:
            print(f'{len(removed)} units depend on a changed source and'
                  ' are compiled again')
        return
    if args.provenance_only:
        raise SystemExit(0 if provenance_only(
            *(path.read_text() for path in args.provenance_only)) else 1)
    if args.changed:
        for line in changed(*(path.read_text() for path in args.changed)):
            print(line)
        return
    if args.split_commands:
        if args.root is None:
            parser.error('--split-commands needs --root')
        try:
            built_projects(args.root)
            for row in split_commands(args.root):
                print(' '.join(row))
        except ProjectError as error:
            parser.exit(2, f'landin: split commands: {error}\n')
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
