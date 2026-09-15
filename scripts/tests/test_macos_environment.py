#!/usr/bin/env python3
"""Fail-closed native environment evidence, without requiring a Mac."""
from pathlib import Path
import json
import os
import re
import signal
import sys
import subprocess
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import macos_environment as macos


RUNTIME = """      failed: runtime/example [none-off]: producer failed to complete output
error[L0500]: cannot run x86_64-pc-linux-gnu-gcc for target linux-x86-64
  --> <unknown source>
  = note: install a toolchain named x86_64-pc-linux-gnu-gcc, or name another with --toolchain=NAME
"""
ABI = ("      failed: abi/example [none-off] C link: producer could not be run: "
       "x86_64-pc-linux-gnu-gcc\n")
TRANSCRIPT = ("fixture execution\n  pass  positive fixtures emit\n"
              "  FAIL  runtime fixtures execute\n" + RUNTIME + ABI
              + "  pass  another case\n\ncases 3, passed 2, failed 1, checks 20\n")


class MacOSEnvironment(unittest.TestCase):
    def test_native_only(self):
        macos.native_host("Darwin", "arm64", "0")
        for identity in (("Linux", "arm64", "0"), ("Darwin", "x86_64", "1"),
                         ("Darwin", "arm64", "1"), ("Darwin", "arm64", "")):
            with self.subTest(identity=identity), self.assertRaises(ValueError):
                macos.native_host(*identity)

    def test_expected_runtime_failure(self):
        self.assertEqual(macos.harness_result(1, TRANSCRIPT)["passed"], 2)
        with self.assertRaises(ValueError):
            macos.harness_result(1, TRANSCRIPT, timed_out=True)

    def test_host_scope_needs_its_banner_and_zero_failures(self):
        text = ("HOST-ONLY compiler checks; target workload emission/execution excluded\n"
                "harness\n  pass  complete host check\n"
                "cases 1, passed 1, failed 0, checks 3\n")
        self.assertEqual(macos.harness_result(0, text, host_only=True)["scope"],
                         "compiler-host")
        for bad in (text.replace("HOST-ONLY", "partial"), "FILTERED\n" + text,
                    text.replace("failed 0", "failed 1")):
            with self.assertRaises(ValueError):
                macos.harness_result(0, bad, host_only=True)
        with self.assertRaises(ValueError):
            macos.harness_result(0, text)

    def test_policy_drift_is_rejected_before_building(self):
        policy = json.loads(macos.POLICY.read_text())
        pins = dict(re.findall(r"^(LANDIN_\w+)=([^\n]+)$",
                    (macos.ROOT / "environments/pins.sh").read_text(), re.M))
        replies = {"translation": "0", "macos-version": policy["macos_major"] + ".1",
                   "sdk_version": policy["sdk_version"], "sdk_build": policy["sdk_build"],
                   "ada-target": "aarch64-apple-darwin24.6.0",
                   "gnatls-version": "GNATLS " + pins["LANDIN_GNAT_VERSION"].rsplit("-", 1)[0],
                   "gprbuild-version": "GPRBUILD " + pins["LANDIN_GPRBUILD_VERSION"].rsplit("-", 1)[0],
                   "gcc-version": pins["LANDIN_GNAT_VERSION"].rsplit("-", 1)[0]}
        for label in ("clang", "assembler", "linker", "debugger"):
            replies[label + "-version"] = (json.dumps({"version": policy[label]})
                                           if label == "linker" else policy[label])

        class FakeCapture:
            def text(self, name, argv):
                return replies.get(name, "/selected/tool")

        with patch.object(macos.platform, "system", return_value="Darwin"), \
                patch.object(macos.platform, "machine", return_value="arm64"), \
                patch.object(macos.shutil, "which", side_effect=lambda name:
                    None if name == "x86_64-pc-linux-gnu-gcc" else "/pinned/" + name), \
                patch.object(macos, "sha256", return_value="digest"):
            macos.validate(FakeCapture())
            for key in replies:
                old = replies[key]
                replies[key] = "unexpected"
                with self.subTest(key=key), self.assertRaises(ValueError):
                    macos.validate(FakeCapture())
                replies[key] = old

    def test_reject_incomplete_filtered_or_other_failures(self):
        for text in ("FILTERED\n" + TRANSCRIPT, TRANSCRIPT.split("cases")[0],
                     TRANSCRIPT + TRANSCRIPT,
                     TRANSCRIPT.replace("passed 2", "passed 1"),
                     TRANSCRIPT.replace("  pass  another case", "  FAIL  another case"),
                     TRANSCRIPT.replace("runtime fixtures execute", "frontend")):
            with self.subTest(text=text), self.assertRaises(ValueError):
                macos.harness_result(1, text)
        for code in (0, -9, 70):
            with self.assertRaises(ValueError):
                macos.harness_result(code, TRANSCRIPT)

    def test_runtime_case_cannot_hide_a_regression(self):
        for bad in ("      raised STORAGE_ERROR\n",
                    "      failed: metadata is invalid\n",
                    RUNTIME.replace("L0500", "L0300"),
                    RUNTIME.replace("cannot run", "failed to run"),
                    ABI.replace("x86_64-pc-linux-gnu-gcc", "some-other-tool")):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                macos.harness_result(1, TRANSCRIPT.replace(RUNTIME, bad))

    def test_resource_outcomes_stay_distinct(self):
        for code, text, timeout, expected in (
            (0, "", False, "accepted"),
            (71, "refine: host resources exhausted", False, "reported-exhaustion"),
            (1, "raised STORAGE_ERROR", False, "raw-exception"),
            (1, "error[L0111]: too deep", False, "diagnostic"),
            (-5, "", False, "signal"),
            (-signal.SIGXCPU, "", False, "cpu-limit"),
            (-9, "", True, "timeout"),
            (70, "internal compiler defect", False, "unexpected-failure"),
            (1, "", False, "unexpected-failure"),
        ):
            self.assertEqual(macos.classify(code, text, timeout), expected)

    def test_capture_retains_failure_and_timeout(self):
        with tempfile.TemporaryDirectory() as tmp:
            capture = macos.Capture(Path(tmp))
            with self.assertRaises(ValueError):
                capture.run("failure", [sys.executable, "-c",
                            "import sys; print('retained'); sys.exit(7)"])
            self.assertEqual(capture.records[0]["returncode"], 7)
            self.assertIn("retained", (Path(tmp) / "failure.stdout").read_text())
            code, _, expired = capture.run("timeout", [sys.executable, "-c",
                "import time; time.sleep(60)"], timeout=0.1, check=False)
            self.assertTrue(expired)
            self.assertLess(code, 0)
            self.assertTrue((Path(tmp) / "commands.json").is_file())

    def test_timeout_stops_a_separate_tool_group(self):
        with tempfile.TemporaryDirectory() as tmp:
            pid_file = Path(tmp) / "child.pid"
            code = ("import os, subprocess, sys, time\nfrom pathlib import Path\n"
                    "child = subprocess.Popen([sys.executable, '-c', "
                    "'import time; time.sleep(60)'], preexec_fn=os.setpgrp)\n"
                    f"Path({str(pid_file)!r}).write_text(str(child.pid))\n"
                    "time.sleep(60)\n")
            try:
                capture = macos.Capture(Path(tmp))
                capture.run("group-timeout", [sys.executable, "-c", code],
                            timeout=2, check=False)
                child = int(pid_file.read_text())
                status = subprocess.run(["ps", "-o", "stat=", "-p", str(child)],
                                        capture_output=True, text=True, timeout=5)
                # A reparented zombie is already stopped; reaping belongs to
                # init on this host, not to the validation process.
                self.assertTrue(not status.stdout.strip()
                                or status.stdout.strip().startswith("Z"))
            finally:
                if pid_file.exists():
                    try:
                        os.killpg(int(pid_file.read_text()), signal.SIGKILL)
                    except ProcessLookupError:
                        pass


if __name__ == "__main__":
    unittest.main()
