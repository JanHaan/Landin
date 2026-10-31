#!/usr/bin/env python3
"""Fetch the vendor inputs devices/inputs.json pins, by URL and SHA-256.

A device's SVD and the vendor headers its generated modules are checked
against are not in this tree: each is named in devices/inputs.json by the
URL it is fetched from and the SHA-256 it must have.  This fetches each
one asked for, or every one, into a cache -- $LANDIN_INPUTS, or
~/.cache/landin/inputs -- as CACHE/NAME, verifies its hash, and prints
the path of each.  A cached file is verified every time it is used; one
whose bytes differ is fetched again, and a download whose bytes differ is
refused and never put in the cache.

An input whose pin says `"fetch": "by hand"` is one its publisher will not
serve to a script, such as ST's RM0433: a person downloads it from its URL
and puts it at CACHE/NAME.  This verifies a copy put there and never tries
to download one; without a copy it says where to put it.  Such an input is
fetched only when named, or with --all.

    python3 scripts/fetch_inputs.py                 # every input a script may fetch
    python3 scripts/fetch_inputs.py --all           # and verify those supplied by hand
    python3 scripts/fetch_inputs.py rp2040/RP2040.svd
    python3 scripts/fetch_inputs.py --offline NAME  # refuse to download

Standard library only, so it runs wherever check.py does.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
LOCK = ROOT / 'devices' / 'inputs.json'


class InputError(Exception):
    """An input that is not pinned, cannot be fetched, or has other bytes."""


def cache_root():
    named = os.environ.get('LANDIN_INPUTS')
    if named:
        return Path(named)
    return Path.home() / '.cache' / 'landin' / 'inputs'


def read_lock(path=LOCK):
    """The lock's inputs, refusing one that is not well formed."""
    lock = json.loads(Path(path).read_text(encoding='utf-8'))
    if lock.get('schema') != 1 or set(lock) != {'schema', 'inputs'}:
        raise InputError(str(path) + ': not a schema 1 lock')
    inputs = lock['inputs']
    for name, pin in inputs.items():
        parts = name.split('/')
        if (not name or name.startswith('/') or '\\' in name
                or any(part in ('', '.', '..') for part in parts)):
            raise InputError(name + ': not a relative input name')
        if not {'url', 'sha256'} <= set(pin) <= {'url', 'sha256', 'fetch'} \
                or pin.get('fetch', 'by script') not in ('by script', 'by hand'):
            raise InputError(name + ': a pin is a url, a sha256 and, for an'
                             ' input a person supplies, "fetch": "by hand"')
        if not pin['url'].startswith('https://'):
            raise InputError(name + ': fetched only over https')
        digest = pin['sha256']
        if len(digest) != 64 or any(c not in '0123456789abcdef' for c in digest):
            raise InputError(name + ': sha256 is not 64 lowercase hex digits')
    return inputs


def digest(data):
    return hashlib.sha256(data).hexdigest()


def fetch(name, inputs=None, cache=None, offline=False, opener=None):
    """The verified cached path of input NAME, fetching it if need be."""
    inputs = read_lock() if inputs is None else inputs
    if name not in inputs:
        raise InputError(name + ': devices/inputs.json pins no such input')
    pin = inputs[name]
    target = (cache_root() if cache is None else Path(cache)) / name
    if target.is_file() and digest(target.read_bytes()) == pin['sha256']:
        return target
    if pin.get('fetch') == 'by hand':
        found = (' The copy there has SHA-256 ' + digest(target.read_bytes())
                 + '.') if target.is_file() else ''
        raise InputError(name + ' is supplied by hand: its publisher does not'
                         ' serve it to a script. Download it from ' + pin['url']
                         + ' and put it at ' + str(target) + '; its SHA-256 must be '
                         + pin['sha256'] + '.' + found)
    if offline:
        raise InputError(name + ': not in the cache at ' + str(target)
                         + ', and --offline forbids fetching it')
    opener = opener or urllib.request.urlopen
    try:
        with opener(pin['url'], timeout=120) as response:
            data = response.read()
    except OSError as error:
        raise InputError(name + ': cannot fetch ' + pin['url'] + ': '
                         + str(error)) from error
    if digest(data) != pin['sha256']:
        raise InputError(name + ': ' + pin['url'] + ' has SHA-256 '
                         + digest(data) + ', not the pinned '
                         + pin['sha256'] + '; nothing was cached')
    target.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=target.parent, delete=False) as out:
        out.write(data)
    os.chmod(out.name, 0o644)
    os.replace(out.name, target)
    return target


def main(argv=None):
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('names', nargs='*',
                        help='inputs to fetch, as devices/inputs.json names them;'
                        ' every one when none is named')
    parser.add_argument('--all', action='store_true',
                        help='also verify the inputs supplied by hand')
    parser.add_argument('--offline', action='store_true',
                        help='use the cache only, and fail on a missing input')
    args = parser.parse_args(argv)
    try:
        inputs = read_lock()
        chosen = args.names or sorted(
            name for name in inputs
            if args.all or inputs[name].get('fetch') != 'by hand')
        for name in chosen:
            print(fetch(name, inputs, offline=args.offline))
    except InputError as error:
        print('fetch_inputs: ' + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
