"""Strict native LLDB SB API session; imported by Apple's LLDB, not host Python."""
import json
from pathlib import Path
import lldb
import sys

if sys.flags.optimize:
    raise RuntimeError("LLDB assertions require Python optimization disabled")


def run(debugger, config_path):
    config = json.loads(Path(config_path).read_text())
    debugger.SetAsync(False)
    target = debugger.CreateTarget(config['executable'])
    assert target.IsValid(), 'LLDB target creation failed'
    symbol_file = str(target.GetModuleAtIndex(0).GetSymbolFileSpec())
    print('SYMBOL FILE', symbol_file)
    assert '.dSYM/Contents/Resources/DWARF/' in symbol_file, 'session must use the packaged dSYM'
    source = config['source']
    lines = config['lines']
    checks = []

    def record(label, actual, expected):
        print(label, repr(actual), 'expected', repr(expected))
        assert actual == expected, (label, actual, expected)
        checks.append(label)

    def breakpoint(key):
        bp = target.BreakpointCreateByLocation(source, lines[key])
        assert bp.GetNumLocations() > 0, ('unresolved source breakpoint', key)
        return bp

    def frame(key, function):
        assert process.GetState() == lldb.eStateStopped, process.GetState()
        thread = process.GetSelectedThread()
        f = thread.GetFrameAtIndex(0)
        record(key + '.function', f.GetFunctionName(), function)
        record(key + '.line', f.GetLineEntry().GetLine(), lines[key])
        record(key + '.file', f.GetLineEntry().GetFileSpec().GetFilename(), Path(source).name)
        print('source:', Path(source).read_text().splitlines()[lines[key] - 1])
        return f

    def value(f, path):
        parts = path.split('.')
        v = f.FindVariable(parts[0])
        for part in parts[1:]:
            if part == '*':
                v = v.Dereference()
            elif part.isdigit():
                v = v.GetChildAtIndex(int(part))
            else:
                v = v.GetChildMemberWithName(part)
        assert v.IsValid(), ('missing value', path)
        error = lldb.SBError()
        result = v.GetValueAsSigned(error)
        assert error.Success(), (path, str(error), str(v))
        return result

    def values(f, scope, expected):
        for name, expected_value in expected.items():
            record(scope + '.' + name, value(f, name), expected_value)

    def unavailable(f, name):
        v = f.FindVariable(name)
        error = lldb.SBError()
        v.GetValueAsSigned(error)
        record(name + '.unavailable', not v.IsValid() or error.Fail(), True)

    def continued(key, function):
        bp = breakpoint(key)
        process.Continue()
        f = frame(key, function)
        target.BreakpointDelete(bp.GetID())
        return f

    def selected(f, scope, local):
        expected = {'scalar_param': 37, 'scalar_local': local,
                    'pointer_param.*': 41, 'pointer_local.*': 41,
                    'saved_a': 51, 'saved_b': 52, 'saved_c': 53}
        for kind in ('param', 'local'):
            for member, val in {'tiny': 7, 'huge': 7000000000, 'middle': 901}.items():
                expected['record_' + kind + '.' + member] = val
                expected['variant_' + kind + '.choice.payload.record.' + member] = val
            expected['variant_' + kind + '.choice.tag'] = 1
            for index, val in enumerate((111, 222, 333)):
                expected[f'array_{kind}.{index}'] = val
                expected[f'variant_{kind}.choice.payload.values.{index}'] = val
        values(f, scope, expected)

    entry = target.BreakpointCreateByName('debug_outer')
    assert entry.GetNumLocations() == 1
    process = target.LaunchSimple(None, None, config['cwd'])
    try:
        f = frame('outer-entry', 'debug_outer')
        unavailable(f, 'scalar_local')
        values(f, 'entry', {'scalar_param': 37, 'saved_c': 53})
        target.BreakpointDelete(entry.GetID())
        f = continued('outer-ready', 'debug_outer')
        values(f, 'outer-packed', {'packed_local.raw': 0x65a5a5a5})
        record('outer-packed.bytes',
               f.FindVariable('packed_local').GetType().GetByteSize(), 4)
        selected(f, 'outer', 37)
        caller = {'call_site.file_id': 2, 'call_site.line': config['caller_line'],
                  'call_site.column': config['caller_column']}
        values(f, 'caller', caller)
        record('caller ABI bytes', f.FindVariable('call_site').GetType().GetByteSize(), 12)
        process.GetSelectedThread().StepInto()
        f = frame('inner-entry', 'debug_inner')
        unavailable(f, 'scalar_local')
        f = continued('inner-ready', 'debug_inner')
        selected(f, 'inner', 38)
        unavailable(f, 'step_local')
        unavailable(f, 'next_local')
        t = process.GetSelectedThread()
        record('nested stack', [t.GetFrameAtIndex(i).GetFunctionName() for i in range(3)],
               ['debug_inner', 'debug_outer', 'main'])
        for index in range(t.GetNumFrames()):
            print('STACK', t.GetFrameAtIndex(index))
        selected(t.GetFrameAtIndex(1), 'saved-outer', 37)
        values(t.GetFrameAtIndex(1), 'saved-caller', caller)
        record('record bytes', f.FindVariable('record_local').GetType().GetByteSize(), 16)
        record('pointer bytes', f.FindVariable('pointer_local').GetType().GetByteSize(), 8)
        record('array bytes', f.FindVariable('array_local').GetType().GetByteSize(), 6)
        t.StepOver()
        f = frame('inner-next', 'debug_inner')
        values(f, 'stepped', {'step_local': 79})
        f = continued('inner-lexical', 'debug_inner')
        values(f, 'match aliases', {'param_record.huge': 7000000000, 'param_values.1': 222,
                                  'local_record.middle': 901, 'local_values.2': 333})
        bp = target.BreakpointCreateByName('debug_generic')
        record('generic instances', bp.GetNumLocations(), 2)
        process.Continue()
        f = frame('generic-entry', 'debug_generic')
        target.BreakpointDelete(bp.GetID())
        f = continued('generic-ready', 'debug_generic')
        values(f, 'generic', {'generic_param': -1, 'generic_bound': 1, 'generic_local': -1})
        record('generic stack', process.GetSelectedThread().GetFrameAtIndex(1).GetFunctionName(), 'main')
        f = continued('multiple-ready', 'debug_multiple')
        values(f, 'named results', {'base': 5, 'first': 15, 'second': 25})
        f = continued('aliases-ready', 'debug_aliases')
        values(f, 'destructuring', {'renamed_left': 15, 'renamed_right': 25})
        f = continued('loop-element', 'debug_aliases')
        values(f, 'loop alias', {'loop_element': 3, 'loop_sum': 0})
        process.Continue()
        record('inferior exited', process.GetState(), lldb.eStateExited)
        record('inferior status', process.GetExitStatus(), 42)
        Path(config['result']).write_text(json.dumps({'status': 'passed', 'checks': checks}, indent=2) + '\n')
        print('LANDIN LLDB ACCEPTANCE PASSED', len(checks))
    finally:
        if process.GetState() not in (lldb.eStateExited, lldb.eStateDetached):
            process.Kill()


def scalars(debugger, config_path):
    config = json.loads(Path(config_path).read_text())
    debugger.SetAsync(False)
    target = debugger.CreateTarget(config['executable'])
    bp = target.BreakpointCreateByLocation(config['source'], 15)
    assert bp.GetNumLocations() == 1
    process = target.LaunchSimple(None, None, config['cwd'])
    try:
        assert process.GetState() == lldb.eStateStopped
        f = process.GetSelectedThread().GetFrameAtIndex(0)
        assert f.GetLineEntry().GetLine() == 15
        for name, expected, width in (
            ('signed_byte', -7, 1), ('signed_half', -1234, 2),
            ('signed_word', -123456, 4), ('signed_long', -7000000000, 8),
            ('unsigned_byte', 250, 1), ('unsigned_half', 60000, 2),
            ('unsigned_word', 4000000000, 4), ('unsigned_long', 9000000000, 8),
            ('signed_size', -41, 8), ('unsigned_size', 42, 8),
            ('real_single', 1.5, 4), ('real_double', -2.25, 8), ('truth', 1, 1),
        ):
            v = f.FindVariable(name)
            assert v.IsValid() and v.GetError().Success(), (name, str(v))
            error = lldb.SBError()
            actual = (float(v.GetValue()) if name.startswith('real_')
                      else v.GetValueAsUnsigned(error) if name.startswith('unsigned_')
                      else v.GetValueAsSigned(error))
            print('SCALAR', name, actual, 'bytes', v.GetType().GetByteSize())
            assert error.Success() and actual == expected and v.GetType().GetByteSize() == width
        target.BreakpointDelete(bp.GetID())
        process.Continue()
        assert process.GetState() == lldb.eStateExited and process.GetExitStatus() == 42
        Path(config['result']).write_text(json.dumps({'status': 'passed', 'scalar_types': 13}) + '\n')
        print('LANDIN SCALAR LLDB PASSED')
    finally:
        if process.GetState() not in (lldb.eStateExited, lldb.eStateDetached):
            process.Kill()
