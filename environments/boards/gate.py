#!/usr/bin/env python3
"""Run one port's physical board gate on the rig, from prepared bundles.

    python3 environments/boards/gate.py --port=PORT --bundles=DIR --output=NEW_DIRECTORY \
        [--rig=environments/boards/rig.json] [--lock-wait=SECONDS] \
        [--probehive=DIR] [--ram-loader=PATH]

PORT is one of rig.json's ports, whose steps run in order: each port's boot
check, which flashes, cold-starts, checks the physical oracle and restores
the fixed image, then its RAM run; the Pico 2's are both of its
architectures'.  DIR holds the bundles build.py prepared, DIR/BOARD/MODE,
which must have been built from this checkout's source.

Before anything touches the rig, and before the lock is taken, the gate
checks rig.json, every bundle against this checkout, the SRAM helper's
identity, probe-rs's revision, the probehive runtime's pinned files, the
hub cascade and the Arty, and rig.py's record of the loaded bitstream; each
refusal ends the run with its outcome.  It then holds the rig lock, waiting
at most --lock-wait seconds for it, across the whole sequence, so that no
other run comes between the boot check and the RAM run.  Before each step
it writes RIG_STATE/runs/PORT.json, and removes it once every step has run
to its own result: an entry found there says an earlier gate run of the
port was interrupted, which the outcome keeps as previous_interrupted, and
for the Pico 2 stops the run for the operator.

Each step runs as environments/boards/run.py runs it on the rig,
`python3 environments/boards/BOARD/board.py --mode=MODE --bundle=...
--output=NEW_DIRECTORY/BOARD-MODE ARGUMENTS`, in a process group of its
own; SIGINT and SIGTERM are passed on to it, so that it stops at its next
point and records its cancellation.  The sequence stops at the first step
that does not pass.  NEW_DIRECTORY/outcome.json keeps each step's outcome
and the run's provenance, and a summary is appended to $GITHUB_STEP_SUMMARY
when that is set.  The exit status is 0 only for a passed port.

--probehive defaults to RIG_STATE/probehive and --ram-loader to
RIG_STATE/bin/landin-ram-run.
"""

import argparse
import json
import os
import re
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from types import SimpleNamespace

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))
import bundle  # noqa: E402
import common  # noqa: E402
import rig as rigs  # noqa: E402
from common import Failed, NeedsOperator, NeedsSetup, ToolMismatch, require  # noqa: E402

BOARDS = ('rp2040', 'rp2350', 'rp2350_hazard3', 'stm32h753', 'esp32c3', 'esp32c5',
          'esp32', 'esp32s3')
PLACEHOLDER = re.compile(r'\{([a-z_]+)\}')


def utc_now():
    return datetime.now(timezone.utc).isoformat(timespec='seconds')


def port_steps(rig, port, values):
    """PORT's steps from RIG, each (board, mode, arguments) with VALUES and
    the port's location put in for their placeholders.  A location left
    null that a step uses is a setup the rig lacks."""
    ports = rig['ports']
    require(port in ports, 'rig.json has no port %r; its ports are %s' % (port, ', '.join(sorted(ports))))
    spec = ports[port]
    require(isinstance(spec, dict) and isinstance(spec.get('steps'), list) and spec['steps'],
            'rig.json port %s has no steps' % port)
    location = spec.get('location', {})
    require(isinstance(location, dict) and not set(location) & set(values),
            'rig.json port %s has an invalid location' % port)
    known = dict(values, **location)
    steps, unset, used = [], set(), set()
    for step in spec['steps']:
        require(isinstance(step, dict) and step.get('board') in BOARDS
                and step.get('mode') in ('boot', 'ram') and isinstance(step.get('arguments'), list)
                and all(isinstance(a, str) for a in step['arguments']),
                'rig.json port %s has an invalid step: %r' % (port, step))
        for argument in step['arguments']:
            for name in PLACEHOLDER.findall(argument):
                require(name in known, 'rig.json port %s names an unknown placeholder {%s}' % (port, name))
                used.add(name)
                if known[name] is None:
                    unset.add(name)
        require(not any(a.split('=', 1)[0] in ('--mode', '--bundle', '--output', '--record')
                        for a in step['arguments']),
                'rig.json port %s passes an option the gate controls' % port)
        steps.append(step)
    require(not unset, 'port %s is not set up on this rig: rig.json leaves its %s null. %s'
            % (port, ', '.join(sorted(unset)), spec.get('setup', '')), NeedsSetup)
    return [(step['board'], step['mode'],
             [PLACEHOLDER.sub(lambda m: str(known[m.group(1)]), a) for a in step['arguments']])
            for step in steps], used


# The host commands each board tool runs besides probe-rs and the SRAM
# helper, which have checks of their own.  A missing one is found before the
# lock, never in the middle of a sequence that has already flashed a board.
HOST_TOOLS = dict(rp2040=('uhubctl', 'journalctl'), rp2350=('uhubctl', 'journalctl'),
                  rp2350_hazard3=('uhubctl', 'journalctl'),
                  stm32h753=('uhubctl', 'journalctl'), esp32c3=('uhubctl', 'journalctl'),
                  esp32c5=('uhubctl', 'journalctl'), esp32=('uhubctl', 'journalctl'),
                  esp32s3=('uhubctl', 'journalctl'))


def host_tools(steps, used, which=shutil.which):
    """Each host command STEPS' tools run, found on PATH, or needs-setup
    naming every one that is missing; probehive's GPIO shell needs nix."""
    wanted = sorted({tool for board, _, _ in steps for tool in HOST_TOOLS[board]}
                    | ({'nix'} if 'probehive' in used else set()))
    found = {tool: which(tool) for tool in wanted}
    missing = [tool for tool, path in found.items() if not path]
    require(not missing, 'this rig lacks %s on PATH, which the %s steps run: install %s for the'
            ' user that runs the board gate' % (', '.join(missing), ', '.join(
                sorted({board for board, _, _ in steps})), 'them' if len(missing) > 1 else 'it'),
            NeedsSetup)
    return found


def probe_rs_identity(which=shutil.which, run=subprocess.run):
    """probe-rs on PATH and its --version, refused unless it is the pinned
    revision the SRAM helper is built from."""
    found = which('probe-rs')
    require(found, 'no probe-rs on PATH: install the pinned probe-rs %s' % common.HELPER_PROBE_REVISION,
            NeedsSetup)
    try:
        version = run([found, '--version'], capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise ToolMismatch('cannot ask %s for its version: %s' % (found, error)) from error
    text = (version.stdout + version.stderr).strip()
    require(version.returncode == 0 and common.HELPER_PROBE_REVISION[:7] in text,
            'probe-rs %s reports %r, not revision %s, the one the SRAM helper and'
            ' environments/boards/README.md pin' % (found, text, common.HELPER_PROBE_REVISION),
            ToolMismatch)
    return dict(path=found, version=text)


def commit_of(root, environ, run=subprocess.run):
    if environ.get('GITHUB_SHA'):
        return environ['GITHUB_SHA']
    if (Path(root) / '.git').exists():
        found = run(['git', '-C', str(root), 'rev-parse', 'HEAD'], capture_output=True, text=True)
        if found.returncode == 0:
            return found.stdout.strip()
    return None


def tail(path, lines=5):
    try:
        text = Path(path).read_text(errors='replace').splitlines()
    except OSError:
        return ''
    return '\n'.join(text[-lines:])


class Forwarder:
    """SIGINT and SIGTERM passed on to the running step, which stops of
    itself and records its cancellation; between steps the first raises
    Cancelled here."""
    def __init__(self):
        self.child, self.signals, self.previous = None, [], {}

    def __call__(self, number, frame):
        name = signal.Signals(number).name
        self.signals.append(name)
        if self.child is not None:
            try:
                os.kill(self.child.pid, number)
            except ProcessLookupError:
                pass
            return
        if len(self.signals) == 1:
            raise common.Cancelled(name)

    def install(self):
        for number in (signal.SIGINT, signal.SIGTERM):
            self.previous[number] = signal.signal(number, self)

    def restore(self):
        for number, handler in self.previous.items():
            signal.signal(number, handler)


def run_step(root, board, mode, directory, output, arguments, forwarder, environ):
    """One board tool run; returns its step entry for outcome.json."""
    name = '%s-%s' % (board, mode)
    out, log = output / name, output / (name + '.log')
    argv = [sys.executable, str(Path(root) / 'environments/boards' / board / 'board.py'),
            '--mode=' + mode, '--bundle=' + str(directory), '--output=' + str(out), *arguments]
    began = time.monotonic()
    with log.open('wb') as stream:
        stream.write(('$ ' + shlex.join(argv) + '\n').encode())
        stream.flush()
        process = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   stdin=subprocess.DEVNULL, start_new_session=True,
                                   cwd=str(root), env=dict(environ))
        forwarder.child = process
        try:
            for line in process.stdout:
                stream.write(line)
                stream.flush()
                sys.stdout.buffer.write(line)
                sys.stdout.flush()
            code = process.wait()
        finally:
            forwarder.child = None
            process.stdout.close()
            # Anything the tool left in its group once it has ended; a
            # shared bridge runs in a session of its own and stays.
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except (ProcessLookupError, PermissionError):
                pass
    entry = dict(board=board, mode=mode, exit_status=code,
                 elapsed_seconds=round(time.monotonic() - began, 3),
                 output=name, log=log.name, result=None, status=None, failure=None)
    try:
        result = json.loads((out / 'result.json').read_text())
        require(isinstance(result, dict), 'result.json is not an object')
    except (OSError, ValueError, Failed) as error:
        entry.update(outcome='incomplete',
                     failure='the tool exited %d without a readable result.json (%s); its log ends: %s'
                     % (code, error, tail(log)))
        return entry
    entry.update(result=name + '/result.json', status=result.get('status'),
                 failure=result.get('failure'),
                 outcome=result.get('outcome') or ('passed' if result.get('status') == 'passed' else 'failed'))
    if 'cancelled' in result:
        entry['phase'] = result['cancelled'].get('phase')
    if entry['outcome'] == 'passed' and code != 0:
        entry.update(outcome='failed', failure='a passed result but exit status %d' % code)
    return entry


def summary(document):
    def cell(text):
        return ' '.join(str(text or '').split()).replace('|', '\\|')[:240]
    lines = ['### Boards: %s, %s' % (document['port'], document['outcome']), '']
    if document.get('failure'):
        lines += [cell(document['failure']), '']
    if document['steps']:
        lines += ['| step | outcome | seconds | failure |', '|---|---|---|---|']
        lines += ['| %s %s | %s | %s | %s |' % (s['board'], s['mode'], s['outcome'], s['elapsed_seconds'],
                                               cell(s.get('failure'))) for s in document['steps']]
    return '\n'.join(lines) + '\n\n'


def run_gate(args, *, root=ROOT, environ=None, state=None, lock_path=None,
             sysfs=rigs.USB_SYSFS, boot_id_path=rigs.BOOT_ID, validate_bundle=bundle.validate,
             verify_helper=common.verify_ram_helper, probe_rs=probe_rs_identity, which=shutil.which,
             locks='/proc/locks',
             report=None, signals=True):
    environ = os.environ if environ is None else environ
    state = Path(common.RIG_STATE if state is None else state)
    output = Path(args.output).resolve()
    bundle.check_output(output, root)
    output.mkdir(parents=True, exist_ok=False)
    started, began = utc_now(), time.monotonic()
    provenance = dict(
        commit=commit_of(root, environ),
        github={key: environ.get(name) for key, name in (
            ('repository', 'GITHUB_REPOSITORY'), ('run_id', 'GITHUB_RUN_ID'),
            ('run_attempt', 'GITHUB_RUN_ATTEMPT'), ('workflow_ref', 'GITHUB_WORKFLOW_REF'),
            ('event', 'GITHUB_EVENT_NAME'), ('actor', 'GITHUB_ACTOR'), ('ref', 'GITHUB_REF'))},
        host=socket.gethostname(), rig_state=dict(path=str(state), source=common.RIG_STATE_SOURCE),
        bundles=[])
    document = dict(format_version=1, port=args.port, outcome=None, steps=[],
                    provenance=provenance, started=started)
    try:
        provenance['boot_id'] = rigs.boot_id(boot_id_path)
    except OSError:
        provenance['boot_id'] = None
    forwarder = Forwarder()
    if signals:
        forwarder.install()
    lock = None
    journal = state / 'runs' / ('%s.json' % args.port)
    try:
        # Everything before the lock reads files, sysfs and tool versions;
        # nothing touches a board, a probe or a hub.
        provenance['rig'] = dict(path=str(args.rig), sha256=common.sha(args.rig))
        rig = rigs.load_rig(args.rig)
        steps, used = port_steps(rig, args.port, dict(probehive=args.probehive, ram_loader=args.ram_loader))
        for board, mode, _ in steps:
            directory = Path(args.bundles) / board / mode
            try:
                prepared = validate_bundle(directory, board=board, mode=mode, source_root=root)
            except bundle.Invalid as error:
                raise Failed('bundle %s: %s' % (directory, error)) from error
            provenance['bundles'].append(dict(
                board=board, mode=mode, directory=str(directory),
                manifest_sha256=common.sha(directory / 'bundle.json'),
                compiler_identity=prepared.get('compiler_identity'),
                source_identity=(prepared.get('source_identity') or {}).get('sha256')))
        if 'ram_loader' in used:
            require(Path(args.ram_loader).is_file(), 'no SRAM helper at %s: install the pinned'
                    ' landin-ram-run there or name it with --ram-loader' % args.ram_loader, NeedsSetup)
            provenance['helper'] = verify_helper(SimpleNamespace(ram_loader=args.ram_loader))
        provenance['host_tools'] = host_tools(steps, used, which)
        provenance['probe_rs'] = probe_rs()
        if 'probehive' in used:
            provenance['probehive'] = dict(directory=str(args.probehive),
                                           commit=rig['probehive']['commit'],
                                           files=rigs.probehive_files(rig, args.probehive))
        cascade = common.cascade_root(sysfs=sysfs)
        provenance['topology'] = dict(cascade=cascade,
                                      arty=common.off_cascade(rig['arty_serial'], cascade, sysfs))
        if 'probehive' in used:
            provenance['bitstream'] = rigs.verify(rig, state, sysfs, boot_id_path)
        else:
            provenance['bitstream'] = 'not used by this port'
        run_label = environ.get('GITHUB_RUN_ID')
        lock = common.RigLock('gate.py %s%s' % (args.port, ', run %s' % run_label if run_label else ''),
                              lock_path, report=report, locks=locks, timeout=args.lock_wait)
        lock.acquire()
        provenance['lock'] = str(lock.path)
        try:
            previous = json.loads(journal.read_text())
        except FileNotFoundError:
            previous = None
        except (OSError, ValueError) as error:
            previous = dict(unreadable=str(error))
        if previous is not None:
            document['previous_interrupted'] = previous
            require(args.port != 'pico2', 'an earlier gate run of pico2 was interrupted (%s): the Pico 2'
                    ' may be left in either architecture or in its boot ROM.  Check it and restore its'
                    ' fixed image by hand, then remove %s' % (json.dumps(previous), journal),
                    NeedsOperator)
        for index, (board, mode, arguments) in enumerate(steps):
            if forwarder.signals:
                raise common.Cancelled(forwarder.signals[0])
            common.write_state(journal, json.dumps(dict(
                port=args.port, step=index, board=board, mode=mode, started=utc_now(),
                output=str(output), commit=provenance['commit'], github=provenance['github']),
                indent=2) + '\n', state)
            entry = run_step(root, board, mode, Path(args.bundles) / board / mode, output, arguments,
                             forwarder, environ)
            document['steps'].append(entry)
            if entry['outcome'] != 'passed':
                break
        # A step that ended without its own result, or a cancelled one, may
        # have left the board anywhere: the entry stays for the next run.
        if not forwarder.signals and all(s['outcome'] not in ('incomplete', 'cancelled')
                                         for s in document['steps']):
            journal.unlink(missing_ok=True)
        failing = next((s for s in document['steps'] if s['outcome'] != 'passed'), None)
        if failing:
            document['outcome'] = failing['outcome']
            document['failure'] = '%s %s: %s' % (failing['board'], failing['mode'], failing['failure'])
        elif len(document['steps']) < len(steps):
            document['outcome'] = 'cancelled'
            document['failure'] = 'cancelled by %s between steps' % forwarder.signals[0]
        else:
            document['outcome'] = 'passed'
    except (Failed, bundle.Invalid, OSError) as error:
        document['outcome'] = common.outcome_of(error)
        document['failure'] = str(error)
    except KeyboardInterrupt as error:
        document['outcome'] = 'cancelled'
        document['failure'] = 'cancelled by %s' % (forwarder.signals[0] if forwarder.signals else str(error) or 'SIGINT')
    finally:
        if lock is not None:
            lock.release()
        if signals:
            forwarder.restore()
        document['finished'] = utc_now()
        document['elapsed_seconds'] = round(time.monotonic() - began, 3)
        if forwarder.signals:
            document['signals'] = forwarder.signals
        common.write_json(output / 'outcome.json', document)
        if environ.get('GITHUB_STEP_SUMMARY'):
            try:
                with open(environ['GITHUB_STEP_SUMMARY'], 'a') as stream:
                    stream.write(summary(document))
            except OSError as error:
                print('cannot append the step summary: %s' % error, file=sys.stderr)
    print('boards %s: %s%s' % (args.port, document['outcome'],
                               ': ' + document['failure'] if document.get('failure') else ''))
    return document


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--port', required=True, help="one of rig.json's ports")
    parser.add_argument('--bundles', type=Path, required=True,
                        help="build.py's output, holding BOARD/MODE bundles")
    parser.add_argument('--output', type=Path, required=True, help='a new directory')
    parser.add_argument('--rig', type=Path, default=HERE / 'rig.json')
    parser.add_argument('--lock-wait', type=float, default=2700.0,
                        help='seconds to wait for the rig lock before ending rig-busy')
    parser.add_argument('--probehive', type=Path, default=common.RIG_STATE / 'probehive')
    parser.add_argument('--ram-loader', type=Path, default=common.RIG_STATE / 'bin/landin-ram-run')
    args = parser.parse_args(argv)
    if args.output.exists():
        parser.error('the output %s exists: name a new directory' % args.output)
    try:
        document = run_gate(args)
    except (OSError, bundle.Invalid) as error:
        parser.error(str(error))
    return 0 if document['outcome'] == 'passed' else 1


if __name__ == '__main__':
    sys.exit(main())
