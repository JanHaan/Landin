"""Independent RV32 harness controls on Espressif's QEMU (D695).

Hand-written mains, probes/rv32-controls.S, linked with the RV32 harness
start, probes/rv32-start.S, by a script written here from each lane's
recorded profile, and run through backend.execute's session on both RV32
machines: a return, a trap, an overrun stack, and on the rv32imac lane an
executed A-extension read-modify-write.  Each image is also held to its
level's checks, and the A-extension image to being refused at rv32imc, so
the lanes are shown to judge before any compiler output reaches them.
First, an Arm session, an RV32 one and an Arm one again are served by one
GDB, as every lane's sessions on a worker are.
"""
import json
import re
import subprocess

from backend import (HERE, LEVELS, execute, harness_start, image_contract, recorded, region,
                     rv32_image, tool)
import run as runner
from run import Run, gdb_listener, oracle, require, stop

#  Each control: its LANDIN_CONTROL number, the levels it runs at, and what
#  the session must see: an exit byte, a trap, or the overrun's message.
CONTROLS = {
    'return': (1, ('rv32imc', 'rv32imac'), 42),
    'trap': (2, ('rv32imc', 'rv32imac'), 'trap'),
    'overrun': (3, ('rv32imc', 'rv32imac'), 'overran its'),
    'read-modify-write': (4, ('rv32imac',), 42),
    #  The same program assembled at rv32imac and run on the esp32c3 lane's
    #  core, from which the lane removes A: its first AMO is an illegal
    #  instruction (D696).
    'a-extension-traps': (4, ('rv32imc',), 'amoadd.w'),
}


def control_script(profile):
    """A linker script for PROFILE, written here rather than derived: the
    section and symbol contract refine's RV32 firmware script keeps, its
    entry word first at the text region's origin, then the trap table at
    the profile's vector address, then the reset routine, so
    the controls do not depend on the compiler they will judge."""
    text, data = region(profile, 'text'), region(profile, 'data')
    bottom = profile['stack_top'] - profile['stack_reserved']
    #  Inside the output section `.` counts from the region's origin.
    table = profile['vector_address'] - text['origin']
    return '\n'.join([
        '/* RV32 harness controls only: never a firmware script. */',
        'MEMORY {',
        '  TEXT (rx) : ORIGIN = %d, LENGTH = %d' % (text['origin'], text['length']),
        '  DATA (rwx) : ORIGIN = %d, LENGTH = %d' % (data['origin'], data['length']),
        '}',
        'ENTRY(_landin_firmware_entry)',
        'SECTIONS {',
        '  .text : {',
        '    KEEP(*(.text.landin_entry))',
        '    . = %d;' % table,
        '    KEEP(*(.isr_vector))',
        '    KEEP(*(.text.landin_reset))',
        '    *(.text .text.*) *(.rodata .rodata.* .srodata .srodata.*)',
        '  } > TEXT',
        '  .data : { *(.data .data.* .sdata .sdata.*) } > DATA AT > TEXT',
        '  _landin_firmware_data_load = LOADADDR(.data);',
        '  _landin_firmware_data_start = ADDR(.data);',
        '  _landin_firmware_data_end = ADDR(.data) + SIZEOF(.data);',
        '  _landin_firmware_ramtext_load = _landin_firmware_data_load;',
        '  _landin_firmware_ramtext_start = _landin_firmware_data_start;',
        '  _landin_firmware_ramtext_end = _landin_firmware_data_start;',
        '  .bss (NOLOAD) : { *(.bss .bss.* .sbss .sbss.* COMMON) } > DATA',
        '  _landin_firmware_bss_start = ADDR(.bss);',
        '  _landin_firmware_bss_end = ADDR(.bss) + SIZEOF(.bss);',
        '  _landin_firmware_stack_bottom = %d;' % bottom,
        '  _landin_firmware_stack_top = %d;' % profile['stack_top'],
        '  ASSERT(_landin_firmware_bss_end <= _landin_firmware_stack_bottom,'
        ' "static RAM reaches the stack")',
        '}', ''])


def control(parent, name, level, before=(), directory=None):
    """Build and run one control at LEVEL under PARENT's output, in
    DIRECTORY there if given; BEFORE goes to a returning control's session."""
    number, _, want = CONTROLS[name]
    out = parent.out / 'rv32-controls' / (directory or name + '--' + level)
    out.mkdir(parents=True)
    run = Run(out, parent.tools)
    profile = recorded(LEVELS[level]['profile'])
    script = out / 'control.ld'
    script.write_text(control_script(profile))
    gcc = tool(run, level, 'gcc')
    flags = LEVELS['rv32imac' if number == 4 else level]['flags'] + [
        '-mabi=ilp32', '-g3', '-nostdlib']
    objects = [harness_start(run, profile, level)]
    objects.append(out / 'input-1.o')
    run.command('assemble-1', [gcc, *flags, '-DLANDIN_CONTROL=%d' % number, '-c',
                               HERE / 'probes/rv32-controls.S', '-o', objects[1]])
    elf = out / 'program.elf'
    run.command('assemble-link', [gcc, *flags, '-Wl,-T,' + str(script), *objects, '-o', elf])
    image_contract(elf, profile)
    attributes = run.command('elf', [tool(run, level, 'readelf'), '-h', '-A', '-S', elf])
    disassembly = run.command('disassembly', [tool(run, level, 'objdump'), '-dr', elf])
    if name != 'a-extension-traps':
        rv32_image(level, attributes, disassembly)
    if number == 4:
        #  The same image at rv32imc is what the esp32c3 lane refuses, since
        #  its emulated core would execute it.
        try:
            rv32_image('rv32imc', attributes, disassembly)
        except RuntimeError as error:
            require('amoadd.w' in str(error) and 'lr.w' in str(error),
                    'rv32imc refused the A image without naming its instructions: %s' % error)
        else:
            raise RuntimeError('rv32imc admitted an image holding A-extension instructions')
    if name == 'a-extension-traps':
        first = re.search(r'^\s*([0-9a-f]+):\s+\S+\s+%s\b' % re.escape(want), disassembly, re.M)
        require(first is not None, 'the A image holds no ' + want)
        execute(run, elf, None, False, level=level, profile=profile)
        seen = json.loads((out / 'observed.json').read_text())
        require(seen['trapped'] and seen['mcause'] == 2
                and seen['mepc'].startswith('%#x ' % int(first.group(1), 16)),
                'the %s core did not refuse %s as an illegal instruction: %s'
                % (LEVELS[level]['machine'], want, json.dumps(seen)))
    elif want == 'trap':
        execute(run, elf, 0, True, level=level, profile=profile)
    elif isinstance(want, int):
        execute(run, elf, want, False, before, level=level, profile=profile)
    else:
        try:
            execute(run, elf, 0, False, level=level, profile=profile)
        except RuntimeError as error:
            require(want in str(error), 'the overrun failed otherwise: %s' % error)
        else:
            raise RuntimeError('the overrun control passed its session')
    record = {'control': name, 'level': level, 'machine': LEVELS[level]['machine'],
              'status': 'passed'}
    (out / 'result.json').write_text(json.dumps(record, indent=2) + '\n')
    return record


#  Python a session runs before it makes a breakpoint of its own: no
#  breakpoint or watchpoint, internal or not, is left from the session before.
UNMARKED = ['python', 'import gdb',
            'left = [b.location or b.expression for b in gdb.breakpoints()]',
            'assert not left, "a session before this one left %s" % left', 'end']


def arm_session(run, elf, name, lines):
    """One session of the M0 probe ELF on QEMU's microbit, LINES after the
    connection: the cpu lane's program, without its checks."""
    listener, port, stub = gdb_listener()
    script = run.out / (name + '.gdb')
    script.write_text('\n'.join(['set pagination off', 'set confirm off',
                                 'target remote 127.0.0.1:%d' % port, *lines, 'quit', '']))
    argv = [str(run.bin / 'qemu-system-arm'), '-M', 'microbit', '-accel', 'tcg,thread=single',
            '-display', 'none', '-monitor', 'none', '-serial', 'none', '-kernel', str(elf),
            '-S', *stub]
    run.commands.append({'name': 'qemu-' + name, 'argv': argv, 'timeout_seconds': 25})
    with (run.out / ('qemu-' + name + '.log')).open('wb') as log:
        with listener:
            process = subprocess.Popen(argv, cwd=run.out, env=run.env, stdout=log, stderr=log,
                                       start_new_session=True, pass_fds=(listener.fileno(),))
        try:
            require(process.poll() is None, 'QEMU exited before connection')
            oracle(run.debug(name, elf, script), 'SHARED_DEBUGGER_PASS')
        finally:
            stop(process)


def shared_debugger(parent):
    """An Arm session, an RV32 one and an Arm one again, served by one GDB.

    `Run.debug` serves every session on a thread from one GDB
    (gdb_server.py), so a lane meets what the sessions before it on that
    thread left, which a lane run alone never does: the description an Arm
    target reported refused an RV32 script's `set architecture riscv:rv32`,
    and that setting refused the next Arm executable.  The first session
    also leaves an internal breakpoint and an internal watchpoint, which
    `delete` spares, and each later one holds that it sees neither.
    """
    out = parent.out / 'rv32-controls' / 'shared-debugger'
    pids = []

    def served():
        pids.append(runner.SERVERS.server.process.pid)
    first = Run(out / 'arm', parent.tools)
    first.out.mkdir(parents=True)
    first.build('cpu')
    elf = first.out / 'cpu.elf'
    arm_session(first, elf, 'gdb-arm', [
        *UNMARKED, 'python',
        'assert gdb.selected_inferior().architecture().name().startswith("arm")',
        'gdb.Breakpoint("done", internal=True)',
        'gdb.Breakpoint("fault_seen", gdb.BP_WATCHPOINT, gdb.WP_WRITE, internal=True)',
        'end', 'delete breakpoints', 'continue', 'python',
        'assert int(gdb.parse_and_eval("$pc")) == int(gdb.parse_and_eval("&done"))',
        'assert len(gdb.breakpoints()) == 2',
        'print("SHARED_DEBUGGER_PASS")', 'end'])
    served()
    control(parent, 'return', 'rv32imc', before=UNMARKED, directory='shared-debugger/rv32')
    served()
    again = Run(out / 'arm-again', parent.tools)
    again.out.mkdir()
    arm_session(again, elf, 'gdb-arm', [
        *UNMARKED, 'break done', 'continue', 'python',
        'assert gdb.selected_inferior().architecture().name().startswith("arm")',
        'assert int(gdb.parse_and_eval("result")) == 0x610',
        'print("SHARED_DEBUGGER_PASS")', 'end'])
    served()
    require(len(set(pids)) == 1, 'the shared-debugger sessions were served by GDBs %s, not one'
            % ', '.join(map(str, pids)))
    record = {'control': 'shared-debugger', 'sessions': ['armv6-m', 'rv32imc', 'armv6-m'],
              'gdb_processes': 1, 'status': 'passed'}
    (out / 'result.json').write_text(json.dumps(record, indent=2) + '\n')
    return record


def execute_suite(parent):
    """Every control at each of its levels; run.py's `rv32-controls` lane."""
    results = [shared_debugger(parent)]
    print('rv32 control: shared-debugger, Arm, RV32 and Arm through one GDB, passed',
          flush=True)
    for name, (_, levels, _) in CONTROLS.items():
        for level in levels:
            results.append(control(parent, name, level))
            print('rv32 control: %s at %s on %s passed'
                  % (name, level, LEVELS[level]['machine']), flush=True)
    (parent.out / 'rv32-controls' / 'result.json').write_text(
        json.dumps({'status': 'passed', 'controls': results}, indent=2) + '\n')
    return results


#  The atomics probes each RV32 lane holds its level to (D695): the
#  read-modify-writes the A extension admits, and an eight-byte cell, which
#  no RV32 level has.
READ_MODIFY_WRITE = HERE / 'probes/rv32-read-modify-write.ldn'
WIDE = HERE / 'probes/rv32-wide-atomic.ldn'
#  The uses rv32imc refuses, each where the program reaches it.
REFUSED_USES = ('atomic.exchange(', 'atomic.add(', 'atomic.add_relaxed(',
                'atomic.compare_exchange(')


def refused_lines(run, refine, level, source):
    """The lines of SOURCE refine refuses with L0344 at LEVEL, every other
    code a failure."""
    try:
        run.command('compile-refusal', [refine, source, '--target=rv32', '--level=' + level,
                                        '--emit=asm', '-o', run.out / 'refused.s'], timeout=60)
    except RuntimeError:
        command = run.commands[-1]
        require(command.get('exit') == 1 and not command.get('timed_out'),
                'refine did not refuse %s with a diagnostic' % source.name)
    else:
        raise RuntimeError('%s compiled at %s, which must refuse it' % (source.name, level))
    log = (run.out / 'compile-refusal.log').read_text()
    codes = sorted(set(re.findall(r'^error\[(L\d+)\]', log, re.M)))
    require(codes == ['L0344'], '%s at %s was refused with %s, not L0344 alone; inspect %s'
            % (source.name, level, ', '.join(codes), run.out / 'compile-refusal.log'))
    return {int(line) for line in re.findall(
        r'^error\[L0344\][^\n]*\n\s*--> [^\n]*%s:(\d+):' % re.escape(source.name), log, re.M)}


def atomics(parent, refine, lane):
    """The lane's atomics: on sifive-e, rv32imac executes the read-modify-
    write probe, its image holding AMO and LR/SC instructions; on esp32c3,
    rv32imc refuses each of its exchanges, adds and compare-exchanges at
    its use; both refuse the eight-byte cell where it is declared."""
    level = next(key for key, one in LEVELS.items() if one.get('lane') == lane)
    root = parent.out / lane / 'atomics'
    results = {}
    out = root / 'read-modify-write'
    out.mkdir(parents=True)
    run = Run(out, parent.tools)
    if 'a' in LEVELS[level]['extensions']:
        from backend import build
        elf = build(run, refine, [str(READ_MODIFY_WRITE)], 'none', 'off', level=level)
        execute(run, elf, 42, False, level=level)
        found = sorted(set(re.findall(r'\t((?:amo\w+|lr|sc)\.w)\b',
                                      (out / 'disassembly.log').read_text())))
        require(any(op.startswith('amo') for op in found) and 'lr.w' in found and 'sc.w' in found,
                'the rv32imac image holds no AMO and LR/SC pair: %s' % ', '.join(found))
        results['read-modify-write'] = {'verdict': 'executed', 'instructions': found}
    else:
        source = READ_MODIFY_WRITE.read_text().splitlines()
        uses = {number for number, line in enumerate(source, 1)
                if any(use in line for use in REFUSED_USES)}
        lines = refused_lines(run, refine, level, READ_MODIFY_WRITE)
        require(uses <= lines, 'rv32imc did not refuse the read-modify-writes at lines %s'
                % ', '.join(map(str, sorted(uses - lines))))
        results['read-modify-write'] = {'verdict': 'refused', 'codes': ['L0344'],
                                        'lines': sorted(lines)}
    out = root / 'wide'
    out.mkdir()
    cell = next(number for number, line in enumerate(WIDE.read_text().splitlines(), 1)
                if 'atomic.cell(u64)' in line)
    lines = refused_lines(Run(out, parent.tools), refine, level, WIDE)
    require(cell in lines, '%s did not refuse the u64 cell at line %d' % (level, cell))
    results['wide'] = {'verdict': 'refused', 'codes': ['L0344'], 'lines': sorted(lines)}
    (root / 'result.json').write_text(json.dumps(results, indent=2) + '\n')
    return results
