"""scripts/actionlint.py runs the pinned actionlint over every workflow, with
the pinned shellcheck's pass over their `run:` scripts, and refuses, saying
how to get them, an actionlint or a shellcheck that is missing or another
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
SHELLCHECK = actionlint.pins()["LANDIN_SHELLCHECK_VERSION"]


def fake(directory, version, status=0, shellcheck=SHELLCHECK):
    """An actionlint answering VERSION that records its arguments, beside a
    shellcheck answering SHELLCHECK, or none when it is None."""
    program = Path(directory) / "actionlint"
    program.write_text(
        "#!/bin/sh\n"
        'if [ "$1" = -version ]; then echo %s; echo built; exit 0; fi\n'
        'printf "%%s\\n" "$@" > "$0.arguments"\n'
        "exit %d\n" % (version, status))
    program.chmod(0o755)
    if shellcheck is not None:
        checker = Path(directory) / "shellcheck"
        checker.write_text(
            "#!/bin/sh\n"
            'if [ "$1" = --version ]; then\n'
            "  echo 'ShellCheck - shell script analysis tool'\n"
            "  echo 'version: %s'; exit 0\n"
            "fi\n"
            "exit 1\n" % shellcheck)
        checker.chmod(0o755)
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
        self.assertIn("no actionlint or shellcheck on PATH", said)
        self.assertIn("`nix develop` provides the pinned actionlint " + PINNED
                      + " and shellcheck " + SHELLCHECK, said)
        self.assertIn("python3 scripts/actionlint.py --install DIR", said)

    def test_a_missing_shellcheck_is_refused_rather_than_skipped(self):
        #  actionlint would pass over every `run:` script without one.
        with tempfile.TemporaryDirectory() as directory:
            program = fake(directory, PINNED, shellcheck=None)
            status, _, said = run([], directory)
            self.assertFalse(Path(str(program) + ".arguments").exists())
        self.assertEqual(status, 2)
        self.assertIn("no shellcheck on PATH", said)

    def test_another_version_is_refused_rather_than_run(self):
        with tempfile.TemporaryDirectory() as directory:
            program = fake(directory, "1.6.0")
            status, _, said = run([], directory + os.pathsep + os.environ["PATH"])
            self.assertFalse(Path(str(program) + ".arguments").exists())
        self.assertEqual(status, 2)
        self.assertIn("is actionlint version 1.6.0 and environments/pins.sh"
                      " pins " + PINNED, said)

    def test_another_shellcheck_is_refused_rather_than_run(self):
        with tempfile.TemporaryDirectory() as directory:
            program = fake(directory, PINNED, shellcheck="0.9.0")
            status, _, said = run([], directory + os.pathsep + os.environ["PATH"])
            self.assertFalse(Path(str(program) + ".arguments").exists())
        self.assertEqual(status, 2)
        self.assertIn("is shellcheck version 0.9.0 and environments/pins.sh"
                      " pins " + SHELLCHECK, said)

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
        #  The pinned shellcheck, named by its path, checks every `run:`
        #  script, and no host's pyflakes decides the verdict.
        self.assertIn("-shellcheck=" + str(Path(directory) / "shellcheck"),
                      arguments)
        self.assertIn("-pyflakes=", arguments)
        self.assertEqual(sorted(a for a in arguments if a.startswith(".github/")), workflows)
        self.assertIn("with shellcheck %s: %d workflows clean"
                      % (SHELLCHECK, len(workflows)), said)

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

    def test_no_step_runs_python_as_its_shell(self):
        #  The pyflakes pass stays off because it would have nothing to
        #  read: a step that runs Python as its shell needs it pinned too.
        for path in (ROOT / ".github/workflows").iterdir():
            text = path.read_text(encoding="utf-8")
            self.assertNotRegex(text, r"(?m)^\s*shell:\s*python", path.name)


class Install(unittest.TestCase):
    """--install fetches the pinned releases and refuses other bytes."""

    def archive(self, directory, tool, body):
        """A release archive of TOOL holding BODY as its program."""
        pinned, _, member_name, _ = actionlint.TOOLS[tool]
        version = actionlint.pins()["LANDIN_%s_VERSION" % pinned]
        member_name = member_name.format(version=version)
        path = Path(directory) / ("release-%s.tar" % tool)
        with tarfile.open(path, "w:gz" if tool == "actionlint" else "w:xz") as tar:
            readme = tarfile.TarInfo(
                (member_name.rsplit("/", 1)[0] + "/" if "/" in member_name
                 else "") + "README.txt")
            readme.size = 2
            tar.addfile(readme, io.BytesIO(b"hi"))
            data = body.encode()
            member = tarfile.TarInfo(member_name)
            member.size, member.mode = len(data), 0o755
            tar.addfile(member, io.BytesIO(data))
        return path.read_bytes()

    def values(self, archives):
        values = dict(actionlint.pins())
        suffix = actionlint.ASSETS[("Linux", "x86_64")][0]
        for tool, archive in archives.items():
            values["LANDIN_%s_SHA256_%s" % (actionlint.TOOLS[tool][0], suffix)] = (
                hashlib.sha256(archive).hexdigest())
        return values

    def opener(self, archives, seen):
        def opened(url, timeout):
            seen.append(url)
            return io.BytesIO(archives["shellcheck" if "/shellcheck-" in url
                                       else "actionlint"])
        return opened

    def test_the_pinned_archives_are_unpacked(self):
        with tempfile.TemporaryDirectory() as directory, \
                patch("actionlint.platform.system", return_value="Linux"), \
                patch("actionlint.platform.machine", return_value="x86_64"):
            archives = {tool: self.archive(directory, tool, "#!/bin/sh\necho %s\n" % tool)
                        for tool in actionlint.TOOLS}
            seen = []
            binaries = actionlint.install(Path(directory) / "into", self.values(archives),
                                          opener=self.opener(archives, seen))
            into = Path(directory) / "into"
            self.assertEqual(binaries, {"actionlint": into / "actionlint",
                                        "shellcheck": into / "shellcheck"})
            for binary in binaries.values():
                self.assertTrue(os.access(binary, os.X_OK))
            self.assertEqual((into / "shellcheck").read_text(),
                             "#!/bin/sh\necho shellcheck\n")
            self.assertEqual(sorted(p.name for p in into.iterdir()),
                             ["actionlint", "shellcheck"])
        values = actionlint.pins()
        self.assertEqual(seen, [
            "%s/v%s/actionlint_%s_linux_amd64.tar.gz" % (
                values["LANDIN_ACTIONLINT_RELEASES"], PINNED, PINNED),
            "%s/v%s/shellcheck-v%s.linux.x86_64.tar.xz" % (
                values["LANDIN_SHELLCHECK_RELEASES"], SHELLCHECK, SHELLCHECK)])

    def test_other_bytes_are_refused_before_anything_is_unpacked(self):
        for tool in actionlint.TOOLS:
            with self.subTest(tool=tool), tempfile.TemporaryDirectory() as directory, \
                    patch("actionlint.platform.system", return_value="Linux"), \
                    patch("actionlint.platform.machine", return_value="x86_64"):
                archives = {each: self.archive(directory, each, "#!/bin/sh\n")
                            for each in actionlint.TOOLS}
                values = self.values(archives)
                archives[tool] = self.archive(directory, tool, "#!/bin/sh\necho other\n")
                with self.assertRaisesRegex(actionlint.Refusal,
                                            "not the .* environments/pins.sh holds"):
                    actionlint.fetch(Path(directory) / "into", values, tool,
                                     opener=self.opener(archives, []))
                self.assertEqual(list((Path(directory) / "into").iterdir()), [])

    def test_an_archive_without_the_program_is_refused(self):
        with tempfile.TemporaryDirectory() as directory, \
                patch("actionlint.platform.system", return_value="Linux"), \
                patch("actionlint.platform.machine", return_value="x86_64"):
            #  The program at the archive's top, not in its versioned
            #  directory where the release puts it.
            path = Path(directory) / "flat.tar.xz"
            with tarfile.open(path, "w:xz") as tar:
                member = tarfile.TarInfo("shellcheck")
                member.size = 0
                tar.addfile(member, io.BytesIO(b""))
            archives = {"shellcheck": path.read_bytes()}
            with self.assertRaisesRegex(actionlint.Refusal, "holds no shellcheck program"):
                actionlint.fetch(Path(directory) / "into", self.values(archives),
                                 "shellcheck", opener=self.opener(archives, []))
            self.assertEqual(list((Path(directory) / "into").iterdir()), [])

    def test_a_host_with_no_pinned_release_is_refused(self):
        with self.assertRaisesRegex(actionlint.Refusal, "no pinned actionlint for Linux riscv64"):
            actionlint.asset(actionlint.pins(), "Linux", "riscv64")
        with self.assertRaisesRegex(actionlint.Refusal, "no pinned shellcheck for Linux riscv64"):
            actionlint.asset(actionlint.pins(), "Linux", "riscv64", tool="shellcheck")

    def test_every_pinned_checksum_is_an_asset(self):
        #  The pins hold a checksum for each asset this fetches, and no other.
        values = actionlint.pins()
        for tool, (pinned, _, _, _) in actionlint.TOOLS.items():
            prefix = "LANDIN_%s_SHA256_" % pinned
            held = {name[len(prefix):] for name in values if name.startswith(prefix)}
            self.assertEqual(held, {each[0] for each in actionlint.ASSETS.values()}, tool)


if __name__ == "__main__":
    unittest.main()
