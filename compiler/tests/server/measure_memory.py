#!/usr/bin/env python3
"""Linux native server memory comparison; no compiler changes or rebuilds.

The temporary LD_PRELOAD probe samples glibc's live allocation count whenever
stdin blocks for more protocol input, and once after session teardown. This
separates retained allocations from allocator RSS retention. The process's VmHWM peak
RSS records transient memory too, but is a process-wide high-water mark, not
an exact measure of syntax-transfer storage alone. Run both binaries with the
same generated workspace and report results without imposing a byte cap.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import select
import subprocess
import sys
import tempfile
import time

PROBE = r'''
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <malloc.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>
static int logfd = -1;
static long highest_peak;
static void sample(const char *phase) {
    if (logfd < 0) return;
    struct mallinfo2 m = mallinfo2();
    /* VmHWM belongs to this executable's memory map. ru_maxrss can retain
       the spawning Python process's resident-set floor across exec. */
    char status[4096];
    long peak = -1;
    int fd = open("/proc/self/status", O_RDONLY);
    if (fd >= 0) {
        long size = syscall(SYS_read, fd, status, sizeof status - 1);
        close(fd);
        if (size > 0) {
            status[size] = 0;
            char *field = strstr(status, "VmHWM:");
            if (field) peak = strtol(field + 6, NULL, 10);
        }
    }
    /* Kernel RSS accounting is approximate; retain the highest observed
       high-water value rather than interpreting small counter reversals. */
    if (peak > highest_peak) highest_peak = peak;
    peak = highest_peak;
    char line[160];
    int n = snprintf(line, sizeof line, "%s %zu %ld\n", phase,
                     (size_t)m.uordblks + (size_t)m.hblkhd, peak);
    syscall(SYS_write, logfd, line, (size_t)n);
}
__attribute__((constructor)) static void start(void) {
    logfd = open(getenv("LANDIN_MEMORY_LOG"), O_WRONLY|O_CREAT|O_TRUNC, 0600);
}
ssize_t read(int fd, void *buffer, size_t size) {
    static ssize_t (*next)(int, void *, size_t);
    if (!next) next = dlsym(RTLD_NEXT, "read");
    if (fd == 0) sample("idle");
    return next(fd, buffer, size);
}
__attribute__((destructor)) static void stop(void) {
    sample("teardown");
    if (logfd >= 0) close(logfd);
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--refine", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if sys.platform != "linux":
        parser.error("the allocator and VmHWM probe requires Linux/glibc")
    with tempfile.TemporaryDirectory(prefix="landin-server-memory-") as temp:
        root = Path(temp)
        c = root / "probe.c"
        c.write_text(PROBE)
        probe = root / "probe.so"
        subprocess.run(["cc", "-shared", "-fPIC", "-O2", str(c), "-ldl",
                        "-o", str(probe)], check=True)
        shared = root / "shared"
        shared.mkdir()
        shared_text = routines(500)
        (shared / "shared.ldn").write_text(shared_text)
        text = "import shared\n\n" + routines(300)
        text += "main: () -> (status: i32) =\n    status = i32 (shared.f000 (0))\nend main\n"
        broken = "broken: () -> none =\n    x := (\nend broken\n"
        paths = []
        for index in range(4):
            directory = root / f"app{index}"
            directory.mkdir()
            source = directory / "main.ldn"
            source.write_text(text)
            (directory / "broken.ldn").write_text(broken if index % 2 else "")
            paths.append(source)
        result = {"workload": {"modules": 4, "routines_per_module": 300,
                              "shared_routines": 500, "broken_modules": 2,
                              "same_queries": 40, "alternating_queries": 40,
                              "edits": 20, "units": "bytes and KiB"}}
        for name, binary in (("baseline", args.baseline), ("combined", args.refine)):
            result[name] = run(binary.resolve(), probe, root, paths, text, name)
        args.output.write_text(json.dumps(result, indent=2) + "\n")
        print(json.dumps(result, indent=2))


def routines(count):
    return "\n".join(f"pub f{i:03}: (x: u32) -> (y: u32) =\n    y = x + {i}\nend f{i:03}\n"
                     for i in range(count))


def run(binary, probe, root, paths, text, label):
    log = root / f"{label}.log"
    env = dict(os.environ, LD_PRELOAD=str(probe), LANDIN_MEMORY_LOG=str(log))
    process = subprocess.Popen([str(binary), "lsp", "--stdio"], env=env,
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE)
    buffer = b""
    identifier = 0
    seen = []
    samples = []

    def send(method, params=None, request=False):
        nonlocal identifier
        message = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            message["params"] = params
        if request:
            identifier += 1
            message["id"] = identifier
        data = json.dumps(message).encode()
        process.stdin.write(b"Content-Length: %d\r\n\r\n" % len(data) + data)
        process.stdin.flush()
        if request:
            receive(identifier)

    def receive(wanted):
        nonlocal buffer
        deadline = time.monotonic() + 60
        while True:
            while b"\r\n\r\n" in buffer:
                header, rest = buffer.split(b"\r\n\r\n", 1)
                length = int(header.split(b":", 1)[1])
                if len(rest) < length:
                    break
                message = json.loads(rest[:length])
                buffer = rest[length:]
                seen.append(message)
                if message.get("id") == wanted:
                    if "error" in message:
                        raise RuntimeError(message)
                    return
            if time.monotonic() > deadline:
                raise TimeoutError("server response")
            if select.select([process.stdout], [], [], 1)[0]:
                data = os.read(process.stdout.fileno(), 65536)
                if not data:
                    raise RuntimeError(process.stderr.read().decode())
                buffer += data

    def sample(phase):
        # The response precedes cleanup. Wait for the next blocking read's
        # sample, after the server has returned from its analysis visitor.
        time.sleep(0.03)
        lines = log.read_text().splitlines()
        event, live, peak = lines[-1].split()
        samples.append({"phase": phase, "event": event,
                        "live_bytes": int(live), "peak_rss_kib": int(peak)})

    def hover(index):
        send("textDocument/hover", {"textDocument": {"uri": paths[index].as_uri()},
                                   "position": {"line": 2, "character": 5}}, True)

    send("initialize", {"capabilities": {}, "initializationOptions":
                        {"roots": [root.as_uri()]}}, True)
    sample("initialized")
    for index, source in enumerate(paths):
        send("textDocument/didOpen", {"textDocument": {
            "uri": source.as_uri(), "languageId": "landin", "version": 1,
            "text": text}})
        for previous in range(index + 1):
            hover(previous)
        sample(f"open-{index + 1}-cached")
    for turn in range(40):
        hover(0)
    sample("same-40")
    for turn in range(40):
        hover(turn % 4)
    sample("alternating-40")
    for version in range(2, 22):
        send("textDocument/didChange", {"textDocument": {
            "uri": paths[0].as_uri(), "version": version},
            "contentChanges": [{"text": text + ("\n" if version % 2 else "")} ]})
        for index in range(4):
            hover(index)
        sample(f"edit-{version - 1}")
    # Closing an imported document invalidates analyses in remaining modules.
    imported = root / "shared/shared.ldn"
    send("textDocument/didOpen", {"textDocument": {"uri": imported.as_uri(),
         "languageId": "landin", "version": 1, "text": imported.read_text()}})
    hover(0)
    sample("import-open")
    send("textDocument/didClose", {"textDocument": {"uri": imported.as_uri()}})
    hover(0)
    sample("import-close")
    for source in paths:
        send("textDocument/didClose", {"textDocument": {"uri": source.as_uri()}})
    send("shutdown", request=True)
    sample("all-closed")
    send("exit")
    output, errors = process.communicate(timeout=60)
    if process.returncode != 0 or errors or output:
        raise RuntimeError((process.returncode, output, errors))
    event, live, peak = log.read_text().splitlines()[-1].split()
    samples.append({"phase": "session-teardown", "event": event,
                    "live_bytes": int(live), "peak_rss_kib": int(peak)})
    diagnostics = [m for m in seen if m.get("method") == "textDocument/publishDiagnostics"]
    codes = sorted({d["code"] for m in diagnostics for d in m["params"]["diagnostics"]})
    if "L0102" not in codes:
        raise AssertionError("mixed broken source was not analysed")
    if any(code not in ("L0102", "L0103") for code in codes):
        raise AssertionError(f"unexpected diagnostics: {codes}")
    return {"compiler": str(binary),
            "compiler_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
            "samples": samples,
            "requests": identifier, "publications": len(diagnostics),
            "diagnostic_codes": codes}


if __name__ == "__main__":
    main()
