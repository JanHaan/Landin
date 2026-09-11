#!/usr/bin/env python3
"""Regression controls for measured-program execution and determinism."""
from __future__ import annotations

import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location(
    "quality_check", Path(__file__).with_name("check.py"))
assert SPEC is not None and SPEC.loader is not None
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)


class QualityTests(unittest.TestCase):
    def test_complete_derivatives_have_all_profiles(self):
        expected = CHECK.PROFILES + (("none", "all"), ("speed", "all"))
        for name in ("derived-parser", "derived-containers", "derived-hosted-memory"):
            self.assertIn(name, CHECK.FIXTURE_NAMES)
            self.assertEqual(CHECK.profiles_for(name), expected)

    def test_parser_uses_original_request_and_oracle(self):
        config = CHECK.fixture_configuration("derived-parser")
        self.assertEqual(config["run_args"],
                         ("../tests/fixtures/runtime/derived-parser/input.txt",))
        self.assertEqual(config["expected_status"], 42)
        self.assertEqual(config["expected_output"],
                         (config["source"] / "output.txt").read_bytes())
        self.assertTrue((config["execution_cwd"] / config["run_args"][0]).is_file())
        result = subprocess.CompletedProcess([], 42, config["expected_output"])
        with patch.object(CHECK.subprocess, "run", return_value=result) as run:
            CHECK.execute_measurement(Path("/test/program"), **{
                key: config[key] for key in
                ("expected_status", "run_args", "expected_output", "execution_cwd")})
        self.assertEqual(run.call_args.args[0],
                         ["/test/program", *config["run_args"]])
        self.assertEqual(run.call_args.kwargs["cwd"], config["execution_cwd"])
        self.assertEqual(run.call_args.kwargs["stderr"], subprocess.STDOUT)
        self.assertNotIn("text", run.call_args.kwargs)

    def execute(self, source, expected=b"answer\n", status=42):
        return CHECK.execute_measurement(
            Path(sys.executable), run_args=("-c", source),
            expected_output=expected, expected_status=status)

    def test_matching_bytes_and_status_pass(self):
        self.execute("import sys; print('answer'); sys.exit(42)")

    def test_wrong_stdout_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "output differs"):
            self.execute("import sys; print('wrong'); sys.exit(42)")

    def test_wrong_stderr_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "output differs"):
            self.execute("import sys; print('answer'); print('wrong', file=sys.stderr); sys.exit(42)")

    def test_wrong_status_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "returned 0, expected 42"):
            self.execute("print('answer')")

    def test_line_endings_are_not_normalized(self):
        with self.assertRaisesRegex(ValueError, "output differs"):
            self.execute("import sys; sys.stdout.buffer.write(b'answer\\r\\n'); sys.exit(42)")

    def test_existing_empty_oracle_rejects_either_stream(self):
        for stream in ("stdout", "stderr"):
            with self.subTest(stream=stream), self.assertRaisesRegex(ValueError, "output differs"):
                self.execute(f"import sys; print('unexpected', file=sys.{stream})", b"", 0)

    def parser_measurements(self):
        root = CHECK.HERE.parents[2]
        config = CHECK.fixture_configuration("derived-parser")
        files = [config["source"] / "main.ldn"]
        for directory in ("core/diag", "core/io", "core/mem", "core/text", "core/vec",
                          "examples/config_parser/lexer", "examples/config_parser/parser"):
            files.extend((root / directory).glob("*.ldn"))
        sample = {
            "sources": [{"source": number, "path_hex": str(path).encode().hex()}
                        for number, path in enumerate(files, 1)],
            "items": [{"source": number, "item": number}
                      for number in range(1, len(files) + 1)],
            "build": {"routines": [{"item": number}
                                   for number in range(1, len(files) + 1)]},
            "execution": {"argv": list(config["run_args"]), "status": 42,
                          "output_sha256": hashlib.sha256(config["expected_output"]).hexdigest()},
            "text_bytes": 1,
        }
        return {"-".join(profile): copy.deepcopy(sample)
                for profile in CHECK.profiles_for("derived-parser")}

    def test_complete_parser_measurements_pass(self):
        CHECK.check_parser_measurements(self.parser_measurements())

    def test_missing_parser_profile_is_rejected(self):
        measurements = self.parser_measurements()
        del measurements["speed-all"]
        with self.assertRaisesRegex(ValueError, "required profile"):
            CHECK.check_parser_measurements(measurements)

    def test_missing_parser_source_is_rejected(self):
        measurements = self.parser_measurements()
        measurements["none-off"]["sources"].pop()
        with self.assertRaisesRegex(ValueError, "source closure"):
            CHECK.check_parser_measurements(measurements)

    def test_missing_parser_routines_are_rejected(self):
        measurements = self.parser_measurements()
        measurements["none-off"]["build"]["routines"] = []
        with self.assertRaisesRegex(ValueError, "routine evidence"):
            CHECK.check_parser_measurements(measurements)

    def test_changed_parser_request_is_rejected(self):
        measurements = self.parser_measurements()
        measurements["none-off"]["execution"]["argv"] = []
        with self.assertRaisesRegex(ValueError, "original execution oracle"):
            CHECK.check_parser_measurements(measurements)

    def test_changed_repeated_assembly_or_report_is_rejected(self):
        for changed in ("assembly", "report"):
            with self.subTest(changed=changed), tempfile.TemporaryDirectory() as tmp:
                destination = Path(tmp) / "program"
                calls = []

                def compile_request(args, **kwargs):
                    calls.append(args)
                    destination.with_suffix(".s").write_bytes(
                        b"changed" if changed == "assembly" and len(calls) == 2 else b"assembly")
                    destination.with_suffix(".json").write_text(json.dumps(
                        {"changed": changed == "report" and len(calls) == 2}))
                    return ""

                with patch.object(CHECK, "run", side_effect=compile_request):
                    with self.assertRaisesRegex(ValueError, "nondeterministic " + changed):
                        CHECK.measure(Path("refine"), {}, Path("main.ldn"),
                                      destination, ("none", "off"))
                self.assertEqual(len(calls), 2)
                self.assertEqual(calls[0], calls[1])


if __name__ == "__main__":
    unittest.main()
