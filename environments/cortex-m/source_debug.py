"""R6.100 executable Cortex line/function debugger contract, on the Linux host."""
import json
from pathlib import Path
import socket
import subprocess
import sys
import time

from driver import HERE, build
from firmware import execute
from run import Run, oracle, remove_renode_lock, require, stop

sys.path.insert(0, str(HERE.parents[1] / 'scripts'))
from cortex_debug import Image, verify


PRELUDE = [
    'python', 'import gdb',
    'def frame(name, suffix=None, line=None):',
    '    f=gdb.newest_frame()',
    '    assert f.name() == name, (f.name(), name)',
    '    sal=f.find_sal()',
    '    if suffix: assert sal.symtab.filename.endswith(suffix), sal.symtab.filename',
    '    if line: assert sal.line == line, (sal.line,line)',
    'def chain(names):',
    '    f=gdb.newest_frame()',
    '    for name in names:',
    '        assert f and f.name() == name, (f.name() if f else None,name)',
    '        f=f.older()',
    'def v(s): return int(gdb.parse_and_eval(s)) & 0xffffffff',
    'end']


def checked(run, elf):
    record = verify(elf, elf, str(elf)+'.sources.json', str(elf)+'.s', elf.parent)
    (run.out/'debug-selection.json').write_text(json.dumps(record, indent=2)+'\n')
    return record


def cpu(run, elf):
    checked(run, elf)
    execute(run, elf, ['directory '+str(elf.parent), *PRELUDE,
        'break source/app/main.ldn:61', 'continue', 'python',
        'frame("start","source/app/main.ldn",61)',
        'chain(["start","_landin_firmware_reset"])', 'end',
        'step', 'python', 'frame("start","source/app/main.ldn",62)', 'end',
        'break source/drivers/uart/uart.ldn:38', 'continue', 'python',
        'frame("open","source/drivers/uart/uart.ldn",38)',
        'chain(["open","start","_landin_firmware_reset"])',
        'assert "No locals" in gdb.execute("info locals",to_string=True)',
        'assert "No arguments" in gdb.execute("info args",to_string=True)',
        'print("R6100_CPU_SOURCE_PASS")', 'end', 'bt'], 'R6100_CPU_SOURCE_PASS')


def renode(run, elf, commands):
    """Bounded remote session; selection precedes any debugger attachment."""
    checked(run, elf)
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    script = run.out/'source-debug.resc'
    script.write_text('\n'.join([
        f'include @{HERE}/probes/DriverPeripheral.cs',
        'mach create "source-debug"',
        f'machine LoadPlatformDescription @{HERE}/probes/driver.repl',
        f'sysbus LoadELF @{elf}', f'machine StartGdbServer {port}', '']) )
    gdb_script = run.out/'source-debug.gdb'
    gdb_script.write_text('\n'.join([
        'set pagination off', 'set confirm off',
        'directory '+str(elf.parent), f'target remote 127.0.0.1:{port}', *PRELUDE,
        'monitor start', *commands,
        'python', 'print("R6100_RENODE_SOURCE_PASS")', 'end', 'quit', '']))
    argv = [str(run.renode), '--disable-xwt', '--console', '--plain',
            '--config', str(run.out/'renode.config'), str(script)]
    record = dict(name='renode-source', argv=argv, timeout_seconds=40)
    run.commands.append(record)
    tick = time.monotonic()
    with (run.out/'renode-source.log').open('wb') as log:
        process = subprocess.Popen(argv, cwd=run.out, env=run.env, stdin=subprocess.PIPE,
                                   stdout=log, stderr=log, start_new_session=True)
        try:
            deadline = time.monotonic()+15
            while True:
                require(process.poll() is None, 'Renode exited before connection')
                # Do not consume the stub's first connection just to probe its port.
                if 'GDB server with all CPUs started' in (run.out/'renode-source.log').read_text():
                    break
                require(time.monotonic() < deadline, 'Renode GDB startup timeout')
                time.sleep(.05)
            text = run.command('gdb-renode-source', [run.bin/'gdb-multiarch', '-q',
                '-nx', '-batch', elf, '-x', gdb_script], timeout=25)
            oracle(text, 'R6100_RENODE_SOURCE_PASS')
        finally:
            stop(process)
            if process.stdin:
                process.stdin.close()
            remove_renode_lock(run.out)
            record.update(seconds=time.monotonic()-tick, exit=process.returncode)
            (run.out/'commands.json').write_text(json.dumps(run.commands, indent=2)+'\n')


def application(run, elf):
    renode(run, elf, [
        'break source/drivers/uart/uart.ldn:38', 'continue', 'python',
        'frame("open","source/drivers/uart/uart.ldn",38)',
        'chain(["open","start","_landin_firmware_reset"])', 'end',
        'delete breakpoints', 'break device_barrier', 'continue', 'python',
        'frame("device_barrier","source/core/cpu/cpu.ldn")',
        'chain(["device_barrier","open","start"])', 'end',
        'delete breakpoints', 'break wait_for_interrupt', 'continue', 'python',
        'frame("wait_for_interrupt","source/core/cpu/cpu.ldn")', 'end',
        'delete breakpoints', 'break source/app/main.ldn:30',
        'monitor sysbus.model Feed 49', 'monitor sysbus.model Feed 65',
        'monitor sysbus.model Feed 48', 'monitor sysbus.model Tick 1000',
        'continue', 'python',
        'frame("timer_irq","source/app/main.ldn",30)',
        'assert v("$xpsr") & 511 == 17',
        # Interrupt CFI ends at the handler; EXC_RETURN is not a call address.
        'assert gdb.newest_frame().older() is None', 'end', 'bt',
        'delete breakpoints', 'break source/app/main.ldn:48', 'continue', 'python',
        'frame("handle","source/app/main.ldn",48)',
        'assert 0x20000000 <= v("$pc") < 0x20003000',
        'chain(["handle","start","_landin_firmware_reset"])', 'end', 'bt',
        'delete breakpoints', 'break uartdr_write', 'continue', 'python',
        'frame("uartdr_write","source/rp2040/uart0/device.ldn")',
        'chain(["uartdr_write","handle","start"])', 'end', 'bt',
        'delete breakpoints', 'finish', 'python',
        'frame("handle","source/app/main.ldn")', 'end',
        'break wait_for_interrupt','continue','delete breakpoints',
        'monitor sysbus.model DelayStop 20 -1','monitor sysbus.model Feed 65',
        'monitor sysbus.model Tick 1000','break source/app/main.ldn:55',
        'continue','python','frame("halt","source/app/main.ldn",55)',
        'chain(["halt","start","_landin_firmware_reset"])',
        'assert v("*(unsigned*)&app_state") == 3','end','bt'])


def library(run, elf, kind):
    checked(run, elf)
    if kind in ('pool','vec'):
        name, path, line = (('allocate','source/core/mem/mem.ldn',34) if kind == 'pool'
                            else ('reserve','source/core/vec/vec.ldn',94))
        commands = [f'break {path}:{line}', 'continue', 'python',
            f'frame({name!r},{path!r},{line})',
            f'chain([{name!r},"exercise","start","_landin_firmware_reset"])',
            'assert "No locals" in gdb.execute("info locals",to_string=True)', 'end', 'bt',
            'delete breakpoints', 'break _landin_firmware_returned', 'continue',
            'python', 'assert v("*(unsigned*)&observed") == 42',
            'assert v("$sp") == 0x20004000', 'end']
    elif kind == 'noreturn':
        commands = ['break *start', 'continue', 'delete breakpoints',
            'set *(unsigned*)&mode = 1', 'break invoke', 'continue', 'python',
            'frame("invoke","source/app/main.ldn")',
            'chain(["invoke","start","_landin_firmware_reset"])', 'end',
            'delete breakpoints', 'break finished', 'continue', 'python',
            'frame("finished","source/app/main.ldn")',
            'chain(["finished","finish","invoke","start"])',
            'assert v("*(unsigned*)&observed") == 42',
            'assert v("*(unsigned*)&later") == 0', 'end', 'bt']
    elif kind == 'panic':
        commands = ['break *start', 'continue', 'delete breakpoints',
            'set *(unsigned*)&mode = 8', 'set *(int*)&input = 0',
            'break panic_handler', 'continue', 'python',
            'frame("panic_handler","source/app/main.ldn")',
            'chain(["panic_handler","quotient","start"])', 'end', 'bt',
            'delete breakpoints', 'break finished', 'continue', 'python',
            'assert v("*(unsigned*)&observed_kind") == 2',
            'assert v("*(unsigned*)&later") == 0',
            'assert v("*(unsigned*)&entries") == 1', 'end']
    else:
        raise ValueError(kind)
    execute(run, elf, ['directory '+str(elf.parent), *PRELUDE, *commands,
        'python', 'print("R6100_LIBRARY_SOURCE_PASS")', 'end'], 'R6100_LIBRARY_SOURCE_PASS')


def veneer(run, elf):
    checked(run, elf)
    execute(run, elf, ['directory '+str(elf.parent), *PRELUDE,
        'break boot.ldn:10', 'continue', 'python',
        'frame("flash_helper","boot.ldn",10)',
        'chain(["flash_helper","ram_worker","start"])', 'end', 'bt',
        'delete breakpoints', 'finish', 'python',
        'frame("ram_worker","boot.ldn")',
        'assert 0x20000000 <= v("$pc") < 0x20003000', 'end',
        'break boot.ldn:13', 'continue', 'python',
        'frame("ram_irq","boot.ldn",13)',
        'assert gdb.newest_frame().older() is None',
        'assert v("$xpsr") & 511 == 11', 'end', 'bt',
        'delete breakpoints', 'break _landin_firmware_returned', 'continue', 'python',
        'assert v("*(unsigned*)&observed") == 42',
        'assert v("*(unsigned*)&irq_seen") == 1',
        'assert v("$sp") == 0x20004000 and v("$r12") == 0',
        'print("R6100_VENEER_SOURCE_PASS")', 'end'], 'R6100_VENEER_SOURCE_PASS')


def interrupt(run, elf, naked=False):
    checked(run,elf)
    if naked:
        commands=['break start','continue','python',
            'frame("start","boot.ldn")',
            'assert gdb.newest_frame().older() is None',
            'end','delete breakpoints','break opaque','continue','python',
            'frame("opaque","boot.ldn")',
            'chain(["opaque","worker","start"])',
            'assert gdb.newest_frame().older().older().older() is None',
            'end','bt','delete breakpoints','break naked_handler','continue','python',
            'frame("naked_handler","boot.ldn")',
            'assert gdb.newest_frame().older() is None',
            'assert v("$lr") == 0xfffffffd and v("$xpsr") & 511 == 11',
            'assert v("$sp") == 0x20004000',
            'end','bt','delete breakpoints','break _landin_firmware_returned',
            'continue','python','assert v("*(unsigned*)&observed") == 124',
            'assert v("*(unsigned*)&naked_hits") == 1','end']
    else:
        commands=['break helper','continue','python',
            'frame("helper","boot.ldn")',
            'chain(["helper","svc_handler"])',
            'assert gdb.newest_frame().older().older() is None',
            'end','bt','delete breakpoints','break irq_handler','continue','python',
            'frame("irq_handler","boot.ldn")',
            'assert gdb.newest_frame().older() is None',
            'assert v("$lr") == 0xfffffff1 and v("$xpsr") & 511 == 16',
            'end','bt','delete breakpoints','break _landin_firmware_returned',
            'continue','python','assert v("*(unsigned*)&completed") == 4','end']
    execute(run,elf,['directory '+str(elf.parent),*PRELUDE,*commands,
        'python','assert v("$sp") == '+str(0x20003800 if naked else 0x20004000),
        'print("R6100_INTERRUPT_SOURCE_PASS")','end'],'R6100_INTERRUPT_SOURCE_PASS')
