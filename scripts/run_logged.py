#!/usr/bin/env python3
"""Run a command with a retained log, exit status and resource summary.

    python3 scripts/run_logged.py --output NEW_DIRECTORY -- COMMAND [ARG ...]

Use the agent's background-command facility for completion notifications.
This wrapper stays attached to the command and forwards interruption signals.
It does not select tests, enter an environment, or supply acceptance evidence.
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


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path,
                        help="new directory for command.log and result.json")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
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


if __name__ == "__main__":
    sys.exit(main())
