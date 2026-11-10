#!/usr/bin/env python3
"""The rig runner's job hooks, against simulated job environments."""
import contextlib
import io
import json
import os
from pathlib import Path
import signal
import stat
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'environments/rig-runner'))
import hook  # noqa: E402

REPOSITORY = 'JanHaan/Landin'
WORKFLOW = '.github/workflows/gate.yml'
ARGS = ['started', '--repository', REPOSITORY, '--workflow', WORKFLOW, '--actor', 'JanHaan',
        '--grace', '0']


class Processes:
    """A process table for the hook to read, and a record of what it ended.

    These cases also run inside real GitHub Actions jobs, where this process
    has a real Runner.Worker above it, so no case in this process may let
    the hook read the real table or send a real signal.
    """

    def __init__(self, case, root, chain=(('bash', 'bash'), ('Runner.Worker', 'Runner.Worker'),
                                          ('Runner.Listener', 'Runner.Listener'))):
        self.proc, self.killed, self.pids = root / 'proc', [], []
        pid = os.getppid()
        for index, (command, argument) in enumerate(chain):
            parent = 1 if index == len(chain) - 1 else 70000 + index
            entry = self.proc / str(pid)
            entry.mkdir(parents=True)
            (entry / 'stat').write_text('%d (%s) S %d 1 1 0' % (pid, command, parent))
            (entry / 'cmdline').write_bytes(b'/opt/runner/bin/' + argument.encode() + b'\0x\0')
            self.pids.append(pid)
            pid = parent
        saved = hook.PROC, hook.kill
        hook.PROC, hook.kill = self.proc, lambda pid, number: self.killed.append((pid, number))
        case.addCleanup(lambda: setattr(hook, 'PROC', saved[0]))
        case.addCleanup(lambda: setattr(hook, 'kill', saved[1]))


class Started(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.log = self.root / 'hook.log'
        self.processes = Processes(self, self.root)

    def job(self, event='push', ref='refs/heads/main', payload=None, **env):
        if payload is None:
            payload = {'repository': {'full_name': REPOSITORY}, 'sender': {'login': 'JanHaan'}}
            if event == 'push':
                payload['ref'] = ref
        path = self.root / 'event.json'
        path.write_text(json.dumps(payload))
        values = dict(GITHUB_REPOSITORY=REPOSITORY, GITHUB_EVENT_NAME=event, GITHUB_REF=ref,
                      GITHUB_SHA='0' * 40, GITHUB_EVENT_PATH=str(path),
                      GITHUB_WORKFLOW_REF='%s/%s@%s' % (REPOSITORY, WORKFLOW, ref),
                      GITHUB_ACTOR='JanHaan', GITHUB_TRIGGERING_ACTOR='JanHaan',
                      GITHUB_RUN_ID='1', GITHUB_RUN_ATTEMPT='1', GITHUB_JOB='board')
        values.update({key: value for key, value in env.items() if value is not None})
        for key in [key for key, value in env.items() if value is None]:
            values.pop(key, None)
        return values

    def verdict(self, env):
        stderr = io.StringIO()
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(stderr):
            status = hook.main(ARGS + ['--log', str(self.log)], env)
        entry = json.loads(self.log.read_text().splitlines()[-1])
        self.assertEqual(entry['verdict'], 'accepted' if status == 0 else 'refused')
        return status, stderr.getvalue()

    def assertAccepted(self, env):
        del self.processes.killed[:]
        status, message = self.verdict(env)
        self.assertEqual(status, 0, message)
        self.assertEqual(self.processes.killed, [])

    def assertRefused(self, env, words):
        del self.processes.killed[:]
        status, message = self.verdict(env)
        self.assertEqual(status, 1)
        self.assertIn(words, message)
        # Every refusal ends the job's worker; none rests on the exit status.
        self.assertEqual(self.processes.killed, [(self.processes.pids[1], signal.SIGKILL)])

    def test_main_push_schedule_and_manual_branch_run_are_accepted(self):
        self.assertAccepted(self.job())
        self.assertAccepted(self.job('schedule'))
        self.assertAccepted(self.job('workflow_dispatch'))
        self.assertAccepted(self.job('workflow_dispatch', 'refs/heads/r1260-integration'))

    def test_pull_requests_never_run_whatever_the_workflow_says(self):
        for event in ('pull_request', 'pull_request_target', 'workflow_run', 'merge_group'):
            self.assertRefused(self.job(event, 'refs/pull/7/merge'), 'never reaches the rig')
        payload = {'repository': {'full_name': REPOSITORY}, 'ref': 'refs/heads/main',
                   'pull_request': {'number': 7}}
        self.assertRefused(self.job(payload=payload), 'pull request')
        self.assertRefused(self.job(GITHUB_HEAD_REF='fork-branch'), 'pull request')

    def test_a_fork_or_other_repository_is_refused(self):
        self.assertRefused(self.job(GITHUB_REPOSITORY='someone/Landin'), 'repository')
        payload = {'repository': {'full_name': 'someone/Landin'}, 'ref': 'refs/heads/main'}
        self.assertRefused(self.job(payload=payload), 'another repository')

    def test_only_main_receives_pushes_and_schedules(self):
        self.assertRefused(self.job('push', 'refs/heads/topic'), 'only refs/heads/main')
        self.assertRefused(self.job('schedule', 'refs/heads/topic'), 'only refs/heads/main')
        payload = {'repository': {'full_name': REPOSITORY}, 'ref': 'refs/heads/topic'}
        self.assertRefused(self.job(payload=payload), 'push payload')

    def test_only_the_named_workflow_at_the_ref_being_run(self):
        self.assertRefused(self.job(GITHUB_WORKFLOW_REF=REPOSITORY + '/.github/workflows/other.yml@refs/heads/main'),
                           'workflow')
        self.assertRefused(self.job(GITHUB_WORKFLOW_REF=REPOSITORY + '/' + WORKFLOW + '@refs/heads/topic'),
                           'workflow')
        self.assertRefused(self.job(GITHUB_WORKFLOW_REF=None), 'workflow')

    def test_manual_runs_need_an_allowed_actor_who_also_triggered_them(self):
        self.assertRefused(self.job('workflow_dispatch', GITHUB_ACTOR='someone'), 'only JanHaan')
        self.assertRefused(self.job('workflow_dispatch', GITHUB_TRIGGERING_ACTOR='github-actions[bot]'),
                           'only JanHaan')
        payload = {'repository': {'full_name': REPOSITORY}, 'sender': {'login': 'someone'}}
        self.assertRefused(self.job('workflow_dispatch', payload=payload), 'only JanHaan')
        self.assertRefused(self.job('workflow_dispatch', 'refs/tags/v1'), 'only a branch')

    def test_an_unreadable_payload_is_refused(self):
        env = self.job()
        Path(env['GITHUB_EVENT_PATH']).write_text('not json')
        self.assertRefused(env, 'cannot read the event payload')
        env.pop('GITHUB_EVENT_PATH')
        self.assertRefused(env, 'cannot read the event payload')
        self.assertRefused(self.job(payload=[]), 'not an object')

    def test_a_payload_the_rules_cannot_read_is_refused_and_not_a_traceback(self):
        payload = {'repository': 'JanHaan/Landin', 'ref': 'refs/heads/main'}
        self.assertRefused(self.job(payload=payload), 'could not be judged')

    def test_a_job_the_log_cannot_record_is_refused(self):
        stderr = io.StringIO()
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(stderr):
            status = hook.main(ARGS + ['--log', str(self.root / 'absent' / 'hook.log')], self.job())
        self.assertEqual(status, 1)
        self.assertIn('cannot write the log', stderr.getvalue())
        self.assertEqual(self.processes.killed, [(self.processes.pids[1], signal.SIGKILL)])

    def test_the_worker_is_recognised_under_the_names_it_is_started_by(self):
        for chain in ((('bash', 'bash'), ('dotnet', 'dotnet')),          # dotnet Runner.Worker.dll
                      (('sh', 'sh'), ('.Runner.Worker-', '.Runner.Worker-wrapped')),
                      (('Runner.Worker', 'Runner.Worker'),)):
            with tempfile.TemporaryDirectory() as name:
                processes = Processes(self, Path(name), chain)
                if chain[-1][0] == 'dotnet':
                    (processes.proc / str(processes.pids[-1]) / 'cmdline').write_bytes(
                        b'/usr/bin/dotnet\0/opt/runner/bin/Runner.Worker.dll\0spawnclient\0')
                self.assertEqual(hook.worker(), processes.pids[-1], chain)
        with tempfile.TemporaryDirectory() as name:
            Processes(self, Path(name), (('bash', 'bash'), ('sshd', 'sshd')))
            self.assertIsNone(hook.worker())

    def test_without_a_worker_the_refusal_says_that_only_its_status_refuses(self):
        processes = Processes(self, self.root / 'by-hand', (('bash', 'bash'),))
        stderr = io.StringIO()
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(stderr):
            status = hook.main(ARGS + ['--log', str(self.log)], self.job('pull_request'))
        self.assertEqual(status, 1)
        self.assertIn('only its exit status', stderr.getvalue())
        self.assertEqual(processes.killed, [])
        self.assertIsNone(json.loads(self.log.read_text().splitlines()[-1])['worker'])

    def test_a_refusal_removes_the_actions_the_runner_downloaded_for_the_job(self):
        work = self.root / '_work'
        (work / '_actions' / 'someone' / 'action' / 'v1').mkdir(parents=True)
        (work / '_actions' / 'someone' / 'action' / 'v1' / 'index.js').write_text('')
        (work / 'Landin').mkdir()
        env = self.job('pull_request', RUNNER_WORKSPACE=str(work / 'Landin'))
        self.assertRefused(env, 'never reaches the rig')
        self.assertFalse((work / '_actions').exists())
        self.assertTrue(json.loads(self.log.read_text().splitlines()[-1])['actions_removed'])
        (work / '_actions' / 'actions' / 'checkout').mkdir(parents=True)
        self.assertAccepted(self.job(RUNNER_WORKSPACE=str(work / 'Landin')))
        self.assertTrue((work / '_actions' / 'actions' / 'checkout').exists())

    def test_a_step_that_would_run_after_a_failed_hook_does_not_run(self):
        """The refusal against real processes, not the table above.

        The stand-in worker does what a runner that goes on after a failed
        pre-job step does: it runs the hook, ignores that it failed, and
        runs the next step.  The hook runs in its own process, whose nearest
        ancestor of the worker's name is the stand-in.
        """
        if not Path('/proc/self/stat').exists():
            self.skipTest('no /proc: the hook is for the Linux rig')
        marker = self.root / 'step-ran'
        runner = self.root / 'Runner.Worker'
        runner.write_text('#!/bin/sh\n"$@"\necho "hook status $?"\n: > "$MARKER"\n')
        runner.chmod(runner.stat().st_mode | stat.S_IXUSR)
        # As the runner does, the hook is a script that a shell runs.
        script = '%s %s %s --log %s; exit $?' % (
            sys.executable, ROOT / 'environments/rig-runner/hook.py', ' '.join(ARGS), self.log)

        def run(env):
            return subprocess.run(
                [str(runner), '/bin/sh', '-c', script], text=True,
                env=dict(env, MARKER=str(marker), PATH=os.environ['PATH']),
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)

        result = run(self.job('pull_request', 'refs/pull/7/merge'))
        self.assertEqual(result.returncode, -signal.SIGKILL, result.stdout + result.stderr)
        self.assertFalse(marker.exists())
        self.assertNotIn('hook status', result.stdout)
        self.assertIn('never reaches the rig', result.stderr)
        # An accepted job's worker goes on to its steps.
        result = run(self.job())
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('hook status 0', result.stdout)
        self.assertTrue(marker.exists())


class Completed(unittest.TestCase):
    def test_removes_only_a_workspace_inside_the_runner_work_directory(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            work = root / 'work' / 'Landin'
            workspace = work / 'Landin'
            (workspace / 'environments').mkdir(parents=True)
            (workspace / 'flake.nix').write_text('')
            outside = root / 'outside'
            outside.mkdir()
            (outside / 'kept').write_text('')
            log = root / 'hook.log'
            env = dict(GITHUB_WORKSPACE=str(outside), RUNNER_WORKSPACE=str(work))
            self.assertEqual(hook.main(['completed', '--log', str(log)], env), 0)
            self.assertTrue((outside / 'kept').exists())
            env = dict(GITHUB_WORKSPACE=str(work), RUNNER_WORKSPACE=str(work))
            self.assertEqual(hook.main(['completed', '--log', str(log)], env), 0)
            self.assertTrue(workspace.exists())
            env = dict(GITHUB_WORKSPACE=str(workspace), RUNNER_WORKSPACE=str(work))
            self.assertEqual(hook.main(['completed', '--log', str(log)], env), 0)
            self.assertEqual(list(workspace.iterdir()), [])
            self.assertEqual(json.loads(log.read_text().splitlines()[-1])['removed'],
                             ['environments', 'flake.nix'])
            self.assertEqual(hook.main(['completed'], {}), 0)

    def test_never_fails_a_job_and_logs_only_what_is_gone(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            work = root / 'work' / 'Landin'
            workspace = work / 'Landin'
            # A directory a build step left unwritable is still removed.
            (workspace / 'stuck' / 'inner').mkdir(parents=True)
            (workspace / 'stuck' / 'inner' / 'file').write_text('')
            (workspace / 'stuck' / 'inner').chmod(0o500)
            (workspace / 'stuck').chmod(0o500)
            (workspace / 'file').write_text('')
            workspace.chmod(0o500)
            log = root / 'hook.log'
            env = dict(GITHUB_WORKSPACE=str(workspace), RUNNER_WORKSPACE=str(work))
            self.assertEqual(hook.main(['completed', '--log', str(log)], env), 0)
            entry = json.loads(log.read_text().splitlines()[-1])
            self.assertEqual((entry['removed'], entry['kept']), (['file', 'stuck'], []))
            self.assertEqual(list(workspace.iterdir()), [])
            # What cannot be removed is reported as kept, never as removed.
            (workspace / 'held').write_text('')
            real = hook.remove
            self.addCleanup(lambda: setattr(hook, 'remove', real))
            hook.remove = lambda path: False
            stderr = io.StringIO()
            with contextlib.redirect_stderr(stderr):
                self.assertEqual(hook.main(['completed', '--log', str(log)], env), 0)
            hook.remove = real
            entry = json.loads(log.read_text().splitlines()[-1])
            self.assertEqual((entry['removed'], entry['kept']), ([], ['held']))
            self.assertIn('held', stderr.getvalue())
            # A log that cannot be written does not fail a finished job.
            stderr = io.StringIO()
            with contextlib.redirect_stderr(stderr):
                self.assertEqual(hook.main(['completed', '--log', str(root / 'absent' / 'log')],
                                           env), 0)
            self.assertIn('cannot write', stderr.getvalue())


if __name__ == '__main__':
    unittest.main()
