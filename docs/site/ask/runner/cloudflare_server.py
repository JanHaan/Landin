#!/usr/bin/env python3
"""One job per microVM. No keys, shell input, package fetches or compiler build."""
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import os
import threading

from container_entry import MAX_SOURCE, run_request


class Handler(BaseHTTPRequestHandler):
    used = False

    def setup(self):
        super().setup()
        self.connection.settimeout(3)

    def log_message(self, *_):
        pass  # Never retain visitor source or program output in provider logs.

    def reply(self, status, data):
        body = json.dumps(data).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self.reply(200 if self.path == "/health" else 404, {"ready": not Handler.used})

    def do_POST(self):
        if self.path != "/run" or Handler.used:
            self.reply(409, {"error": "This sandbox cannot accept another job."})
            return
        Handler.used = True
        try:
            if self.headers.get("Transfer-Encoding"):
                raise ValueError("chunked input is unsupported")
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 < length <= 16_384:
                raise ValueError("invalid length")
            body = self.rfile.read(length)
            if len(body) != length:
                raise ValueError("incomplete request")
            code = json.loads(body).get("code")
            if not isinstance(code, str) or len(code.encode()) > MAX_SOURCE:
                raise ValueError("invalid source")
            self.reply(200, run_request(code, isolated=True))
        except Exception:
            self.reply(500, {"error": "The sandbox could not finish this job."})
        finally:
            self.server.finished = True


def main():
    # Trusted root controller; its compile/run children drop to 65532 with
    # zero capabilities. Those children cannot cancel this outer watchdog.
    if os.getuid() != 0:
        raise SystemExit("controller must start as root")
    watchdog = threading.Timer(45, lambda: os._exit(124))
    watchdog.daemon = True
    watchdog.start()
    server = HTTPServer(("0.0.0.0", 8080), Handler)
    server.finished = False
    server.timeout = 1
    try:
        while not server.finished:
            server.handle_request()
    finally:
        server.server_close()
        watchdog.cancel()


if __name__ == "__main__":
    main()
