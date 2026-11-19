#!/usr/bin/env python3
"""Scripted Debug Adapter Protocol sessions through `refine dap`.

The session plays an editor: it compiles main.ldn with --debug=full and
--panic-map, starts `refine dap` (or `refine-dap`), and launches the
program, or attaches to a debugger stub already serving it.  It sets a
source breakpoint in `add` and a function breakpoint on `panic_handler`,
and holds what every debugger must show alike:

* the stop at the breakpoint, its frames `add` then `main` and the
  breakpoint's line in main.ldn;
* the arguments `a` and `b`, and the fields of `main`'s record `p`;
* a step to the next line, and a step out to the call in `main`;
* the panic in `crash` as an exception stop whose description names the
  line its site resolves to, `exceptionInfo` naming the check, and the
  frames `panic_handler` then `crash`;
* the exit status 42 the handler gives, what the program wrote when it was
  launched, and a disconnect that ends the adapter with status 0.

Every message is kept in OUTPUT/LABEL.dap.jsonl.  The lines come from the
`-- @NAME` markers in main.ldn.  The Linux lanes run it over GDB and over
LLDB's adapter, Darwin over LLDB, RV64 over GDB attached to QEMU's stub,
and FreeBSD's VM lanes over LLDB attached to lldb-server in the guest
(compiler/tests/freebsd/check.py imports run_session).
"""
import argparse
import json
import os
from pathlib import Path
import platform
import re
import select
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
SOURCE = HERE / 'main.ldn'

if sys.flags.optimize:
    raise RuntimeError('the DAP session needs Python assertions')

HOST_TARGETS = {('Linux', 'x86_64'): 'linux-x86-64',
                ('Linux', 'aarch64'): 'linux-arm64',
                ('Darwin', 'arm64'): 'darwin-arm64'}


def source_lines(source=SOURCE):
    """{marker: line} for each `-- @NAME` comment."""
    found = {}
    for number, text in enumerate(Path(source).read_text().splitlines(), 1):
        for name in re.findall(r'--\s*@([\w-]+)', text):
            found[name] = number
    return found


class Adapter:
    """An editor's end of one `refine dap` process."""

    def __init__(self, argv, transcript, limit=60):
        self.process = subprocess.Popen(argv, stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE)
        self.transcript = open(transcript, 'w')
        self.limit = limit
        self.seq = 0
        self.held = b''
        self.waiting = []
        self.seen = []

    def close(self):
        if self.process.poll() is None:
            self.process.kill()
        self.process.wait()
        self.transcript.close()

    def send(self, command, **arguments):
        self.seq += 1
        message = {'seq': self.seq, 'type': 'request', 'command': command,
                   'arguments': arguments}
        self.transcript.write(json.dumps({'sent': message}) + '\n')
        data = json.dumps(message).encode()
        self.process.stdin.write(b'Content-Length: %d\r\n\r\n' % len(data)
                                 + data)
        self.process.stdin.flush()
        return self.seq

    def receive(self):
        deadline = time.monotonic() + self.limit
        while True:
            end = self.held.find(b'\r\n\r\n')
            if end >= 0:
                headers = self.held[:end].decode().split('\r\n')
                length = int(next(line.split(':', 1)[1] for line in headers
                                  if line.lower().startswith('content-length')))
                if len(self.held) >= end + 4 + length:
                    message = json.loads(self.held[end + 4:end + 4 + length])
                    self.held = self.held[end + 4 + length:]
                    self.transcript.write(json.dumps({'received': message})
                                          + '\n')
                    self.transcript.flush()
                    self.seen.append(message)
                    return message
            left = deadline - time.monotonic()
            ready, _, _ = select.select([self.process.stdout], [], [],
                                        max(0, left))
            assert ready, f'refine dap said nothing for {self.limit} seconds'
            data = os.read(self.process.stdout.fileno(), 65536)
            assert data, 'refine dap ended its output'
            self.held += data

    def request(self, command, **arguments):
        seq = self.send(command, **arguments)
        while True:
            message = self.receive()
            if message.get('type') == 'response' \
                    and message.get('request_seq') == seq:
                assert message.get('command') == command, message
                return message
            self.waiting.append(message)

    def require(self, command, **arguments):
        answer = self.request(command, **arguments)
        assert answer.get('success'), (command, answer)
        return answer.get('body') or {}

    def event(self, name):
        for index, message in enumerate(self.waiting):
            if message.get('event') == name:
                return self.waiting.pop(index)
        while True:
            message = self.receive()
            if message.get('event') == name:
                return message
            self.waiting.append(message)


def frames(adapter, thread):
    return adapter.require('stackTrace', threadId=thread)['stackFrames']


def variables(adapter, reference):
    return {item['name']: item for item in
            adapter.require('variables',
                            variablesReference=reference)['variables']}


def locals_of(adapter, frame):
    scopes = adapter.require('scopes', frameId=frame['id'])['scopes']
    return variables(adapter, scopes[0]['variablesReference'])


def check(label, actual, expected, checks):
    print(f'{label}: {actual!r}', flush=True)
    assert actual == expected, (label, actual, expected)
    checks.append(label)


def run_session(adapter_argv, program, source, output, label, debugger=None,
                debugger_path=None, remote=None, cwd=None):
    """One scripted session; returns the checks it made.  Raises
    AssertionError naming the first that failed."""
    lines = source_lines(source)
    output = Path(output)
    output.mkdir(parents=True, exist_ok=True)
    adapter = Adapter(adapter_argv, output / (label + '.dap.jsonl'))
    checks = []
    name = Path(source).name
    try:
        capabilities = adapter.require(
            'initialize', clientID='landin-session', adapterID='landin',
            linesStartAt1=True, columnsStartAt1=True, pathFormat='path')
        check('capabilities.exceptionInfo',
              capabilities.get('supportsExceptionInfoRequest'), True, checks)
        start = {'program': str(program),
                 'cwd': str(cwd or Path(program).parent)}
        if debugger:
            start['debugger'] = debugger
        if debugger_path:
            start['debuggerPath'] = debugger_path
        if remote:
            start['remote'] = remote
        adapter.require('attach' if remote else 'launch', **start)
        adapter.event('initialized')
        points = adapter.require(
            'setBreakpoints', source={'path': str(source)},
            breakpoints=[{'line': lines['add']}])['breakpoints']
        check('breakpoint.verified', points[0].get('verified'), True, checks)
        adapter.require('setFunctionBreakpoints',
                        breakpoints=[{'name': 'panic_handler'}])
        adapter.require('configurationDone')

        stop = adapter.event('stopped')['body']
        check('stop.reason', stop['reason'], 'breakpoint', checks)
        thread = stop['threadId']
        stack = frames(adapter, thread)
        check('stop.function', stack[0]['name'], 'add', checks)
        check('stop.line', stack[0]['line'], lines['add'], checks)
        check('stop.file', Path(stack[0]['source']['path']).name, name, checks)
        check('caller.function', stack[1]['name'], 'main', checks)
        check('caller.line', stack[1]['line'], lines['call'], checks)
        arguments = locals_of(adapter, stack[0])
        check('add.a', arguments['a']['value'], '3', checks)
        check('add.b', arguments['b']['value'], '4', checks)
        record = locals_of(adapter, stack[1])['p']
        assert record['variablesReference'] > 0, record
        fields = variables(adapter, record['variablesReference'])
        check('main.p.x', fields['x']['value'], '3', checks)
        check('main.p.y', fields['y']['value'], '4', checks)

        adapter.require('next', threadId=thread)
        stop = adapter.event('stopped')['body']
        check('next.reason', stop['reason'], 'step', checks)
        check('next.line', frames(adapter, thread)[0]['line'],
              lines['after-add'], checks)
        adapter.require('stepOut', threadId=thread)
        stop = adapter.event('stopped')['body']
        check('out.reason', stop['reason'], 'step', checks)
        check('out.function', frames(adapter, thread)[0]['name'], 'main',
              checks)

        adapter.require('continue', threadId=thread)
        stop = adapter.event('stopped')['body']
        thread = stop['threadId']
        check('panic.reason', stop['reason'], 'exception', checks)
        described = re.fullmatch(r'panic: overflow at (.*):(\d+):(\d+)',
                                 stop.get('description', ''))
        assert described, stop
        check('panic.file', Path(described[1]).name, name, checks)
        check('panic.line', int(described[2]), lines['crash'], checks)
        info = adapter.require('exceptionInfo', threadId=thread)
        check('panic.exceptionId', info['exceptionId'], 'overflow', checks)
        stack = frames(adapter, thread)
        check('panic.function', stack[0]['name'], 'panic_handler', checks)
        check('panic.caller', stack[1]['name'], 'crash', checks)

        adapter.require('continue', threadId=thread)
        check('exit.code', adapter.event('exited')['body']['exitCode'], 42,
              checks)
        if not remote:
            written = ''.join(message['body']['output'] for message
                              in adapter.waiting + adapter.seen
                              if message.get('event') == 'output'
                              and message['body'].get('category') == 'stdout')
            check('program.output', 'started' in written, True, checks)
        adapter.require('disconnect')
        check('adapter.status', adapter.process.wait(timeout=30), 0, checks)
        return checks
    finally:
        adapter.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('--refine', required=True,
                        help='the refine whose `refine dap` is driven')
    parser.add_argument('--adapter', help='run this refine-dap directly'
                        ' rather than through `refine dap`')
    parser.add_argument('--target', help='the target to compile for;'
                        ' the host\'s by default')
    parser.add_argument('--debugger', action='append',
                        choices=('gdb', 'lldb'),
                        help='a debugger to run the session over; the'
                        ' program\'s own by default; may be repeated')
    parser.add_argument('--debugger-path', action='append', default=[],
                        metavar='NAME=PATH',
                        help='start the debugger NAME as PATH')
    parser.add_argument('--qemu', help='run the program under this QEMU'
                        ' user emulator and attach GDB to its stub')
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    sys.path.insert(0, str(HERE.parents[2] / 'scripts'))
    import refine_revision
    import build_lock
    refine_revision.warn(args.refine)  # is it this checkout's?
    #  A rebuild of this build waits for the session rather than replace
    #  refine-dap under it.
    build_lock.reading(args.refine)

    output = Path(args.output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    target = args.target or HOST_TARGETS[(platform.system(),
                                          platform.machine())]
    program = output / 'program'
    compiled = subprocess.run(
        [args.refine, 'compile', '--target=' + target, '--debug=full',
         '--panic-map', str(SOURCE), '-o', str(program)],
        capture_output=True, text=True)
    assert compiled.returncode == 0, compiled.stdout + compiled.stderr
    adapter = [args.adapter] if args.adapter else [args.refine, 'dap']
    paths = dict(item.split('=', 1) for item in args.debugger_path)
    results = {}
    for debugger in args.debugger or [None]:
        label = f'{target}-{debugger or "default"}'
        qemu = None
        remote = None
        try:
            if args.qemu:
                stub = output / (label + '.gdb.sock')
                stub.unlink(missing_ok=True)
                qemu = subprocess.Popen([args.qemu, '-g', str(stub),
                                         str(program)])
                deadline = time.monotonic() + 15
                while not stub.exists() and time.monotonic() < deadline:
                    time.sleep(0.02)
                assert stub.exists(), 'QEMU did not open its GDB socket'
                remote = str(stub)
            checks = run_session(adapter, program, SOURCE, output, label,
                                 debugger=debugger,
                                 debugger_path=paths.get(debugger or ''),
                                 remote=remote)
            results[label] = {'status': 'passed', 'checks': len(checks)}
            print(f'LANDIN DAP SESSION PASSED {label}: {len(checks)} checks',
                  flush=True)
        finally:
            if qemu is not None:
                qemu.kill()
                qemu.wait()
    (output / 'result.json').write_text(json.dumps(results, indent=1) + '\n')


if __name__ == '__main__':
    main()
