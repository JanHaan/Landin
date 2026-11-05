#!/usr/bin/env python3
"""The rig runner's job hooks, against simulated job environments."""
import contextlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'environments/rig-runner'))
import hook  # noqa: E402

REPOSITORY = 'JanHaan/Landin'
WORKFLOW = '.github/workflows/gate.yml'
ARGS = ['started', '--repository', REPOSITORY, '--workflow', WORKFLOW, '--actor', 'JanHaan']


class Started(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.log = self.root / 'hook.log'

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
        status, message = self.verdict(env)
        self.assertEqual(status, 0, message)

    def assertRefused(self, env, words):
        status, message = self.verdict(env)
        self.assertEqual(status, 1)
        self.assertIn(words, message)

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


if __name__ == '__main__':
    unittest.main()
