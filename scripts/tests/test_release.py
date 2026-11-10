#!/usr/bin/env python3
"""scripts/release.py against a throwaway repository and a stand-in `gh`.

The stand-in keeps one release in a JSON file and does what the real
command does with it, as far as release.py asks: view, create, upload,
delete-asset and edit.  It can be told to fail an upload part-way, which is
the case the draft exists for.  What the real `gh` and GitHub do is not
shown here; the order of the requests, and what a reader of the releases
page could see between them, is.
"""
import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import release  # noqa: E402

GH = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
state_path = Path(os.environ["FAKE_GH_STATE"])
state = json.loads(state_path.read_text())
state["calls"].append(sys.argv[1:])
assert sys.argv[1] == "release", sys.argv
verb, tag = sys.argv[2], sys.argv[3]
found = state["release"]


def done(status=0, said="", error=""):
    #  What a reader of the releases page could see after this request.
    public = [] if found is None or found["draft"] else sorted(found["assets"])
    state["seen"].append(public)
    state_path.write_text(json.dumps(state))
    sys.stdout.write(said)
    sys.stderr.write(error)
    sys.exit(status)


if verb == "view":
    if found is None or found["tag"] != tag:
        done(1, error="release not found\n")
    done(0, json.dumps(dict(isDraft=found["draft"],
                            assets=[dict(name=n) for n in found["assets"]])))
if verb == "create":
    assert found is None and "--verify-tag" in sys.argv
    found = state["release"] = dict(tag=tag, draft="--draft" in sys.argv, assets=[])
    done()
if verb == "upload":
    for index, path in enumerate(sys.argv[4:]):
        if state["fail_upload_after"] is not None and index >= state["fail_upload_after"]:
            state["fail_upload_after"] = None
            done(1, error="HTTP 502\n")
        name = os.path.basename(path)
        assert name not in found["assets"], "an asset of this name exists"
        found["assets"].append(name)
    done()
if verb == "delete-asset":
    found["assets"].remove(sys.argv[4])
    done()
if verb == "edit":
    assert "--draft=false" in sys.argv
    found["draft"] = False
    done()
raise SystemExit("the stand-in gh does not know " + verb)
'''


class Publish(unittest.TestCase):
    NAMES = ["landin-0.0.0-aarch64-linux.tar.gz", "landin-0.0.0-aarch64-linux.tar.gz.sha256",
             "landin-0.0.0-x86_64-linux.tar.gz", "landin-0.0.0-x86_64-linux.tar.gz.sha256"]

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        tools = self.root / "bin"
        tools.mkdir()
        (tools / "gh").write_text(GH.replace("#!/usr/bin/env python3", "#!" + sys.executable))
        (tools / "gh").chmod(0o755)
        self.assets = self.root / "release-assets"
        self.assets.mkdir()
        for name in self.NAMES:
            (self.assets / name).write_text(name)
        self.state = self.root / "state.json"
        self.write(dict(release=None, calls=[], seen=[], fail_upload_after=None))
        saved = {key: os.environ.get(key) for key in ("PATH", "FAKE_GH_STATE")}
        os.environ["PATH"] = "%s%s%s" % (tools, os.pathsep, os.environ["PATH"])
        os.environ["FAKE_GH_STATE"] = str(self.state)
        self.addCleanup(lambda: [os.environ.pop(key) if value is None
                                 else os.environ.__setitem__(key, value)
                                 for key, value in saved.items()])

    def write(self, state):
        self.state.write_text(json.dumps(state))

    def read(self):
        return json.loads(self.state.read_text())

    def run_publish(self):
        said = io.StringIO()
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(said):
            status = release.main(["release.py", "publish", "v0.0.0", str(self.assets)])
        return status, said.getvalue()

    def test_a_release_is_public_only_once_it_holds_every_file(self):
        status, said = self.run_publish()
        self.assertEqual(status, 0, said)
        state = self.read()
        self.assertEqual(state["release"], dict(tag="v0.0.0", draft=False, assets=self.NAMES))
        # At no request was a part of the release public.
        self.assertEqual({tuple(seen) for seen in state["seen"]}, {(), tuple(self.NAMES)})
        self.assertEqual([call[1] for call in state["calls"]],
                         ["view", "create", "upload", "view", "edit"])

    def test_an_upload_that_stops_leaves_a_draft_the_next_run_completes(self):
        state = self.read()
        state["fail_upload_after"] = 2
        self.write(state)
        status, said = self.run_publish()
        self.assertEqual(status, 1)
        self.assertIn("gh release upload v0.0.0 failed", said)
        state = self.read()
        self.assertEqual((state["release"]["draft"], state["release"]["assets"]),
                         (True, self.NAMES[:2]))
        self.assertEqual({tuple(seen) for seen in state["seen"]}, {()})
        # The same command again: the draft's files are not this build's.
        status, said = self.run_publish()
        self.assertEqual(status, 0, said)
        state = self.read()
        self.assertEqual(state["release"], dict(tag="v0.0.0", draft=False, assets=self.NAMES))
        self.assertEqual({tuple(seen) for seen in state["seen"]}, {(), tuple(self.NAMES)})

    def test_a_published_release_never_has_a_file_replaced(self):
        state = self.read()
        state["release"] = dict(tag="v0.0.0", draft=False, assets=[self.NAMES[0]])
        self.write(state)
        status, said = self.run_publish()
        self.assertEqual(status, 1)
        self.assertIn("already publishes %s; refusing to replace it" % self.NAMES[0], said)
        self.assertEqual(self.read()["release"]["assets"], [self.NAMES[0]])
        self.assertEqual([call[1] for call in self.read()["calls"]], ["view"])

    def test_a_published_release_without_these_files_receives_them(self):
        state = self.read()
        state["release"] = dict(tag="v0.0.0", draft=False, assets=["notes.txt"])
        self.write(state)
        status, said = self.run_publish()
        self.assertEqual(status, 0, said)
        self.assertEqual(self.read()["release"]["assets"], ["notes.txt"] + self.NAMES)

    def test_nothing_to_publish_is_refused(self):
        for path in self.assets.iterdir():
            path.unlink()
        status, said = self.run_publish()
        self.assertEqual(status, 1)
        self.assertIn("holds no file to publish", said)
        self.assertEqual(self.read()["calls"], [])


class Gated(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.origin = self.root / "origin"
        self.git(self.root, "init", "-q", "-b", "main", str(self.origin))
        self.commit(self.origin, "one")
        self.clone = self.root / "clone"
        self.git(self.root, "clone", "-q", str(self.origin), str(self.clone))
        self.asked = []

    def git(self, cwd, *arguments):
        environment = dict(os.environ, GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_SYSTEM=os.devnull,
                           GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@example.org",
                           GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@example.org")
        return subprocess.run(["git", *arguments], cwd=cwd, check=True, text=True, env=environment,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout.strip()

    def commit(self, where, text):
        (where / "file").write_text(text)
        self.git(where, "add", "file")
        self.git(where, "commit", "-q", "-m", text)
        return self.git(where, "rev-parse", "HEAD")

    def runs(self, **changes):
        head = self.git(self.clone, "rev-parse", "HEAD")
        run = dict(id=7, head_sha=head, event="push", head_branch="main",
                   status="completed", conclusion="success")
        run.update(changes)

        def api(path):
            self.asked.append(path)
            return dict(workflow_runs=[run])
        return api

    def reason(self, api):
        with contextlib.redirect_stdout(io.StringIO()):
            return release.gated(api, cwd=self.clone)

    def test_a_commit_on_main_whose_own_gate_passed_may_be_released(self):
        self.assertIsNone(self.reason(self.runs()))
        head = self.git(self.clone, "rev-parse", "HEAD")
        self.assertEqual(self.asked, [
            "actions/workflows/gate.yml/runs?head_sha=%s&event=push&branch=main"
            "&status=success&per_page=20" % head])
        # An older commit of main is released the same way.
        self.commit(self.origin, "two")
        self.git(self.clone, "fetch", "-q", "origin")
        self.assertIsNone(self.reason(self.runs()))

    def test_a_commit_that_is_not_on_main_is_refused_before_github_is_asked(self):
        self.git(self.clone, "checkout", "-q", "-b", "topic")
        self.commit(self.clone, "unmerged")
        self.assertIn("is not on main", self.reason(self.runs()))
        self.assertEqual(self.asked, [])

    def test_a_commit_whose_gate_did_not_pass_on_main_is_refused(self):
        for changes in (dict(conclusion="failure"), dict(head_branch="topic"),
                        dict(event="workflow_dispatch"), dict(head_sha="0" * 40),
                        dict(status="in_progress", conclusion=None)):
            with self.subTest(changes=changes):
                self.assertIn("whose own gate passed", self.reason(self.runs(**changes)))
        self.assertIn("whose own gate passed", self.reason(lambda path: dict(workflow_runs=[])))
        self.assertIn("could not be read", self.reason(lambda path: dict(message="Not Found")))

    def test_a_checkout_without_main_is_refused(self):
        self.git(self.clone, "update-ref", "-d", "refs/remotes/origin/main")
        self.assertIn("has no origin/main", self.reason(self.runs()))


if __name__ == "__main__":
    unittest.main()
