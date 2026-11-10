#!/usr/bin/env python3
"""The rig runner's job hooks: which jobs may reach the boards.

    python3 hook.py started --repository OWNER/NAME --workflow PATH \
        --actor LOGIN [--actor LOGIN ...] [--log FILE] [--grace SECONDS]
    python3 hook.py completed [--log FILE]

The self-hosted runner on the rig host runs `started` before every job it is
assigned (ACTIONS_RUNNER_HOOK_JOB_STARTED) and `completed` after it
(ACTIONS_RUNNER_HOOK_JOB_COMPLETED).  A refused job must run none of its
steps, so no code from the repository runs on the rig.

A nonzero exit alone does not promise that.  The runner runs the hook as a
step of the job, and a later step written `if: always()`, or the `pre:` entry
of an action the job names, has a condition that a failed earlier step can
still satisfy.  So a refusal does not rest on step conditions.  `started`
removes the actions the runner downloaded for the job while it set the job
up, then kills the runner's worker process for this job, the ancestor of the
hook named Runner.Worker, and only then exits nonzero.  The worker is the
process that would evaluate and run every later step; without it there is
none.  The listener that started the worker reports the job failed and waits
for the next one.

This is the control that keeps untrusted code off the boards.  A pull
request from a fork runs the workflow files of its own merge commit, so it
can delete any `if:` the repository's workflow puts on its board jobs, or
add a workflow that names the rig's label; the runner itself must refuse.
`started` accepts only:

  - this repository, in the environment and in the event payload alike;
  - a push to refs/heads/main, a schedule on refs/heads/main, or a manual
    dispatch from a branch of this repository by an allowed actor, who
    also triggered the run;
  - the named workflow file at the ref being run;
  - no pull request in the event, its environment or its payload.

Everything else is refused with its reason.  The hook lives on the rig
host, outside the runner's directory and outside any checkout; the copy in
the repository is its source and its controls, so a change here reaches
the rig only when the maintainer deploys it.

`completed` removes the job's workspace, so the next job starts from its
own checkout.  It never fails a job: what it could not remove or write it
reports on standard error, and what stayed in the workspace is the log's
`kept`.

Both append one line of JSON per job to LOG, when given.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import signal
import stat
import sys
import time

MAIN = 'refs/heads/main'
EVENTS = ('push', 'schedule', 'workflow_dispatch')
# The runner's process for one job.  It is an ancestor of the hook, and the
# only process that runs the job's steps.
WORKER = 'Runner.Worker'
# Where a process's parent and names are read, and how one is ended.  The
# controls replace both.
PROC = Path('/proc')
kill = os.kill


def refusal(env, payload, repository, workflow, actors):
    """Why a job may not run on the rig, or None when it may."""
    name = env.get('GITHUB_EVENT_NAME', '')
    ref = env.get('GITHUB_REF', '')
    if env.get('GITHUB_REPOSITORY') != repository:
        return 'repository %r is not %s' % (env.get('GITHUB_REPOSITORY'), repository)
    if name not in EVENTS:
        return 'event %r never reaches the rig; only %s do' % (name, ', '.join(EVENTS))
    if not isinstance(payload, dict):
        return 'the event payload is not an object'
    if (payload.get('repository') or {}).get('full_name') != repository:
        return 'the event payload names another repository'
    if 'pull_request' in payload or env.get('GITHUB_HEAD_REF') or env.get('GITHUB_BASE_REF'):
        return 'a pull request never reaches the rig'
    if env.get('GITHUB_WORKFLOW_REF') != '%s/%s@%s' % (repository, workflow, ref):
        return 'workflow %r is not %s at %s' % (env.get('GITHUB_WORKFLOW_REF'), workflow, ref)
    if name in ('push', 'schedule'):
        if ref != MAIN:
            return '%s of %r: only %s reaches the rig' % (name, ref, MAIN)
        if name == 'push' and payload.get('ref') != MAIN:
            return 'the push payload names ref %r' % payload.get('ref')
        return None
    if not ref.startswith('refs/heads/'):
        return 'a manual run of %r: only a branch of this repository reaches the rig' % ref
    people = (env.get('GITHUB_ACTOR'), env.get('GITHUB_TRIGGERING_ACTOR'),
              (payload.get('sender') or {}).get('login'))
    if any(person not in actors for person in people):
        return 'a manual run by %s: only %s may start one' % (
            '/'.join(str(person) for person in people), ', '.join(sorted(actors)))
    return None


def note(log, entry):
    if log:
        entry = dict(entry, time=time.strftime('%Y-%m-%dT%H:%M:%S%z'))
        with Path(log).open('a') as stream:
            stream.write(json.dumps(entry, sort_keys=True) + '\n')


def identity(env):
    return {key: env.get(key) for key in (
        'GITHUB_REPOSITORY', 'GITHUB_EVENT_NAME', 'GITHUB_REF', 'GITHUB_SHA',
        'GITHUB_WORKFLOW_REF', 'GITHUB_RUN_ID', 'GITHUB_RUN_ATTEMPT', 'GITHUB_JOB',
        'GITHUB_ACTOR', 'GITHUB_TRIGGERING_ACTOR')}


def parent_and_names(pid):
    """A process's parent and the names it goes by, or None when unreadable.

    The names are the kernel's command name and the base names of its first
    two arguments, so a worker started as `dotnet Runner.Worker.dll` or
    through a wrapper is recognised like one started as `Runner.Worker`.
    """
    try:
        # "pid (command name) state parent ..."; the name may hold ')' itself.
        text = (PROC / str(pid) / 'stat').read_text(errors='replace')
        command, rest = text[text.index('(') + 1:].rsplit(')', 1)
        parent = int(rest.split()[1])
        arguments = (PROC / str(pid) / 'cmdline').read_bytes().split(b'\0')[:2]
    except (OSError, ValueError, IndexError):
        return None
    return parent, [command] + [os.path.basename(argument.decode(errors='replace'))
                                for argument in arguments]


def worker(pid=None):
    """The nearest ancestor that is the runner's worker, or None."""
    pid = os.getppid() if pid is None else pid
    seen = set()
    while pid > 1 and pid not in seen:
        seen.add(pid)
        found = parent_and_names(pid)
        if found is None:
            return None
        parent, names = found
        if any(WORKER in name for name in names):
            return pid
        pid = parent
    return None


def make_removable(tree):
    """Give the owner back the directory permissions a step took away."""
    for directory, _, _ in os.walk(tree):
        try:
            os.chmod(directory, stat.S_IMODE(os.lstat(directory).st_mode) | stat.S_IRWXU)
        except OSError:
            pass


def remove(path):
    """Remove a file, a symlink or a tree; whether it is gone afterwards."""
    try:
        if path.is_dir() and not path.is_symlink():
            make_removable(path)
            shutil.rmtree(path, ignore_errors=True)
        else:
            path.unlink(missing_ok=True)
    except OSError:
        pass
    return not os.path.lexists(path)


def downloaded_actions(env):
    """The directory the runner unpacks a job's actions into, or None.

    It is `_actions` beside the repository's work directory.  The runner
    fills it while it sets a job up, which is before this hook runs, so a
    refused job has already written there.
    """
    root = env.get('RUNNER_WORKSPACE')
    if not root:
        return None
    actions = Path(root).parent / '_actions'
    return actions if actions.is_dir() and not actions.is_symlink() else None


def refuse(args, env, reason):
    """Refuse a job so that none of its steps can run; the exit status."""
    actions = downloaded_actions(env)
    cleared = remove(actions) if actions is not None else None
    target = worker()
    try:
        note(args.log, dict(identity(env), hook='started', verdict='refused', reason=reason,
                            worker=target, actions_removed=cleared))
    except OSError as error:
        print('rig runner: cannot write %s: %s' % (args.log, error), file=sys.stderr, flush=True)
    print('This runner serves only trusted jobs of %s: %s.' % (args.repository, reason),
          file=sys.stderr, flush=True)
    if target is None:
        print("rig runner: no %s among this hook's ancestors, so only its exit status "
              'refuses the job.' % WORKER, file=sys.stderr, flush=True)
        return 1
    print("rig runner: ending this job's worker, process %d, so that no step of it runs."
          % target, file=sys.stderr, flush=True)
    # The worker waits for this hook, so nothing of the job runs meanwhile;
    # the pause lets it send the lines above before it goes.
    time.sleep(args.grace)
    try:
        kill(target, signal.SIGKILL)
    except OSError as error:
        print('rig runner: could not end process %d: %s' % (target, error),
              file=sys.stderr, flush=True)
    return 1


def started(args, env):
    try:
        payload = json.loads(Path(env['GITHUB_EVENT_PATH']).read_text())
    except (KeyError, OSError, ValueError) as error:
        reason = 'cannot read the event payload: %s' % error
    else:
        try:
            reason = refusal(env, payload, args.repository, args.workflow, set(args.actor))
        except Exception as error:  # A payload of an unexpected shape is refused too.
            reason = 'the event could not be judged: %r' % error
    if reason is None:
        try:
            note(args.log, dict(identity(env), hook='started', verdict='accepted', reason=None))
        except OSError as error:
            # A job the log cannot record does not run.
            reason = 'cannot write the log %s: %s' % (args.log, error)
    if reason:
        return refuse(args, env, reason)
    print('rig runner: accepted %s of %s at %s' % (
        env.get('GITHUB_EVENT_NAME'), env.get('GITHUB_REF'), env.get('GITHUB_SHA')), flush=True)
    return 0


def completed(args, env):
    workspace, root = env.get('GITHUB_WORKSPACE'), env.get('RUNNER_WORKSPACE')
    removed, kept = [], []
    try:
        # Only a workspace inside the runner's own work directory is removed.
        if (workspace and root and Path(workspace).is_dir() and not Path(workspace).is_symlink()
                and Path(workspace).resolve().is_relative_to(Path(root).resolve())
                and Path(workspace).resolve() != Path(root).resolve()):
            os.chmod(workspace, stat.S_IMODE(os.lstat(workspace).st_mode) | stat.S_IRWXU)
            for child in Path(workspace).iterdir():
                (removed if remove(child) else kept).append(child.name)
    except OSError as error:
        kept.append('%s: %s' % (workspace, error))
    if kept:
        print('rig runner: could not remove from the workspace: %s' % ', '.join(sorted(kept)),
              file=sys.stderr, flush=True)
    try:
        note(args.log, dict(identity(env), hook='completed', removed=sorted(removed),
                            kept=sorted(kept)))
    except OSError as error:
        print('rig runner: cannot write %s: %s' % (args.log, error), file=sys.stderr, flush=True)
    return 0


def main(argv=None, env=None):
    env = os.environ if env is None else env
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest='command', required=True)
    start = commands.add_parser('started', help='refuse every job that is not trusted')
    start.add_argument('--repository', required=True)
    start.add_argument('--workflow', required=True,
                       help='the workflow file, as .github/workflows/NAME.yml')
    start.add_argument('--actor', action='append', required=True,
                       help='a login allowed to start a manual run; repeat for more')
    start.add_argument('--log', type=Path)
    start.add_argument('--grace', type=float, default=2.0, metavar='SECONDS',
                       help="how long a refusal's message has to reach the job's log before "
                            "the job's worker is ended (default: %(default)s)")
    finish = commands.add_parser('completed', help="remove the job's workspace")
    finish.add_argument('--log', type=Path)
    args = parser.parse_args(argv)
    return started(args, env) if args.command == 'started' else completed(args, env)


if __name__ == '__main__':
    sys.exit(main())
