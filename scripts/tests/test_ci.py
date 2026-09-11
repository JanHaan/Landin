#!/usr/bin/env python3
"""Failure-path tests for committed acceptance and guarded publication.

Temporary Git remotes and fake native processes; never invokes a publisher.
"""
import copy
import io
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts/ci"))
import common
import records
import approval
import controller
import job


class ArchiveTests(unittest.TestCase):
    def archive(self, entries):
        out = io.BytesIO()
        with tarfile.open(fileobj=out, mode="w:gz") as archive:
            for name, kind, payload in entries:
                entry = tarfile.TarInfo(name)
                entry.mode = 0o755 if kind == "executable" else 0o644
                if kind == "link":
                    entry.type = tarfile.SYMTYPE
                    entry.linkname = payload
                elif kind == "fifo":
                    entry.type = tarfile.FIFOTYPE
                elif kind == "hardlink":
                    entry.type = tarfile.LNKTYPE
                    entry.linkname = payload
                else:
                    entry.size = len(payload)
                archive.addfile(entry, io.BytesIO(payload) if isinstance(payload, bytes) else None)
        return out.getvalue()

    def test_filename_bytes_modes_and_safe_symlink(self):
        name = "quote' back\\slash\nunicode-é.ldn"
        data = self.archive([(name, "executable", b"bytes"), ("AGENTS.md", "file", b"rules"),
                             ("CLAUDE.md", "link", "AGENTS.md")])
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "source"
            rows = common.archive_inventory(data, root)
            self.assertEqual(rows, common.working_inventory(root))
            self.assertEqual((root / "CLAUDE.md").read_bytes(), b"rules")
            self.assertTrue((root / name).stat().st_mode & 0o111)

    def test_non_utf8_archive_inventory(self):
        name = os.fsdecode(b"nonutf-\xff.ldn")
        data = self.archive([(name, "file", b"bytes")])
        rows = common.archive_inventory(data)
        self.assertEqual(common.decoded_name(rows[0]["name"]), name)
        if sys.platform.startswith("linux"):
            with tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp) / "source"
                self.assertEqual(common.archive_inventory(data, root), common.working_inventory(root))

    def test_reject_unsafe_paths_before_extracting(self):
        for name in ("../escape", "/absolute", "a/../../escape", "a//b", "a/./b", ".git/config",
                     ".acceptance/request.json", "compiler/ada/build/injected", "x/__pycache__/cache"):
            with self.subTest(name=name), tempfile.TemporaryDirectory() as tmp:
                destination = Path(tmp) / "source"
                with self.assertRaises(common.Invalid):
                    common.archive_inventory(self.archive([(name, "file", b"bad")]), destination)
                self.assertFalse(destination.exists())

    def test_duplicate_and_special_files(self):
        for entries in ([('x', 'file', b'1'), ('x', 'file', b'2')],
                        [('x', 'fifo', '')], [('x', 'hardlink', 'target')]):
            with self.subTest(entries=entries), self.assertRaises(common.Invalid):
                common.archive_inventory(self.archive(entries))

    def test_symlink_escape_cycle_and_parent(self):
        for entries in ([('x', 'link', '../outside')], [('x', 'link', '/outside')],
                        [('x', 'link', 'y'), ('y', 'link', 'x')],
                        [('x', 'link', 'safe'), ('x/child', 'file', b'bad')],
                        [('x', 'link', 'y/../../outside'), ('y', 'link', 'safe')],
                        [('x', 'link', '.acceptance/record.json')]):
            with self.subTest(entries=entries), self.assertRaises(common.Invalid):
                common.archive_inventory(self.archive(entries))

    def test_duplicate_json_and_nonfinite(self):
        for data in (b'{"a":1,"a":2}', b'{"a":NaN}', b'{"a":Infinity}'):
            with self.assertRaises(common.Invalid):
                common.decode(data)

    def test_atomic_new_record_never_replaces(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'record.json'
            common.write_new(path, {'first': True})
            with self.assertRaises(FileExistsError):
                common.write_new(path, {'second': True})
            self.assertEqual(common.read_json(path), {'first': True})


class GitFixture(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="landin-ci-test-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / "repo"
        self.root.mkdir()
        common.git(self.root, "init", "-b", "main")
        # Only disposable fixture repositories use this isolated global
        # config. The invoking user's config and repository identity stay intact.
        config = Path(self.tmp.name) / "gitconfig"
        config.write_text("[user]\nname = CI fixture\nemail = fixture@example.invalid\n")
        self.environment = patch.dict(os.environ, {"GIT_CONFIG_GLOBAL": str(config), "GIT_CONFIG_NOSYSTEM": "1"})
        self.environment.start()
        self.addCleanup(self.environment.stop)
        (self.root / 'scripts/ci').mkdir(parents=True)
        shutil.copy2(ROOT / 'scripts/ci/policy.json', self.root / 'scripts/ci/policy.json')
        (self.root / 'AGENTS.md').write_text('rules\n')
        (self.root / 'CLAUDE.md').symlink_to('AGENTS.md')
        (self.root / 'source.txt').write_text('first\n')
        (self.root / 'environments').mkdir()
        shutil.copy2(ROOT / 'environments/pins.sh', self.root / 'environments/pins.sh')
        common.git(self.root, 'add', 'scripts/ci/policy.json', 'AGENTS.md', 'CLAUDE.md', 'source.txt', 'environments/pins.sh')
        common.git(self.root, 'commit', '-m', 'Initial fixture')
        self.commit = common.git(self.root, 'rev-parse', 'HEAD').decode().strip()
        self.archive, self.source = common.commit_source(self.root, self.commit)
        self.request = {'schema': 1, 'run_id': 'test-run', **self.source}
        self.remote = Path(self.tmp.name) / 'remote.git'
        common.git(self.root, 'init', '--bare', str(self.remote))
        common.git(self.root, 'push', str(self.remote), 'HEAD:refs/heads/main')

    def native_environment(self):
        import re
        pins = (self.root / "environments/pins.sh").read_text()
        gnat = re.search(r"^LANDIN_GNAT_VERSION=(.+)$", pins, re.M)[1]
        gpr = re.search(r"^LANDIN_GPRBUILD_VERSION=(.+)$", pins, re.M)[1]
        env = {"HOME": "/home/landin", "LANDIN_GNAT_HOME": "/opt/gnat-" + gnat,
               "LANDIN_GPRBUILD_HOME": "/opt/gprbuild-" + gpr, "LANG": "C.UTF-8", "LC_ALL": "C.UTF-8",
               "TZ": "UTC", "PYTHONDONTWRITEBYTECODE": "1", "LANDIN_BUILD_INCREMENTAL": "no",
               "LANDIN_BUILD_TAG": "native-ci", "CLANG": "clang-19"}
        env["PATH"] = env["LANDIN_GNAT_HOME"] + "/bin:" + env["LANDIN_GPRBUILD_HOME"] + "/bin:/usr/local/bin:/usr/bin:/bin"
        tools = {name: {"path": "/usr/bin/" + name, "sha256": "1" * 64, "version": name + " fixture"}
                 for name in records.NATIVE_TOOLS}
        tools["gnatls"]["version"] = "GNATLS " + gnat.rsplit("-", 1)[0]
        tools["gprbuild"]["version"] = "GPRBUILD " + gpr.rsplit("-", 1)[0]
        tools["clang-19"]["version"] = "Debian clang version 19.1.7"
        return {"execution_environment": env, "platform": "Linux-x86_64", "kernel": "fixture kernel",
                "hostname": "fixture", "os_release": "ID=debian", "boot_id": "12345678-1234-1234-1234-123456789abc",
                "packages": "".join(name + "=fixture-version\n" for name in sorted(records.NATIVE_PACKAGES)),
                "binaries": tools, "slot_runner_sha256": "2" * 64,
                "pins_sha256": common.file_hash(self.root / "environments/pins.sh")}

    def bundle(self):
        root = Path(self.tmp.name) / 'bundle'
        root.mkdir()
        environment = self.native_environment()
        common.write_new(root / 'request.json', self.request)
        common.write_new(root / 'environment.json', environment)
        (root / 'source.tar.gz').write_bytes(self.archive)
        completed = {'schema': 1, 'request_sha256': common.identity(self.request),
                     'environment_sha256': common.identity(environment), 'jobs': {}}
        for task in self.request['policy']['jobs']:
            record = {'schema': 1, 'job': task['id'], 'request_sha256': common.identity(self.request),
                      'environment_sha256': common.identity(environment),
                      'source_before': self.source['source_sha256'], 'source_after': self.source['source_sha256'],
                      'policy_sha256': self.source['policy_sha256'], 'status': 'passed',
                      'started': '2026-09-11T00:00:00+00:00', 'finished': '2026-09-11T00:01:00+00:00',
                      'duration': 60, 'steps': [], 'files': [], 'fonts': 'unavailable'}
            for index, argv in enumerate(records.commands_for(self.request, task)):
                log = root / 'attempts' / task['id'] / 'one' / f'step-{index:02d}.log'
                log.parent.mkdir(parents=True, exist_ok=True)
                log.write_text('passed\n')
                record['steps'].append({'argv': argv, 'environment': dict(environment['execution_environment'], LANDIN_BUILD_MODE=task['mode']),
                                       'started': record['started'], 'finished': record['finished'], 'duration': 1,
                                       'exit': 0, 'log': log.relative_to(root).as_posix()})
                record['files'].append(job.evidence_entry(root, log))
            path = root / 'jobs' / (task['id'] + '.json')
            common.write_new(path, record)
            completed['jobs'][task['id']] = {'path': path.relative_to(root).as_posix(), 'sha256': common.file_hash(path)}
        common.write_new(root / 'record.json', completed)
        return root

    def tag(self, annotation=None, target=None):
        annotation = annotation or records.approval_for(self.bundle())
        common.git(self.root, 'tag', '-a', approval.tag_name(self.commit), target or self.commit,
                   '-F', '-', input=common.canonical(annotation))


class GitTests(GitFixture):
    def test_archive_is_committed_bytes_after_edit(self):
        (self.root / 'source.txt').write_text('later edit')
        archive, source = common.commit_source(self.root, self.commit)
        self.assertEqual((archive, source), (self.archive, self.source))
        with self.assertRaises(common.Invalid):
            common.clean_checkout(self.root)

    def test_archive_configuration_cannot_change_identity(self):
        with patch.dict(os.environ, {"GIT_CONFIG_COUNT": "2", "GIT_CONFIG_KEY_0": "tar.umask",
                                     "GIT_CONFIG_VALUE_0": "0077", "GIT_CONFIG_KEY_1": "tar.tar.gz.command",
                                     "GIT_CONFIG_VALUE_1": "printf substituted-compressor"}):
            self.assertEqual(common.commit_source(self.root, self.commit), (self.archive, self.source))

    def test_hidden_index_flags_cannot_authorize_changed_bytes(self):
        self.tag()
        common.git(self.root, "push", str(self.remote), "refs/tags/" + approval.tag_name(self.commit))
        for flag, unset in (("--assume-unchanged", "--no-assume-unchanged"), ("--skip-worktree", "--no-skip-worktree")):
            common.git(self.root, "update-index", flag, "source.txt")
            (self.root / "source.txt").write_text("unapproved bytes")
            self.assertEqual(common.git(self.root, "status", "--porcelain"), b"")
            with self.assertRaisesRegex(common.Invalid, "checkout bytes differ"):
                approval.guard(self.root, str(self.remote))
            (self.root / "source.txt").write_text("first\n")
            common.git(self.root, "update-index", unset, "source.txt")

    def test_incomplete_native_provenance_cannot_approve(self):
        root = self.bundle()
        original = self.native_environment()
        variants = []
        for field in original:
            changed = copy.deepcopy(original); changed.pop(field); variants.append(changed)
        for field, value in (("platform", "Darwin-arm64"), ("pins_sha256", "0" * 64),
                             ("binaries", {}), ("packages", "git=only\n")):
            changed = copy.deepcopy(original); changed[field] = value; variants.append(changed)
        changed = copy.deepcopy(original); changed["execution_environment"]["LANDIN_QEMU"] = "qemu"; variants.append(changed)
        changed = copy.deepcopy(original); changed["execution_environment"]["PATH"] += ":/unapproved"; variants.append(changed)
        for environment in variants:
            with self.assertRaises(common.Invalid):
                records.validate_environment(environment, self.request, root)

    def test_export_ignore_cannot_change_tested_tree(self):
        (self.root / '.gitattributes').write_text('source.txt export-ignore\n')
        common.git(self.root, 'add', '.gitattributes')
        common.git(self.root, 'commit', '-m', 'Attribute fixture')
        with self.assertRaisesRegex(common.Invalid, 'differs from committed tree'):
            common.commit_source(self.root, 'HEAD')

    def test_policy_omission_mode_and_developer_selector(self):
        policy = self.source['policy']
        mutations = []
        changed = copy.deepcopy(policy); changed['jobs'].pop(); mutations.append(changed)
        changed = copy.deepcopy(policy); changed['jobs'][0]['mode'] = 'release'; mutations.append(changed)
        changed = copy.deepcopy(policy); changed['jobs'][0]['commands'][2].append('--case=fast'); mutations.append(changed)
        changed = copy.deepcopy(policy); changed['jobs'][0]['commands'].pop(0); mutations.append(changed)
        for value in mutations:
            with self.assertRaises(common.Invalid):
                common.validate_policy(value)

    def test_bundle_and_approval_roundtrip(self):
        root = self.bundle()
        annotation = records.approval_for(root)
        records.validate_approval(annotation, self.source)
        controller.approve(self.root, root)
        self.assertEqual(approval.read_approval(self.root, self.commit), annotation)
        with self.assertRaises(subprocess.CalledProcessError):
            controller.approve(self.root, root)

    def test_bundle_log_corruption(self):
        root = self.bundle()
        next(root.glob('attempts/*/*/step-*.log')).write_text('corrupt')
        with self.assertRaisesRegex(common.Invalid, 'hash mismatch'):
            records.validate_bundle(root)

    def test_bundle_archive_corruption(self):
        root = self.bundle()
        (root / 'source.tar.gz').write_bytes(b'corrupt')
        with self.assertRaises(common.Invalid):
            records.validate_bundle(root)

    def test_partial_mixed_failed_duplicate_jobs(self):
        root = self.bundle()
        task = self.request['policy']['jobs'][0]
        original = common.read_json(root / 'jobs' / (task['id'] + '.json'))
        environment = common.read_json(root / 'environment.json')
        mutations = []
        for key, value in (('status','failed'), ('request_sha256','0'*64),
                           ('source_after','0'*64), ('policy_sha256','0'*64),
                           ('environment_sha256','0'*64)):
            changed = copy.deepcopy(original); changed[key] = value; mutations.append(changed)
        changed = copy.deepcopy(original); changed['steps'].pop(); mutations.append(changed)
        changed = copy.deepcopy(original); changed['steps'].append(changed['steps'][0]); mutations.append(changed)
        changed = copy.deepcopy(original); changed['steps'][0]['exit'] = 1; mutations.append(changed)
        changed = copy.deepcopy(original); changed['steps'][0]['environment']['LANDIN_QEMU'] = 'qemu'; mutations.append(changed)
        for value in mutations:
            with self.assertRaises(common.Invalid):
                records.validate_job(value, self.request, task, environment, root)
        (root / 'jobs' / (task['id'] + '.json')).unlink()
        with self.assertRaises(common.Invalid):
            records.validate_bundle(root)

    def test_lightweight_and_malformed_tags(self):
        name = approval.tag_name(self.commit)
        common.git(self.root, 'tag', name, self.commit)
        with self.assertRaises(common.Invalid):
            approval.read_approval(self.root, self.commit)
        common.git(self.root, 'tag', '-d', name)
        common.git(self.root, 'tag', '-a', name, '-m', 'not JSON')
        with self.assertRaises(common.Invalid):
            approval.read_approval(self.root, self.commit)

    def test_wrong_target_or_missing_job_approval(self):
        annotation = records.approval_for(self.bundle())
        for field in ('commit', 'tree', 'source_sha256', 'policy_sha256', 'request_sha256'):
            changed = copy.deepcopy(annotation); changed[field] = '0' * len(changed[field])
            with self.assertRaises(common.Invalid):
                records.validate_approval(changed, self.source)
        annotation['jobs'].pop('documents')
        with self.assertRaises(common.Invalid):
            records.validate_approval(annotation, self.source)

    def test_guard_accepts_canonical_approval(self):
        self.tag()
        common.git(self.root, 'push', str(self.remote), 'refs/tags/' + approval.tag_name(self.commit))
        self.assertEqual(approval.guard(self.root, str(self.remote)), self.commit)

    def test_guard_dirty_checkout(self):
        self.tag()
        (self.root / 'untracked').write_text('dirty')
        with self.assertRaisesRegex(common.Invalid, 'dirty'):
            approval.guard(self.root, str(self.remote))

    def test_guard_missing_canonical_tag(self):
        self.tag()
        with self.assertRaisesRegex(common.Invalid, 'canonical ref missing'):
            approval.guard(self.root, str(self.remote))

    def test_guard_stale_checkout(self):
        self.tag()
        (self.root / 'source.txt').write_text('new')
        common.git(self.root, 'add', 'source.txt'); common.git(self.root, 'commit', '-m', 'New main')
        common.git(self.root, 'push', str(self.remote), 'HEAD:refs/heads/main')
        common.git(self.root, 'checkout', '--detach', self.commit)
        with self.assertRaisesRegex(common.Invalid, 'not current canonical main'):
            approval.guard(self.root, str(self.remote))

    def test_default_promotion_uses_canonical_ssh(self):
        self.tag()
        original = controller.git
        calls = []
        def canonical_ssh(root, *args, **kwargs):
            calls.append(args)
            translated = tuple(str(self.remote) if word == controller.PROMOTION_REMOTE else word for word in args)
            return original(root, *translated, **kwargs)
        with patch.object(controller, "git", side_effect=canonical_ssh), patch.object(
                controller, "remote_ref", return_value=self.commit):
            controller.promote(self.root, self.commit)
        pushes = [args for args in calls if args[:2] == ("push", "--atomic")]
        self.assertEqual(len(pushes), 1)
        self.assertEqual(pushes[0][2], "git@git.sr.ht:~sinnfrei/landin")
        self.assertEqual(approval.CANONICAL, "https://git.sr.ht/~sinnfrei/landin")

    def test_atomic_promotion(self):
        self.tag()
        controller.promote(self.root, self.commit, str(self.remote))
        self.assertEqual(approval.remote_ref(self.root, str(self.remote), 'refs/heads/main'), self.commit)
        self.assertEqual(approval.guard(self.root, str(self.remote)), self.commit)

    def test_tag_collision_refuses_promotion(self):
        self.tag()
        common.git(self.root, 'push', str(self.remote), 'refs/tags/' + approval.tag_name(self.commit))
        with self.assertRaisesRegex(common.Invalid, 'already exists'):
            controller.promote(self.root, self.commit, str(self.remote))

    def test_non_fast_forward_refuses_without_pushing_tag(self):
        self.tag()
        (self.root / 'source.txt').write_text('remote newer')
        common.git(self.root, 'add', 'source.txt'); common.git(self.root, 'commit', '-m', 'Remote update')
        common.git(self.root, 'push', str(self.remote), 'HEAD:refs/heads/main')
        with self.assertRaises(subprocess.CalledProcessError):
            controller.promote(self.root, self.commit, str(self.remote))
        self.assertFalse(common.git(self.root, 'ls-remote', '--refs', str(self.remote), 'refs/tags/*'))

    def test_atomic_push_race_rejects_both_updates(self):
        self.tag()
        original = controller.git
        def racing_git(root, *args, **kwargs):
            if args[:2] == ('push', '--atomic'):
                (self.root / 'source.txt').write_text('racing update')
                original(root, 'add', 'source.txt'); original(root, 'commit', '-m', 'Race update')
                original(root, 'push', str(self.remote), 'HEAD:refs/heads/main')
            return original(root, *args, **kwargs)
        with patch.object(controller, 'git', side_effect=racing_git):
            with self.assertRaises(subprocess.CalledProcessError):
                controller.promote(self.root, self.commit, str(self.remote))
        self.assertFalse(common.git(self.root, 'ls-remote', '--refs', str(self.remote), 'refs/tags/*'))

    def test_invalid_remote_slot_and_run_names(self):
        for name in ('../bad', '-option', 'host;true', 'x y'):
            with self.assertRaises(common.Invalid):
                controller.ssh_command(name, ['true'])
            with self.assertRaises(common.Invalid):
                controller.validate_run_id(name)

    def test_ssh_argv_preserves_shell_metacharacters(self):
        import shlex
        words = ['landin-ci', 'run', 'slot', '--', 'printf', "quote' back\\slash $(literal)"]
        argv = controller.ssh_command('host', words)
        self.assertEqual(shlex.split(argv[-1]), words)


class RunnerControlTests(GitFixture):
    def native_setup(self):
        self.work = Path(self.tmp.name) / "work"
        self.root_patch = patch.object(job, "WORK", self.work)
        self.root_patch.start(); self.addCleanup(self.root_patch.stop)
        self.provenance = self.native_environment()
        self.provenance_patch = patch.object(job, "provenance", return_value=self.provenance)
        self.provenance_patch.start(); self.addCleanup(self.provenance_patch.stop)
        archive = Path(self.tmp.name) / "source.tar.gz"; archive.write_bytes(self.archive)
        job.initialize(self.request, archive)
        self.run = self.work / self.request["run_id"]
        self.native_source = self.run / "source"
        return archive

    def fake_run(self, name, code=0):
        class Process:
            def __init__(self, *args, **kwargs):
                self.stdout = io.BytesIO(b"fixture command result\n")
                self.returncode = code
                if not kwargs.get("pass_fds"):
                    raise AssertionError("child must retain job lock after runner interruption")
            def wait(self):
                return self.returncode
        with patch.object(job.subprocess, "Popen", Process), patch.object(job.subprocess, "run", return_value=
                subprocess.CompletedProcess([], 1, stdout=b"fonts unavailable\n")):
            return job.run_job(self.run, name, self.native_source)

    def test_initialized_request_collision_and_environment_change(self):
        archive = self.native_setup()
        job.initialize(self.request, archive)
        changed = copy.deepcopy(self.request); changed["commit"] = "0" * 40
        with self.assertRaisesRegex(common.Invalid, "collision"):
            job.initialize(changed, archive)
        with patch.object(job, "provenance", return_value={"changed": True}):
            with self.assertRaisesRegex(common.Invalid, "environment changed"):
                job.initialize(self.request, archive)

    def test_partial_completion_refused(self):
        self.native_setup()
        with self.assertRaisesRegex(common.Invalid, "missing required job"):
            job.finalize(self.run)
        self.assertFalse((self.run / "record.json").exists())

    def test_passed_job_reuses_verified_evidence(self):
        self.native_setup()
        self.assertEqual(self.fake_run("suite-debug"), 0)
        record = (self.run / "jobs/suite-debug.json").read_bytes()
        with patch.object(job.subprocess, "Popen", side_effect=AssertionError("must not rerun")):
            self.assertEqual(job.run_job(self.run, "suite-debug", self.native_source), 0)
        self.assertEqual((self.run / "jobs/suite-debug.json").read_bytes(), record)
        next(self.run.glob("attempts/suite-debug/*/step-00.log")).write_text("corrupt")
        with self.assertRaisesRegex(common.Invalid, "hash mismatch"):
            job.run_job(self.run, "suite-debug", self.native_source)

    def test_lost_live_output_does_not_fail_the_command(self):
        self.native_setup()
        class Disconnected:
            @property
            def buffer(self):
                return self
            def write(self, *args):
                raise BrokenPipeError("lost SSH output")
            def flush(self):
                raise BrokenPipeError("lost SSH output")
        with patch.object(job.sys, "stdout", Disconnected()):
            self.assertEqual(self.fake_run("suite-debug"), 0)
        record = common.read_json(self.run / "jobs/suite-debug.json")
        self.assertEqual(record["status"], "passed")
        self.assertTrue(all((self.run / step["log"]).read_bytes() for step in record["steps"]))
        self.assertEqual(job.run_job(self.run, "suite-debug", self.native_source), 0)

    def test_failed_job_cannot_resume(self):
        self.native_setup()
        self.assertEqual(self.fake_run("suite-debug", 9), 9)
        self.assertFalse((self.run / "jobs/suite-debug.json").exists())
        with self.assertRaisesRegex(common.Invalid, "failed job requires"):
            self.fake_run("suite-debug")

    def test_interrupted_attempt_resumes_without_replacing_history(self):
        self.native_setup()
        interrupted = self.run / "attempts/suite-debug/interrupted/started.json"
        common.write_new(interrupted, {"started": "before interruption"})
        self.assertEqual(self.fake_run("suite-debug"), 0)
        self.assertEqual(common.read_json(interrupted), {"started": "before interruption"})

    def test_changed_slot_source_refused(self):
        self.native_setup()
        (self.native_source / "source.txt").write_text("changed")
        with self.assertRaisesRegex(common.Invalid, "slot source mismatch"):
            self.fake_run("suite-debug")

    def test_corrupt_archive_never_creates_completion_marker(self):
        self.native_setup()
        for task in self.request["policy"]["jobs"]:
            self.assertEqual(self.fake_run(task["id"]), 0)
        path = self.run / "source.tar.gz"
        changed = bytearray(path.read_bytes()); changed[4] ^= 1
        path.write_bytes(changed)
        self.assertEqual(common.archive_inventory(changed), self.request["inventory"])
        with self.assertRaisesRegex(common.Invalid, "archive mismatch"):
            job.finalize(self.run)
        self.assertFalse((self.run / "record.json").exists())

    def test_complete_record_and_export_survive_slot_deletion(self):
        self.native_setup()
        for task in self.request["policy"]["jobs"]:
            self.assertEqual(self.fake_run(task["id"]), 0)
        job.finalize(self.run)
        before = (self.run / "record.json").read_bytes()
        job.finalize(self.run)
        self.assertEqual((self.run / "record.json").read_bytes(), before)
        output = io.BytesIO()
        class Sink:
            buffer = output
        with patch.object(job.sys, "stdout", Sink()):
            job.export(self.run)
        exported = Path(self.tmp.name) / "exported"
        common.archive_inventory(output.getvalue(), exported)
        shutil.rmtree(self.native_source)
        records.validate_bundle(exported)


class PublicationWiringTests(unittest.TestCase):
    def test_guard_failure_precedes_render_fonts_and_upload(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "scripts").mkdir(); (root / "bin").mkdir()
            for name in ("env.sh", "site.sh"):
                shutil.copy2(ROOT / "scripts" / name, root / "scripts" / name)
            python = root / "bin/python3"
            python.write_text("#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$PROBE_LOG\"\nexit 91\n")
            python.chmod(0o755)
            probe = root / "probe.log"
            result = subprocess.run(["sh", str(root / "scripts/site.sh"), "--publish"],
                                    env={**os.environ, "PATH": str(root / "bin") + ":" + os.environ["PATH"],
                                         "PROBE_LOG": str(probe)}, capture_output=True)
            self.assertEqual(result.returncode, 91)
            lines = probe.read_text().splitlines()
            self.assertEqual(len(lines), 1)
            self.assertIn("scripts/ci/approval.py", lines[0])
            self.assertFalse((root / "docs/site/site").exists())

    def test_manifest_and_guard_invariants_reject_regression(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("landin_document_checker", ROOT / "check.py")
        checker = importlib.util.module_from_spec(spec); spec.loader.exec_module(checker)
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for name in ("scripts/ci/common.py", "scripts/ci/policy.json", "scripts/site.sh",
                         ".build.yml", ".builds/github-mirror.yml"):
                target = root / name; target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(ROOT / name, target)
            with patch.object(checker, "ROOT", str(root)):
                self.assertEqual(checker.check_native_ci(True), [])
                pages = root / ".build.yml"
                original = pages.read_text()
                pages.write_text(original.replace("python3 scripts/ci/approval.py", "true"))
                self.assertTrue(checker.check_native_ci(True))
                pages.write_text(original)
                (root / ".builds/nix.yml").write_text("tasks: []\n")
                self.assertTrue(checker.check_native_ci(True))


@unittest.skipUnless(sys.platform.startswith('linux'), 'flock runner tests require Linux')
class RunnerTests(unittest.TestCase):
    def test_busy_lock(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'lock'
            with job.lock(path):
                with self.assertRaisesRegex(common.Invalid, 'BUSY'):
                    with job.lock(path):
                        self.fail('second acquisition succeeded')
            with job.lock(path):
                pass


if __name__ == '__main__':
    unittest.main()
