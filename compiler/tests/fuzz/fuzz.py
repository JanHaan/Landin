#!/usr/bin/env python3
"""Mutate the corpus and drive `refine lsp` with it, and keep what breaks it.

Every positive, negative, runtime and ABI fixture directory with exactly one
direct `.ldn` file, and every reproducer in `reproducers/`, is a seed. Each
mutant is one of seven mutations of one seed, chosen by a splitmix64 generator
from its own seed number, so a seed number names one mutant on every host and
every Python. The seed's file is opened under the repository root, changed
to the mutant, and asked for hover, a definition, formatting and code actions
at positions the same generator picks.

A mutant is a hit when the server stops, or does not answer within the
per-response bound, or answers a request with anything but a result or
an error of the protocol, or reports a compiler defect, on its log or
through showMessage.  A diagnostic is never a hit: refusing a mutant is
what a mutant should get.  Each hit is written as OUT/hit-SEED.ldn beside
its transcript, OUT/hit-SEED.lsp, and the run fails.

One server serves a batch of mutants, each its own document, closed after
it, so a defect that only a long session reaches can show, and a hit
restarts the server.  `--batch` runs the old oracle instead, `refine FILE`
on each mutant, where any exit but 0 or 1 is a hit.  `--reduce FILE` deletes
lines from a hit, sixteen at a time down to one, for as long as it still
breaks the server.

The gate runs `fuzz.py --refine PATH --seed 500000 --rounds 1`, under a
memory bound the runner's limit sets.  Standard library only.
"""
import argparse
import json
import os
from pathlib import Path
import re
import resource
import select
import subprocess
import sys
import tempfile
import time

HERE = Path(__file__).resolve().parent
FIXTURES = HERE.parent / "fixtures"
ROOT = HERE.parents[2]
MASK = (1 << 64) - 1

KEYWORDS = ("end begin match if then else elsif while do loop for in break "
            "continue with return fail try defer undo sink inout escaping "
            "from ptr addr mut type struct variant atom concept is any "
            "unchecked zeroed lenof sizeof when complete public import fixed "
            "range").split()
PUNCTUATION = ["(", ")", "[", "]", ":", "=", ",", ".", "..", "..<", "->",
               "!", "|", "+%", "<<", "-", '"', "'", "--", "{-", "-}", "\n",
               " ", "0x", "1e999", "99999999999999999999999999"]


class Generator:
    """splitmix64: the same numbers from the same seed everywhere."""

    def __init__(self, seed):
        self.state = seed & MASK

    def next(self):
        self.state = (self.state + 0x9E3779B97F4A7C15) & MASK
        z = self.state
        z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & MASK
        z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & MASK
        return z ^ (z >> 31)

    def below(self, bound):
        return self.next() % bound if bound > 0 else 0


def mutate(seed, text):
    """One of the seven mutations, as mutate.pl made them."""
    pick = Generator(seed)
    kind = pick.below(7)
    length = max(len(text), 1)
    if kind == 0:
        return text[:pick.below(length)]
    lines = text.split("\n")
    if kind == 1:
        del lines[pick.below(len(lines))]
        return "\n".join(lines)
    if kind == 2:
        copied = lines[pick.below(len(lines))]
        lines.insert(pick.below(len(lines)), copied)
        return "\n".join(lines)
    if kind == 3:
        words = list(re.finditer(r"\b[a-z_][a-z0-9_]*\b", text))
        if not words:
            return text
        word = words[pick.below(len(words))]
        return (text[:word.start()] + KEYWORDS[pick.below(len(KEYWORDS))]
                + text[word.end():])
    if kind == 4:
        at = pick.below(length)
        return text[:at] + PUNCTUATION[pick.below(len(PUNCTUATION))] + text[at:]
    if kind == 5:
        at = pick.below(length)
        return text[:at] + text[at + 1:]
    words = list(re.finditer(r"\S+", text))
    if len(words) < 2:
        return text
    first, second = (words[pick.below(len(words))],
                     words[pick.below(len(words))])
    if first.start() >= second.start():
        return text
    return (text[:first.start()] + second.group() + text[first.end():
            second.start()] + first.group() + text[second.end():])


def seeds():
    """(label, path, text) for every seed source, in a fixed order.

    An editor holds text, not bytes, so a byte that is not UTF-8 is read as
    it would show one: U+FFFD.  The scanner's own byte checks are the
    parser suite's to drive; what reaches a server is always UTF-8."""
    found = []
    for kind in ("positive", "negative", "runtime", "abi"):
        for directory in sorted((FIXTURES / kind).iterdir()):
            sources = sorted(directory.glob("*.ldn"))
            if len(sources) == 1:
                found.append((kind + "/" + directory.name, sources[0],
                              sources[0].read_bytes().decode(
                                  "utf-8", "replace")))
    for path in sorted((HERE / "reproducers").glob("*.ldn")):
        found.append(("reproducers/" + path.name, path,
                      path.read_bytes().decode("utf-8", "replace")))
    return found


def framed(message):
    data = json.dumps(message, ensure_ascii=False).encode(
        "utf-8", "surrogateescape")
    return b"Content-Length: %d\r\n\r\n" % len(data) + data


class Server:
    """One `refine lsp` process and what it has said."""

    def __init__(self, refine, memory, seconds):
        def limit():
            #  Darwin refuses to lower RLIMIT_AS, so there the bound is
            #  the host's own; the gate runs the lane on Linux, where it
            #  holds.  A refusal must not stop the server from starting.
            if memory:
                try:
                    resource.setrlimit(resource.RLIMIT_AS, (memory, memory))
                except (ValueError, OSError):
                    pass
        self.seconds = seconds
        self.process = subprocess.Popen(
            [refine, "lsp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, preexec_fn=limit)
        self.held = b""
        self.log = b""
        self.stderr_open = True
        self.transcript = []
        self.diagnostics = []
        self.next_id = 1
        self.request("initialize", {"capabilities": {},
                                    "initializationOptions": {
                                        "roots": [ROOT.as_uri()]}})
        self.notify("initialized", {})

    def send(self, message):
        self.transcript.append("-> " + json.dumps(message, ensure_ascii=False))
        try:
            self.process.stdin.write(framed(message))
            self.process.stdin.flush()
        except (BrokenPipeError, OSError):
            raise Broken("the server closed its input")

    def notify(self, method, params):
        self.send({"jsonrpc": "2.0", "method": method, "params": params})

    def receive(self):
        """The next message, or Broken."""
        deadline = time.monotonic() + self.seconds
        while True:
            head, separator, rest = self.held.partition(b"\r\n\r\n")
            if separator:
                fields = dict(line.split(b":", 1)
                              for line in head.split(b"\r\n") if b":" in line)
                length = int(fields.get(b"Content-Length", b"-1"))
                if length < 0:
                    raise Broken("a frame with no length")
                if len(rest) >= length:
                    body, self.held = rest[:length], rest[length:]
                    text = body.decode("utf-8", "surrogateescape")
                    self.transcript.append("<- " + text)
                    try:
                        return json.loads(text)
                    except ValueError:
                        raise Broken("a body that is not JSON")
            left = deadline - time.monotonic()
            if left <= 0:
                raise Broken("no answer within %d seconds" % self.seconds)
            ready, _, _ = select.select(
                [self.process.stdout] + ([self.process.stderr]
                                         if self.stderr_open else []),
                [], [], left)
            for stream in ready:
                data = os.read(stream.fileno(), 1 << 16)
                if stream is self.process.stderr:
                    if not data:
                        self.stderr_open = False
                    self.log += data
                    if b"defect" in self.log:
                        raise Broken("the server logged a defect")
                elif not data:
                    raise Broken("the server closed its output")
                else:
                    self.held += data

    def request(self, method, params):
        """The answer to a request; notifications on the way are checked."""
        number = self.next_id
        self.next_id += 1
        self.send({"jsonrpc": "2.0", "id": number, "method": method,
                   "params": params})
        while True:
            message = self.receive()
            if message.get("method") == "window/showMessage" and \
                    "defect" in message.get("params", {}).get("message", ""):
                raise Broken("the server reported a defect")
            if message.get("method") == "textDocument/publishDiagnostics":
                self.diagnostics.append(message["params"])
            if "id" not in message:
                continue
            if message["id"] != number:
                raise Broken("an answer to the wrong request")
            if "result" in message:
                return message["result"]
            error = message.get("error", {})
            if error.get("code") == -32603 or "defect" in str(error):
                raise Broken("the request failed: %s" % error)
            if not isinstance(error.get("code"), int):
                raise Broken("an answer with neither result nor error")
            return None

    def stop(self):
        """Shut down a server and report a failed or premature exit."""
        problem = ""
        exit_status = None
        try:
            status = self.process.poll()
            if status is not None:
                problem = "server stopped before shutdown, status %d" % status
            else:
                try:
                    self.request("shutdown", None)
                    self.notify("exit", None)
                    self.process.wait(timeout=self.seconds)
                except Broken as broken:
                    problem = "shutdown: %s" % broken
                except subprocess.TimeoutExpired:
                    problem = "shutdown timed out after %d seconds" % self.seconds
                except Exception as error:
                    problem = "shutdown: %s: %s" % (type(error).__name__, error)
                if problem and "closed its output" in problem and \
                        self.process.poll() is None:
                    try:
                        self.process.wait(timeout=self.seconds)
                    except subprocess.TimeoutExpired:
                        pass
            if not problem and self.process.returncode != 0:
                problem = "server exited after shutdown, status %d" % self.process.returncode
        finally:
            exit_status = self.process.poll()
            if self.process.poll() is None:
                self.process.kill()
                self.process.wait()
            for stream in (self.process.stdin, self.process.stdout,
                           self.process.stderr):
                try:
                    stream.close()
                except OSError:
                    pass
        if problem and exit_status is not None and "status" not in problem:
            problem += ", exit status %d" % exit_status
        return problem


class Broken(Exception):
    pass


def position(pick, text):
    lines = text.split("\n")
    line = pick.below(len(lines))
    return {"line": line, "character": pick.below(len(lines[line]) + 2)}


def serve_one(server, seed, path, original, mutant):
    """Give the server one mutant as an editor would."""
    uri = path.as_uri()
    pick = Generator(seed ^ 0x5DEECE66D)
    server.notify("textDocument/didOpen", {"textDocument": {
        "uri": uri, "languageId": "landin", "version": 1, "text": original}})
    server.notify("textDocument/didChange", {
        "textDocument": {"uri": uri, "version": 2},
        "contentChanges": [{"text": mutant}]})
    document = {"uri": uri}
    for method in ("textDocument/hover", "textDocument/definition"):
        server.request(method, {"textDocument": document,
                                "position": position(pick, mutant)})
    server.request("textDocument/formatting", {
        "textDocument": document,
        "options": {"tabSize": 4, "insertSpaces": True}})
    start = position(pick, mutant)
    server.request("textDocument/codeAction", {
        "textDocument": document,
        "range": {"start": start, "end": start},
        "context": {"diagnostics": []}})
    server.notify("textDocument/didClose", {"textDocument": document})


def check_imports(server):
    """Prove that rooted analysis reaches checking through fixture imports."""
    path = (FIXTURES / "negative/core-failing-needs-mutable-inner/main.ldn")
    uri = path.as_uri()
    server.diagnostics.clear()
    server.notify("textDocument/didOpen", {"textDocument": {
        "uri": uri, "languageId": "landin", "version": 1,
        "text": path.read_text(encoding="utf-8")}})
    try:
        # A response follows the diagnostics published for the open.
        server.request("textDocument/hover", {
            "textDocument": {"uri": uri},
            "position": {"line": 9, "character": 48}})
        if not any(report.get("uri") == uri and any(
                diagnostic.get("code") == "L0340" and
                diagnostic.get("range", {}).get("start", {}).get("line") == 9
                for diagnostic in report.get("diagnostics", []))
                for report in server.diagnostics):
            raise Broken("import check did not reach L0340 at line 10")
    finally:
        server.notify("textDocument/didClose", {"textDocument": {"uri": uri}})


def batch_one(refine, seconds, mutant):
    path = Path("/tmp") / ("landin-fuzz-%d.ldn" % os.getpid())
    path.write_bytes(mutant.encode("utf-8", "surrogateescape"))
    try:
        ran = subprocess.run([refine, str(path)], capture_output=True,
                             timeout=seconds)
    except subprocess.TimeoutExpired:
        return "timed out"
    finally:
        path.unlink(missing_ok=True)
    report = ran.stdout + ran.stderr
    if ran.returncode not in (0, 1) or b"internal compiler defect" in report:
        return "exit %d" % ran.returncode
    return ""


def reduce_one(refine, memory, seconds, out, text):
    """Test a reduction in a module containing only the trial source."""
    with tempfile.TemporaryDirectory(prefix="reduce-", dir=out) as directory:
        path = Path(directory).resolve() / "case.ldn"
        path.write_bytes(text.encode("utf-8", "surrogateescape"))
        server = Server(refine, memory, seconds)
        problem = ""
        try:
            serve_one(server, 0, path, text, text)
        except Broken as broken:
            problem = str(broken)
        finally:
            stopped = server.stop()
        return problem or stopped


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--refine", required=True)
    parser.add_argument("--seed", type=int, default=500000)
    parser.add_argument("--rounds", type=int, default=1)
    parser.add_argument("--out", default="")
    parser.add_argument("--seconds", type=int, default=10,
                        help="bound on one response")
    parser.add_argument("--memory", type=int, default=2 << 30,
                        help="address-space bound on the server, in bytes")
    parser.add_argument("--per-server", type=int, default=50)
    parser.add_argument("--batch", action="store_true",
                        help="run refine FILE on each mutant instead")
    parser.add_argument("--reduce", default="",
                        help="reduce this hit instead of fuzzing")
    arguments = parser.parse_args()
    refine = os.path.abspath(arguments.refine)
    out = Path(arguments.out or ("/tmp/landin-fuzz-%d" % arguments.seed))
    out.mkdir(parents=True, exist_ok=True)

    def breaks(text):
        """Whether a fresh server breaks on this trial in isolation."""
        if arguments.batch:
            return batch_one(refine, arguments.seconds, text)
        return reduce_one(refine, arguments.memory, arguments.seconds,
                          out, text)

    if arguments.reduce:
        text = Path(arguments.reduce).read_text(encoding="utf-8",
                                                errors="surrogateescape")
        lines = text.split("\n")
        for size in (16, 8, 4, 2, 1):
            changed = True
            while changed:
                changed = False
                index = len(lines) - size
                while index >= 0:
                    trial = lines[:index] + lines[index + size:]
                    if breaks("\n".join(trial)):
                        lines = trial
                        changed = True
                    index -= size
        reduced = out / "reduced.ldn"
        reduced.write_text("\n".join(lines), encoding="utf-8",
                           errors="surrogateescape")
        print("reduced to %d lines: %s" % (len(lines), reduced))
        return 0

    started = time.monotonic()
    total, hits = 0, 0
    server = None
    last = None

    def hit(seed, label, mutant, transcript, problem):
        nonlocal hits
        hits += 1
        (out / ("hit-%d.ldn" % seed)).write_bytes(
            mutant.encode("utf-8", "surrogateescape"))
        (out / ("hit-%d.lsp" % seed)).write_text(
            "\n".join(transcript) + "\n", encoding="utf-8",
            errors="surrogateescape")
        print("HIT seed=%d src=%s :: %s" % (seed, label, problem),
              flush=True)

    if not arguments.batch:
        server = Server(refine, arguments.memory, arguments.seconds)
        try:
            check_imports(server)
        except Broken as problem:
            print("import check failed: %s" % problem, file=sys.stderr)
            server.stop()
            return 1
        stopped = server.stop()
        if stopped:
            print("import check failed: %s" % stopped, file=sys.stderr)
            return 1
        server = None
    for label, path, original in seeds():
        for _ in range(arguments.rounds):
            seed = arguments.seed + total
            total += 1
            mutant = mutate(seed, original)
            problem = ""
            if arguments.batch:
                problem = batch_one(refine, arguments.seconds, mutant)
                transcript = []
            else:
                if server is None or total % arguments.per_server == 0:
                    if server is not None:
                        stopped = server.stop()
                        if stopped:
                            hit(*last[:3], last[3] + server.transcript,
                                stopped)
                    server = Server(refine, arguments.memory,
                                    arguments.seconds)
                    last = None
                try:
                    serve_one(server, seed, path, original, mutant)
                except Broken as broken:
                    problem = str(broken)
                transcript = server.transcript
                server.transcript = []
                if problem:
                    server.stop()
                    server = None
                    last = None
                else:
                    last = (seed, label, mutant, transcript)
            if problem:
                hit(seed, label, mutant, transcript, problem)
    if server is not None:
        stopped = server.stop()
        if stopped:
            hit(*last[:3], last[3] + server.transcript, stopped)
    print("total=%d hits=%d seconds=%d out=%s"
          % (total, hits, time.monotonic() - started, out))
    return 1 if hits else 0


if __name__ == "__main__":
    sys.exit(main())
