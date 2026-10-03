#!/usr/bin/env python3
"""Bounded framed-server checks for the fuzz driver's close oracle."""
import contextlib
import io
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
    def run_driver(self, sources, per_server, action="healthy", close=0):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            stub = directory / "stub"
            stub.write_text("#!%s\n%s" % (sys.executable, STUB))
            stub.chmod(0o755)
            out = directory / "out"
            originals = [("source-%d" % i, "source %d\n" % i)
                         for i in range(sources)]
            argv = ["fuzz.py", "--refine", str(stub), "--out", str(out),
                    "--seconds", "1", "--memory", "0", "--per-server",
                    str(per_server)]
            output = io.StringIO()
            with mock.patch.object(fuzz, "seeds", return_value=originals), \
                    mock.patch.object(sys, "argv", argv), \
                    mock.patch.dict(os.environ, {"FUZZ_STUB_ACTION": action,
                                                 "FUZZ_STUB_CLOSE": str(close)}), \
                    contextlib.redirect_stdout(output):
                status = fuzz.main()
            artifacts = {p.name: p.read_bytes() for p in out.iterdir()}
            return status, output.getvalue(), artifacts, originals

    def assert_hit(self, sources, per_server, close, expected_seed, action="crash"):
        status, output, artifacts, originals = self.run_driver(
            sources, per_server, action, close)
        self.assertEqual(status, 1, output)
        self.assertIn("hits=1", output)
        self.assertIn("src=source-%d" % (expected_seed - 500000), output)
        self.assertEqual(set(artifacts), {"hit-%d.ldn" % expected_seed,
                                          "hit-%d.lsp" % expected_seed})
        original = originals[expected_seed - 500000][1]
        self.assertEqual(artifacts["hit-%d.ldn" % expected_seed],
                         fuzz.mutate(expected_seed, original).encode())
        transcript = artifacts["hit-%d.lsp" % expected_seed].decode()
        self.assertIn("file:///fuzz/m%d/case.ldn" % expected_seed, transcript)
        self.assertIn("textDocument/didClose", transcript)
        if action in ("shutdown_eof", "timeout"):
            self.assertIn('"method": "shutdown"', transcript)
        return output

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


if __name__ == "__main__":
    unittest.main()
