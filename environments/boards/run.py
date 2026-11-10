#!/usr/bin/env python3
"""Build on this host, copy checked inputs, run the board tool on rigpi.

    python3 environments/boards/run.py --board=rp2040 --refine=REFINE \
        --output=NEW_DIRECTORY -- --probehive /home/jan/src/probehive

Arguments after -- go to the board tool. The rigpi tool owns the rig lock
and all hardware operations. Local output retains the prepared bundle,
source, command logs and the board run's complete output, including failed
runs. The remote staging directory is removed once that output is here, a
failed run's too; it stays, with its path in transfer.json, when
--keep-remote asks, or when the result or a requested record could not be
retrieved and the remote copy is the only one.
--record LOCAL_PATH retrieves the board tool's passed record without
replacing an existing local file. RAM records cannot be named record.json.
"""
import argparse
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile
import time

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import build  # noqa: E402
import bundle  # noqa: E402
import common  # noqa: E402


def transport(command, log, *, live=False):
    """The only process boundary allowed to reach another host."""
    with Path(log).open('wb') as stream:
        stream.write(('$ ' + shlex.join([str(part) for part in command]) + '\n').encode())
        stream.flush()
        if not live:
            return subprocess.run([str(part) for part in command], stdout=stream,
                                  stderr=subprocess.STDOUT, text=True).returncode
        process = subprocess.Popen([str(part) for part in command], stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT)
        try:
            for line in process.stdout:
                stream.write(line)
                stream.flush()
                sys.stdout.write(line.decode('utf-8', errors='replace'))
                sys.stdout.flush()
            return process.wait()
        except BaseException:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            raise
        finally:
            process.stdout.close()


def manual_boot(arguments):
    """Follow the last transport selector, including argparse's prefixes.

    The board parser remains responsible for validity and ambiguity. An
    invalid prefix may enable progress, but cannot permit hardware work.
    """
    selected = None
    for index, value in enumerate(arguments):
        option, separator, setting = value.partition('=')
        if option.startswith('--') and '--boot-transport'.startswith(option):
            selected = setting if separator else (arguments[index + 1]
                if index + 1 < len(arguments) else None)
    return selected == 'manual-uf2'


def remove_remote(ssh, remote, output, transfer, kept=None):
    """Remove the run's staging directory on the host unless KEPT says why
    it stays; what happened is transfer['remote_cleanup'].

    REMOTE is the path mktemp gave, already held to /tmp/landin-board.NAME,
    so the command removes nothing else.  A removal that fails leaves the
    run's verdict alone: the directory is the host's to clear.
    """
    if kept:
        transfer['remote_cleanup'] = 'kept: ' + kept
        return
    status = transport(ssh + ['rm -rf -- ' + shlex.quote(remote)], output / 'remote-cleanup.log')
    transfer['remote_cleanup'] = ('removed' if status == 0 else
                                  'failed with status %s; see remote-cleanup.log' % status)


def execute(args, board_args=()):
    if not re.fullmatch(r'[A-Za-z0-9_][A-Za-z0-9_.@-]*', args.host):
        raise bundle.Invalid('host must be an SSH hostname or USER@HOST, without options')
    # These options belong to the wrapper; passing them twice could select
    # another image/mode or replace the retained output path.
    reserved = ('--bundle', '--mode', '--output', '--refine', '--record')
    for value in board_args:
        option = value.split('=', 1)[0]
        # argparse in the board tools also accepts option abbreviations.
        if option.startswith('--') and any(key.startswith(option) for key in reserved):
            raise bundle.Invalid('%s is controlled by the wrapper' % value)
    record = getattr(args, 'record', None)
    if record is not None:
        record = Path(record).expanduser().absolute()
        if args.mode == 'ram' and record.name == 'record.json':
            raise bundle.Invalid('RAM evidence is separate: use --record=ram-record.json')
        if record.exists() or record.is_symlink():
            raise bundle.Invalid('refusing to replace existing record: %s' % record)
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
    live = args.mode == 'boot' and manual_boot(board_args)
    if live:
        helper = remote + '/prepared/source/environments/boards/manual.py'
        status_command = ['python3', helper, 'status', '--output', remote + '/result']
        transfer['manual_status_command'] = shlex.join([str(part) for part in ssh]
                                                     + [shlex.join(status_command)])
        transfer['manual_output'] = remote + '/result'
    (output / 'transfer.json').write_text(json.dumps(transfer, indent=2) + '\n')
    keep = 'asked for with --keep-remote' if getattr(args, 'keep_remote', False) else None
    if transport(scp + ['-r', stage, args.host + ':' + remote + '/prepared'], output / 'copy.log'):
        #  Nothing ran there: what the directory holds is a partial copy.
        remove_remote(ssh, remote, output, transfer, keep)
        (output / 'transfer.json').write_text(json.dumps(transfer, indent=2) + '\n')
        raise bundle.Invalid('copy failed; see copy.log')
    tool = remote + '/prepared/source/environments/boards/' + args.board + '/board.py'
    command = ['python3', tool, '--mode=' + args.mode,
               '--bundle=' + remote + '/prepared/bundle', '--output=' + remote + '/result'] + list(board_args)
    remote_record = remote + ('/ram-record.json' if args.mode == 'ram' else '/record.json')
    if record is not None:
        command.append('--record=' + remote_record)
    if live:
        print('Manual boot results on %s: %s' % (args.host, transfer['manual_output']), flush=True)
        print('Status: ' + transfer['manual_status_command'], flush=True)
        status = transport(ssh + [shlex.join(command)], output / 'remote-run.log', live=True)
    else:
        status = transport(ssh + [shlex.join(command)], output / 'remote-run.log')
    copied = transport(scp + ['-r', args.host + ':' + remote + '/result', output / 'rigpi'],
                       output / 'retrieve.log')
    record_failed = False
    if record is not None:
        transfer.update(record_path=str(record), record_status='skipped')
        if status == 0:
            try:
                incoming = output / 'record-transfer'
                incoming.mkdir()
                staged_record = incoming / Path(remote_record).name
                retrieved = transport(scp + [args.host + ':' + remote_record, staged_record],
                                      output / 'record-retrieve.log')
                transfer['record_retrieval_status'] = retrieved
                if retrieved:
                    raise bundle.Invalid('record copy failed; see record-retrieve.log')
                if staged_record.is_symlink() or not staged_record.is_file():
                    raise bundle.Invalid('record copy produced no regular record file')
                data = staged_record.read_bytes()
                kept = json.loads(data)
                if not isinstance(kept, dict) or kept.get('status') != 'passed' or kept.get('mode') != args.mode:
                    raise bundle.Invalid('the retrieved record is not a passed %s run' % args.mode)
                record.parent.mkdir(parents=True, exist_ok=True)
                # Publish complete bytes with an exclusive link on the same
                # filesystem. A raced-in destination is never replaced, and a
                # failed write never leaves a partial record under its name.
                with tempfile.NamedTemporaryFile(dir=record.parent, prefix='.landin-record-') as destination:
                    destination.write(data)
                    destination.flush()
                    os.link(destination.name, record)
                transfer['record_status'] = 'written'
            except (OSError, ValueError) as error:
                record_failed = True
                transfer.update(record_status='failed', record_error=str(error))
    #  The remote copy goes once everything it holds is here.  What could
    #  not be retrieved has no other copy, so the directory then stays.
    remove_remote(ssh, remote, output, transfer, keep or (
        'the result was not retrieved; see retrieve.log' if copied else
        'the record was not retrieved: ' + transfer['record_error'] if record_failed else None))
    transfer.update(exit_status=status, retrieval_status=copied,
                    elapsed_seconds=round(time.monotonic() - started, 3))
    (output / 'transfer.json').write_text(json.dumps(transfer, indent=2) + '\n')
    print('%s %s: %s; results %s; remote %s:%s %s' %
          (args.board, args.mode, 'passed' if status == 0 and copied == 0 and not record_failed else 'failed',
           output, args.host, remote, transfer['remote_cleanup']))
    if record_failed:
        print('record failed: ' + transfer['record_error'])
    return status if status else int(copied != 0 or record_failed)


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
    parser.add_argument('--record', type=Path, help="copy the tool's passed record to a new local file")
    parser.add_argument('--keep-remote', action='store_true',
                        help="leave the run's staging directory on the host, its path in"
                             ' transfer.json, rather than remove it once the output is retrieved')
    parser.add_argument('--host', default='jan@10.42.0.60')
    parser.add_argument('--identity', type=Path, default=Path('~/.ssh/epycmicro-2026-09-17'))
    args = parser.parse_args(arguments)
    try:
        return execute(args, board_args)
    except (OSError, bundle.Invalid, common.Failed, subprocess.TimeoutExpired) as error:
        parser.error(str(error))


if __name__ == '__main__':
    sys.exit(main())
