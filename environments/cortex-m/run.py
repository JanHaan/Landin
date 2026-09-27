#!/usr/bin/env python3
"""Independent M0 controls and native Landin/Renode peripheral execution.

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


PORTS = threading.local()
PORT_BLOCKS = iter(range(20000, 60000, 500))
PORT_LOCK = threading.Lock()


def renode_gdb_port():
    """A port for Renode's debugger stub that no concurrent worker also picks.

    Renode's stub binds a port number itself and cannot be handed a socket,
    so a port chosen by binding and releasing one races any other worker
    choosing at the same moment.  Each worker thread owns a block of five
    hundred ports and walks through it; blocks do not overlap.  A port some
    unrelated process holds still fails loudly: Renode reports it in use.
    """
    if not hasattr(PORTS, 'block'):
        with PORT_LOCK:
            PORTS.block = next(PORT_BLOCKS)
        PORTS.next = 0
    port = PORTS.block + PORTS.next % 500
    PORTS.next += 1
    return port


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


def oracle(text, marker, stock=False):
    require(text.count(marker) == 1, 'missing/duplicate result marker: ' + marker)
    require(not re.search(r'error|exception|assertion|unhandled read', text, re.I),
            'probe reports an error')
    for line in text.splitlines():
        if '[WARNING]' in line:
            require(stock and ('Tags: CIRC (0x1)' in line or
                    "Unknown baud rate, couldn't trigger the idle line interrupt" in line),
                    'unexpected model warning: ' + line.strip())


def remove_renode_lock(output):
    # Renode's process has exited before this is called. This empty runtime
    # coordination file is not evidence; native export excludes *.lock files.
    path = output / 'renode.config.lock'
    if path.exists() or path.is_symlink():
        require(path.is_file() and not path.is_symlink() and path.stat().st_size == 0,
                'unexpected Renode lock file')
        path.unlink()


class Run:
    def __init__(self, output, tools):
        self.out, self.tools = output, tools
        self.commands = []
        self.env = dict(os.environ, LC_ALL='C', LANG='C')
        self.env['LD_LIBRARY_PATH'] = str(tools / 'root/usr/lib/x86_64-linux-gnu')
        self.bin = tools / 'root/usr/bin'
        self.renode = tools / 'renode/renode_1.17.0-portable/renode'

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

    def command(self, name, argv, timeout=30):
        tick = time.monotonic()
        record = {'name': name, 'argv': list(map(str, argv)), 'timeout_seconds': timeout}
        self.commands.append(record)
        with (self.out / (name + '.log')).open('wb') as log:
            try:
                p = subprocess.Popen(record['argv'], cwd=self.out, env=self.env,
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

    def renode_script(self, name, lines, marker, stock=False, timeout=30):
        script = self.out / (name + '.resc')
        script.write_text('\n'.join(lines + ['quit']) + '\n')
        try:
            text = self.command(name, [self.renode, '--disable-xwt', '--console', '--plain',
                                      '--config', self.out / 'renode.config', script], timeout=timeout)
        finally:
            remove_renode_lock(self.out)
        oracle(text, marker, stock)

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
        symbols = self.build('peripheral')
        stage = symbols['stage']
        lines = [f'include @{HERE}/probes/PrototypePeripheral.cs', 'mach create "prototype"',
                 f'machine LoadPlatformDescription @{HERE}/probes/prototype.repl',
                 f'sysbus LoadELF @{self.out}/peripheral.elf']
        def run(): lines.append('emulation RunFor "0.001"')
        def check(expr): lines.append('python "' + expr + '"')
        def stage_is(n):
            check(f'assert monitor.Machine.SystemBus.ReadDoubleWord({stage}) == {n}')
        run(); stage_is(1)
        lines += ['sysbus.model Feed 88', f'sysbus WriteDoubleWord {stage} 2']
        run(); stage_is(3)
        lines += ['sysbus.model Feed 65', 'sysbus.model Feed 66']
        run(); lines += [f'sysbus WriteDoubleWord {stage} 4']
        run(); stage_is(5)
        lines += ['sysbus.model Feed 67', 'sysbus.model Feed 68']
        run(); lines += [f'sysbus WriteDoubleWord {stage} 6']
        run(); stage_is(7)
        lines += ['sysbus.model Feed 69']
        run(); lines += [f'sysbus WriteDoubleWord {stage} 8']
        run(); stage_is(9)
        lines += ['sysbus.model Error']
        run(); lines += [f'sysbus WriteDoubleWord {stage} 10']
        run()
        check(f'assert monitor.Machine.SystemBus.ReadDoubleWord({symbols["result"]}) == 0x610')
        lines += [f'include @{HERE}/probes/model-checks.py']
        self.renode_script('peripheral', lines, 'R610_PERIPHERAL_PASS')
        self.renode_script('stock', ['mach create "stock"',
                          f'machine LoadPlatformDescription @{HERE}/probes/stock.repl',
                          f'include @{HERE}/probes/stock.py'], 'R610_STOCK_LIMIT_CONFIRMED', stock=True)

    def execute(self, refine=None):
        supported_host()
        installed = json.loads((self.tools / 'installation.json').read_text())
        require(installed['lock_sha256'] == sha(HERE / 'tools.lock.json'), 'tool lock mismatch')
        before = {area: inventory(self.tools / area) for area in ('root', 'renode')}
        require(before == installed['files'], 'installed tools changed')
        (self.out / 'tools.json').write_text(json.dumps(installed, sort_keys=True)+'\n')
        for name, tool, expected in [
            ('qemu-version', self.bin / 'qemu-system-arm', '10.0.13'),
            ('gcc-version', self.bin / 'arm-none-eabi-gcc', '14.2.1 20241119'),
            ('binutils-version', self.bin / 'arm-none-eabi-as', '2.44'),
            ('gdb-version', self.bin / 'gdb-multiarch', '16.3'),
            ('renode-version', self.renode, '1.17.0+20260907gitf1dd1b4af')]:
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
