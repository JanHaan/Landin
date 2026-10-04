"""Regression checks for the scaling command's input validation."""

import contextlib
import io
from unittest import mock
import json
from pathlib import Path
import tempfile
from unittest.mock import patch
import pathlib
import subprocess
import sys
import unittest


sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import scaling

SCALING = pathlib.Path(__file__).resolve().parents[1] / "scaling.py"


class ScalingArguments(unittest.TestCase):
    def test_empty_generated_range_fails(self):
        result = subprocess.run(
            [sys.executable, str(SCALING), "--refine=" + sys.executable,
             "--largest=999", "--no-derived"],
            capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 2)
        self.assertIn("--largest must be at least 1000", result.stderr)
        self.assertNotIn("functions:", result.stdout)


class StageReportFreshness(unittest.TestCase):
    def test_success_without_new_report_rejects_previous_measurement(self):
        with tempfile.TemporaryDirectory() as work:
            report = Path(work) / "stages.json"
            calls = 0

            def compile_once(command, *_args, **_kwargs):
                nonlocal calls
                calls += 1
                self.assertEqual(command[2], "--stage-report=" + str(report))
                if calls == 1:
                    report.write_text(json.dumps({
                        "stages": [
                            {"stage": name, "processor_us": 100,
                             "peak_kib": 32}
                            for name in scaling.FRONTEND + scaling.EMISSION
                        ],
                        "sizes": {"declarations": 111},
                    }))
                return subprocess.CompletedProcess(command, 0, b"", b"")

            with patch.object(scaling, "run_compiler",
                              side_effect=compile_once):
                first = scaling.measure("refine", work, work, str(report), 5)
                self.assertEqual(first["sizes"]["declarations"], 111)
                with self.assertRaisesRegex(
                        RuntimeError, "did not write the stage report"):
                    scaling.measure("refine", work, work, str(report), 5)
            self.assertEqual(calls, 2)


class CapturedOutput(io.StringIO):
    def reconfigure(self, **kwargs):
        pass


class ScalingMemory(unittest.TestCase):
    def verdict(self, peaks):
        samples = iter({"frontend": float(size), "emission": float(size),
                        "peak_kib": peak,
                        "sizes": {"declarations": size}}
                       for size, peak in zip(scaling.SIZES, peaks))
        stdout, stderr = CapturedOutput(), io.StringIO()
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory) / "measurements.json"
            with (mock.patch.object(scaling, "build_launcher", return_value=None),
                  mock.patch.object(scaling, "FAMILIES", (("sample", lambda _: {}),)),
                  mock.patch.object(scaling, "write_program"),
                  mock.patch.object(scaling, "median_of", side_effect=lambda *args: next(samples)),
                  contextlib.redirect_stdout(stdout),
                  contextlib.redirect_stderr(stderr)):
                status = scaling.main(["--refine", sys.executable, "--runs=1",
                                       "--no-derived", "--json", str(report)])
            record = json.loads(report.read_text())
        return status, stdout.getvalue(), stderr.getvalue(), record

    def test_quadratic_memory_fails_with_linear_time(self):
        status, output, errors, record = self.verdict(
            [1024, 4096, 16384, 65536, 262144])
        self.assertEqual(status, 1)
        self.assertIn("peak memory 1000 -> 2000 grew 4.00x", errors)
        self.assertNotIn("frontend", errors)
        self.assertIn("4.00x", output)
        self.assertEqual(record["memory_limit"], 2.5)
        self.assertEqual(record["families"]["sample"][1]["ratios"]["peak_kib"], 4)

    def test_memory_at_limit_passes(self):
        status, _, errors, _ = self.verdict([1024, 2560, 6400, 16000, 40000])
        self.assertEqual(status, 0)
        self.assertEqual(errors, "")

    def test_missing_peak_fails(self):
        status, _, errors, record = self.verdict([0, 2048, 4096, 8192, 16384])
        self.assertEqual(status, 1)
        self.assertIn("no positive peak memory measurement", errors)
        self.assertEqual(record["families"]["sample"], [])


class ScalingSamples(unittest.TestCase):
    def sample(self, peak):
        return {"frontend": 1, "emission": 1, "peak_kib": peak,
                "stages": {name: 1 for name in scaling.FRONTEND + scaling.EMISSION},
                "sizes": {"declarations": 1000}}

    def test_peak_is_maximum_of_all_five_samples(self):
        peaks = [100, 200, 900, 300, 400]
        with mock.patch.object(scaling, "measure",
                               side_effect=[self.sample(p) for p in peaks]):
            result = scaling.median_of("refine", ".", ".", ".", 5, 1)
        self.assertEqual(result["peak_kib"], 900)
        self.assertEqual(result["samples"]["peak_kib"], peaks)

    def test_bad_sample_cannot_hide_behind_positive_maximum(self):
        for bad in (None, 0, -1, "100", False, float("inf"), float("nan")):
            with self.subTest(bad=bad):
                samples = [self.sample(100), self.sample(bad), self.sample(200)]
                if bad is None:
                    samples[1].pop("peak_kib")
                with mock.patch.object(scaling, "measure", side_effect=samples):
                    with self.assertRaisesRegex(RuntimeError, "peak memory"):
                        scaling.median_of("refine", ".", ".", ".", 3, 1)

    def test_missing_stage_peak_is_rejected(self):
        with tempfile.TemporaryDirectory() as work:
            report = Path(work) / "stages.json"
            def compile_once(command, *_args):
                rows = [{"stage": name, "processor_us": 100, "peak_kib": 500}
                        for name in scaling.FRONTEND + scaling.EMISSION]
                rows[0].pop("peak_kib")
                report.write_text(json.dumps({"stages": rows, "sizes": {}}))
                return subprocess.CompletedProcess(command, 0, b"", b"")
            with mock.patch.object(scaling, "run_compiler", side_effect=compile_once):
                with self.assertRaisesRegex(RuntimeError, "peak memory.*loading"):
                    scaling.measure("refine", work, work, str(report), 1)


class ScalingLauncher(unittest.TestCase):
    def test_native_child_does_not_inherit_python_peak(self):
        with tempfile.TemporaryDirectory() as work:
            launcher = scaling.build_launcher(work)
            probe = Path(work) / "peak.c"
            binary = Path(work) / "peak"
            probe.write_text('#include <stdio.h>\n#include <sys/resource.h>\n'
                             'int main(void) { struct rusage r; '
                             'if(getrusage(RUSAGE_SELF,&r)) return 2; '
                             'long k=r.ru_maxrss;\n#ifdef __APPLE__\nk/=1024;\n#endif\n'
                             'printf("%ld\\n",k); return 0; }\n')
            subprocess.run([scaling.os.environ.get("CC", "cc"), str(probe),
                            "-o", str(binary)], check=True, capture_output=True)
            parent_memory = bytearray(64 * 1024 * 1024)
            # bytearray commits these pages; retain it across fork and exec.
            result = scaling.run_compiler([launcher, str(binary)], 10)
            self.assertEqual(len(parent_memory), 64 * 1024 * 1024)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertLess(int(result.stdout), 32 * 1024)
            self.assertGreater(int(result.stdout), 0)
            result = scaling.run_compiler(
                [launcher, sys.executable, "-c", "raise SystemExit(7)"], 10)
            self.assertEqual(result.returncode, 7)

    def test_timeout_stops_launcher_process_group(self):
        child = mock.MagicMock()
        child.__enter__.return_value = child
        child.pid = 12345
        child.communicate.side_effect = [
            subprocess.TimeoutExpired(["launcher", "refine"], 1), (b"", b"")]
        with (mock.patch.object(scaling.subprocess, "Popen", return_value=child) as start,
              mock.patch.object(scaling.os, "killpg") as kill):
            with self.assertRaises(subprocess.TimeoutExpired):
                scaling.run_compiler(["launcher", "refine"], 1)
        self.assertTrue(start.call_args.kwargs["start_new_session"])
        kill.assert_called_once_with(child.pid, scaling.signal.SIGKILL)
        self.assertEqual(child.communicate.call_count, 2)


if __name__ == "__main__":
    unittest.main()
