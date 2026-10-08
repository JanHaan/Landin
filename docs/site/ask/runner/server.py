#!/usr/bin/env python3
"""VM-local authenticated runner. Public TLS is terminated by the proxy."""
from datetime import datetime, timezone
import hmac
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import sqlite3
import subprocess
import threading
from container_entry import execute

HERE = Path(__file__).resolve().parent
MAX_BODY = 16_384
MAX_SOURCE = 8192
DAILY_JOBS = 200


def container_command(image, name):
    if not re.fullmatch(r"sha256:[a-f0-9]{64}", image):
        raise ValueError("RUNNER_IMAGE must be an immutable local Docker image ID")
    return [
        "docker", "run", "--name", name, "--label=landin.ask=1", "--rm", "-i", "--pull=never",
        "--runtime=runsc", "--network=none", "--read-only", "--cap-drop=ALL",
        "--security-opt=no-new-privileges", "--user=65532:65532", "--cpus=1",
        "--memory=512m", "--memory-swap=512m", "--pids-limit=64", "--ipc=none",
        "--ulimit", "nofile=64:64", "--ulimit", "core=0:0", "--log-driver=none",
        "--ulimit", "nproc=64:64",
        "--tmpfs", "/work:rw,nosuid,nodev,size=16777216,uid=65532,gid=65532,mode=700",
        "--tmpfs", "/tmp:rw,noexec,nosuid,nodev,size=16777216,uid=65532,gid=65532,mode=700",
        "--workdir=/work", "--env=TMPDIR=/tmp", "--env=LANG=C.UTF-8",
        "--entrypoint=/usr/bin/python3", image, "/opt/landin/container_entry.py"]


class Quotas:
    def __init__(self, path):
        self.path = path
        with sqlite3.connect(path) as db:
            db.execute("CREATE TABLE IF NOT EXISTS jobs (day TEXT PRIMARY KEY, count INTEGER NOT NULL)")

    def reserve(self, day=None):
        day = day or datetime.now(timezone.utc).date().isoformat()
        with sqlite3.connect(self.path, timeout=2, isolation_level=None) as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT count FROM jobs WHERE day=?", (day,)).fetchone()
            count = row[0] if row else 0
            if count >= DAILY_JOBS:
                db.rollback()
                return False
            db.execute("INSERT INTO jobs VALUES (?, ?) ON CONFLICT(day) DO UPDATE SET count=excluded.count",
                       (day, count + 1))
            db.execute("DELETE FROM jobs WHERE day < date(?, '-7 days')", (day,))
            db.commit()
        return True


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass  # Do not retain source, requests, bearer tokens or output.

    def setup(self):
        super().setup()
        self.connection.settimeout(3)

    def reply(self, status, data):
        body = json.dumps(data).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if self.path != "/run":
            return self.reply(404, {"error": "No such endpoint."})
        supplied = self.headers.get("Authorization", "")
        if not hmac.compare_digest(supplied.encode(), ("Bearer " + self.server.runner_key).encode()):
            return self.reply(403, {"error": "Forbidden."})
        try:
            if self.headers.get("Transfer-Encoding"):
                raise ValueError("chunked requests are not supported")
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 < length <= MAX_BODY:
                raise ValueError("invalid length")
            body = self.rfile.read(length)
            if len(body) != length:
                raise ValueError("incomplete body")
            request = json.loads(body)
            code = request.get("code")
            if (not isinstance(code, str) or not code.strip() or "\0" in code
                    or len(code.encode()) > MAX_SOURCE):
                raise ValueError("invalid source")
        except (ValueError, AttributeError, UnicodeError):
            return self.reply(400, {"error": "Invalid source request."})
        if not self.server.job_slot.acquire(blocking=False):
            return self.reply(429, {"error": "Runner busy."})
        name = "landin-ask-" + os.urandom(16).hex()
        try:
            if not self.server.quotas.reserve():
                return self.reply(429, {"error": "Daily execution quota exhausted."})
            # Program text is stdin data only, never shell text, Docker flags,
            # host paths, image names or environment variables.
            status, result, output = execute(container_command(self.server.image, name),
                25, 48_000, input_bytes=json.dumps({"code": code}).encode(), cwd=None)
            if status == "timeout":
                return self.reply(200, {"status": "timeout", "output": "Execution stopped at the outer time limit.",
                    "exitCode": None, "compiler": self.server.compiler_sha256})
            if status != "finished" or result:
                return self.reply(503, {"error": "Sandbox failed."})
            data = json.loads(output)
            if not isinstance(data, dict):
                raise ValueError("invalid sandbox result")
            # The container's claimed compiler identity is not trusted.
            data["compiler"] = self.server.compiler_sha256
            self.reply(200, data)
        except (ValueError, OSError):
            self.reply(503, {"error": "Sandbox failed."})
        finally:
            # docker run's CLI timeout alone would leave its container running.
            # Always remove it through the daemon before opening another slot.
            try:
                subprocess.run(["docker", "rm", "-f", name], stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL, timeout=5, check=False)
                remaining = subprocess.run(["docker", "ps", "-a", "--filter", "name=^/" + name + "$",
                    "--format={{.ID}}"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                    timeout=5, check=False)
                if remaining.returncode != 0 or remaining.stdout.strip():
                    self.server.unsafe_cleanup = True
            except (OSError, subprocess.TimeoutExpired):
                # Fail closed until the operator restarts and inspects the VM.
                self.server.unsafe_cleanup = True
            if not self.server.unsafe_cleanup:
                self.server.job_slot.release()


class Server(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address, key, image, quota_path, compiler_sha256):
        if len(key) < 32 or not re.fullmatch(r"[a-f0-9]{64}", compiler_sha256):
            raise ValueError("set a strong RUNNER_KEY and the checked COMPILER_SHA256")
        container_command(image, "configuration-check")
        self.runner_key, self.image = key, image
        self.compiler_sha256 = compiler_sha256
        self.quotas, self.job_slot = Quotas(quota_path), threading.BoundedSemaphore(1)
        self.connections, self.unsafe_cleanup = threading.BoundedSemaphore(8), False
        super().__init__(address, Handler)

    def process_request(self, request, client_address):
        if not self.connections.acquire(blocking=False):
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except BaseException:
            self.connections.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.connections.release()


def main():
    if os.uname().machine != "x86_64":
        raise SystemExit("runner: this image/target pair requires Linux x86-64")
    state = Path(os.environ.get("RUNNER_STATE", "/var/lib/landin-ask"))
    state.mkdir(parents=True, exist_ok=True)
    # A crashed launcher must not start another job alongside an orphan.
    remaining = subprocess.run(["docker", "ps", "-a", "--filter", "label=landin.ask=1",
        "--format={{.ID}}"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        timeout=5, check=False)
    if remaining.returncode != 0 or remaining.stdout.strip():
        raise SystemExit("runner: Docker unavailable or leftover sandboxes require inspection")
    server = Server(("127.0.0.1", 8788), os.environ["RUNNER_KEY"], os.environ["RUNNER_IMAGE"],
                    state / "quotas.sqlite", os.environ["COMPILER_SHA256"])
    # Explicit runsc requests never fall back to Docker's shared-kernel runtime.
    # Configuration and sandbox denial probes still need operator verification.
    server.serve_forever()


if __name__ == "__main__":
    main()
