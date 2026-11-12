"""scripts/actionlint.py runs the pinned actionlint over every workflow, and
refuses, saying how to get it, an actionlint that is missing or another
version."""

import hashlib
import io
import os
import sys
import tarfile
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import actionlint  # noqa: E402

PINNED = actionlint.pins()["LANDIN_ACTIONLINT_VERSION"]


def fake(directory, version, status=0):
    """An actionlint answering VERSION that records its arguments."""
    program = Path(directory) / "actionlint"
    program.write_text(
        "#!/bin/sh\n"
        'if [ "$1" = -version ]; then echo %s; echo built; exit 0; fi\n'
        'printf "%%s\\n" "$@" > "$0.arguments"\n'
        "exit %d\n" % (version, status))
    program.chmod(0o755)
    return program


def run(argv, path):
    out, err = io.StringIO(), io.StringIO()
    with patch.dict(os.environ, {"PATH": path}), redirect_stdout(out), \
            redirect_stderr(err):
        status = actionlint.main(argv)
    return status, out.getvalue(), err.getvalue()


class Located(unittest.TestCase):
    def test_a_missing_actionlint_says_how_to_get_it(self):
        with tempfile.TemporaryDirectory() as empty:
            status, _, said = run([], empty)
        self.assertEqual(status, 2)
        self.assertIn("no actionlint on PATH", said)
        self.assertIn("`nix develop` provides the pinned " + PINNED, said)
        self.assertIn("python3 scripts/actionlint.py --install DIR", said)

    def test_another_version_is_refused_rather_than_run(self):
        with tempfile.TemporaryDirectory() as directory:
            program = fake(directory, "1.6.0")
            status, _, said = run([], directory + os.pathsep + os.environ["PATH"])
            self.assertFalse(Path(str(program) + ".arguments").exists())
        self.assertEqual(status, 2)
        self.assertIn("is version 1.6.0 and environments/pins.sh pins " + PINNED, said)

    def test_every_workflow_is_linted_with_the_configuration(self):
        with tempfile.TemporaryDirectory() as directory:
            program = fake(directory, PINNED)
            status, said, _ = run([], directory + os.pathsep + os.environ["PATH"])
            arguments = Path(str(program) + ".arguments").read_text().splitlines()
        self.assertEqual(status, 0)
        workflows = sorted(path.relative_to(ROOT).as_posix()
                           for path in (ROOT / ".github/workflows").iterdir()
                           if path.suffix in (".yml", ".yaml"))
        self.assertGreaterEqual(len(workflows), 5)
        self.assertEqual(arguments[:2], ["-config-file", str(ROOT / ".github/actionlint.yaml")])
        #  The host's shellcheck and pyflakes never decide the verdict.
        self.assertIn("-shellcheck=", arguments)
        self.assertIn("-pyflakes=", arguments)
        self.assertEqual(sorted(a for a in arguments if a.startswith(".github/")), workflows)
        self.assertIn("%d workflows clean" % len(workflows), said)

    def test_a_finding_fails_the_run(self):
        with tempfile.TemporaryDirectory() as directory:
            fake(directory, PINNED, status=1)
            status, said, _ = run([], directory + os.pathsep + os.environ["PATH"])
        self.assertEqual(status, 1)
        self.assertNotIn("clean", said)

    def test_the_configuration_names_the_rig(self):
        text = (ROOT / ".github/actionlint.yaml").read_text(encoding="utf-8")
        self.assertIn("self-hosted-runner:", text)
        self.assertIn("- landin-rig\n", text)


class Install(unittest.TestCase):
    """--install fetches the pinned release and refuses other bytes."""

    def archive(self, directory, body):
        path = Path(directory) / "release.tar.gz"
        with tarfile.open(path, "w:gz") as tar:
            data = body.encode()
            member = tarfile.TarInfo("actionlint")
            member.size, member.mode = len(data), 0o755
            tar.addfile(member, io.BytesIO(data))
        return path.read_bytes()

    def values(self, archive):
        values = dict(actionlint.pins())
        name = actionlint.ASSETS[("Linux", "x86_64")][0]
        values["LANDIN_ACTIONLINT_SHA256_" + name] = hashlib.sha256(archive).hexdigest()
        return values

    def opener(self, archive, seen):
        def opened(url, timeout):
            seen.append(url)
            return io.BytesIO(archive)
        return opened

    def test_the_pinned_archive_is_unpacked(self):
        with tempfile.TemporaryDirectory() as directory, \
                patch("actionlint.platform.system", return_value="Linux"), \
                patch("actionlint.platform.machine", return_value="x86_64"):
            archive = self.archive(directory, "#!/bin/sh\necho %s\n" % PINNED)
            seen = []
            binary = actionlint.install(Path(directory) / "into", self.values(archive),
                                        opener=self.opener(archive, seen))
            self.assertEqual(binary, Path(directory) / "into/actionlint")
            self.assertTrue(os.access(binary, os.X_OK))
            self.assertEqual(sorted(p.name for p in binary.parent.iterdir()), ["actionlint"])
        values = actionlint.pins()
        self.assertEqual(seen, ["%s/v%s/actionlint_%s_linux_amd64.tar.gz" % (
            values["LANDIN_ACTIONLINT_RELEASES"], PINNED, PINNED)])

    def test_other_bytes_are_refused_before_anything_is_unpacked(self):
        with tempfile.TemporaryDirectory() as directory, \
                patch("actionlint.platform.system", return_value="Linux"), \
                patch("actionlint.platform.machine", return_value="x86_64"):
            archive = self.archive(directory, "#!/bin/sh\necho %s\n" % PINNED)
            values = self.values(archive)
            other = self.archive(directory, "#!/bin/sh\necho other\n")
            with self.assertRaisesRegex(actionlint.Refusal, "not the .* environments/pins.sh holds"):
                actionlint.install(Path(directory) / "into", values,
                                   opener=self.opener(other, []))
            self.assertEqual(list((Path(directory) / "into").iterdir()), [])

    def test_a_host_with_no_pinned_release_is_refused(self):
        with self.assertRaisesRegex(actionlint.Refusal, "no pinned actionlint for Linux riscv64"):
            actionlint.asset(actionlint.pins(), "Linux", "riscv64")

    def test_every_pinned_checksum_is_an_asset(self):
        #  The pins hold a checksum for each asset this fetches, and no other.
        values = actionlint.pins()
        held = {name[len("LANDIN_ACTIONLINT_SHA256_"):] for name in values
                if name.startswith("LANDIN_ACTIONLINT_SHA256_")}
        self.assertEqual(held, {suffix for suffix, _ in actionlint.ASSETS.values()})


if __name__ == "__main__":
    unittest.main()
