#!/usr/bin/env python3
"""Build on this host, copy checked inputs, run the board tool on rigpi.

    python3 environments/boards/run.py --board=rp2040 --refine=REFINE \
        --output=NEW_DIRECTORY -- --probehive /home/jan/src/probehive

Arguments after -- go to the board tool. The rigpi tool owns the rig lock
and all hardware operations. Remote files are retained with their paths in
transfer.json; local output retains the prepared bundle, source, command
logs and the board run's complete output, including failed runs.
"""
import argparse
import json
from pathlib import Path
import re
import shlex
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import build  # noqa: E402
import bundle  # noqa: E402
import common  # noqa: E402


def transport(command, log):
    """The only process boundary allowed to reach another host."""
    with Path(log).open('w') as stream:
        stream.write('$ ' + shlex.join([str(part) for part in command]) + '\n')
        stream.flush()
        result = subprocess.run([str(part) for part in command], stdout=stream,
                                stderr=subprocess.STDOUT, text=True)
    return result.returncode


def execute(args, board_args=()):
    if not re.fullmatch(r'[A-Za-z0-9_][A-Za-z0-9_.@-]*', args.host):
        raise bundle.Invalid('host must be an SSH hostname or USER@HOST, without options')
    # These options belong to the wrapper; passing them twice could select
    # another image/mode or replace the retained output path.
    reserved = ('--bundle', '--mode', '--output', '--refine', '--record')
    for value in board_args:
        if any(value == key or value.startswith(key + '=') for key in reserved):
            raise bundle.Invalid('%s is controlled by the wrapper' % value)
    output = args.output.resolve()
    bundle.check_output(output, build.ROOT)
    output.mkdir(parents=True, exist_ok=False)
    started = time.monotonic()
    stage = output / 'prepared'
    stage.mkdir()
    # Build against the original tree; transfer an identical source snapshot.
    source = bundle.source_identity(build.ROOT)
    build.prepare(args.board, args.mode, args.refine, stage / 'bundle', source)
    if bundle.snapshot(stage / 'source', build.ROOT) != source:
        raise bundle.Invalid('source changed after preparation; build again')
    ssh = ['ssh', '-i', args.identity.expanduser(), '-o', 'BatchMode=yes', args.host]
    scp = ['scp', '-i', args.identity.expanduser(), '-o', 'BatchMode=yes']
    # mktemp returns a private path. Accept only this fixed prefix and a
    # basename with no shell metacharacters; do not unpack remote archives.
    made = subprocess.run([str(part) for part in ssh] + [
        'umask 077; mktemp -d /tmp/landin-board.XXXXXXXX'],
        capture_output=True, text=True)
    (output / 'remote-prepare.log').write_text(made.stdout + made.stderr)
    remote = made.stdout.strip()
    if made.returncode or not re.fullmatch(r'/tmp/landin-board\.[A-Za-z0-9]+', remote):
        raise bundle.Invalid('remote staging failed; see remote-prepare.log')
    transfer = dict(host=args.host, directory=remote, board=args.board, mode=args.mode,
                    source_identity=source['sha256'])
    (output / 'transfer.json').write_text(json.dumps(transfer, indent=2) + '\n')
    if transport(scp + ['-r', stage, args.host + ':' + remote + '/prepared'], output / 'copy.log'):
        raise bundle.Invalid('copy failed; see copy.log')
    tool = remote + '/prepared/source/environments/boards/' + args.board + '/board.py'
    command = ['python3', tool, '--mode=' + args.mode,
               '--bundle=' + remote + '/prepared/bundle', '--output=' + remote + '/result'] + list(board_args)
    status = transport(ssh + [shlex.join(command)], output / 'remote-run.log')
    copied = transport(scp + ['-r', args.host + ':' + remote + '/result', output / 'rigpi'],
                       output / 'retrieve.log')
    transfer.update(exit_status=status, retrieval_status=copied,
                    elapsed_seconds=round(time.monotonic() - started, 3))
    (output / 'transfer.json').write_text(json.dumps(transfer, indent=2) + '\n')
    print('%s %s: %s; results %s; remote %s:%s' %
          (args.board, args.mode, 'passed' if status == 0 and copied == 0 else 'failed',
           output, args.host, remote))
    return status if status else int(copied != 0)


def main(argv=None):
    arguments = list(sys.argv[1:] if argv is None else argv)
    if '--' in arguments:
        split = arguments.index('--')
        arguments, board_args = arguments[:split], arguments[split + 1:]
    else:
        board_args = []
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--board', choices=build.BOARDS, required=True)
    parser.add_argument('--mode', choices=('ram', 'boot'), default='ram')
    parser.add_argument('--refine', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--host', default='jan@10.42.0.60')
    parser.add_argument('--identity', type=Path, default=Path('~/.ssh/epycmicro-2026-09-17'))
    args = parser.parse_args(arguments)
    try:
        return execute(args, board_args)
    except (OSError, bundle.Invalid, common.Failed, subprocess.TimeoutExpired) as error:
        parser.error(str(error))


if __name__ == '__main__':
    sys.exit(main())
