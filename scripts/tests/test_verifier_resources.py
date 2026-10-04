"""Controls for portable representative resource evidence, not new limits."""
import contextlib
import io
import json
from pathlib import Path
import resource
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import verifier_resources as resources


class ResourceEvidence(unittest.TestCase):
    def test_existing_large_workloads_are_not_shrunk(self):
        sources = resources.workloads()
        self.assertEqual(sources["branches-16000"], resources.scaling.branches(16000))
        self.assertEqual(sources["large-routine-24000"]["main.ldn"].count("r +%= 1\n"),
                         24000)
        pointer = sources["pointers64-128"]["main.ldn"]
        self.assertEqual(pointer.count(": ptr mut u32 = cell"), 64)
        self.assertEqual(pointer.count("end if"), 128)
        self.assertEqual(resources.RUNS, 5)

    def run_evidence(self, failure=False):
        sample = {"frontend": 1.0, "emission": 2.0, "peak_kib": 1234}
        measurements = [sample.copy() for _ in range(5)]
        if failure:
            measurements[2] = RuntimeError("no positive peak memory measurement")
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "evidence"
            with (mock.patch.object(resources, "workloads",
                                    return_value={"case": {"main.ldn": ""}}),
                  mock.patch.object(resources.scaling, "build_launcher", return_value="launcher"),
                  mock.patch.object(resources.scaling, "measure", side_effect=measurements),
                  mock.patch.object(resources, "stack_probe", return_value={"status": 139}),
                  mock.patch.object(resources.resource, "setrlimit"),
                  contextlib.redirect_stdout(io.StringIO())):
                status = resources.main(["--refine", sys.executable, "--output", str(output)])
            record = json.loads((output / "resources.json").read_text())
        return status, record

    def test_low_stack_failures_are_observations_not_new_policy(self):
        status, record = self.run_evidence()
        self.assertEqual(status, 0)
        row = record["workloads"]["case"]
        self.assertEqual(len(row["samples"]), 5)
        self.assertEqual(len(row["stack_probes"]), 4)
        self.assertEqual(row["summary"]["peak_kib_max"], 1234)
        self.assertIn("binary_sha256", record)
        self.assertIn("source_sha256", row)

    def test_bad_normal_sample_fails_and_retains_all_evidence(self):
        status, record = self.run_evidence(failure=True)
        self.assertEqual(status, 1)
        row = record["workloads"]["case"]
        self.assertEqual(len(row["samples"]), 5)
        self.assertEqual(len(row["stack_probes"]), 4)
        self.assertNotIn("summary", row)
        self.assertIn("positive peak", record["failures"][0])

    def test_existing_output_is_refused(self):
        with tempfile.TemporaryDirectory() as temporary:
            marker = Path(temporary) / "keep"
            marker.write_text("untouched")
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                resources.main(["--refine", sys.executable, "--output", temporary])
            self.assertEqual(marker.read_text(), "untouched")

    def test_probe_honors_hard_limit_without_launching(self):
        with (mock.patch.object(resources.resource, "getrlimit", return_value=(1024, 1024)),
              mock.patch.object(resources.subprocess, "Popen") as launch):
            result = resources.stack_probe(["unused"], 2048, 1)
        self.assertEqual(result["status"], "skipped-hard-limit")
        launch.assert_not_called()

    def test_actual_probe_disables_cores_and_preserves_parent_limits(self):
        before = resource.getrlimit(resource.RLIMIT_STACK)
        script = ("import json,resource; print(json.dumps(["
                  "resource.getrlimit(resource.RLIMIT_STACK),"
                  "resource.getrlimit(resource.RLIMIT_CORE)])); raise SystemExit(7)")
        result = resources.stack_probe([sys.executable, "-c", script], 2048, 5)
        self.assertEqual(result["status"], 7)
        stack, core = json.loads(result["stdout"])
        self.assertEqual(stack[0], 2048 * 1024)
        self.assertEqual(core, [0, 0])
        self.assertEqual(resource.getrlimit(resource.RLIMIT_STACK), before)

    def test_timeout_kills_and_collects_entire_process_group(self):
        child = mock.MagicMock(pid=456)
        child.__enter__.return_value = child
        child.communicate.side_effect = [subprocess.TimeoutExpired("compiler", 1),
                                         (b"partial", b"timeout")]
        with (mock.patch.object(resources.subprocess, "Popen", return_value=child) as launch,
              mock.patch.object(resources.os, "killpg") as kill):
            result = resources.stack_probe(["launcher", "compiler"], 2048, 1)
        self.assertEqual(result["status"], "timeout")
        self.assertEqual(result["stdout"], "partial")
        self.assertTrue(launch.call_args.kwargs["start_new_session"])
        kill.assert_called_once_with(456, resources.signal.SIGKILL)
        self.assertEqual(child.communicate.call_count, 2)


if __name__ == "__main__":
    unittest.main()
