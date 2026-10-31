"""LLDB's batch sessions over an ELF image, shared by FreeBSD and Linux.

Two sessions, each a command file for `lldb --batch -s FILE IMAGE` and a
verdict over the transcript it prints.  No Python runs inside LLDB, so a
debugger built without it runs them too, as FreeBSD's base LLDB is:

- the source session, over compiler/tests/freebsd/debug.ldn: a source-line
  stop in `inner`, the frames `inner`, `outer` and `main`, the locals and
  the caller's, a step out to the caller, a stop on `outer`'s result and
  the exit status 42;
- the stack switch's session (D469), whose stops and verdict are
  switch_frames.py's; its command file needs the number of instructions
  in the switch routine, which the lane counts in the image.

compiler/tests/freebsd/check.py runs them in its VM, and
compiler/tests/debugging/lldb_linux.py on this Linux host, so a change to
either session or to its verdict is first run here rather than in the gate.
"""
from pathlib import Path
import re
import sys

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
sys.path.insert(0, str(HERE))
import switch_frames  # noqa: E402

SOURCE = ROOT / "compiler/tests/freebsd/debug.ldn"
STATUS = 42
#  The statements the source session stops at, found by their text so an
#  edit above them moves nothing.
NEEDLES = ("result = local + 1", "result = step(local)", "result = ready")


class Mismatch(ValueError):
    """A transcript is not what the session requires."""


def require(condition, message):
    if not condition:
        raise Mismatch(message)


def source_lines():
    """The line of each NEEDLES statement in SOURCE."""
    text = SOURCE.read_text().splitlines()
    return {needle: next(i for i, line in enumerate(text, 1) if needle in line)
            for needle in NEEDLES}


def source_commands(lines):
    return ["settings set target.disable-aslr false",
            f'breakpoint set --file {SOURCE.name} --line {lines["result = local + 1"]}',
            "run", "frame info", "frame variable argument local", "thread backtrace",
            "frame select 1", "frame variable argument local",
            "frame select 2", "frame info", "frame select 0",
            "thread step-out", "frame info",
            f'breakpoint set --file {SOURCE.name} --line {lines["result = ready"]}',
            "continue", "frame info", "frame variable result",
            "breakpoint delete --force", "continue"]


def check_source(text, lines, label):
    """Hold a source session's transcript to its stops, frames and values."""
    require(re.search(SOURCE.name.replace(".", r"\.") + ":"
                      + str(lines["result = local + 1"]) + r"[:\s]", text),
            label + ": no source-line stop")
    for frame, name in ((0, "inner"), (1, "outer"), (2, "main")):
        require(re.search(r"frame #" + str(frame) + r":.*\b" + name + r"\b", text),
                label + ": stack frame missing: " + name)
    for name, value in (("argument", 40), ("local", 41), ("argument", 30),
                        ("local", 40), ("result", 42)):
        require(re.search(r"\b" + name + r" = " + str(value) + r"\b", text),
                label + ": local/caller/return value missing: " + str((name, value)))
    unwound = text.split("(lldb) thread step-out", 1)[-1].split("(lldb) breakpoint set", 1)[0]
    require("stop reason = step out" in unwound, label + ": no completed step-out stop")
    require(re.search(r"frame #0:.*\bouter\b", unwound),
            label + ": step-out failed to unwind to caller")
    require(re.search(r"exited with status = " + str(STATUS) + r"\b", text),
            label + ": final execution status missing")


def switch_commands(instructions):
    """The stack switch's session, stepping INSTRUCTIONS through each switch."""
    return switch_frames.lldb_commands(switch_frames.fibre_line(), instructions)


def check_switch(text, label, target):
    """Hold a stack switch transcript to switch_frames' record; its summary."""
    require(re.search(r"exited with status = " + str(switch_frames.STATUS) + r"\b", text),
            label + ": the workload did not exit " + str(switch_frames.STATUS))
    try:
        return switch_frames.check(switch_frames.lldb_stops(text),
                                   switch_frames.ARCH[target], target)
    except switch_frames.Mismatch as error:
        raise Mismatch(label + ": " + str(error)) from None
