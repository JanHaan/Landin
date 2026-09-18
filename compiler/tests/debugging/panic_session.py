"""Native LLDB panic/noreturn source and unwind assertions."""
import json
import sys
from pathlib import Path
import lldb


if sys.flags.optimize:
    raise RuntimeError("panic debugger assertions require Python optimization disabled")


def run(debugger, config_path):
    config = json.loads(Path(config_path).read_text())
    debugger.SetAsync(False)
    target = debugger.CreateTarget(config['executable'])
    assert target.IsValid()
    assert '.dSYM/' in str(target.GetModuleAtIndex(0).GetSymbolFileSpec())
    source = config['source']
    before = target.BreakpointCreateByLocation(source, config['operation_line'])
    handler = target.BreakpointCreateByLocation(source, config['handler_line'])
    assert before.GetNumLocations() > 0 and handler.GetNumLocations() > 0
    process = target.LaunchSimple(None, None, config['cwd'])

    def integer(frame, name):
        value = frame.FindVariable(name)
        error = lldb.SBError()
        result = value.GetValueAsUnsigned(error)
        assert value.IsValid() and error.Success(), (name, str(value), str(error))
        return result

    try:
        assert process.GetState() == lldb.eStateStopped
        frame = process.GetSelectedThread().GetFrameAtIndex(0)
        assert frame.GetFunctionName() == 'crash'
        assert frame.GetLineEntry().GetLine() == config['operation_line']
        assert integer(frame, 'value') == 1 and integer(frame, 'high') == 255
        target.BreakpointDelete(before.GetID())
        process.Continue()
        assert process.GetState() == lldb.eStateStopped
        thread = process.GetSelectedThread()
        frame = thread.GetFrameAtIndex(0)
        assert frame.GetFunctionName() == 'panic_handler'
        assert frame.GetLineEntry().GetLine() == config['handler_line']
        assert integer(frame, 'kind') == 2
        assert integer(frame, 'site') == config['site']
        frames = [thread.GetFrameAtIndex(i) for i in range(thread.GetNumFrames())]
        names = [f.GetFunctionName() for f in frames]
        print('PANIC STACK', names)
        assert names[:2] == ['panic_handler', 'crash'], names
        assert names[2].startswith('invoke') and names[3:5] == ['run_thing', 'main'], names
        assert frames[1].GetLineEntry().GetLine() == config['operation_line']
        assert frames[1].GetLineEntry().GetFileSpec().GetFilename() == 'main.ldn'
        target.BreakpointDelete(handler.GetID())
        process.Continue()
        assert process.GetState() == lldb.eStateExited and process.GetExitStatus() == 42
        Path(config['result']).write_text(json.dumps({'status': 'passed', 'frames': names[:5],
                                                     'site': config['site']})+'\n')
        print('LANDIN PANIC LLDB PASSED')
    finally:
        if process.IsValid() and process.GetState() != lldb.eStateExited:
            process.Kill()
