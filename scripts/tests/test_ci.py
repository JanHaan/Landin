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
import publish
import resources


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
                     ".acceptance/request.json", "compiler/ada/build/injected",
                     "compiler/ada/.build-locks/all", "x/__pycache__/cache"):
            with self.subTest(name=name), tempfile.TemporaryDirectory() as tmp:
                destination = Path(tmp) / "source"
                with self.assertRaises(common.Invalid):
                    common.archive_inventory(self.archive([(name, "file", b"bad")]), destination)
                self.assertFalse(destination.exists())

    def test_generated_locks_do_not_change_source_identity(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "compiler/ada/src/example.adb"
            source.parent.mkdir(parents=True)
            source.write_text("source")
            expected = common.working_inventory(root)
            locks = root / "compiler/ada/.build-locks"
            locks.mkdir()
            (locks / "all").touch()
            (locks / "native-ci-debug").touch()
            (locks / "native-ci-debug.cgpr").write_text("generated configuration")
            self.assertEqual(common.working_inventory(root), expected)
            source.write_text("changed")
            self.assertNotEqual(common.working_inventory(root), expected)

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
                "resource_limits": {"cgroup": "/acceptance", "memory_bytes": 100 * 1024 ** 3,
                                    "swap_bytes": 0},
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
        for key, value in (("memory_bytes", 128 * 1024 ** 3), ("swap_bytes", 1),
                           ("memory_bytes", "max"), ("cgroup", "/../elsewhere")):
            changed = copy.deepcopy(original); changed["resource_limits"][key] = value; variants.append(changed)
        for environment in variants:
            with self.assertRaises(common.Invalid):
                records.validate_environment(environment, self.request, root)

    def test_export_ignore_cannot_change_tested_tree(self):
        (self.root / '.gitattributes').write_text('source.txt export-ignore\n')
        common.git(self.root, 'add', '.gitattributes')
        common.git(self.root, 'commit', '-m', 'Attribute fixture')
        with self.assertRaisesRegex(common.Invalid, 'differs from committed tree'):
            common.commit_source(self.root, 'HEAD')

    def test_user_git_helpers_belong_to_the_persistent_work_volume(self):
        root = self.bundle()
        environment = self.native_environment()
        env = environment["execution_environment"]
        tools = Path(env["HOME"]) / "work/.ci-tools"
        env["GIT_EXEC_PATH"] = str(tools / "usr/lib/git-core")
        env["GIT_TEMPLATE_DIR"] = str(tools / "usr/share/git-core/templates")
        env["PATH"] = env["PATH"].replace("/usr/local/bin:", str(tools / "usr/bin") + ":/usr/local/bin:")
        records.validate_environment(environment, self.request, root)
        for key in ("PATH", "GIT_EXEC_PATH", "GIT_TEMPLATE_DIR"):
            env[key] = env[key].replace("work/.ci-tools", ".local/share/landin-ci-tools")
        with self.assertRaisesRegex(common.Invalid, "unexpected Git helpers"):
            records.validate_environment(environment, self.request, root)

    def test_policy_omission_mode_and_developer_selector(self):
        policy = self.source['policy']
        mutations = []
        changed = copy.deepcopy(policy); changed['jobs'].pop(); mutations.append(changed)
        changed = copy.deepcopy(policy); changed['jobs'][0]['mode'] = 'release'; mutations.append(changed)
        changed = copy.deepcopy(policy); changed['jobs'][0]['commands'][2].append('--case=fast'); mutations.append(changed)
        changed = copy.deepcopy(policy); changed['jobs'][0]['commands'].pop(0); mutations.append(changed)
        changed = copy.deepcopy(policy); changed['limits']['parallel_jobs'] = 9; mutations.append(changed)
        changed = copy.deepcopy(policy); changed['limits']['memory_bytes'] *= 2; mutations.append(changed)
        changed = copy.deepcopy(policy); changed['limits']['swap_bytes'] = 1; mutations.append(changed)
        changed = copy.deepcopy(policy); changed['limits']['step_seconds'] = 0; mutations.append(changed)
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


class AcceptanceSchedulingTests(GitFixture):
    def test_parallel_jobs_cancel_peers_after_failure(self):
        import threading
        barrier = threading.Barrier(8, timeout=5)
        cancelled = threading.Event()
        calls = []
        def slot(*args):
            name = args[-1]
            calls.append(name)
            barrier.wait()
            if name == "suite-debug":
                return 9
            self.assertTrue(cancelled.wait(5), "peers must receive cancellation")
            return 125
        def remote(*args):
            self.assertEqual(args[2], "cancel")
            cancelled.set()
        with patch.object(controller, "initialize"), patch.object(controller, "slot_run", side_effect=slot), \
                patch.object(controller, "remote_job", side_effect=remote) as remote_call, \
                patch.object(controller, "export") as export:
            with self.assertRaisesRegex(common.Invalid, "incomplete/failed"):
                controller.accept(self.root, "HEAD", "fixture", Path(self.tmp.name) / "state")
        self.assertEqual(set(calls), {item["id"] for item in common.required_jobs()})
        remote_call.assert_called_once()
        export.assert_not_called()

    def test_all_parallel_jobs_must_pass_before_finalizing(self):
        with patch.object(controller, "initialize"), patch.object(controller, "slot_run", return_value=0) as slot, \
                patch.object(controller, "remote_job") as remote, patch.object(controller, "export") as export:
            controller.accept(self.root, "HEAD", "fixture", Path(self.tmp.name) / "state")
        self.assertEqual(slot.call_count, 8)
        self.assertEqual(remote.call_args.args[2], "finalize")
        export.assert_called_once()


class ResourceControlTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="landin-resource-test-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.proc = self.root / "membership"
        self.proc.write_text("0::/acceptance\n")
        self.group = self.root / "acceptance"
        self.group.mkdir()
        (self.group / "memory.max").write_text(str(100 * 1024 ** 3))
        (self.group / "memory.swap.max").write_text("0")
        self.policy = common.read_json(ROOT / "scripts/ci/policy.json")

    def inspect(self):
        return resources.containment(self.policy, self.proc, self.root)

    def test_finite_cgroup_limits_and_namespace_root(self):
        expected = {"cgroup": "/acceptance", "memory_bytes": 100 * 1024 ** 3, "swap_bytes": 0}
        self.assertEqual(self.inspect(), expected)
        self.proc.write_text("0::/\n")
        self.assertEqual(resources.containment(self.policy, self.proc, self.group),
                         dict(expected, cgroup="/"))

    def test_unlimited_missing_and_excessive_limits_refuse(self):
        for name, value in (("memory.max", "max"), ("memory.max", str(128 * 1024 ** 3)),
                            ("memory.max", "0"), ("memory.max", "-1"),
                            ("memory.swap.max", "max"), ("memory.swap.max", "1")):
            with self.subTest(name=name, value=value):
                path = self.group / name
                original = path.read_text()
                path.write_text(value)
                with self.assertRaises(common.Invalid):
                    self.inspect()
                path.write_text(original)
        (self.group / "memory.max").unlink()
        with self.assertRaisesRegex(common.Invalid, "cannot verify"):
            self.inspect()

    def test_unsupported_or_escaping_membership_refuses(self):
        for membership in ("1:memory:/acceptance\n", "0::/../acceptance\n", "0::/acceptance\n1:cpu:/\n"):
            self.proc.write_text(membership)
            with self.assertRaises(common.Invalid):
                self.inspect()

    def test_oom_accounting_reads_kills_without_reclaim_events(self):
        (self.group / "memory.events").write_text("max 200\noom 3\noom_kill 2\noom_group_kill 1\n")
        self.assertEqual(resources.oom_events(self.inspect(), self.root),
                         {"oom_kill": 2, "oom_group_kill": 1})

    def execute(self, script, seconds=2, live=lambda chunk: None, cancelled=lambda: False):
        output = io.BytesIO()
        code = resources.command([sys.executable, "-c", script], cwd=self.root,
                                 env=os.environ.copy(), pass_fds=(), output=output,
                                 live=live, seconds=seconds, cancelled=cancelled)
        return code, output.getvalue()

    def test_small_command_streams_output_and_preserves_exit(self):
        observed = []
        code, output = self.execute("import sys; print('result'); sys.exit(7)", live=observed.append)
        self.assertEqual(code, 7)
        self.assertEqual(output, b"result\n")
        self.assertEqual(b"".join(observed), output)

    def test_silent_command_times_out_even_after_closing_output(self):
        code, output = self.execute("import os,time; os.close(1); os.close(2); time.sleep(3)", seconds=0.1)
        self.assertEqual(code, 124)
        self.assertIn(b"timed out", output)

    def test_exited_leader_cannot_leave_a_child_holding_output(self):
        import time
        child = "import time,pathlib; time.sleep(0.6); pathlib.Path('survivor').write_text('alive')"
        script = "import subprocess,sys; subprocess.Popen([sys.executable,'-c'," + repr(child) + "])"
        code, output = self.execute(script, seconds=0.2)
        self.assertEqual(code, 124)
        self.assertIn(b"timed out", output)
        time.sleep(0.7)
        self.assertFalse((self.root / "survivor").exists())

    def test_slow_observational_output_cannot_extend_child_deadline(self):
        import time
        script = ("import time,pathlib; print('ready',flush=True); time.sleep(0.5); "
                  "pathlib.Path('survivor').write_text('alive')")
        code, output = self.execute(script, seconds=0.2, live=lambda chunk: time.sleep(0.7))
        self.assertEqual(code, 124)
        self.assertIn(b"timed out", output)
        self.assertFalse((self.root / "survivor").exists())

    @unittest.skipUnless(sys.platform.startswith('linux'), 'native session inspection requires Linux')
    def test_compiler_style_child_process_group_is_stopped(self):
        import time
        child = "import time,pathlib; time.sleep(0.6); pathlib.Path('survivor').write_text('alive')"
        script = ("import subprocess,sys,time; subprocess.Popen([sys.executable,'-c'," + repr(child)
                  + "],process_group=0); time.sleep(3)")
        code, output = self.execute(script, seconds=0.2)
        self.assertEqual(code, 124)
        self.assertIn(b"timed out", output)
        time.sleep(0.7)
        self.assertFalse((self.root / "survivor").exists())

    def test_cancellation_stops_child_despite_slow_output(self):
        import time
        marker = self.root / "cancelled"
        script = ("import time,pathlib; print('ready',flush=True); time.sleep(0.5); "
                  "pathlib.Path('survivor').write_text('alive')")
        def observe(chunk):
            marker.touch()
            time.sleep(0.7)
        code, output = self.execute(script, live=observe, cancelled=marker.exists)
        self.assertEqual(code, 125)
        self.assertIn(b"cancelled", output)
        self.assertFalse((self.root / "survivor").exists())

    def test_cancelled_run_never_starts_command(self):
        with patch.object(resources.subprocess, "Popen") as popen:
            code, output = self.execute("raise AssertionError", cancelled=lambda: True)
        self.assertEqual(code, 125)
        popen.assert_not_called()

    def test_preflight_refuses_before_any_native_tool_probe(self):
        with patch.object(job.platform, "system", return_value="Linux"), \
                patch.object(job.platform, "machine", return_value="x86_64"), \
                patch.object(job, "containment", side_effect=common.Invalid("uncapped host")), \
                patch.object(job, "capture") as capture:
            with self.assertRaisesRegex(common.Invalid, "uncapped"):
                job.provenance(self.root, self.policy)
        capture.assert_not_called()


class RunnerControlTests(GitFixture):
    def native_setup(self):
        self.work = Path(self.tmp.name) / "work"
        self.root_patch = patch.object(job, "WORK", self.work)
        self.root_patch.start(); self.addCleanup(self.root_patch.stop)
        self.provenance = self.native_environment()
        self.provenance_patch = patch.object(job, "provenance", return_value=self.provenance)
        self.provenance_patch.start(); self.addCleanup(self.provenance_patch.stop)
        self.oom_patch = patch.object(job, "oom_events", return_value={"oom_kill": 0, "oom_group_kill": 0})
        self.oom_patch.start(); self.addCleanup(self.oom_patch.stop)
        archive = Path(self.tmp.name) / "source.tar.gz"; archive.write_bytes(self.archive)
        job.initialize(self.request, archive)
        self.run = self.work / self.request["run_id"]
        self.native_source = self.run / "source"
        return archive

    def fake_run(self, name, code=0):
        def command(*args, **kwargs):
            self.assertEqual(len(kwargs["pass_fds"]), 3, "child must retain host and job locks")
            self.assertEqual(kwargs["seconds"], self.request["policy"]["limits"]["step_seconds"])
            chunk = b"fixture command result\n"
            kwargs["output"].write(chunk)
            kwargs["live"](chunk)
            return code
        with patch.object(job, "command", command), patch.object(job.subprocess, "run", return_value=
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

    def test_oom_cannot_be_hidden_by_successful_command_exit(self):
        self.native_setup()
        with patch.object(job, "oom_events", side_effect=[{"oom_kill": 0}, {"oom_kill": 1}]):
            self.assertEqual(self.fake_run("suite-debug"), 1)
        self.assertFalse((self.run / "jobs/suite-debug.json").exists())

    def test_font_probe_timeout_is_a_retained_failed_attempt(self):
        self.native_setup()
        with patch.object(job.subprocess, "run", side_effect=subprocess.TimeoutExpired("font probe", 30)), \
                patch.object(job, "command") as command:
            self.assertEqual(job.run_job(self.run, "suite-debug", self.native_source), 1)
        command.assert_not_called()
        result = next(self.run.glob("attempts/suite-debug/*/result.json"))
        self.assertEqual(common.read_json(result)["status"], "failed")
        with self.assertRaisesRegex(common.Invalid, "failed job requires"):
            self.fake_run("suite-debug")

    def test_another_run_cannot_overlap_native_execution(self):
        self.native_setup()
        with job.lock(self.work / ".execution.lock"):
            with self.assertRaisesRegex(common.Invalid, "BUSY"):
                self.fake_run("suite-debug")
        self.assertFalse((self.run / "attempts").exists())

    def test_host_slots_bound_concurrency_across_runs(self):
        import contextlib
        self.native_setup()
        limit = self.request["policy"]["limits"]["parallel_jobs"]
        with contextlib.ExitStack() as stack:
            for _ in range(limit):
                stack.enter_context(job.execution_slot(limit))
            with self.assertRaisesRegex(common.Invalid, "capacity exhausted"):
                self.fake_run("suite-debug")
        self.assertEqual(self.fake_run("suite-debug"), 0)

    def test_failure_cancels_unstarted_peer_and_prevents_finalization(self):
        self.native_setup()
        self.assertEqual(self.fake_run("suite-debug", 9), 9)
        self.assertTrue((self.run / "cancelled").exists())
        with self.assertRaisesRegex(common.Invalid, "run cancelled"):
            self.fake_run("suite-release")
        with self.assertRaisesRegex(common.Invalid, "cannot finalize"):
            job.finalize(self.run)

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


class PublicationLockTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="landin-publication-test-")
        self.addCleanup(self.temporary.cleanup)
        base = Path(self.temporary.name)
        self.root, self.remote = base / "source", base / "remote.git"
        self.root.mkdir()
        publish.git(self.root, "init", "-b", "main")
        publish.git(self.root, "config", "user.name", "Publication test")
        publish.git(self.root, "config", "user.email", "test@invalid")
        (self.root / "README").write_text("source")
        publish.git(self.root, "add", "README")
        publish.git(self.root, "commit", "-m", "source")
        self.commit = publish.git(self.root, "rev-parse", "HEAD").decode().strip()
        publish.git(self.root, "init", "--bare", str(self.remote))
        publish.git(self.root, "push", str(self.remote), "main")

    def lock(self):
        return publish.PublicationLock(self.root, self.commit, str(self.remote))

    def test_two_publishers_cannot_hold_the_same_lock(self):
        first, second = self.lock(), self.lock()
        self.assertNotEqual(first.oid, second.oid)
        first.acquire(wait_seconds=0)
        with self.assertRaisesRegex(common.Invalid, "publication busy"):
            second.acquire(wait_seconds=0)
        self.assertEqual(second.current(), first.oid)
        first.release()
        second.acquire(wait_seconds=0)
        second.release()
        self.assertIsNone(first.current())

    def test_an_old_owner_cannot_release_a_replacement_lock(self):
        first, second = self.lock(), self.lock()
        first.acquire(wait_seconds=0)
        publish.git(self.root, "push", "--force-with-lease=" + publish.LOCK_REF + ":" + first.oid,
                    str(self.remote), second.oid + ":" + publish.LOCK_REF)
        with self.assertRaises(subprocess.CalledProcessError):
            first.release()
        self.assertEqual(first.current(), second.oid)
        second.release()

    def test_racing_create_cannot_replace_the_winner(self):
        first, second = self.lock(), self.lock()
        observed = first.current
        initial = True
        def race():
            nonlocal initial
            if initial:
                initial = False
                second.acquire(wait_seconds=0)
                return None
            return observed()
        with patch.object(first, "current", side_effect=race):
            with self.assertRaisesRegex(common.Invalid, "publication busy"):
                first.acquire(wait_seconds=0)
        self.assertEqual(first.current(), second.oid)
        second.release()

    def test_lost_acquisition_response_is_reconciled_by_unique_identity(self):
        owner = self.lock()
        real_git = publish.git
        def lost(root, *args, **kwargs):
            result = real_git(root, *args, **kwargs)
            if args[0] == "push":
                raise subprocess.TimeoutExpired(["git", "push"], 30)
            return result
        with patch.object(publish, "git", side_effect=lost):
            owner.acquire(wait_seconds=0)
        self.assertEqual(owner.current(), owner.oid)
        owner.release()

    def workflow(self, *, approval_results=None, upload_failure=None, render_failure=False):
        events = []
        commit = "a" * 40
        class Lock:
            oid = "b" * 40
            def __init__(self, root, candidate):
                events.append(("lock", candidate))
            def acquire(self):
                events.append("acquire")
            def release(self):
                events.append("release")
        def prepare(root, directory):
            events.append("render")
            self.assertNotEqual(directory.parent, self.root)
            if render_failure:
                raise common.Invalid("render failed")
            archive = directory / "site.tar.gz"
            archive.write_bytes(b"rendered archive")
            return archive
        def upload(argv, **kwargs):
            self.assertEqual(argv[:3], ["hut", "pages", "publish"])
            self.assertEqual(Path(argv[-1]).read_bytes(), b"rendered archive")
            events.append(("upload", argv[4]))
            if argv[4] == upload_failure:
                raise subprocess.TimeoutExpired(argv, 120)
        results = iter(approval_results or [commit] * 3)
        def approved(root):
            result = next(results)
            events.append(("approved", result))
            return result
        with patch.object(publish, "PublicationLock", Lock), \
                patch.object(publish, "approved", side_effect=approved), \
                patch.object(publish, "prepare_archive", side_effect=prepare), \
                patch.object(publish, "run", side_effect=upload):
            try:
                publish.publish(self.root, "first.example", "second.example")
            except (common.Invalid, subprocess.SubprocessError) as error:
                return events, error
        return events, None

    def test_final_guard_and_both_uploads_are_inside_the_lock(self):
        events, error = self.workflow()
        self.assertIsNone(error)
        self.assertEqual([e for e in events if isinstance(e, str)],
                         ["acquire", "render", "release"])
        acquire, release = events.index("acquire"), events.index("release")
        self.assertEqual([e for e in events[acquire + 1:release] if isinstance(e, tuple)],
                         [("approved", "a" * 40), ("approved", "a" * 40),
                          ("upload", "first.example"), ("upload", "second.example")])

    def test_changed_candidate_never_uploads_the_old_archive(self):
        for results in (["a" * 40, "b" * 40], ["a" * 40, "a" * 40, "b" * 40]):
            with self.subTest(results=results):
                events, error = self.workflow(approval_results=results)
                self.assertIsInstance(error, common.Invalid)
                self.assertEqual(events[-1], "release")
                self.assertFalse(any(isinstance(e, tuple) and e[0] == "upload" for e in events))

    def test_uncertain_upload_never_releases_the_lock(self):
        for failed in ("first.example", "second.example"):
            with self.subTest(failed=failed):
                events, error = self.workflow(upload_failure=failed)
                self.assertIsInstance(error, subprocess.TimeoutExpired)
                self.assertNotIn("release", events)

    def test_render_failure_releases_before_any_upload(self):
        events, error = self.workflow(render_failure=True)
        self.assertIsInstance(error, common.Invalid)
        self.assertEqual(events[-1], "release")
        self.assertFalse(any(isinstance(e, tuple) and e[0] == "upload" for e in events))

    def test_archive_is_isolated_and_normalizes_publisher_modes(self):
        def render(argv, **kwargs):
            if "--to" in argv:
                site = Path(argv[argv.index("--to") + 1])
                site.mkdir()
                (site / "index.html").write_text("rendered")
                (site / "index.html").chmod(0o600)
                (site / "fonts").mkdir()
                (site / "fonts/font.woff2").write_bytes(b"font")
        with tempfile.TemporaryDirectory() as temporary, patch.object(publish, "run", side_effect=render):
            archive = publish.prepare_archive(self.root, Path(temporary))
            with tarfile.open(archive) as contents:
                self.assertEqual({m.name: m.mode for m in contents.getmembers()},
                                 {"index.html": 0o644, "fonts": 0o755, "fonts/font.woff2": 0o644})
                self.assertTrue(all(m.uid == m.gid == 0 for m in contents.getmembers()))


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
                         ".build.yml", ".builds/github-mirror.yml",
                         "environments/native-ci/compose.resources.yaml"):
                target = root / name; target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(ROOT / name, target)
            with patch.object(checker, "ROOT", str(root)):
                self.assertEqual(checker.check_native_ci(True), [])
                override = root / "environments/native-ci/compose.resources.yaml"
                limits = override.read_text()
                override.write_text(limits.replace("107374182400", "137438953472"))
                self.assertTrue(checker.check_native_ci(True))
                override.write_text(limits)
                pages = root / ".build.yml"
                original = pages.read_text()
                pages.write_text(original.replace("python3 scripts/ci/approval.py", "true"))
                self.assertTrue(checker.check_native_ci(True))
                pages.write_text(original)
                site = root / "scripts/site.sh"
                script = site.read_text()
                site.write_text(script.replace("exec python3", "python3"))
                self.assertTrue(checker.check_native_ci(True))
                site.write_text(script)
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
