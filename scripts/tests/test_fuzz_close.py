#!/usr/bin/env python3
"""Bounded framed-server checks for the fuzz driver's close oracle."""
import contextlib
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] /
                       "compiler/tests/fuzz"))
import fuzz


STUB = r'''
import json
import os
import sys
import time

closed = 0

def send(message):
    body = json.dumps(message).encode("utf-8")
    sys.stdout.buffer.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
    sys.stdout.buffer.flush()

while True:
    headers = {}
    while True:
        line = sys.stdin.buffer.readline()
        if not line:
            sys.exit(0)
        if line == b"\r\n":
            break
        key, value = line.split(b":", 1)
        headers[key.lower()] = value.strip()
    message = json.loads(sys.stdin.buffer.read(int(headers[b"content-length"])))
    method = message.get("method")
    if method == "textDocument/didClose":
        closed += 1
        if closed == int(os.environ.get("FUZZ_STUB_CLOSE", "0")):
            action = os.environ["FUZZ_STUB_ACTION"]
            if action == "crash":
                os._exit(70)
            if action == "eof":
                sys.exit(0)
            if action == "timeout":
                time.sleep(10)
    if method == "shutdown" and os.environ.get("FUZZ_STUB_ACTION") == "shutdown_eof":
        sys.exit(0)
    if "id" in message:
        send({"jsonrpc": "2.0", "id": message["id"], "result": None})
    if method == "exit":
        sys.exit(0)
'''


class CloseOracleTest(unittest.TestCase):
    def run_driver(self, sources, per_server, action="healthy", close=0,
                   healthy_preflight=True):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            stub = directory / "stub"
            stub.write_text("#!%s\n%s" % (sys.executable, STUB))
            stub.chmod(0o755)
            out = directory / "out"
            originals = []
            for i in range(sources):
                module = directory / ("source-%d" % i)
                module.mkdir()
                path = module / ("min-100299.ldn" if i == 0 else "case.ldn")
                text = "source %d\n" % i
                path.write_text(text)
                label = "reproducers/min-100299.ldn" if i == 0 else "source-%d" % i
                originals.append((label, path, text))
            argv = ["fuzz.py", "--refine", str(stub), "--out", str(out),
                    "--seconds", "1", "--memory", "0", "--per-server",
                    str(per_server)]
            output = io.StringIO()
            server_type = fuzz.Server
            starts = 0

            def start(*args):
                nonlocal starts
                starts += 1
                if starts == 1 and healthy_preflight:
                    with mock.patch.dict(os.environ, {
                            "FUZZ_STUB_ACTION": "healthy", "FUZZ_STUB_CLOSE": "0"}):
                        return server_type(*args)
                return server_type(*args)

            # These controls isolate shutdown and rollover from the startup
            # semantic probes, which have separate positive/negative controls.
            with mock.patch.object(fuzz, "seeds", return_value=originals), \
                    mock.patch.object(fuzz, "Server", side_effect=start), \
                    mock.patch.object(fuzz, "check_imports"), \
                    mock.patch.object(fuzz, "check_reproducer"), \
                    mock.patch.object(sys, "argv", argv), \
                    mock.patch.dict(os.environ, {"FUZZ_STUB_ACTION": action,
                                                 "FUZZ_STUB_CLOSE": str(close)}), \
                    contextlib.redirect_stdout(output), \
                    contextlib.redirect_stderr(output):
                status = fuzz.main()
            artifacts = {p.name: p.read_bytes() for p in out.iterdir()}
            return status, output.getvalue(), artifacts, originals

    def assert_hit(self, sources, per_server, close, expected_seed, action="crash"):
        status, output, artifacts, originals = self.run_driver(
            sources, per_server, action, close)
        self.assertEqual(status, 1, output)
        self.assertIn("hits=1", output)
        label, path, original = originals[expected_seed - 500000]
        self.assertIn("src=" + label, output)
        self.assertEqual(set(artifacts), {"hit-%d.ldn" % expected_seed,
                                          "hit-%d.lsp" % expected_seed})
        self.assertEqual(artifacts["hit-%d.ldn" % expected_seed],
                         fuzz.mutate(expected_seed, original).encode())
        transcript = artifacts["hit-%d.lsp" % expected_seed].decode()
        opened = next(json.loads(line[3:]) for line in transcript.splitlines()
                      if line.startswith("-> ") and
                      json.loads(line[3:]).get("method") == "textDocument/didOpen")
        uri = opened["params"]["textDocument"]["uri"]
        if label.startswith("reproducers/"):
            self.assertIn("/out/reproducers-", uri)
            self.assertTrue(uri.endswith("/min-100299/min-100299.ldn"))
            self.assertNotEqual(uri, path.as_uri())
        else:
            self.assertEqual(uri, path.as_uri())
        self.assertIn("textDocument/didClose", transcript)
        if action in ("shutdown_eof", "timeout"):
            self.assertIn('"method": "shutdown"', transcript)
        return output

    def test_initialize_names_repository_import_root(self):
        with tempfile.TemporaryDirectory() as temporary:
            stub = Path(temporary) / "stub"
            stub.write_text("#!%s\n%s" % (sys.executable, STUB))
            stub.chmod(0o755)
            with mock.patch.dict(os.environ, {"FUZZ_STUB_ACTION": "healthy",
                                               "FUZZ_STUB_CLOSE": "0"}):
                server = fuzz.Server(str(stub), 0, 1)
                try:
                    initialize = json.loads(server.transcript[0][3:])
                    self.assertEqual(initialize["method"], "initialize")
                    self.assertEqual(
                        initialize["params"]["initializationOptions"]["roots"],
                        [fuzz.ROOT.as_uri()])
                finally:
                    stopped = server.stop()
                self.assertEqual(stopped, "")

    def test_final_close_crash(self):
        self.assertIn("70", self.assert_hit(1, 2, 1, 500000))

    def test_rollover_close_crash(self):
        self.assertIn("70", self.assert_hit(3, 3, 2, 500001))

    def test_healthy_shutdown_and_rollover(self):
        status, output, artifacts, _ = self.run_driver(3, 2)
        self.assertEqual(status, 0, output)
        self.assertIn("hits=0", output)
        self.assertEqual(artifacts, {})

    def test_premature_eof_is_a_hit(self):
        self.assertIn("status 0", self.assert_hit(1, 2, 1, 500000, "eof"))

    def test_shutdown_eof_is_a_hit(self):
        self.assertIn("shutdown", self.assert_hit(1, 2, 0, 500000,
                                                  "shutdown_eof"))

    def test_close_timeout_is_a_hit(self):
        self.assertIn("no answer within", self.assert_hit(1, 2, 1, 500000,
                                                         "timeout"))

    def test_preflight_shutdown_failure_stops_before_mutation(self):
        status, output, artifacts, _ = self.run_driver(
            1, 2, "shutdown_eof", healthy_preflight=False)
        self.assertEqual(status, 1)
        self.assertIn("seed check failed: shutdown", output)
        self.assertNotIn("HIT seed=", output)
        self.assertEqual(artifacts, {})


if __name__ == "__main__":
    unittest.main()
