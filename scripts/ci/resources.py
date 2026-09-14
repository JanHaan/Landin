"""Native acceptance containment checks and bounded command supervision."""
import os
from pathlib import Path
import selectors
import signal
import subprocess
import threading
import time

from common import Invalid, require, validate_limits


def containment(policy, proc=Path("/proc/self/cgroup"), mount=Path("/sys/fs/cgroup")):
    """Require explicit limits on our cgroup; never mutate host configuration."""
    rows = proc.read_text().splitlines()
    require(len(rows) == 1 and rows[0].startswith("0::/"),
            "acceptance requires a unified cgroup v2 hierarchy")
    group = rows[0][3:]
    require(".." not in group.split("/"), "invalid native cgroup membership")
    directory = mount / group.lstrip("/")
    values = {"cgroup": group}
    for name, key in (("memory.max", "memory_bytes"), ("memory.swap.max", "swap_bytes")):
        try:
            value = (directory / name).read_text().strip()
        except OSError as exc:
            raise Invalid("cannot verify native memory containment: " + str(exc)) from exc
        require(value.isascii() and value.isdecimal(),
                "acceptance requires a finite " + name + " on " + str(directory))
        values[key] = int(value)
    return validate_limits(values, policy)


def kill_owned_groups(pid):
    """Include compiler tool groups inside the command's dedicated session."""
    groups = {pid}
    proc = Path("/proc")
    if proc.is_dir():
        for entry in proc.iterdir():
            if entry.name.isdecimal():
                try:
                    fields = (entry / "stat").read_text().rsplit(")", 1)[1].split()
                    if int(fields[3]) == pid:
                        groups.add(int(fields[2]))
                except (OSError, ValueError, IndexError):
                    # A process can exit while its proc entry is inspected.
                    continue
    # Freeze known groups first: ordinary tool creation cannot continue while
    # they are stopped. Then collect any group created during that snapshot.
    for group in groups:
        try:
            os.killpg(group, signal.SIGSTOP)
        except ProcessLookupError:
            pass
    if proc.is_dir():
        for entry in proc.iterdir():
            if entry.name.isdecimal():
                try:
                    fields = (entry / "stat").read_text().rsplit(")", 1)[1].split()
                    if int(fields[3]) == pid:
                        groups.add(int(fields[2]))
                except (OSError, ValueError, IndexError):
                    continue
    for group in groups:
        try:
            os.killpg(group, signal.SIGKILL)
        except ProcessLookupError:
            pass


def terminate(process):
    """Stop owned tool groups even after the original group leader exits."""
    kill_owned_groups(process.pid)
    process.wait(timeout=5)


def oom_events(limits, mount=Path("/sys/fs/cgroup")):
    path = mount / limits["cgroup"].lstrip("/") / "memory.events"
    events = dict(line.split() for line in path.read_text().splitlines())
    require("oom_kill" in events, "missing native OOM accounting")
    return {key: int(events.get(key, "0")) for key in ("oom_kill", "oom_group_kill")}


def command(argv, *, cwd, env, pass_fds, output, live, seconds):
    """Stream output without allowing a silent process or inherited pipe to hang."""
    process = subprocess.Popen(argv, cwd=cwd, env=env, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, pass_fds=pass_fds,
                               start_new_session=True)
    deadline = time.monotonic() + seconds
    expired = threading.Event()
    killed = threading.Event()

    def expire():
        expired.set()
        kill_owned_groups(process.pid)
        killed.set()

    # Observational SSH output or a slow log sink must not extend the child's
    # running time. The timer enforces the deadline independently of streaming.
    timer = threading.Timer(seconds, expire)
    timer.daemon = True
    timer.start()

    def timed_out():
        output.write(b"\nlandin-ci: command process group timed out\n")
        output.flush()
        return 124

    try:
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            while selector.get_map() or process.poll() is None:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    return timed_out()
                for key, _ in selector.select(min(remaining, 0.1)):
                    chunk = os.read(key.fd, 8192)
                    if chunk:
                        output.write(chunk)
                        output.flush()
                        live(chunk)
                    else:
                        selector.unregister(key.fileobj)
            code = process.wait()
            return timed_out() if expired.is_set() else code
    finally:
        # Also covers exceptions in the log sink or observational callback.
        timer.cancel()
        timer.join()
        try:
            if killed.is_set():
                process.wait(timeout=5)
            else:
                terminate(process)
        finally:
            process.stdout.close()
