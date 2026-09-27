#!/usr/bin/env python3
"""Independent M0 controls and native Landin peripheral execution on QEMU.

Retained hosted transport is separate from the compiler-generated M0 execution.
"""
import argparse
import atexit
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import socket
import subprocess
import sys
import threading
import time

from gdb_server import GdbServer
from setup import DEFAULT, HERE, inventory, sha, supported_host

#  The GDB every session on one thread shares; `Run.debug` starts it.  One
#  per thread, because a GDB serves one session at a time and the corpus
#  runs its programs on several workers.
SERVERS = threading.local()


def workers():
    """How many programs the corpus runs at once: LANDIN_CORTEX_JOBS, default 1."""
    value = os.environ.get('LANDIN_CORTEX_JOBS', '1')
    require(value.isdigit() and 1 <= int(value) <= 64, 'LANDIN_CORTEX_JOBS must be 1 to 64')
    return int(value)

FLAGS = ['-mcpu=cortex-m0', '-mthumb', '-mfloat-abi=soft', '-mabi=aapcs',
         '-ffreestanding', '-fno-builtin', '-fno-omit-frame-pointer', '-g3',
         '-O1', '-Wall', '-Wextra', '-Werror', '-nostdlib']


def gdb_listener():
    """A loopback listening socket for QEMU's debugger stub, and its QEMU arguments.

    Choosing a free port and letting QEMU bind it later races any other
    process choosing one in between, which parallel workers do.  QEMU is
    given this socket already bound and listening, so no other process can
    take the port.  The caller passes `fd` to Popen's `pass_fds` and closes
    the socket after QEMU has started.
    """
    sock = socket.socket()
    sock.bind(('127.0.0.1', 0))
    sock.listen(1)
    os.set_inheritable(sock.fileno(), True)
    #  `-gdb tcp:` sets TCP_NODELAY and a plain socket chardev does not;
    #  without it every small stub reply waits on Nagle, three seconds a
    #  session.
    return sock, sock.getsockname()[1], [
        '-chardev', 'socket,id=gdb,fd=%d,server=on,wait=off,nodelay=on' % sock.fileno(),
        '-gdb', 'chardev:gdb']


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def stop(process):
    if process.poll() is None:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=2)


def oracle(output, marker):
    """Hold a debugger session's output to its result marker and to no error."""
    require(output.count(marker) == 1, 'missing/duplicate result marker: ' + marker)
    require(not re.search(r'error|exception|assertion|unhandled read', output, re.I),
            'probe reports an error')
    for line in output.splitlines():
        require('[WARNING]' not in line, 'unexpected warning: ' + line.strip())


class Run:
    def __init__(self, output, tools):
        self.out, self.tools = output, tools
        self.commands = []
        self.env = dict(os.environ, LC_ALL='C', LANG='C')
        self.env['LD_LIBRARY_PATH'] = str(tools / 'root/usr/lib/x86_64-linux-gnu')
        self.bin = tools / 'root/usr/bin'

    def debug(self, name, elf, script, timeout=20):
        """One debugger session, recorded like a command.

        The session runs in the process-wide GDB server rather than a GDB of
        its own; see gdb_server.py.  Its record, log and failure are this
        run's, exactly as a batch `gdb-multiarch -x SCRIPT ELF` would leave
        them.
        """
        server = getattr(SERVERS, 'server', None)
        if server is not None and (server.gdb, server.env) != (self.bin / 'gdb-multiarch', self.env):
            server.stop()
            server = None
        if server is None:
            server = SERVERS.server = GdbServer(self.bin / 'gdb-multiarch', self.env, self.out)
            atexit.register(server.stop)
        server.cwd = self.out
        tick = time.monotonic()
        record = {'name': name, 'argv': [str(self.bin / 'gdb-multiarch'), '-q', '-nx',
                                         '-batch', str(elf), '-x', str(script)],
                  'timeout_seconds': timeout, 'server': True}
        self.commands.append(record)
        log = self.out / (name + '.log')
        try:
            try:
                record["exit"] = 0 if server.session(elf, script, log, timeout) else 1
            except TimeoutError:
                record['timed_out'] = True
                raise RuntimeError(name + ' timed out')
            except OSError as error:
                record['exit'] = None
                raise RuntimeError(name + ' lost its debugger: ' + str(error))
        finally:
            record['seconds'] = time.monotonic() - tick
            (self.out / 'commands.json').write_text(json.dumps(self.commands, indent=2)+'\n')
        require(record['exit'] == 0, name + ' failed; inspect retained log')
        return log.read_text(errors='replace')

    def command(self, name, argv, timeout=30, env=None):
        tick = time.monotonic()
        record = {'name': name, 'argv': list(map(str, argv)), 'timeout_seconds': timeout}
        self.commands.append(record)
        with (self.out / (name + '.log')).open('wb') as log:
            try:
                p = subprocess.Popen(record['argv'], cwd=self.out, env=env or self.env,
                                     stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
                try:
                    record['exit'] = p.wait(timeout=timeout)
                except subprocess.TimeoutExpired:
                    record['timed_out'] = True
                    stop(p)
                    raise RuntimeError(name + ' timed out')
            finally:
                record['seconds'] = time.monotonic() - tick
                (self.out / 'commands.json').write_text(json.dumps(self.commands, indent=2)+'\n')
        require(record['exit'] == 0, name + ' failed; inspect retained log')
        return (self.out / (name + '.log')).read_text(errors='replace')

    def build(self, name, extra=()):
        self.command('build-' + name, [self.bin / 'arm-none-eabi-gcc', *FLAGS,
                     '-Wl,-T,' + str(HERE / 'probes/memory.ld') + ',--gc-sections,-Map,' + name + '.map',
                     HERE / 'probes/start.S', HERE / ('probes/' + name + '.c'), *extra, '-o', name + '.elf'])
        self.command('elf-' + name, [self.bin / 'arm-none-eabi-readelf', '-h', '-A', '-S', name + '.elf'])
        self.command('size-' + name, [self.bin / 'arm-none-eabi-size', name + '.elf'])
        symbols = self.command('symbols-' + name, [self.bin / 'arm-none-eabi-nm', name + '.elf'])
        return {s[2]: int(s[0], 16) for line in symbols.splitlines() if len(s := line.split()) == 3}

    def qemu(self):
        symbols = self.build('cpu')
        # Loopback-only debugger endpoint, fresh port; a bind race fails this run.
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
        gdb = [f'target remote 127.0.0.1:{port}', 'set pagination off', 'set confirm off',
               'python', 'import gdb',
               'def value(expr): return int(gdb.parse_and_eval(expr))',
               'assert value("$sp") == 0x20004000',
               f'assert value("$pc") == {symbols["reset"]}',
               'assert value("*(unsigned int*)0") == 0x20004000',
               f'assert value("*(unsigned int*)4") == {symbols["reset"] | 1}',
               'end', 'stepi', 'python',
               f'assert value("$pc") != {symbols["reset"]}', 'end',
               'break done', 'continue', 'python',
               'assert value("result") == 0x610',
               'assert all(value(n) == 1 for n in ("svc_seen", "pend_seen", "tick_seen", "irq_seen"))',
               'end', 'set $pc = fault_probe', 'break fault_done', 'continue',
               'python', 'assert value("fault_seen") == 3', 'end',
               'monitor system_reset', 'maintenance flush register-cache', 'python',
               f'assert value("$pc") == {symbols["reset"]}',
               'assert value("$sp") == 0x20004000', 'end',
               'continue', 'python', 'assert value("result") == 0x610',
               'print("R610_QEMU_PASS")', 'end', 'quit']
        (self.out / 'cpu.gdb').write_text('\n'.join(gdb)+'\n')
        argv = [str(self.bin / 'qemu-system-arm'), '-M', 'microbit', '-accel', 'tcg,thread=single',
                '-display', 'none', '-monitor', 'none', '-serial', 'file:uart.log',
                '-kernel', 'cpu.elf', '-S', '-gdb', f'tcp:127.0.0.1:{port}']
        self.commands.append({'name': 'qemu', 'argv': argv, 'timeout_seconds': 25})
        with (self.out / 'qemu.log').open('wb') as log:
            p = subprocess.Popen(argv, cwd=self.out, env=self.env, stdout=log, stderr=log,
                                 start_new_session=True)
            try:
                deadline = time.monotonic() + 3
                while True:
                    require(p.poll() is None, 'QEMU exited before debugger connection')
                    try:
                        with socket.create_connection(('127.0.0.1', port), timeout=.1):
                            break
                    except OSError:
                        require(time.monotonic() < deadline, 'QEMU debugger startup timed out')
                        time.sleep(.02)
                text = self.debug('gdb', 'cpu.elf', 'cpu.gdb', timeout=20)
                oracle(text, 'R610_QEMU_PASS')
            finally:
                stop(p)
        require((self.out / 'uart.log').read_bytes() == b'R610 UART\nR610 UART\n', 'UART output mismatch')

    def peripheral(self):
        """The prototype-1 register/DMA contract under hand-written C."""
        from machine import Machine, Refused
        from models import PrototypePeripheral
        symbols = self.build('peripheral')
        stage = symbols['stage']
        model = PrototypePeripheral()
        with Machine(self, self.out / 'peripheral.elf', 'peripheral', poll=[stage]) as m:
            m.map(0x40020000, 0x7000, model)
            m.trap(symbols['fault_done'], 'hard fault')
            u32 = m.u32
            def reach(n):
                m.until(lambda: u32(stage) == n)
            def settle_then(n):
                m.settle()
                m.write_u32(stage, n)
            reach(1)
            model.feed(88)
            m.write_u32(stage, 2)
            reach(3)
            model.feed(65)
            model.feed(66)
            settle_then(4)
            reach(5)
            model.feed(67)
            model.feed(68)
            settle_then(6)
            reach(7)
            model.feed(69)
            settle_then(8)
            reach(9)
            model.error()
            settle_then(10)
            m.settle()
            require(u32(symbols['result']) == 0x610, 'prototype peripheral result %#x'
                    % u32(symbols['result']))
        require(model.transfers == 5 and model.errors == 1, 'prototype transfers and errors')
        require(not model.level('irq'), 'prototype interrupt left asserted')
        # Unknown registers and direction or width violations are refusals.
        for action in [lambda: model.read(0x6004, 4), lambda: model.write(0x6000, 4, 1),
                       lambda: model.read(0x6068, 4), lambda: model.read(0, 2),
                       lambda: model.write(0x10, 2, 1), lambda: model.write(0x605c, 4, 65536)]:
            try:
                action()
            except Refused:
                continue
            raise RuntimeError('prototype model accepted a refused access')
        model.reset()
        require(model.read(0, 4) == 0 and model.read(0x6000, 4) == 0, 'prototype reset')
        # An invalid destination and an unsupported direction are errors, not writes.
        model.write(0x605c, 4, 4)
        model.write(0x6060, 4, 0x40021004)
        model.write(0x6064, 4, 0x100)
        model.write(0x6058, 4, 9)
        model.feed(42)
        require(model.transfers == 0 and model.errors == 1, 'bad destination accepted')
        require(model.read(0x6000, 4) == 0x80 and model.level('irq'), 'error status')
        model.write(0x6004, 4, 0)
        require(model.read(0x6000, 4) == 0x80, 'zero one-clears cleared')
        model.write(0x6004, 4, 0x80)
        require(model.read(0x6000, 4) == 0 and not model.level('irq'), 'one-clears')
        model.write(0x6064, 4, 0x20000000)
        model.write(0x6058, 4, 0xc9)
        model.feed(42)
        require(model.transfers == 0 and model.errors == 2, 'unsupported direction accepted')
        model.set_input(0x1234)
        require(model.read(0x10, 2) == 0x1234, 'halfword input')

    def execute(self, refine=None):
        supported_host()
        installed = json.loads((self.tools / 'installation.json').read_text())
        require(installed['lock_sha256'] == sha(HERE / 'tools.lock.json'), 'tool lock mismatch')
        before = {area: inventory(self.tools / area) for area in ('root',)}
        require(before == installed['files'], 'installed tools changed')
        (self.out / 'tools.json').write_text(json.dumps(installed, sort_keys=True)+'\n')
        for name, tool, expected in [
            ('qemu-version', self.bin / 'qemu-system-arm', '10.0.13'),
            ('gcc-version', self.bin / 'arm-none-eabi-gcc', '14.2.1 20241119'),
            ('binutils-version', self.bin / 'arm-none-eabi-as', '2.44'),
            ('gdb-version', self.bin / 'gdb-multiarch', '16.3')]:
            require(expected in self.command(name, [tool, '--version']), name + ' mismatch')
        self.qemu()
        self.peripheral()
        from abi import execute
        execute(self)
        from memory import execute as memory_execute
        memory_execute(self)
        from packed import execute as packed_execute
        packed_execute(self)
        require(refine is not None, 'native Landin compiler is required')
        from packed_native import execute as native_execute
        native_execute(self, refine)
        from backend_acceptance import execute as backend_execute
        backend_execute(self, refine)
        from firmware import execute_suite as firmware_execute
        firmware_execute(self, refine)
        from freestanding import execute_suite as freestanding_execute
        freestanding_execute(self, refine)
        from devices import execute_suite as devices_execute
        devices_execute(self, refine)
        from driver import execute_suite as driver_execute
        driver_execute(self, refine)
        from evidence import execute_suite as evidence_execute
        evidence_execute(self, refine)
        require(before == {area: inventory(self.tools / area) for area in before}, 'tools changed during probes')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tools', type=Path, default=DEFAULT)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--refine', type=Path, required=True)
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    record = {'status': 'failed', 'inputs': inventory(HERE), 'platform': os.uname().sysname,
              'machine': os.uname().machine, 'kernel': os.uname().release}
    try:
        Run(out, args.tools.resolve()).execute(args.refine)
        require(record['inputs'] == inventory(HERE), 'probe inputs changed')
        record['status'] = 'passed'
    except Exception as exc:
        record['error'] = str(exc)
        print('Cortex-M probes FAILED:', exc, file=sys.stderr)
    finally:
        record['files'] = inventory(out)
        (out / 'result.json').write_text(json.dumps(record, indent=2, sort_keys=True)+'\n')
    print('Cortex-M probes ' + record['status'] + ': ' + str(out))
    return 0 if record['status'] == 'passed' else 1


if __name__ == '__main__':
    sys.exit(main())
