"""The stack switch's session inside LLDB, through its SB API.

Darwin's lane runs it: the same stops as every other target's session
(switch_frames.py), made by stepping each switch an instruction at a time
until the pc leaves the switch routine, which LLDB's Python can do without
counting the routine's instructions first.  It writes the stops it saw to
the configuration's `result`, and switch_frames.check holds them to the
record in the lane's own Python.
"""
import json
from pathlib import Path
import sys

import lldb

sys.path.insert(0, str(Path(__file__).resolve().parent))
import switch_frames  # noqa: E402

if sys.flags.optimize:
    raise RuntimeError("LLDB assertions require Python optimization disabled")


def names(thread):
    """The routine of every frame, innermost first; LLDB names a routine
    without debug information by its symbol."""
    found = []
    for index in range(thread.GetNumFrames()):
        frame = thread.GetFrameAtIndex(index)
        found.append(frame.GetFunctionName() or frame.GetSymbol().GetName() or "??")
    return found


def step(target, thread):
    """One stop as switch_frames.Step's fields."""
    frame = thread.GetFrameAtIndex(0)
    pc = frame.GetPCAddress()
    symbol = frame.GetSymbol()
    function = frame.GetFunctionName() or symbol.GetName() or "??"
    offset = None
    if symbol.IsValid():
        offset = (pc.GetLoadAddress(target)
                  - symbol.GetStartAddress().GetLoadAddress(target))
    instructions = target.ReadInstructions(pc, 1)
    text = ""
    if instructions.GetSize():
        instruction = instructions.GetInstructionAtIndex(0)
        text = (instruction.GetMnemonic(target) + " "
                + instruction.GetOperands(target)).strip()
    return {"function": function, "offset": offset, "instruction": text,
            "frames": names(thread)}


def run(debugger, config_path):
    config = json.loads(Path(config_path).read_text())
    debugger.SetAsync(False)
    target = debugger.CreateTarget(config["executable"])
    assert target.IsValid(), config["executable"]
    fibre = target.BreakpointCreateByLocation(switch_frames.SOURCE.name,
                                              switch_frames.fibre_line())
    assert fibre.GetNumLocations() > 0, "no location for the in-fibre stop"
    launch = lldb.SBLaunchInfo([])
    launch.SetWorkingDirectory(config["cwd"])
    error = lldb.SBError()
    process = target.Launch(launch, error)
    assert error.Success(), str(error)
    stops = {}
    try:
        assert process.GetState() == lldb.eStateStopped, process.GetState()
        thread = process.GetSelectedThread()
        stops["fibre"] = {"function": names(thread)[0], "offset": None,
                          "instruction": "", "frames": names(thread)}
        target.BreakpointDelete(fibre.GetID())
        switch = target.BreakpointCreateByRegex(
            "^" + switch_frames.SWITCH.replace(".", "\\.") + "$")
        assert switch.GetNumLocations() > 0, "no location for the switch routine"
        for each in switch_frames.SWITCHES:
            process.Continue()
            assert process.GetState() == lldb.eStateStopped, process.GetState()
            thread = process.GetSelectedThread()
            steps = [step(target, thread)]
            while (steps[-1]["function"] == switch_frames.SWITCH
                   and len(steps) < switch_frames.STEP_LIMIT):
                thread.StepInstruction(False)
                thread = process.GetSelectedThread()
                steps.append(step(target, thread))
            stops[each["name"]] = steps
        target.BreakpointDelete(switch.GetID())
        process.Continue()
        stops["exit_status"] = process.GetExitStatus()
        stops["state"] = process.GetState() == lldb.eStateExited
    finally:
        Path(config["result"]).write_text(json.dumps(stops, indent=2) + "\n")
        if process.GetState() not in (lldb.eStateExited, lldb.eStateDetached):
            process.Kill()
    print("LANDIN SWITCH LLDB STOPPED")

