#!/usr/bin/env python3
"""Run a command with a retained log, exit status and resource summary.

    python3 scripts/run_logged.py --output NEW_DIRECTORY -- COMMAND [ARG ...]
    python3 scripts/run_logged.py --wait DIRECTORY [--timeout SECONDS]

Use the agent's background-command facility for completion notifications.
This wrapper stays attached to the command and forwards interruption signals.
It does not select tests, enter an environment, or supply acceptance evidence.

`--wait` is the blocking wait for an agent that receives no notification, a
subagent among them: it returns the run's own summary and exit status once
`result.json` exists, or after SECONDS (540 by default, inside a
ten-minute tool call) exits 124 saying the run is still going, so the same
call can simply be made again.  A run whose wrapper died before writing a
result exits 125, rather than being waited for until the timeout.  It
replaces sleep loops over the log and `pgrep -f`, whose pattern matches the
polling shell's own command line, so that a wait on a process ending never
ends.
"""
import argparse
import datetime
import json
import os
from pathlib import Path
import resource
import signal
import subprocess
import sys
import time


def timestamp():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


STILL_RUNNING = 124
NO_RESULT = 125


def alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def last_line(log):
    """The log's last nonempty line, for a run still going."""
    try:
        with log.open("rb") as stream:
            stream.seek(0, os.SEEK_END)
            stream.seek(max(0, stream.tell() - 4096))
            lines = stream.read().decode(errors="replace").splitlines()
    except OSError:
        return ""
    return next((line for line in reversed(lines) if line.strip()), "")


def summarise(result, log, result_path):
    exit_status = result["exit_status"]
    print("exit=%d elapsed=%.2fs user=%.2fs system=%.2fs peak-child-rss=%.1fMiB"
          % (exit_status, result["elapsed_seconds"], result["user_cpu_seconds"],
             result["system_cpu_seconds"],
             result["peak_child_rss_bytes"] / (1024 * 1024)))
    print("result: %s" % result_path)
    if exit_status:
        # Bound failure output without losing the complete diagnostic log.
        with log.open("rb") as stream:
            stream.seek(0, os.SEEK_END)
            stream.seek(max(0, stream.tell() - 16384))
            tail = stream.read().decode(errors="replace").splitlines()[-20:]
        print("last log lines (up to 16 KiB; complete output in command.log):")
        for line in tail:
            print(line)
    return exit_status


def wait(output, timeout, parser):
    """Block until the run in `output` ends, or `timeout` seconds pass."""
    output = output.absolute()
    result_path = output / "result.json"
    running = output / "running.json"
    deadline = time.monotonic() + timeout
    # A run launched in the background a moment ago may not have made its
    # directory yet; a mistyped one is refused once this grace has passed.
    appear_by = time.monotonic() + min(timeout, 30)
    while True:
        if result_path.exists():
            result = json.loads(result_path.read_text())
            print("log: %s" % result["log"])
            return summarise(result, Path(result["log"]), result_path)
        if running.exists():
            pid = json.loads(running.read_text())["pid"]
            if not alive(pid):
                # The wrapper writes its result before it exits, so look once
                # more before calling the run lost.
                if result_path.exists():
                    continue
                print("run in %s ended without a result: its wrapper, pid %d,"
                      " is gone (killed?); see %s"
                      % (output, pid, output / "command.log"))
                return NO_RESULT
        elif time.monotonic() > appear_by:
            parser.error("%s holds no run_logged.py run" % output)
        if time.monotonic() >= deadline:
            line = last_line(output / "command.log")
            print("still running after %ds: %s" % (timeout, output))
            if line:
                print("last log line: %s" % line)
            print("wait again with the same command")
            return STILL_RUNNING
        time.sleep(1)


def main(argv=None):
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    which = parser.add_mutually_exclusive_group(required=True)
    which.add_argument("--output", type=Path,
                       help="new directory for command.log and result.json")
    which.add_argument("--wait", type=Path, metavar="DIRECTORY",
                       help="block until the run writing DIRECTORY ends")
    parser.add_argument("--timeout", type=float, default=540,
                        help="seconds --wait blocks before exiting 124")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    if args.wait is not None:
        if args.command:
            parser.error("--wait takes no command")
        return wait(args.wait, args.timeout, parser)
    command = args.command
    if command[:1] == ["--"]:
        command = command[1:]
    if not command:
        parser.error("name the command after --")
    output = args.output.absolute()
    try:
        output.mkdir(mode=0o700, parents=True, exist_ok=False)
    except OSError as error:
        parser.error("cannot create a new output directory %s: %s"
                     % (output, error))

    log = output / "command.log"
    result_path = output / "result.json"
    result = {"schema": 1, "command": command, "cwd": os.getcwd(),
              "started_at": timestamp(), "log": str(log)}
    started = time.monotonic()
    before = resource.getrusage(resource.RUSAGE_CHILDREN)
    interrupted = None
    child = None

    def forward(number, _frame):
        nonlocal interrupted
        interrupted = number
        if child is not None:
            try:
                os.killpg(child.pid, number)
            except ProcessLookupError:
                pass

    previous = {number: signal.signal(number, forward)
                for number in (signal.SIGINT, signal.SIGTERM)}
    (output / "running.json").write_text(json.dumps(
        {"pid": os.getpid(), "started_at": result["started_at"],
         "command": command, "log": str(log)}) + "\n")
    print("log: %s" % log, flush=True)
    try:
        with log.open("wb") as stream:
            try:
                child = subprocess.Popen(command, stdout=stream,
                                         stderr=subprocess.STDOUT,
                                         start_new_session=True)
                # An interruption can arrive before Popen assigns child.
                if interrupted is not None:
                    forward(interrupted, None)
                returncode = child.wait()
            except OSError as error:
                returncode = 127 if isinstance(error, FileNotFoundError) else 126
                result["launch_error"] = str(error)
                stream.write(("cannot launch command: %s\n" % error).encode())
    finally:
        for number, handler in previous.items():
            signal.signal(number, handler)

    after = resource.getrusage(resource.RUSAGE_CHILDREN)
    exit_status = (128 + interrupted if interrupted is not None else
                   128 - returncode if returncode < 0 else returncode)
    result.update(
        finished_at=timestamp(), elapsed_seconds=time.monotonic() - started,
        returncode=returncode, exit_status=exit_status,
        interrupted_by=interrupted,
        user_cpu_seconds=after.ru_utime - before.ru_utime,
        system_cpu_seconds=after.ru_stime - before.ru_stime,
        # Darwin reports bytes; Linux reports KiB. This is a process peak,
        # not the simultaneous memory footprint of the entire process tree.
        peak_child_rss_bytes=after.ru_maxrss * (1 if sys.platform == "darwin"
                                               else 1024))
    temporary = output / "result.json.tmp"
    temporary.write_text(json.dumps(result, indent=2) + "\n")
    temporary.replace(result_path)
    return summarise(result, log, result_path)


if __name__ == "__main__":
    sys.exit(main())
