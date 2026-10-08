#!/usr/bin/env python3
"""Compile only visitor Landin source with an image's prebuilt refine."""
import json
import os
from pathlib import Path
import selectors
import signal
import subprocess
import sys
import time

MAX_SOURCE = 8192
MAX_OUTPUT = 12_000


def restricted_command(command, seconds):
    """Drop privileges and bound children of the trusted microVM controller."""
    return ["/usr/bin/prlimit", "--as=536870912", f"--cpu={max(1, int(seconds))}",
            "--nproc=64", "--fsize=16777216", "--nofile=64", "--core=0", "--",
            "/usr/bin/setpriv", "--reuid=65532", "--regid=65532", "--clear-groups",
            "--bounding-set=-all", "--no-new-privs", "--", *command]


def execute(command, seconds, maximum=MAX_OUTPUT, input_bytes=None, cwd="/work", isolated=False):
    """Bound combined stdout/stderr while reading, rather than after exit."""
    if isolated:
        command = restricted_command(command, seconds)
    process = subprocess.Popen(command, stdin=(subprocess.PIPE if input_bytes is not None else subprocess.DEVNULL),
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               start_new_session=True, cwd=cwd)
    output, status = bytearray(), "finished"
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    sent = 0
    if input_bytes is not None:
        os.set_blocking(process.stdin.fileno(), False)
        selector.register(process.stdin, selectors.EVENT_WRITE)
    deadline = time.monotonic() + seconds
    try:
        while selector.get_map():
            left = deadline - time.monotonic()
            if left <= 0:
                status = "timeout"
                break
            for key, _ in selector.select(min(left, 0.1)):
                if key.fileobj is process.stdin:
                    try:
                        sent += os.write(process.stdin.fileno(), input_bytes[sent:sent + 4096])
                    except BrokenPipeError:
                        sent = len(input_bytes)
                    if sent >= len(input_bytes):
                        selector.unregister(process.stdin)
                        process.stdin.close()
                    continue
                chunk = os.read(key.fileobj.fileno(), 4096)
                if not chunk:
                    selector.unregister(key.fileobj)
                else:
                    output.extend(chunk[:max(0, maximum - len(output))])
                    if len(output) >= maximum:
                        status = "output_limit"
                        break
            if status != "finished":
                break
        if status == "finished":
            try:
                process.wait(timeout=max(0.001, deadline - time.monotonic()))
            except subprocess.TimeoutExpired:
                status = "timeout"
    finally:
        # Kill the entire process group on success too: background children
        # must not survive. Container removal also kills detached descendants.
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait(timeout=2)
        process.stdout.close()
        if process.stdin is not None and not process.stdin.closed:
            process.stdin.close()
        selector.close()
    return status, process.returncode, output.decode("utf-8", errors="replace")


def run_request(code, isolated=False):
    if (not isinstance(code, str) or not code.strip() or "\0" in code
            or len(code.encode("utf-8")) > MAX_SOURCE):
        raise ValueError("invalid source")
    compiler = Path("/opt/landin/compiler.sha256").read_text().split()[0]
    module = Path("/work/main")
    module.mkdir()
    if isolated:
        os.chown(module, 65532, 65532)
    (module / "main.ldn").write_text(code)
    status, result, output = execute([
        "/opt/landin/refine", "--root=/work", "--root=/opt/landin",
        "--target=linux-x86-64", "--emit=exe", "-o", "/work/program",
        "/work/main"], 15, isolated=isolated)
    if status == "finished" and result == 0:
        status, result, run_output = execute(["/work/program"], 2,
                                              max(1, MAX_OUTPUT - len(output.encode("utf-8"))),
                                              isolated=isolated)
        output += run_output
        if status == "finished":
            status = "terminated" if result < 0 else "ran"
    elif status == "finished":
        status = "compile_error"
    # Replacement of invalid UTF-8 can expand byte length. Clip once more to
    # keep the wire response bounded, including compiler diagnostics.
    output = output.encode("utf-8")[:MAX_OUTPUT].decode("utf-8", errors="ignore")
    return dict(status=status, exitCode=result, output=output, compiler=compiler)


def main():
    payload = sys.stdin.buffer.read(16_385)
    if len(payload) > 16_384:
        raise ValueError("request too large")
    print(json.dumps(run_request(json.loads(payload).get("code"))))


if __name__ == "__main__":
    main()
