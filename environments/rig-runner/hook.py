#!/usr/bin/env python3
"""The rig runner's job hooks: which jobs may reach the boards.

    python3 hook.py started --repository OWNER/NAME --workflow PATH \
        --actor LOGIN [--actor LOGIN ...] [--log FILE]
    python3 hook.py completed [--log FILE]

The self-hosted runner on the rig host runs `started` before every job it is
assigned (ACTIONS_RUNNER_HOOK_JOB_STARTED) and `completed` after it
(ACTIONS_RUNNER_HOOK_JOB_COMPLETED).  A nonzero `started` means the job
does not run and is marked failed, before any of its steps, so no code from
the repository runs on the rig.

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
own checkout.  It never fails a job.

Both append one line of JSON per job to LOG, when given.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import sys
import time

MAIN = 'refs/heads/main'
EVENTS = ('push', 'schedule', 'workflow_dispatch')


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


def started(args, env):
    try:
        payload = json.loads(Path(env['GITHUB_EVENT_PATH']).read_text())
    except (KeyError, OSError, ValueError) as error:
        payload, reason = None, 'cannot read the event payload: %s' % error
    else:
        reason = refusal(env, payload, args.repository, args.workflow, set(args.actor))
    note(args.log, dict(identity(env), hook='started',
                        verdict='refused' if reason else 'accepted', reason=reason))
    if reason:
        print('This runner serves only trusted jobs of %s: %s.' % (args.repository, reason),
              file=sys.stderr, flush=True)
        return 1
    print('rig runner: accepted %s of %s at %s' % (
        env.get('GITHUB_EVENT_NAME'), env.get('GITHUB_REF'), env.get('GITHUB_SHA')), flush=True)
    return 0


def completed(args, env):
    workspace, root = env.get('GITHUB_WORKSPACE'), env.get('RUNNER_WORKSPACE')
    removed = []
    # Only a workspace inside the runner's own work directory is removed.
    if (workspace and root and Path(workspace).is_dir() and not Path(workspace).is_symlink()
            and Path(workspace).resolve().is_relative_to(Path(root).resolve())
            and Path(workspace).resolve() != Path(root).resolve()):
        for child in Path(workspace).iterdir():
            if child.is_dir() and not child.is_symlink():
                shutil.rmtree(child, ignore_errors=True)
            else:
                child.unlink(missing_ok=True)
            removed.append(child.name)
    note(args.log, dict(identity(env), hook='completed', removed=sorted(removed)))
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
    finish = commands.add_parser('completed', help="remove the job's workspace")
    finish.add_argument('--log', type=Path)
    args = parser.parse_args(argv)
    return started(args, env) if args.command == 'started' else completed(args, env)


if __name__ == '__main__':
    sys.exit(main())
