#!/usr/bin/env python3
"""Run every scripted session through `refine lsp` itself.

The test program runs each `session.lsp` in-process against a fake channel
and a fake filesystem.  This runs the same transcripts through the real
executable over pipes, so standard input and output, the C channel adapter
and the native filesystem are what carry them.  It never builds: pass an
already-built refine.

Deliberate real-host exception: each session's `workspace/` is copied into
its own temporary directory, and `file:///workspace` in what is sent and
what is expected is that directory's URI, so the expected bytes are the
transcript's own with only that prefix changed.  A `pause` is a moment the
script waits for the server to have answered what came before it.
"""
import argparse
import json
import os
from pathlib import Path
import select
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.parse

HERE = Path(__file__).resolve().parent
PREFIX = "file:///workspace"
SECONDS = 60


def framed(body):
    data = body.encode("utf-8", "surrogateescape")
    return b"Content-Length: %d\r\n\r\n" % len(data) + data


def unescaped(text):
    out, index = [], 0
    while index < len(text):
        if text[index] == "\\" and index + 1 < len(text):
            out.append({"r": "\r", "n": "\n"}.get(text[index + 1],
                                                  text[index + 1]))
            index += 2
        else:
            out.append(text[index])
            index += 1
    return "".join(out).encode("utf-8", "surrogateescape")


def parse(transcript):
    """(chunks of input split at each pause, disk edits, messages, status)."""
    chunks, edits, current, expected, status = [], [], b"", [], None
    for line in transcript.split("\n")[:-1]:
        if line.startswith("-> "):
            current += framed(line[3:])
        elif line.startswith("raw: "):
            current += unescaped(line[5:])
        elif line == "pause":
            chunks.append(current)
            edits.append([])
            current = b""
        elif line.startswith("disk: "):
            uri, content = line[6:].split(" | ", 1)
            edits[-1].append((urllib.parse.urlparse(uri).path,
                              unescaped(content)))
        elif line.startswith("<- "):
            expected.append(line[3:])
        elif line.startswith("exit: "):
            status = int(line[6:])
    chunks.append(current)
    return chunks, edits, expected, status


def messages(output):
    """Each framed body in output, in order."""
    found = []
    while output:
        head, separator, rest = output.partition(b"\r\n\r\n")
        if not separator:
            break
        length = int(head.split(b":", 1)[1])
        found.append(rest[:length].decode("utf-8", "surrogateescape"))
        output = rest[length:]
    return found



def run(refine, name):
    directory = HERE / name
    transcript = (directory / "session.lsp").read_text(encoding="utf-8")
    with tempfile.TemporaryDirectory(prefix="landin-lsp-") as scratch:
        workspace = Path(scratch).resolve() / "workspace"
        if (directory / "workspace").is_dir():
            shutil.copytree(directory / "workspace", workspace)
        else:
            workspace.mkdir()
        uri = "file://" + urllib.parse.quote(str(workspace), safe="/")
        transcript = transcript.replace(PREFIX, uri)
        transcript = transcript.replace(
            "file://localhost/workspace",
            "file://localhost" + urllib.parse.quote(str(workspace), safe="/"))
        chunks, edits, expected, status = parse(transcript)

        process = subprocess.Popen([refine, "lsp", "--stdio"],
                                   stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE)
        output = b""
        deadline = time.monotonic() + SECONDS
        for index, chunk in enumerate(chunks):
            process.stdin.write(chunk)
            process.stdin.flush()
            if index == len(chunks) - 1:
                break
            # A pause: wait until the server has said everything it will
            # say about what came before, by reading until it is quiet.
            quiet_since = time.monotonic()
            while time.monotonic() - quiet_since < 1.0:
                if time.monotonic() > deadline:
                    process.kill()
                    return "timed out"
                ready, _, _ = select.select([process.stdout], [], [], 0.1)
                if ready:
                    data = os.read(process.stdout.fileno(), 65536)
                    if not data:
                        break
                    output += data
                    quiet_since = time.monotonic()
            for path, content in edits[index]:
                Path(path).write_bytes(content)
        #  communicate flushes and closes standard input itself, and a
        #  Python before 3.13 refuses to flush one already closed.
        try:
            rest, errors = process.communicate(timeout=SECONDS)
        except subprocess.TimeoutExpired:
            process.kill()
            return "timed out"
        output += rest
        sent = messages(output)
        problems = []
        for index in range(max(len(sent), len(expected))):
            if index >= len(sent):
                problems.append("message %d was never sent: %s"
                                % (index + 1, expected[index][:200]))
            elif index >= len(expected):
                problems.append("message %d was not expected: %s"
                                % (index + 1, sent[index][:200]))
            elif sent[index] != expected[index]:
                problems.append("message %d differs:\n  expected %s\n"
                                "  sent     %s" % (index + 1,
                                                    expected[index][:400],
                                                    sent[index][:400]))
        if process.returncode != status:
            problems.append("exit status %d, not %d"
                            % (process.returncode, status))
        if b"defect" in errors:
            problems.append("stderr: " + errors.decode(errors="replace"))
        return "\n".join(problems)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--refine", required=True)
    arguments = parser.parse_args()
    refine = os.path.abspath(arguments.refine)
    failed = 0
    names = sorted(entry.name for entry in HERE.iterdir()
                   if (entry / "session.lsp").is_file())
    for name in names:
        problem = run(refine, name)
        print("%-24s %s" % (name, "FAIL" if problem else "ok"))
        if problem:
            print("  " + problem.replace("\n", "\n  "))
            failed += 1
    print("%d sessions, %d failed" % (len(names), failed))
    return 1 if failed or not names else 0


if __name__ == "__main__":
    sys.exit(main())
