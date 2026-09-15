"""Complete derived-program oracles, executed inside native LLDB."""
import json
from pathlib import Path
import sys
import lldb

if sys.flags.optimize:
    raise RuntimeError("LLDB assertions require Python optimization disabled")


def run(debugger, config_path):
    config = json.loads(Path(config_path).read_text())
    debugger.SetAsync(False)
    target = debugger.CreateTarget(config['executable'])
    assert target.IsValid()
    assert '.dSYM/Contents/Resources/DWARF/' in str(target.GetModuleAtIndex(0).GetSymbolFileSpec())
    checks = []

    def record(label, actual, expected):
        print(label, repr(actual), 'expected', repr(expected))
        assert actual == expected, (label, actual, expected)
        checks.append({'label': label, 'actual': actual, 'expected': expected})

    def value(frame, path):
        parts = path.split('.')
        result = frame.FindVariable(parts[0])
        for part in parts[1:]:
            result = (result.Dereference() if part == '*' else
                      result.GetChildAtIndex(int(part)) if part.isdigit() else
                      result.GetChildMemberWithName(part))
        assert result.IsValid(), ('missing variable', path)
        error = lldb.SBError()
        actual = (result.GetValueAsSigned(error)
                  if result.GetType().GetTypeFlags() & lldb.eTypeIsSigned
                  else result.GetValueAsUnsigned(error))
        assert error.Success(), (path, str(result), str(error))
        return actual

    breakpoints = {}
    locations = {}
    for stop in config['stops']:
        location = (stop['source'], stop['line'])
        if location not in locations:
            bp = target.BreakpointCreateByLocation(*location)
            assert bp.GetNumLocations() > 0, stop
            locations[location] = bp.GetID()
            breakpoints[bp.GetID()] = []
        breakpoints[locations[location]].append(stop)
    launch = lldb.SBLaunchInfo(config['arguments'])
    launch.SetWorkingDirectory(config['cwd'])
    launch.AddOpenFileAction(1, config['stdout'], False, True)
    launch.AddOpenFileAction(2, config['stderr'], False, True)
    error = lldb.SBError()
    process = target.Launch(launch, error)
    assert error.Success(), str(error)
    seen = []
    try:
        for _ in range(10000):
            if process.GetState() == lldb.eStateExited:
                break
            assert process.GetState() == lldb.eStateStopped, process.GetState()
            thread = process.GetSelectedThread()
            assert thread.GetStopReason() == lldb.eStopReasonBreakpoint, str(thread)
            bp_id = thread.GetStopReasonDataAtIndex(0)
            assert bp_id in breakpoints, bp_id
            frame = thread.GetFrameAtIndex(0)
            matches = [s for s in breakpoints[bp_id] if all(value(frame, name) == expected
                       for name, expected in s.get('when', {}).items())]
            assert len(matches) <= 1, matches
            if not matches:
                process.Continue()
                continue
            stop = matches[0]
            key = stop['name']
            record(key + '.function', frame.GetFunctionName(), stop['stack'][0])
            record(key + '.line', frame.GetLineEntry().GetLine(), stop['line'])
            record(key + '.file', str(frame.GetLineEntry().GetFileSpec()), stop['source'])
            record(key + '.stack', [thread.GetFrameAtIndex(i).GetFunctionName()
                                    for i in range(len(stop['stack']))], stop['stack'])
            for i in range(thread.GetNumFrames()):
                print('STACK', thread.GetFrameAtIndex(i))
            if stop.get('complete_parser'):
                names = [thread.GetFrameAtIndex(i).GetFunctionName() for i in range(thread.GetNumFrames())]
                record(key + '.application', 'parse_file' in names and 'main' in names, True)
            for path, expected in stop['values'].items():
                record(key + '.' + path, value(frame, path), expected)
            for path, expected in stop.get('caller_values', {}).items():
                record(key + '.caller.' + path, value(thread.GetFrameAtIndex(1), path), expected)
            seen.append(key)
            breakpoints[bp_id].remove(stop)
            if not breakpoints[bp_id]:
                target.BreakpointDelete(bp_id)
            if stop.get('steps'):
                target.DisableAllBreakpoints()
            for index, step in enumerate(stop.get('steps', [])):
                if step['action'] == 'out':
                    thread.StepOut()
                elif step['action'] == 'in':
                    thread.StepInto()
                else:
                    assert step['action'] == 'over'
                    thread.StepOver()
                record(key + f'.step-{index}.state', process.GetState(), lldb.eStateStopped)
                frame = process.GetSelectedThread().GetFrameAtIndex(0)
                record(key + f'.step-{index}.function', frame.GetFunctionName(), step['function'])
                record(key + f'.step-{index}.line', frame.GetLineEntry().GetLine(), step['line'])
                if 'stack' in step:
                    record(key + f'.step-{index}.stack', [thread.GetFrameAtIndex(i).GetFunctionName()
                           for i in range(len(step['stack']))], step['stack'])
                for path, expected in step.get('values', {}).items():
                    record(key + f'.step-{index}.' + path, value(frame, path), expected)
            target.EnableAllBreakpoints()
            process.Continue()
        record('stops', sorted(seen), sorted(s['name'] for s in config['stops']))
        record('inferior state', process.GetState(), lldb.eStateExited)
        record('inferior status', process.GetExitStatus(), 42)
        record('stdout', Path(config['stdout']).read_text(), config['expected_stdout'])
        record('stderr', Path(config['stderr']).read_text(), config['expected_stderr'])
        Path(config['result']).write_text(json.dumps({'status': 'passed', 'checks': checks}, indent=2) + '\n')
        print('LANDIN DERIVED LLDB PASSED')
    finally:
        if process.GetState() not in (lldb.eStateExited, lldb.eStateDetached):
            process.Kill()
