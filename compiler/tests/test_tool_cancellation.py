#!/usr/bin/env python3
"""Focused native cancellation controls, linking the actual production C.

Run with --native-only on Linux, Darwin or FreeBSD. No refine build is
needed. Readiness pipes replace timing assumptions. EOF on the inherited
event pipe establishes that both tool and descendant stopped; only the tool
claims to reap its descendant, and the invocation verifies its direct child
was reaped by the production helper. This is not full command-level evidence.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import selectors
import select
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time


def command_controls(refine, output):
    """Interrupt an actual compile/run at the tool's readiness boundary."""
    driver = shutil.which('clang' if sys.platform == 'darwin' else 'gcc')
    if not driver:
        raise SystemExit('native cancellation needs the host C driver')
    results = []
    for command in ('compile', 'run'):
        for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            root = output / (command + '-' + number.name)
            root.mkdir()
            temporary = root / 'temporary'
            temporary.mkdir()
            source = root / 'main.ldn'
            source.write_text('public main: () -> (code: i32) =\n    code = 5\nend main\n')
            product = root / 'program'
            product.write_bytes(b'prior product sentinel\x00\xff\n')
            prior = product.stat()
            assembly = root / 'program.s'
            assembly.write_bytes(b'pre-existing auxiliary sentinel\n')
            receipt = root / 'signal-receipt'
            wrapper = root / 'driver'
            wrapper.write_text('#!' + sys.executable + '\n' + '''import os, signal, sys
driver = ''' + repr(driver) + '''
if '-o' not in sys.argv:
    os.execv(driver, [driver] + sys.argv[1:])
def cancelled(number, frame):
    with open(os.environ['LANDIN_CANCEL_RECEIPT'], 'x') as out:
        out.write(str(number))
    raise SystemExit(128 + number)
for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
    signal.signal(number, cancelled)
os.write(int(os.environ['LANDIN_CANCEL_NOTIFY']), b'R')
os.read(int(os.environ['LANDIN_CANCEL_HOLD']), 1)
os.execv(driver, [driver] + sys.argv[1:])
''')
            wrapper.chmod(0o700)
            notify_read, notify_write = os.pipe()
            hold_read, hold_write = os.pipe()
            env = dict(os.environ, TMPDIR=str(temporary),
                       LANDIN_CANCEL_RECEIPT=str(receipt),
                       LANDIN_CANCEL_NOTIFY=str(notify_write),
                       LANDIN_CANCEL_HOLD=str(hold_read))
            argv = [str(refine), command, str(source),
                    '--toolchain=' + str(wrapper)]
            if command == 'compile':
                argv.extend(['-o', str(product)])
            process = subprocess.Popen(argv, cwd=root, env=env,
                                       stdout=subprocess.PIPE,
                                       stderr=subprocess.PIPE,
                                       pass_fds=(notify_write, hold_read),
                                       start_new_session=True)
            os.close(notify_write)
            os.close(hold_read)
            try:
                if not select.select([notify_read], [], [], 30)[0]:
                    raise TimeoutError('compiler tool did not reach readiness')
                if os.read(notify_read, 1) != b'R':
                    raise AssertionError('compiler tool closed readiness early')
                os.kill(process.pid, number)
                stdout, stderr = process.communicate(timeout=15)
            finally:
                # Release only this invocation's blocked probe on failure;
                # never signal a saved, potentially recycled tool group ID.
                try:
                    os.write(hold_write, b'R')
                except BrokenPipeError:
                    pass
                os.close(hold_write)
                os.close(notify_read)
                if process.poll() is None:
                    process.kill()
                    process.communicate(timeout=10)
            after = product.stat()
            passed = (process.returncode == 128 + number
                      and receipt.read_text() == str(int(number))
                      and product.read_bytes() == b'prior product sentinel\x00\xff\n'
                      and (prior.st_dev, prior.st_ino) == (after.st_dev, after.st_ino)
                      and assembly.read_bytes() == b'pre-existing auxiliary sentinel\n'
                      and not list(temporary.iterdir())
                      and not list(root.glob('.refine-publication-*'))
                      and not stdout)
            row = dict(command=argv, signal=int(number), exit_status=process.returncode,
                       passed=passed, stdout=stdout.decode(errors='replace'),
                       stderr=stderr.decode(errors='replace'), root=str(root))
            results.append(row)
            (output / 'command-results.json').write_text(json.dumps(results, indent=2) + '\n')
            print(('PASS ' if passed else 'FAIL ') + command + '-' + number.name,
                  flush=True)
            if not passed:
                raise AssertionError(row)
    return results


def run_case(executable, output, mode, number):
    number = int(number)
    label = mode + ("-" + signal.Signals(number).name if number else "")
    cwd = output / label
    cwd.mkdir()
    command = [str(executable), mode, str(int(number))]
    process = subprocess.Popen(command, cwd=cwd, stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               start_new_session=True)
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    received = bytearray()
    pending = bytearray()
    injected = False
    deadline = time.monotonic() + 20
    error = None
    eof = False
    try:
        while selector.get_map():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("event stream did not close after controller deadline")
            ready = selector.select(remaining)
            if not ready:
                raise TimeoutError("event stream deadline")
            block = os.read(process.stdout.fileno(), 4096)
            if not block:
                eof = True
                selector.unregister(process.stdout)
                break
            received.extend(block)
            pending.extend(block)
            while b"\n" in pending:
                line, _, tail = pending.partition(b"\n")
                pending = bytearray(tail)
                if line == b"READY":
                    if injected or not number:
                        raise AssertionError("unexpected readiness event")
                    os.kill(process.pid, number)
                    injected = True
                    if mode == "ignore":
                        process.stdin.write(b"R")
                        process.stdin.flush()
        process.wait(timeout=5)
    except (AssertionError, OSError, TimeoutError, subprocess.TimeoutExpired) as caught:
        error = str(caught)
    finally:
        selector.close()
        # The C controller has its own earlier deadline and calls the real
        # stop/reap helper on failure. This final guard only owns the still
        # unreaped subprocess, never a saved tool PID or a recycled group ID.
        if process.poll() is None:
            process.kill()
            process.wait(timeout=5)
        process.stdin.close()
        process.stdout.close()
        stderr = process.stderr.read().decode(errors="replace")
        process.stderr.close()
    stdout = received.decode(errors="replace")
    lines = stdout.splitlines()
    expected = {"DIRECT_REAPED", "PASS"}
    if mode == "ignore":
        expected.add("TOOL_INHERITED_IGNORE")
    if mode in ("cancel", "before", "stubborn"):
        expected.update((f"TOOL_SIGNAL {number}", f"DESCENDANT_SIGNAL {number}"))
        if mode != "stubborn":
            expected.add("DESCENDANT_REAPED_BY_TOOL")
    passed = (error is None and process.returncode == 0 and not stderr
              and eof and expected.issubset(lines) and not pending
              and injected == bool(number))
    result = dict(case=label, command=command, cwd=str(cwd),
                  exit_status=process.returncode, stdout=stdout, stderr=stderr,
                  error=error, passed=passed, event_pipe_eof=eof)
    (cwd / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(("PASS " if passed else "FAIL ") + label, flush=True)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--native-only", action="store_true",
                        help="test the production POSIX helper without refine")
    parser.add_argument('--refine', type=Path,
                        help='also interrupt actual compile/run commands')
    parser.add_argument("--cc", default=os.environ.get("CC", "cc"))
    parser.add_argument("--output", type=Path,
                        help="new directory for retained binaries/logs/results")
    args = parser.parse_args()
    if args.native_only == bool(args.refine):
        parser.error('give --native-only or --refine PATH')
    repo = Path(__file__).resolve().parents[2]
    output = (args.output.absolute() if args.output else
              Path(tempfile.mkdtemp(prefix="landin-tool-cancellation-")))
    if args.output:
        output.mkdir(parents=True)
    production = repo / "compiler/ada/src/platform/landin_tool_process.c"
    harness = repo / "compiler/tests/tool_cancellation.c"
    executable = output / "tool-cancellation"
    cc = shlex.split(args.cc)
    command = [*cc, "-std=c11", "-Wall", "-Wextra", "-Werror", "-pedantic",
               "-pthread", str(production), str(harness), "-o", str(executable)]
    print("evidence: " + str(output), flush=True)
    compiled = subprocess.run(command, capture_output=True, text=True, timeout=60)
    (output / "compile.log").write_text(compiled.stdout + compiled.stderr)
    version = subprocess.run([*cc, "--version"], capture_output=True,
                             text=True, timeout=10)
    summary = dict(scope="FILTERED native-only production POSIX helper",
                   production=str(production), production_sha256=hashlib.sha256(
                       production.read_bytes()).hexdigest(),
                   harness_sha256=hashlib.sha256(harness.read_bytes()).hexdigest(),
                   cc_version=version.stdout + version.stderr,
                   compile_command=command, compile_exit=compiled.returncode,
                   cases=[])
    result_path = output / "results.json"
    result_path.write_text(json.dumps(summary, indent=2) + "\n")
    if compiled.returncode:
        raise SystemExit("compile failed: " + str(output / "compile.log"))
    for mode, number in [("normal", 0)] + [
            (mode, number) for mode in ("cancel", "before", "ignore", "stubborn")
            for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)]:
        result = run_case(executable, output, mode, number)
        summary["cases"].append(result)
        result_path.write_text(json.dumps(summary, indent=2) + "\n")
    passed = sum(row["passed"] for row in summary["cases"])
    print(f"{passed}/{len(summary['cases'])} native controls passed; {result_path}")
    if passed != len(summary["cases"]):
        raise SystemExit(1)
    if args.refine:
        summary['commands'] = command_controls(args.refine.resolve(), output)
        result_path.write_text(json.dumps(summary, indent=2) + '\n')


if __name__ == "__main__":
    main()
