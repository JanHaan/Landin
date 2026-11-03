#!/usr/bin/env python3
"""Checked board images and their matching source snapshot, without rig access.

The manifest is provenance and corruption detection for a trusted developer
transport, not a signature or a substitute for the board's physical oracle.
"""
import hashlib
import json
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[2]
SOURCE_ROOTS = ('environments/boards', 'compiler/tests/board',
                'compiler/tests/driver', 'devices', 'core', 'hosted', 'platform')
SOURCE_FILES = ('flake.nix', 'flake.lock', 'environments/pins.sh')
IGNORED = {'__pycache__', '.git', 'build', 'target'}


class Invalid(ValueError):
    pass


def sha(path):
    value = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def source_files(root=ROOT):
    """All source inputs, including uncommitted and new files in these roots."""
    root = Path(root).resolve()
    files = []
    for name in SOURCE_FILES:
        path = root / name
        if path.is_symlink() or not path.is_file():
            raise Invalid('missing or symlinked source pin: %s' % path)
        files.append(name)
    for name in SOURCE_ROOTS:
        directory = root / name
        if not directory.is_dir():
            raise Invalid('missing source directory: %s' % directory)
        for path in directory.rglob('*'):
            relative = path.relative_to(root)
            if any(part in IGNORED for part in relative.parts) or path.suffix == '.pyc':
                continue
            if path.is_symlink():
                raise Invalid('source snapshot cannot contain symlinks: %s' % relative)
            if path.is_file():
                files.append(relative.as_posix())
    return sorted(files)


def source_identity(root=ROOT):
    files = {name: sha(Path(root) / name) for name in source_files(root)}
    digest = hashlib.sha256(json.dumps(files, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    return dict(sha256=digest, files=files)


def snapshot(destination, root=ROOT):
    """Copy only named source roots, preserving dirty source bytes."""
    destination = Path(destination)
    check_output(destination, root)
    destination.mkdir(parents=True, exist_ok=False)
    before = source_identity(root)
    for name in before['files']:
        target = destination / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(Path(root) / name, target)
    if source_identity(destination) != before or source_identity(root) != before:
        raise Invalid('source changed while making the snapshot; prepare it again')
    return before


def check_output(destination, root=ROOT):
    destination, root = Path(destination).resolve(), Path(root).resolve()
    if any(destination.is_relative_to(root / name) for name in SOURCE_ROOTS):
        raise Invalid('output must be outside the source input directories: %s' % destination)


def write(directory, board, mode, files, metadata, symbols, compiler_identity,
          source=None):
    directory = Path(directory).resolve()
    entries = {}
    for name, path in files.items():
        path = Path(path).resolve()
        try:
            relative = path.relative_to(directory)
        except ValueError as error:
            raise Invalid('artifact is outside bundle: %s' % path) from error
        entries[name] = dict(path=relative.as_posix(), sha256=sha(path))
    manifest = dict(format_version=1, board=board, mode=mode, files=entries,
                    metadata=metadata, symbols=symbols,
                    source_identity=source if source is not None else source_identity(),
                    compiler_identity=compiler_identity)
    (directory / 'bundle.json').write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')
    return manifest


def artifact(prepared, name):
    try:
        relative = Path(prepared['files'][name]['path'])
    except (KeyError, TypeError) as error:
        raise Invalid('bundle has no %s artifact' % name) from error
    if relative.is_absolute() or '..' in relative.parts or not relative.parts:
        raise Invalid('unsafe artifact path: %s' % relative)
    directory = Path(prepared['_directory']).resolve()
    path = directory / relative
    # Refuse symlinks even when they currently point inside the bundle.
    current = directory
    for part in relative.parts:
        current = current / part
        if current.is_symlink():
            raise Invalid('symlink in artifact path: %s' % relative)
    if not path.is_file() or not path.resolve().is_relative_to(directory):
        raise Invalid('missing or escaping artifact: %s' % relative)
    return path


def validate(directory, *, board, mode, source_root=ROOT):
    directory = Path(directory).resolve()
    try:
        if (directory / 'bundle.json').is_symlink():
            raise Invalid('bundle manifest must not be a symlink')
        prepared = json.loads((directory / 'bundle.json').read_text())
        if not isinstance(prepared, dict):
            raise Invalid('bundle manifest must be an object')
        if (prepared.get('format_version'), prepared.get('board'), prepared.get('mode')) != (1, board, mode):
            raise Invalid('bundle format, board or mode does not match this run')
        prepared['_directory'] = directory
        if not isinstance(prepared.get('files'), dict):
            raise Invalid('bundle files must be an object')
        if not {'elf', 'report'} <= prepared['files'].keys():
            raise Invalid('bundle needs ELF and build report')
        for name, entry in prepared['files'].items():
            if sha(artifact(prepared, name)) != entry['sha256']:
                raise Invalid('%s artifact checksum does not match' % name)
        if prepared['source_identity'] != source_identity(source_root):
            raise Invalid('bundle source identity does not match these tool and firmware sources')
        if not isinstance(prepared['metadata'], dict) or not isinstance(prepared['symbols'], dict):
            raise Invalid('bundle metadata and symbols must be objects')
        if not isinstance(prepared['compiler_identity'], dict) or not prepared['compiler_identity'].get('sha256'):
            raise Invalid('bundle has no compiler content identity')
    except (KeyError, TypeError, json.JSONDecodeError) as error:
        raise Invalid('invalid bundle manifest: %s' % error) from error
    return prepared


def consume(run, args, board):
    """Validate before any rig operation, then retain artifacts with the run."""
    prepared = validate(args.bundle, board=board, mode=args.mode)
    destination = Path(run.out).resolve()
    destination.mkdir(parents=True, exist_ok=True)
    retained = {}
    for name in prepared['files']:
        source = artifact(prepared, name)
        target = destination / prepared['files'][name]['path']
        identity = (source.resolve(), prepared['files'][name]['sha256'])
        if target in retained:
            if retained[target] != identity:
                raise Invalid('distinct bundle artifacts collide at: %s' % target)
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.exists() and target.resolve() != source.resolve():
            raise Invalid('refusing to replace run artifact: %s' % target)
        if target.resolve() != source.resolve():
            shutil.copyfile(source, target)
        retained[target] = identity
    manifest = dict(prepared)
    manifest.pop('_directory')
    (destination / 'bundle.json').write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')
    return validate(destination, board=board, mode=args.mode)
