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
from setup import (AREAS, DEFAULT, ESPRESSIF, HERE, RISCV, arm_archive, installed_tools,
                   inventory, riscv_archive, sha, supported_host)

#  The GDB every session on one thread shares; `Run.debug` starts it.  One
#  per thread, because a GDB serves one session at a time and the corpus
#  runs its programs on several workers.
SERVERS = threading.local()


def workers():
    """How many programs the corpus runs at once: LANDIN_CORTEX_JOBS, default 1."""
    value = os.environ.get('LANDIN_CORTEX_JOBS', '1')
    require(value.isdigit() and 1 <= int(value) <= 64, 'LANDIN_CORTEX_JOBS must be 1 to 64')
    return int(value)

#  Every Arm C compilation and link of the lanes: int-sized enums are
#  Cortex-M's C boundary's (D985), where the pinned GCC defaults to short.
FLAGS = ['-mcpu=cortex-m0', '-mthumb', '-mfloat-abi=soft', '-mabi=aapcs', '-fno-short-enums',
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


class CommandFailed(RuntimeError):
    """A recorded command or debugger session that failed or ran out of time.

    The message names the command, how it ended and the log it left, so a
    failure line is enough to find what the tool said.  `name` and `log`
    let a caller decide what the failure means, as the corpus does for a
    link that overflowed its region.
    """

    def __init__(self, name, log, ended):
        super().__init__('%s %s; inspect %s' % (name, ended, log))
        self.name, self.log, self.ended = name, log, ended


def current_lock(tools, installed):
    """Refuse an installation made from another tools.lock.json, saying how to replace it."""
    require(installed['lock_sha256'] == sha(HERE / 'tools.lock.json'),
            'the tools at %s were installed from another tools.lock.json than this'
            ' checkout\'s; install a fresh --tools root with setup.py' % tools)


def unchanged(tools, installed, found):
    """Refuse an installation whose files FOUND differ from what setup recorded,
    naming each area that differs."""
    differ = sorted(area for area in set(found) | set(installed['files'])
                    if found.get(area) != installed['files'].get(area))
    require(not differ, 'installed tools changed since setup recorded them, in %s of %s;'
            ' install a fresh --tools root with setup.py' % (', '.join(differ), tools))


def limit_text(seconds):
    return '%g-second' % seconds


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
        #  Debian's libpulse, which Espressif's QEMU loads through SDL,
        #  finds its own common library through a RUNPATH under /usr.
        libraries = tools / 'root/usr/lib/x86_64-linux-gnu'
        self.env['LD_LIBRARY_PATH'] = '%s:%s' % (libraries, libraries / 'pulseaudio')
        self.bin = tools / 'root/usr/bin'
        self.arm = tools / 'gnat-arm-elf/bin'
        self.riscv = tools / RISCV / 'bin'
        self.espressif = tools / ESPRESSIF / 'bin'

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
                raise CommandFailed(name, log, 'timed out: the session reached its %s limit %.1f s'
                                    ' after it started' % (limit_text(timeout),
                                                           time.monotonic() - tick))
            except OSError as error:
                record['exit'] = None
                raise CommandFailed(name, log, 'lost its debugger: ' + str(error))
        finally:
            record['seconds'] = time.monotonic() - tick
            (self.out / 'commands.json').write_text(json.dumps(self.commands, indent=2)+'\n')
        if record['exit'] != 0:
            raise CommandFailed(name, log, 'failed')
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
                    raise CommandFailed(name, self.out / (name + '.log'),
                                        'timed out: it reached its %s limit %.1f s after it'
                                        ' started' % (limit_text(timeout),
                                                      time.monotonic() - tick))
            finally:
                record['seconds'] = time.monotonic() - tick
                (self.out / 'commands.json').write_text(json.dumps(self.commands, indent=2)+'\n')
        if record['exit'] != 0:
            raise CommandFailed(name, self.out / (name + '.log'),
                                'failed with exit %d' % record['exit'])
        return (self.out / (name + '.log')).read_text(errors='replace')

    def build(self, name, extra=()):
        self.command('build-' + name, [self.arm / 'arm-eabi-gcc', *FLAGS,
                     '-Wl,-T,' + str(HERE / 'probes/memory.ld') + ',--gc-sections,-Map,' + name + '.map',
                     HERE / 'probes/start.S', HERE / ('probes/' + name + '.c'), *extra, '-o', name + '.elf'])
        self.command('elf-' + name, [self.arm / 'arm-eabi-readelf', '-h', '-A', '-S', name + '.elf'])
        self.command('size-' + name, [self.arm / 'arm-eabi-size', name + '.elf'])
        symbols = self.command('symbols-' + name, [self.arm / 'arm-eabi-nm', name + '.elf'])
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

    def execute(self, refine=None, lanes=None):
        """Run LANES, every lane by default, each after the lanes it needs,
        and report each one's verdict whether or not an earlier one failed.

        The installation and tool versions are checked first, and a failure
        there stops the run, since nothing after it would be evidence.  A
        lane whose prerequisite failed is reported as not run.  Raises once
        every selected lane has run, naming each that did not pass.
        """
        supported_host()
        installed = json.loads((self.tools / 'installation.json').read_text())
        current_lock(self.tools, installed)
        require(installed.get('arm') == {key: arm_archive()[key] for key in ('version', 'sha256')},
                'the installed arm-elf archive is not the one environments/pins.sh pins')
        require(installed.get('riscv') == {key: riscv_archive()[key] for key in ('version', 'sha256')},
                'the installed riscv64-elf archive is not the one environments/pins.sh pins')
        before = {area: inventory(self.tools / area) for area in AREAS}
        unchanged(self.tools, installed, before)
        (self.out / 'tools.json').write_text(json.dumps(installed, sort_keys=True)+'\n')
        for name, tool, expected in [
            ('qemu-version', self.bin / 'qemu-system-arm', '10.0.13'),
            ('gcc-version', self.arm / 'arm-eabi-gcc',
             '(GNAT-FSF-builds) ' + arm_archive()['version'].rsplit('-', 1)[0]),
            ('binutils-version', self.arm / 'arm-eabi-as', '2.46.1'),
            ('riscv-gcc-version', self.riscv / 'riscv64-elf-gcc',
             '(GNAT-FSF-builds) ' + riscv_archive()['version'].rsplit('-', 1)[0]),
            ('riscv-binutils-version', self.riscv / 'riscv64-elf-as', '2.46.1'),
            ('espressif-qemu-version', self.espressif / 'qemu-system-riscv32',
             '9.2.2 (esp_develop_9.2.2_20260417)'),
            ('gdb-version', self.bin / 'gdb-multiarch', '16.3')]:
            require(expected in self.command(name, [tool, '--version']), name + ' mismatch')
        selected = selection(lanes)
        needing = [name for name in selected if name in NEEDS_REFINE]
        require(refine is not None or not needing,
                'the lanes %s need a native Landin compiler; pass --refine PATH'
                % ', '.join(needing))
        verdicts = {}
        for name in selected:
            missing = [need for need in NEEDS.get(name, ())
                       if verdicts.get(need, {}).get('status') != 'passed']
            if missing:
                verdicts[name] = {'status': 'not run',
                                  'error': 'it needs the %s lane, which did not pass'
                                           % ', '.join(missing)}
            else:
                tick = time.monotonic()
                try:
                    self.lane(name, refine)
                    verdicts[name] = {'status': 'passed'}
                except Exception as error:
                    verdicts[name] = {'status': 'failed', 'error': str(error)}
                verdicts[name]['seconds'] = round(time.monotonic() - tick, 1)
            print('Cortex-M lane %s %s%s%s' % (name, verdicts[name]['status'],
                  ' in %.0f s' % verdicts[name]['seconds'] if 'seconds' in verdicts[name] else '',
                  ': ' + verdicts[name]['error'] if 'error' in verdicts[name] else ''),
                  file=sys.stderr if 'error' in verdicts[name] else sys.stdout, flush=True)
        self.verdicts = verdicts
        require(before == {area: inventory(self.tools / area) for area in before}, 'tools changed during probes')
        failed = [name for name, verdict in verdicts.items() if verdict['status'] != 'passed']
        require(not failed, '%d of %d lanes did not pass: %s' % (
            len(failed), len(verdicts), '; '.join(
                '%s %s: %s' % (name, verdicts[name]['status'], verdicts[name]['error'])
                for name in failed)))
        return verdicts

    def lane(self, name, refine):
        """Run the lane NAME of LANES."""
        if name == 'cpu':
            self.qemu()
        elif name == 'peripheral':
            self.peripheral()
        elif name == 'abi':
            from abi import execute
            execute(self)
        elif name == 'memory':
            from memory import execute as memory_execute
            memory_execute(self)
        elif name == 'packed':
            from packed import execute as packed_execute
            packed_execute(self)
        elif name == 'packed-native':
            from packed_native import execute as native_execute
            native_execute(self, refine)
        elif name == 'backend':
            from backend_acceptance import execute as backend_execute
            backend_execute(self, refine)
        elif name == 'rv32-controls':
            from rv32_controls import execute_suite as rv32_execute
            rv32_execute(self)
        elif name in ('mps2-an505', 'mps2-an500', 'esp32c3', 'sifive-e'):
            from backend_acceptance import execute_lane
            execute_lane(self, refine, name)
        elif name == 'firmware':
            from firmware import execute_suite as firmware_execute
            firmware_execute(self, refine)
        elif name == 'freestanding':
            from freestanding import execute_suite as freestanding_execute
            freestanding_execute(self, refine)
        elif name == 'devices':
            from devices import execute_suite as devices_execute
            devices_execute(self, refine)
        elif name == 'descriptions':
            from descriptions import execute_suite as descriptions_execute
            descriptions_execute(self, refine)
        elif name == 'driver':
            from driver import execute_suite as driver_execute
            driver_execute(self, refine)
        elif name == 'counterpart':
            from counterpart import execute_suite as counterpart_execute
            counterpart_execute(self, refine)
        else:
            from evidence import execute_suite as evidence_execute
            evidence_execute(self, refine)


#  Every lane run.py runs, in the order it runs them.  `counterpart` is
#  prototype 5's firmware counterpart, its trace judged (D448).  `evidence` compares
#  each debug image with the `driver` lane's, so it needs that lane, and
#  selecting it alone runs both.  `mps2-an505` and `mps2-an500` are the
#  whole corpus again on those emulator lanes (backend_corpus.LANES): at
#  armv8-m.main on the AN505's Cortex-M33, and at armv7e-m with FPv5-D16 on
#  the AN500's Cortex-M7.  `esp32c3` and `sifive-e` are the whole corpus
#  on Espressif's QEMU at rv32imc and rv32imac (D695), each after
#  `rv32-controls`, which shows the RV32 harness judging hand-written
#  programs on both machines and needs no compiler.
LANES = ('cpu', 'peripheral', 'abi', 'memory', 'packed', 'rv32-controls', 'packed-native',
         'backend', 'mps2-an505', 'mps2-an500', 'esp32c3', 'sifive-e', 'firmware',
         'freestanding', 'devices', 'descriptions', 'driver', 'counterpart', 'evidence')
NEEDS = {'evidence': ('driver',), 'esp32c3': ('rv32-controls',),
         'sifive-e': ('rv32-controls',)}
NEEDS_REFINE = set(LANES[LANES.index('packed-native'):])

#  The gate's three Cortex-M jobs, `cortex-m-programs`, `cortex-m-corpus`
#  and `cortex-m-rv32`, each run one part, so none is FILTERED: together
#  they are every lane above, each exactly once, and each part holds the
#  lanes its lanes need, which test.py holds them to.  `corpus` is the three
#  whole-corpus lanes, the M0's `backend` and the M33's and M7's again;
#  `rv32` the RV32 controls and the two RV32 whole corpora (D695), a job of
#  their own, since two more corpora would put `corpus` past the gate's
#  hour; `programs` is the rest, the probes, the firmware and device
#  programs and the debug evidence.  At LANDIN_CORTEX_JOBS=6 on a 32-CPU
#  host the first two took 694 and 708 seconds, and all of them 1,306 in
#  one run, which on a four-CPU runner put one job at risk of that hour.
PARTS = {'programs': ('cpu', 'peripheral', 'abi', 'memory', 'packed', 'packed-native',
                      'firmware', 'freestanding', 'devices', 'descriptions', 'driver',
                      'counterpart', 'evidence'),
         'corpus': ('backend', 'mps2-an505', 'mps2-an500'),
         'rv32': ('rv32-controls', 'esp32c3', 'sifive-e')}


def selection(lanes):
    """LANES in run order with every lane they need; every lane for None."""
    if not lanes:
        return list(LANES)
    unknown = sorted(set(lanes) - set(LANES))
    require(not unknown, 'unknown lane %s; the lanes are %s'
            % (', '.join(unknown), ', '.join(LANES)))
    wanted = set(lanes)
    for name in lanes:
        wanted.update(NEEDS.get(name, ()))
    return [name for name in LANES if name in wanted]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tools', type=Path, default=DEFAULT)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--refine', type=Path,
                        help='the native Landin compiler; every lane from packed-native on'
                             ' needs one, and the probes before it do not')
    chosen = parser.add_mutually_exclusive_group()
    chosen.add_argument('--lane', action='append', choices=LANES,
                        help='run only this lane, and the lanes it needs; repeat for more.'
                             ' A run that selects lanes is FILTERED and is not the gate\'s')
    chosen.add_argument('--part', choices=PARTS,
                        help='run one part of every lane, as one of the gate\'s three Cortex-M'
                             ' jobs does: %s.  The parts together are every lane, so a part'
                             ' is not FILTERED' % '; '.join(
                                 '%s is %s' % (name, ', '.join(lanes))
                                 for name, lanes in PARTS.items()))
    args = parser.parse_args()
    #  A rebuild of this build waits for the lane, rather than replace
    #  refine between two of its compilations.
    sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))
    import build_lock
    if args.refine:
        build_lock.reading(args.refine)
    supported_host(args.output)
    tools = installed_tools(args.tools)
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    lanes = selection(PARTS[args.part] if args.part else args.lane)
    scope = ('FILTERED: ' + ', '.join(lanes) if args.lane else
             'part %s of every lane: %s' % (args.part, ', '.join(lanes)) if args.part else
             'every lane')
    record = {'status': 'failed', 'inputs': inventory(HERE), 'platform': os.uname().sysname,
              'machine': os.uname().machine, 'kernel': os.uname().release, 'scope': scope}
    if args.part:
        record['part'] = args.part
    run = Run(out, tools)
    try:
        run.execute(args.refine, lanes)
        changed = changed_inputs(record['inputs'], inventory(HERE))
        require(not changed, 'probe inputs changed while the lanes ran, so no lane verdict above '
                'holds for this tree: ' + ', '.join(changed))
        record['status'] = 'passed'
    except Exception as exc:
        record['error'] = str(exc)
        print('Cortex-M probes FAILED:', exc, file=sys.stderr)
    finally:
        record['lanes'] = getattr(run, 'verdicts', {})
        record['files'] = inventory(out)
        (out / 'result.json').write_text(json.dumps(record, indent=2, sort_keys=True)+'\n')
    print('Cortex-M probes ' + record['status'] + (
        ' (FILTERED: the lanes %s only, not the gate\'s run)' % ', '.join(lanes) if args.lane
        else ' (part %s: %s; with %s, every lane)' % (
            args.part, ', '.join(lanes), ' and '.join(
                'part ' + name for name in PARTS if name != args.part)) if args.part
        else '') + ': ' + str(out))
    return 0 if record['status'] == 'passed' else 1


def changed_inputs(before, after):
    """Each file of environments/cortex-m added, removed or changed between
    two inventories, in order."""
    return ['%s %s' % ('added' if name not in before else
                       'removed' if name not in after else 'changed', name)
            for name in sorted(set(before) | set(after))
            if before.get(name) != after.get(name)]


if __name__ == '__main__':
    sys.exit(main())
