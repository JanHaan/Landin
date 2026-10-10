"""Executable Cortex line/function debugger contract, on the Linux host."""
import json
from pathlib import Path
import sys

from driver import HERE, build, machine
from firmware import execute
from run import Run, oracle, require

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


def relayed(run, elf, commands):
    """A source session on QEMU, the driver's model behind a relay.

    GDB drives the CPU; the relay serves every model access and runs each
    `monitor` stimulus against the model while GDB has the CPU stopped.
    Selection precedes any debugger attachment.
    """
    checked(run, elf)
    names = run.command('relay-symbols', [run.bin/'arm-none-eabi-nm', elf])
    symbols = {p[2]: int(p[0], 16) for line in names.splitlines() if len(p := line.split()) == 3}
    m, model = machine(run, elf, symbols, 'source-debug-qemu')
    with m:
        port = m.relay({'feed': model.feed, 'tick': model.tick, 'delay_stop': model.delay_stop})
        script = run.out/'source-debug.gdb'
        script.write_text('\n'.join([
            'set pagination off', 'set confirm off', 'set remotetimeout 30',
            'directory '+str(elf.parent), f'target remote 127.0.0.1:{port}', *PRELUDE,
            *commands, 'python', 'print("R6100_RELAYED_SOURCE_PASS")', 'end', 'detach', 'quit', '']))
        text = run.debug('gdb-relayed-source', elf, script, timeout=60)
        oracle(text, 'R6100_RELAYED_SOURCE_PASS')


def application(run, elf):
    relayed(run, elf, [
        'break source/drivers/uart/uart.ldn:38', 'continue', 'python',
        'frame("open","source/drivers/uart/uart.ldn",38)',
        'chain(["open","start","_landin_firmware_reset"])', 'end',
        'delete breakpoints', 'break device_barrier', 'continue', 'python',
        'frame("device_barrier","source/platform/cpu/cpu.ldn")',
        'chain(["device_barrier","open","start"])', 'end',
        'delete breakpoints', 'break wait_for_interrupt', 'continue', 'python',
        'frame("wait_for_interrupt","source/platform/cpu/cpu.ldn")', 'end',
        'delete breakpoints', 'break source/app/main.ldn:30',
        'monitor feed 49', 'monitor feed 65',
        'monitor feed 48', 'monitor tick 1000',
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
        'monitor delay_stop 20 -1','monitor feed 65',
        'monitor tick 1000','break source/app/main.ldn:55',
        'continue','python','frame("halt","source/app/main.ldn",55)',
        'chain(["halt","start","_landin_firmware_reset"])',
        'assert v("*(unsigned*)&app_state") == 3','end','bt'])


def source_line(run, path, statement):
    """Locate an unambiguous executable anchor in the verified source copy."""
    lines = (run.out / path).read_text().splitlines()
    matches = [number for number, text in enumerate(lines, 1)
               if text.strip() == statement]
    require(len(matches) == 1, 'missing or ambiguous source anchor: ' + path)
    return matches[0]


# The library statement each lane stops at: its function, the source copy's
# path, and the statement, which must occur once in that library source.
LIBRARY_ANCHORS = {
    'pool': ('allocate', 'source/core/mem/mem.ldn',
             'block = try provider.alloc(state, size, alignment)'),
    'vec': ('reserve', 'source/core/vec/vec.ldn',
            'old_count: usize = mem.length(value.values)'),
}


def library(run, elf, kind):
    checked(run, elf)
    if kind in LIBRARY_ANCHORS:
        name, path, statement = LIBRARY_ANCHORS[kind]
        line = source_line(run, path, statement)
        commands = [f'break {path}:{line}', 'continue', 'python',
            f'frame({name!r},{path!r},{line})',
            f'chain([{name!r},"exercise","start","_landin_firmware_reset"])',
            'assert "No locals" in gdb.execute("info locals",to_string=True)', 'end', 'bt',
            'delete breakpoints', 'break _landin_firmware_returned', 'continue',
            'python', 'assert v("*(unsigned*)&observed") == 42',
            'assert v("$sp") == 0x20004000', 'end']
    elif kind == 'cpu':
        # [1630]: `platform/cpu` on `general` operands.  The block has its own
        # line, PRIMASK changes across it, and its output is the next line's.
        path = 'source/platform/cpu/cpu.ldn'
        line = source_line(run, path,
            r'previous = assembler.block("mrs {mask}, primask\ncpsid i",')
        commands = [f'break {path}:{line}', 'continue', 'python',
            f'frame("disable_interrupts",{path!r},{line})',
            'chain(["disable_interrupts","start","_landin_firmware_reset"])',
            'assert v("$primask") == 0', 'end', 'next', 'python',
            'frame("disable_interrupts","source/platform/cpu/cpu.ldn")',
            f'assert gdb.newest_frame().find_sal().line != {line}',
            'assert v("$primask") == 1', 'end', 'bt',
            'delete breakpoints', 'break _landin_firmware_returned', 'continue',
            'python', 'assert v("*(unsigned*)&observed") == 0x670', 'end']
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


def leaf(run, elf):
    """Unwind an SP-based leaf, including its interrupted hardware context.

    Ordinary unwinding still stops at interrupt entry. Selecting the saved
    architectural context is a test operation, not a new exception-unwind
    promise. The compiler's leaf CFI must recover its ordinary callers there.
    """
    checked(run, elf)
    line = source_line(run, 'boot.ldn', 'result += 1')
    execute(run, elf, ['directory '+str(elf.parent), *PRELUDE,
        f'break boot.ldn:{line}', 'continue', 'python',
        'chain(["leaf","caller","start","_landin_firmware_reset"])',
        'end', 'bt', 'delete breakpoints',
        'set *(unsigned*)0xe000e014 = 99',
        'set *(unsigned*)0xe000e018 = 0',
        'set *(unsigned*)0xe000e010 = 7',
        'break *tick', 'continue', 'python',
        'assert v("$xpsr") & 511 == 15',
        'assert v("$lr") == 0xfffffff9',
        'assert gdb.newest_frame().older() is None',
        'saved={r:v("$"+r) for r in ("sp","pc","lr")}',
        'import struct',
        'hw=struct.unpack("<8I",bytes(gdb.selected_inferior().read_memory(saved["sp"],32)))',
        'gdb.execute("set $sp = %d"%(saved["sp"]+32+(4 if hw[7]&512 else 0)))',
        'gdb.execute("set $lr = %d"%hw[5])',
        'gdb.execute("set $pc = %d"%hw[6])',
        'chain(["leaf","caller","start","_landin_firmware_reset"])',
        'gdb.execute("bt")',
        'gdb.execute("frame 0")',
        'for reg,value in saved.items(): gdb.execute("set $%s = %d"%(reg,value))',
        'end', 'set *(unsigned*)0xe000e010 = 0',
        'delete breakpoints', 'break _landin_firmware_returned', 'continue',
        'python', 'assert v("*(unsigned*)&observed") == 100000',
        'assert v("*(unsigned*)&interrupted") == 1',
        'assert v("$sp") == 0x20004000 and v("$r11") == 0',
        'print("CORTEX_LEAF_SOURCE_PASS")', 'end'], 'CORTEX_LEAF_SOURCE_PASS')
