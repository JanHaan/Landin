#!/usr/bin/env python3
"""scripts/container_image.py against stand-in `docker` and
`skopeo`.

The stand-ins record every call and answer as the real commands do, as far
as the script asks: a build's context is listed, a run answers the checks
with what a working or a broken image prints, and `skopeo copy` writes a
layout whose images name their platforms.  What the engines and the registry do
is not shown here; what reaches an image's context, what a check accepts
and what is pushed where, is.  The release workflow runs the real thing.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/container_image.py"
HANG = 300
FIRST = ROOT / "compiler/tests/fixtures/runtime/first-program/output.txt"

STAND_IN = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
tool = Path(sys.argv[0]).name
argv = sys.argv[1:]
with open(os.environ["FAKE_CALLS"], "a") as calls:
    calls.write(json.dumps([tool] + argv) + "\n")
said = os.environ.get("FAKE_SAY", "")
if tool == "docker" and argv[0] == "build":
    print(json.dumps(sorted(p.name for p in Path(argv[-1]).iterdir())),
          file=sys.stderr)
elif tool == "docker" and argv[0] == "run":
    work = Path(argv[argv.index("--volume") + 1].split(":")[0]) \
        if "--volume" in argv else None
    if argv[-2:] == ["refine", "version"]:
        print("refine 0.2.11")
        print("library: " + os.environ.get("FAKE_LIBRARY", "/usr/local/lib/landin"))
    elif "compile" in argv:
        (work / argv[argv.index("-o") + 1]).write_text("program")
    elif argv[-1] == "./main" or argv[-2:] == ["run", "main.ldn"]:
        sys.stdout.write(Path(os.environ["FAKE_OUTPUT"]).read_text())
elif tool == "skopeo" and argv[0] == "copy":
    import hashlib
    source, destination = argv[-2], argv[-1]
    def put(layout, data):
        digest = "sha256:" + hashlib.sha256(data).hexdigest()
        path = layout / "blobs" / "sha256" / digest[7:]
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return digest
    def name(layout, ref, descriptor):
        layout.mkdir(parents=True, exist_ok=True)
        index = layout / "index.json"
        top = json.loads(index.read_text()) if index.exists() else {
            "schemaVersion": 2, "manifests": []}
        descriptor = dict(descriptor, annotations={
            "org.opencontainers.image.ref.name": ref})
        top["manifests"].append(descriptor)
        index.write_text(json.dumps(top))
    if source.startswith("docker-archive:"):
        arch = Path(source).stem.split("-")[-1]
        arch = os.environ.get("FAKE_WRONG_" + arch.upper(), arch)
        _, layout, ref = destination.split(":")
        layout = Path(layout)
        config = put(layout, json.dumps({"os": "linux", "architecture": arch}).encode())
        manifest = json.dumps({"config": {"digest": config}}).encode()
        name(layout, ref, {"mediaType": "application/vnd.oci.image.manifest.v1+json",
                           "digest": put(layout, manifest), "size": len(manifest)})
    else:
        assert "--all" in argv
        Path(argv[argv.index("--digestfile") + 1]).write_text("sha256:" + "ab" * 32)
elif tool == "skopeo":
    held = os.environ.get("FAKE_HELD", "").split()
    if any(argv[-1].endswith("/" + name) for name in held):
        print("{}")
    else:
        print(os.environ.get("FAKE_SKOPEO", "manifest unknown"), file=sys.stderr)
        sys.exit(1)
'''


class Stand(unittest.TestCase):
    def setUp(self):
        self.scratch = Path(tempfile.mkdtemp(prefix="landin-image-test-"))
        bin_dir = self.scratch / "bin"
        bin_dir.mkdir()
        for tool in ("docker", "skopeo"):
            (bin_dir / tool).write_text(STAND_IN)
            (bin_dir / tool).chmod(0o755)
        self.calls = self.scratch / "calls"
        self.env = dict(os.environ, PATH="%s%s%s" % (bin_dir, os.pathsep,
                                                     os.environ["PATH"]),
                        FAKE_CALLS=str(self.calls), FAKE_OUTPUT=str(FIRST),
                        GITHUB_REPOSITORY="701-dev/Landin")

    def tearDown(self):
        shutil.rmtree(self.scratch)

    def run_script(self, *argv, **extra):
        done = subprocess.run([sys.executable, str(SCRIPT), *argv],
                              text=True, capture_output=True, timeout=HANG,
                              env=dict(self.env, **extra))
        calls = ([json.loads(line) for line in self.calls.read_text().splitlines()]
                 if self.calls.exists() else [])
        return done, calls


class Build(Stand):
    def test_the_user_image_s_context_is_the_archive_and_the_recipe(self):
        archive = self.scratch / "landin.tar.gz"
        archive.write_bytes(b"archive")
        done, calls = self.run_script("build", "user", str(archive), "--tag", "t",
                                      "--version", "0.2.11", "--revision", "abc")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn('["Containerfile", "landin.tar.gz"]', done.stderr)
        build = calls[0]
        self.assertEqual(build[:2], ["docker", "build"])
        for label in ("org.opencontainers.image.source=https://github.com/701-dev/Landin",
                      "org.opencontainers.image.version=0.2.11",
                      "org.opencontainers.image.revision=abc"):
            self.assertIn(label, build)

    def test_the_contributor_image_is_built_from_environments(self):
        done, calls = self.run_script("build", "contributor", "--tag", "t")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(calls[0][-1], str(ROOT / "environments"))
        self.assertIn("pins.sh", done.stderr)

    def test_a_build_without_its_input_is_refused(self):
        done, calls = self.run_script("build", "user", "--tag", "t")
        self.assertEqual(done.returncode, 1)
        self.assertIn("needs the release archive", done.stderr)
        done, calls = self.run_script("build", "contributor", "x.tar.gz",
                                      "--tag", "t")
        self.assertEqual(done.returncode, 1)
        self.assertEqual(calls, [])


class Check(Stand):
    def test_an_image_that_answers_as_the_readme_says_passes(self):
        done, calls = self.run_script("check", "user", "t")
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertEqual([call[-1] for call in calls],
                         ["version", "main", "./main", "main.ldn"])
        for call in calls:
            self.assertIn("--user", call)
            self.assertTrue(call[call.index("--volume") + 1].endswith(":/work"))

    def test_a_library_elsewhere_or_another_output_fails(self):
        done, _ = self.run_script("check", "user", "t", FAKE_LIBRARY="/opt/lib")
        self.assertEqual(done.returncode, 1)
        self.assertIn("did not name /usr/local/lib/landin", done.stderr)
        other = self.scratch / "other.txt"
        other.write_text("Goodbye\n")
        done, _ = self.run_script("check", "user", "t", FAKE_OUTPUT=str(other))
        self.assertEqual(done.returncode, 1)
        self.assertIn("refine run printed", done.stderr)


class Publish(Stand):
    def images(self):
        directory = self.scratch / "images"
        directory.mkdir()
        for kind in ("user", "contributor"):
            for arch in ("amd64", "arm64"):
                (directory / ("%s-%s.tar" % (kind, arch))).write_bytes(b"i")
        return directory

    def pushes(self, calls):
        return [call[-1] for call in calls
                if call[:2] == ["skopeo", "copy"] and "--all" in call]

    def test_a_rehearsal_pushes_into_a_layout_and_asks_no_registry(self):
        layout = self.scratch / "layout"
        done, calls = self.run_script("publish", "0.2.11", str(self.images()),
                                      "--layout", str(layout))
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(self.pushes(calls),
                         ["oci:%s/published:landin-0.2.11" % layout,
                          "oci:%s/published:landin-contributor-0.2.11" % layout])
        self.assertFalse([call for call in calls if call[1] == "inspect"])
        #  The index names both platforms, each image's own.
        top = json.loads((layout / "index.json").read_text())
        index = [one for one in top["manifests"]
                 if one["annotations"]["org.opencontainers.image.ref.name"]
                 == "landin-0.2.11"][0]
        listed = json.loads((layout / "blobs/sha256" / index["digest"][7:]).read_text())
        self.assertEqual([one["platform"] for one in listed["manifests"]],
                         [{"os": "linux", "architecture": "amd64"},
                          {"os": "linux", "architecture": "arm64"}])

    def test_a_published_version_is_never_replaced(self):
        outputs = self.scratch / "outputs"
        done, calls = self.run_script("publish", "0.2.11", str(self.images()),
                                      "--outputs", str(outputs),
                                      FAKE_HELD="landin:0.2.11")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("ghcr.io/701-dev/landin:0.2.11 is already published",
                      done.stdout)
        self.assertEqual(self.pushes(calls),
                         ["docker://ghcr.io/701-dev/landin-contributor:0.2.11"])
        self.assertEqual(outputs.read_text().splitlines(), [
            "contributor-digest=sha256:" + "ab" * 32,
            "contributor-name=ghcr.io/701-dev/landin-contributor"])

    def test_an_archive_of_another_platform_is_refused(self):
        done, calls = self.run_script("publish", "0.2.11", str(self.images()),
                                      "--layout", str(self.scratch / "layout"),
                                      FAKE_WRONG_ARM64="amd64")
        self.assertEqual(done.returncode, 1)
        self.assertIn("user-arm64.tar holds an image for linux/amd64, not "
                      "linux/arm64", done.stderr)
        self.assertEqual(self.pushes(calls), [])

    def test_a_registry_that_cannot_answer_stops_the_publication(self):
        done, calls = self.run_script("publish", "0.2.11", str(self.images()),
                                      FAKE_SKOPEO="unauthorized")
        self.assertEqual(done.returncode, 1)
        self.assertIn("could not say whether it holds", done.stderr)
        self.assertEqual(self.pushes(calls), [])

    def test_a_missing_platform_archive_is_refused(self):
        directory = self.images()
        (directory / "user-arm64.tar").unlink()
        done, calls = self.run_script("publish", "0.2.11", str(directory),
                                      "--layout", str(self.scratch / "layout"))
        self.assertEqual(done.returncode, 1)
        self.assertIn("user-arm64.tar is missing", done.stderr)


if __name__ == "__main__":
    unittest.main()
