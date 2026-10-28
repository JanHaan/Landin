"""The stack switch's scripted debugger session, shared by every lane.

The roadmap's gate asks, on every target with a stack switch, for a debugger
session that switches fibres and checks the frames of a backtrace through
the switch.  One workload, `runtime/stack-switch-frames`, runs on all of
them, and its stops are in `workload-frames.json` under `switch`, beside
the other workloads', so the test program holds the routines they name to
the source that declares them.  The two compiler routines a backtrace
through a switch passes are named there too, `landin.stack_switch` and
`landin.stack_start` (D469).

A session stops three ways:

- inside `deepest`, on the second fibre's stack after two switches: the
  frames are the fibre's own down to the start routine, and nothing is
  beneath it (D447: a fibre's first frame ends the chain);
- at the switch from the second fibre to the first, an instruction at a
  time from the routine's first to its return: until the instruction that
  moves the stack pointer has run, the frames above the switch routine are
  the leaving fibre's, and from the next instruction on the resumed one's;
- at the switch from the first fibre back to main, the same, the resumed
  frames being main's and whatever the target puts beneath it.

GDB's sessions (Linux, RV64 and Cortex-M) and LLDB's (Darwin and FreeBSD)
produce the same stops, read by `gdb_stops` and `lldb_stops`, and `check`
holds them to the record.  Nothing here runs a debugger: each lane starts
its own, through its own transport, with the commands made here.
"""
from __future__ import annotations

from dataclasses import dataclass, field
import json
from pathlib import Path
import re

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
FIXTURE = ROOT / "compiler/tests/fixtures/runtime/stack-switch-frames"
SOURCE = FIXTURE / "main.ldn"
WORKLOAD = "switch"
RECORD = json.loads((HERE / "workload-frames.json").read_text())[WORKLOAD]
SWITCH = RECORD["switch"]
START = RECORD["start"]
STOPS = RECORD["stops"]
#  The workload's status, as its fixture says.
STATUS = 42
#  The statement the in-fibre stop is made at.
FIBRE_STATEMENT = "reached = depth + 1"
#  The two switches a session steps through, in the order the program
#  makes them, after the in-fibre stop: the second fibre resumes the
#  first, and the first resumes main.  A fibre's frames end at the start
#  routine; main's go on into whatever the target runs main from.
SWITCHES = (
    {"name": "second-to-first",
     "leaving": STOPS["second-switching"] + [START],
     "resumed": STOPS["first-switching"] + [START], "beneath": False},
    {"name": "first-to-main",
     "leaving": STOPS["first-switching"] + [START],
     "resumed": STOPS["main-switching"], "beneath": True},
)
#  The instruction after which the resumed context's frames are the ones
#  above the switch routine, as GDB and LLDB print it: the one that loads
#  the resumed stack pointer.  On arm64 it is the one that points x29 at
#  the resumed stack's frame record, just before sp follows, since the
#  switch's unwind rule follows its frame record (D475).  On Cortex-M0
#  that is the write of MSP or PSP when the selection does not change,
#  and of CONTROL when it does (D460); the ISB after CONTROL makes it architecturally current, which
#  an emulator may already have.
SWAP = {
    "x86-64": r"\bmov[a-z]*\s+%rsi,\s*%rsp\b",
    "arm64": r"\badd\s+x29,\s*x10,\s*#(?:160|0xa0)\b",
    "rv64": r"\bmv\s+sp,\s*(?:a1|x11)\b",
    "cortex-m0": r"\b(?:msr\s+(?:msp|psp|control|MSP|PSP|CONTROL)\b|isb\b)",
}
#  The debuggers whose own unwinder misreads the switch routine's final
#  `ret`, which that one stop is therefore not held to.  FreeBSD 14.4's base
#  LLDB, 19.1.7, ignores CFI in frame 0 on arm64 and emulates the routine's
#  instructions instead; its emulator loses the stack at `mov sp, x10`, so
#  at the `ret` it still reads the return address through x29 and skips a
#  frame.  A clang-built switch with clang's CFI fails the same way, every
#  other instruction of ours unwinds right, and the CFI there is the
#  standard epilogue's; the roadmap's register watches it.
UNRELIABLE_RETURN = {"freebsd-arm64": "LLDB 19.1.7's arm64 frame-0 emulation"}
#  How many instructions a session may step inside one switch before it
#  says the routine never returned.
STEP_LIMIT = 200


class Mismatch(ValueError):
    """A session's frames are not what the record says."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise Mismatch(message)


def fibre_line() -> int:
    lines = [number for number, text in
             enumerate(SOURCE.read_text().splitlines(), 1)
             if text.strip() == FIBRE_STATEMENT]
    require(len(lines) == 1, f"{SOURCE.name} has no single {FIBRE_STATEMENT!r}")
    return lines[0]


#  Each target's architecture, as SWAP names it.
ARCH = {"linux-x86-64": "x86-64", "freebsd-x86-64": "x86-64",
        "linux-arm64": "arm64", "darwin-arm64": "arm64",
        "freebsd-arm64": "arm64", "linux-rv64": "rv64",
        "cortex-m0": "cortex-m0"}


@dataclass
class Step:
    """One stop: the routine and offset of the pc, its instruction when the
    debugger printed it, and the frames' routines, innermost first."""
    function: str
    offset: int | None
    instruction: str
    frames: list[str] = field(default_factory=list)
    ended_cleanly: bool = True


#  GDB.  The commands use no Python and no convenience functions, so the
#  pinned GNAT's GDB, gdb-multiarch and the Arm GDB all run them; the
#  switch routine's extent comes from the image's symbol table, read by
#  the lane, because a loop condition on the pc is all GDB's command
#  language has.

def gdb_commands(location: str, low: int, high: int,
                 start: list[str]) -> list[str]:
    """Stop in the fibre, then step both switches; `start` runs or
    continues the inferior to its first stop.  The lane ends the session."""
    commands = ["set pagination off", "set confirm off", "set width 0",
                "set height 0", f"break {location}", *start,
                'printf "LANDIN-SWITCH-BEGIN fibre\\n"', "bt",
                'printf "LANDIN-SWITCH-END fibre\\n"',
                "delete", f"break *{low:#x}"]
    for switch in SWITCHES:
        commands += [
            "continue", f'printf "LANDIN-SWITCH-BEGIN {switch["name"]}\\n"',
            "set $landin_steps = 0",
            f"while (unsigned long) $pc >= {low:#x} && (unsigned long) $pc < {high:#x}"
            f" && $landin_steps < {STEP_LIMIT}",
            'printf "LANDIN-SWITCH-STEP\\n"', "x/i $pc", "bt", "stepi",
            "set $landin_steps = $landin_steps + 1", "end",
            'printf "LANDIN-SWITCH-STEP\\n"', "x/i $pc", "bt",
            f'printf "LANDIN-SWITCH-END {switch["name"]}\\n"']
    return commands + ["delete"]


def gdb_section(transcript: str, name: str) -> str:
    match = re.search(r"^LANDIN-SWITCH-BEGIN " + re.escape(name) +
                      r"\r?\n(.*?)^LANDIN-SWITCH-END " + re.escape(name) +
                      r"\r?$", transcript, re.M | re.S)
    require(match is not None, f"the GDB transcript has no {name} section")
    return match.group(1)


GDB_FRAME = re.compile(r"^#(\d+)\s+(?:0x[0-9a-fA-F]+ in )?(\S+?) \(", re.M)
GDB_INSTRUCTION = re.compile(
    r"^=> 0x[0-9a-fA-F]+(?: <([^>+]+)(?:\+(\d+))?>)?:\s*(.*?)\s*$", re.M)


def gdb_step(text: str) -> Step:
    frames = [(int(number), name) for number, name in GDB_FRAME.findall(text)]
    require([number for number, _ in frames] == list(range(len(frames))),
            f"GDB's backtrace is not a numbered sequence:\n{text}")
    instruction = GDB_INSTRUCTION.search(text)
    require(instruction is not None, f"GDB printed no instruction:\n{text}")
    function = instruction.group(1) or "??"
    offset = int(instruction.group(2) or 0) if instruction.group(1) else None
    return Step(function, offset, instruction.group(3),
                [name for _, name in frames],
                "Backtrace stopped" not in text)


def gdb_stops(transcript: str) -> dict:
    """The fibre stop and each switch's steps, from a GDB transcript."""
    fibre = gdb_section(transcript, "fibre")
    frames = [name for _, name in GDB_FRAME.findall(fibre)]
    stops = {"fibre": Step(frames[0] if frames else "??", None, "", frames,
                           "Backtrace stopped" not in fibre)}
    for switch in SWITCHES:
        section = gdb_section(transcript, switch["name"])
        chunks = section.split("LANDIN-SWITCH-STEP\n")[1:]
        stops[switch["name"]] = [gdb_step(chunk) for chunk in chunks]
    return stops


#  LLDB.  FreeBSD's LLDB has no Python, so its session is plain commands,
#  and they step a switch by a count: the routine is straight-line on
#  x86-64 and arm64, so its instructions, which the lane counts in the
#  linked image, are its steps, and one more leaves it.

def lldb_commands(line: int, instructions: int) -> list[str]:
    commands = ["settings set target.disable-aslr false",
                f"breakpoint set --file {SOURCE.name} --line {line}",
                "run", "thread backtrace", "breakpoint delete --force",
                "breakpoint set --func-regex '^" + re.escape(SWITCH) + "$'"]
    for _ in SWITCHES:
        commands += ["continue", "thread backtrace"]
        for _ in range(instructions):
            commands += ["thread step-inst", "thread backtrace"]
    return commands + ["breakpoint delete --force", "continue"]


LLDB_FRAME = re.compile(
    r"^\s*\*?\s*frame #(\d+): 0x[0-9a-fA-F]+(?: [^`\s]*`([^\s(]+)"
    r"(?:\([^\n]*?\))?(?: \+ (\d+))?)?", re.M)
LLDB_INSTRUCTION = re.compile(r"^->\s+0x[0-9a-fA-F]+ <\+(\d+)>:\s*(.*?)\s*$",
                              re.M)


def lldb_commands_output(transcript: str) -> list[tuple[str, str]]:
    """(command, output) for each command LLDB echoed in batch mode."""
    parts = re.split(r"^\(lldb\) (.*)$", transcript, flags=re.M)
    return [(parts[i].strip(), parts[i + 1]) for i in range(1, len(parts) - 1, 2)]


def lldb_backtrace(text: str) -> list[tuple[str, int | None]]:
    frames = [(int(n), name or "??", int(offset) if offset else None)
              for n, name, offset in LLDB_FRAME.findall(text)]
    require([n for n, _, _ in frames] == list(range(len(frames))),
            f"LLDB's backtrace is not a numbered sequence:\n{text}")
    return [(name, offset) for _, name, offset in frames]


def lldb_stops(transcript: str) -> dict:
    """The fibre stop and each switch's steps, from an LLDB transcript."""
    pairs = lldb_commands_output(transcript)
    backtraces = [i for i, (command, _) in enumerate(pairs)
                  if command == "thread backtrace"]
    require(backtraces, "the LLDB transcript has no backtrace")
    first = lldb_backtrace(pairs[backtraces[0]][1])
    stops = {"fibre": Step(first[0][0] if first else "??", None, "",
                           [name for name, _ in first])}
    switches = iter(SWITCHES)
    current = None
    for index in backtraces[1:]:
        stopping, said = pairs[index - 1]
        if stopping == "continue":
            current = next(switches)["name"]
            stops[current] = []
        require(current is not None and stopping in ("continue", "thread step-inst"),
                f"an LLDB backtrace follows {stopping!r}")
        frames = lldb_backtrace(pairs[index][1])
        instruction = LLDB_INSTRUCTION.search(said)
        function, offset = frames[0] if frames else ("??", None)
        #  LLDB names a routine's first instruction without "+ 0".
        stops[current].append(Step(
            function, (offset or 0) if function == SWITCH else None,
            instruction.group(2) if instruction else "",
            [name for name, _ in frames]))
    return stops


def recorded_stops(recorded: dict) -> dict:
    """Stops a session wrote as JSON, lldb_switch.py's, as `check` reads
    them."""
    return {name: (Step(**value) if name == "fibre"
                   else [Step(**one) for one in value])
            for name, value in recorded.items()
            if name not in ("exit_status", "state")}


#  The verdict, the same for every debugger.

def check(stops: dict, arch: str, target: str | None = None) -> dict:
    """Hold one session's stops to the record; return what it showed.

    On a target in UNRELIABLE_RETURN the switch routine's final stop, its
    `ret`, is recorded and not judged; every other stop is."""
    fibre = stops["fibre"]
    expected = STOPS["fibre"] + [START]
    require(fibre.frames == expected,
            f"inside the fibre the backtrace is {fibre.frames}, expected "
            f"{expected} and nothing beneath the start routine")
    require(fibre.ended_cleanly,
            "the debugger stopped the fibre's backtrace short of its end")
    summary = {"fibre": fibre.frames}
    swap = re.compile(SWAP[arch])
    for switch in SWITCHES:
        name = switch["name"]
        steps = stops.get(name)
        require(bool(steps), f"the session made no stop in the {name} switch")
        inside = [s for s in steps if s.frames and s.frames[0] == SWITCH]
        require(len(steps) >= 3 and steps[:len(inside)] == inside
                and len(inside) == len(steps) - 1,
                f"{name}: the session did not step from {SWITCH}'s first"
                " instruction through its return; the debugger named its"
                " stops "
                + ", ".join(dict.fromkeys(s.frames[0] if s.frames else "??"
                                          for s in steps)))
        require(inside[0].offset == 0,
                f"{name}: the first stop is at {SWITCH}+{inside[0].offset}"
                ", not at its first instruction")

        def holds(frames, wanted, beneath):
            return (frames[:len(wanted)] == wanted if beneath
                    else frames == wanted)

        phases = []
        exempt = None
        if (target in UNRELIABLE_RETURN and inside
                and re.search(r"\bret\b", inside[-1].instruction)):
            exempt = inside[-1]
            inside = inside[:-1]
        for step in inside:
            above = step.frames[1:]
            where = f"{SWITCH}+{step.offset} ({step.instruction})"
            require(step.ended_cleanly,
                    f"{name}: at {where} the backtrace stopped short")
            if above == switch["leaving"]:
                phases.append("leaving")
            elif holds(above, switch["resumed"], switch["beneath"]):
                phases.append("resumed")
            else:
                raise Mismatch(
                    f"{name}: at {where} the frames above the switch are"
                    f" {above}; expected the leaving context's"
                    f" {switch['leaving']} or the resumed one's"
                    f" {switch['resumed']}")
        require("leaving" in phases and "resumed" in phases,
                f"{name}: the frames were {phases[0]}'s at every instruction")
        turn = phases.index("resumed")
        require(phases == ["leaving"] * turn + ["resumed"] * (len(phases) - turn),
                f"{name}: the frames went back and forth: {phases}")
        moved = inside[turn - 1]
        require(swap.search(moved.instruction) is not None,
                f"{name}: the frames became the resumed context's after"
                f" {SWITCH}+{moved.offset} ({moved.instruction}), which"
                " does not load the resumed stack pointer")
        returned = steps[-1]
        require(holds(returned.frames, switch["resumed"], switch["beneath"]),
                f"{name}: past the switch's return the backtrace is"
                f" {returned.frames}, expected {switch['resumed']}")
        summary[name] = {"instructions": len(inside), "turn": turn,
                         "swap": moved.instruction,
                         "leaving": switch["leaving"],
                         "resumed": returned.frames}
        if exempt is not None:
            summary[name]["not judged"] = {
                "at": f"{SWITCH}+{exempt.offset} ({exempt.instruction})",
                "frames": exempt.frames[1:],
                "because": UNRELIABLE_RETURN[target]}
    return summary


def symbol_extent(listing: str, name: str = SWITCH) -> tuple[int, int]:
    """[low, high) of a symbol, from `nm -S` output."""
    for line in listing.splitlines():
        fields = line.split()
        if len(fields) == 4 and fields[3] == name:
            low = int(fields[0], 16)
            return low, low + int(fields[1], 16)
    raise Mismatch(f"the image has no sized symbol {name}")


#  An assembler's private label prefix in each object format.  A label so
#  spelled is no symbol of the image unless an assembler was told to keep
#  it (`-L`); FreeBSD's links keep none (D475).  On Mach-O, `L` is the
#  assembler's and `l` the linker's, and every external name starts `_`.
PRIVATE = {"elf": (".L",), "mach-o": ("L", "l")}
#  Arm's mapping symbols mark code and data, and name nothing.
MAPPING = re.compile(r"^\$[adtx](?:\.\S*)?$")


def shadowing_symbols(listing: str, object_format: str = "elf") -> list[str]:
    """What in an image's symbol table could name a routine's address
    instead of the routine, from `nm` output with or without `-S`: any
    other symbol at the switch or start routine's address, and any private
    label at the address of a code symbol.  Empty when nothing does."""
    underscore = "_" if object_format == "mach-o" else ""
    routines = {underscore + SWITCH, underscore + START}
    at: dict[int, list[tuple[str, str]]] = {}
    for line in listing.splitlines():
        fields = line.split()
        if len(fields) not in (3, 4) or not re.fullmatch(r"[0-9a-fA-F]+", fields[0]):
            continue
        kind, name = fields[-2], fields[-1]
        if MAPPING.match(name):
            continue
        at.setdefault(int(fields[0], 16), []).append((kind, name))
    missing = [name for name in routines
               if not any(name == each for names in at.values() for _, each in names)]
    problems = [f"the image has no symbol {name}" for name in sorted(missing)]
    private: list[str] = []
    for address, names in sorted(at.items()):
        spelled = [name for _, name in names]
        for routine in sorted(routines & set(spelled)):
            others = [name for name in spelled if name != routine]
            if others:
                problems.append(f"{', '.join(others)} at {routine}'s address"
                                f" {address:#x}")
        if any(kind in "tT" for kind, _ in names) and not routines & set(spelled):
            private += [f"{name} at {address:#x}" for kind, name in names
                        if kind.islower()
                        and name.startswith(PRIVATE[object_format])]
    if private:
        problems.append(f"{len(private)} private labels at code addresses,"
                        f" such as {', '.join(private[:3])}")
    return problems


def instruction_count(listing: str) -> int:
    """The instructions of one routine, from `objdump -d` limited to it."""
    count = len(re.findall(r"^\s+[0-9a-f]+:\s+(?:[0-9a-f]{2,8}\s)+\s*\S",
                           listing, re.M))
    require(count > 0, f"no instructions disassembled for {SWITCH}")
    return count
