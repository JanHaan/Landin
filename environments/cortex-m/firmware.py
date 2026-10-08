#!/usr/bin/env python3
"""Execute the compiler-owned firmware path; never use backend-start.S."""
import argparse
import json
from pathlib import Path
import subprocess
import time

from backend import image_contract
from packed_native import PROFILES
from packed import TRACE
from machine import Machine
from models import EncodingPeripheral, PrototypePeripheral
from run import Run, gdb_listener, oracle, require, stop
from setup import DEFAULT, inventory, sha, supported_host


def execute(run, elf, commands=None, marker="R660_FIRMWARE_BOOT_PASS"):
    listener, port, stub = gdb_listener()
    script = run.out / 'firmware.gdb'
    # Poison RAM before execution to distinguish reset initialization from
    # the emulator loader or its power-on memory contents. Reset twice.
    boot = [
        'set pagination off', 'set confirm off',
        f'target remote 127.0.0.1:{port}',
        'python', 'import gdb',
        'def v(s): return int(gdb.parse_and_eval(s)) & 0xffffffff',
        'assert v("$sp") == 0x20004000',
        'assert v("*(unsigned*)0") == 0x20004000',
        'assert v("*(unsigned*)4") & 1 == 1',
        'assert v("$pc") == v("*(unsigned*)4") & ~1',
        'for slot in (4,5,6,7,8,9,10,12,13,21,42,43,44,45,46,47):',
        '    assert v("*(unsigned*)%d" % (slot*4)) == 0',
        'end',
        *sum(([
            'set *(unsigned*)&initialized = 0xaaaaaaaa',
            'set *(unsigned*)&cleared = 0xbbbbbbbb',
            'set *(unsigned*)&observed = 0xcccccccc',
            'break *start', 'continue', 'python',
            'assert v("$sp") == 0x20004000',
            'assert v("$r11") == 0 and v("$r9") == 0',
            'assert v("*(unsigned*)&initialized") == 0x12345678',
            'assert v("*(unsigned*)&cleared") == 0',
            'assert v("&initialized") >= 0x20000000',
            'assert v("&immutable") < 0x8000',
            'end', 'delete breakpoints',
            'break _landin_firmware_returned', 'continue', 'python',
            'assert v("*(unsigned*)&observed") == 0x12345685',
            'assert v("$sp") == 0x20004000 and v("$r11") == 0',
            'assert v("$r12") == 0', 'end', 'delete breakpoints',
            *(['monitor system_reset', 'maintenance flush register-cache']
              if boot == 0 else [])] for boot in range(2)), []),
        'break _landin_firmware_unhandled', 'continue', 'python',
        'assert v("$xpsr") & 0x1ff == 3',
        'assert v("*(unsigned short*)*(unsigned*)($sp+24)") == 0xde01',
        'assert v("$sp") >= 0x20003000 and v("$sp") % 8 == 0',
        'print("R660_FIRMWARE_BOOT_PASS")', 'end', 'quit', '']
    script.write_text('\n'.join(boot if commands is None else [
        'set pagination off', 'set confirm off',
        f'target remote 127.0.0.1:{port}',
        'python', 'import gdb',
        'def v(s): return int(gdb.parse_and_eval(s)) & 0xffffffff',
        'end', *commands, 'quit', '']))
    argv = [str(run.bin / 'qemu-system-arm'), '-M', 'microbit', '-accel',
            'tcg,thread=single', '-display', 'none', '-monitor', 'none',
            '-serial', 'none', '-kernel', str(elf), '-S', *stub]
    record = {'name': 'qemu-firmware', 'argv': argv, 'timeout_seconds': 25}
    run.commands.append(record)
    tick = time.monotonic()
    with (run.out / 'qemu.log').open('wb') as log:
        with listener:
            process = subprocess.Popen(argv, cwd=run.out, env=run.env, stdout=log,
                                       stderr=log, start_new_session=True,
                                       pass_fds=(listener.fileno(),))
        try:
            #  The stub's socket is listening before QEMU starts, so GDB's
            #  connection waits in its backlog rather than racing the start.
            require(process.poll() is None, 'QEMU exited before connection')
            text = run.debug('gdb-firmware', elf, script, timeout=20)
            oracle(text, marker)
        finally:
            stop(process)
            record['seconds'] = time.monotonic() - tick
            record['exit'] = process.returncode
            (run.out / 'commands.json').write_text(json.dumps(run.commands, indent=2)+'\n')


def build(run, refine, program=None, optimize="none", specialize="off", debug='none',
          level="armv6-m", root=None):
    source = run.out / 'boot.ldn'
    if root is not None:
        (run.out / 'app').mkdir()
        source = run.out / 'app/main.ldn'
    source.write_text(program if program is not None else '''mut initialized: u32 = 0x12345678
mut cleared: u32 = 0
mut observed: u32 = 0
immutable: [2]u32 = [5, 8]
start: () -> none =
    observed = initialized + cleared + immutable[0] + immutable[1]
end start
''')
    elf = run.out / 'firmware.elf'
    run.command('compile', [refine, '--target=cortex-m0', '--level='+level,
        *(['--root='+str(root)] if root is not None else []), '--firmware-entry=start',
        '--emit=exe', '--debug='+debug, '--toolchain=' + str(run.bin / 'arm-none-eabi-gcc'),
        '--optimize='+optimize, '--specialize='+specialize,
        'app' if root is not None else source.name, '-o', elf.name], timeout=60)
    run.command('elf', [run.bin / 'arm-none-eabi-readelf', '-h', '-A', '-S', '-l', '-r', elf])
    run.command('disassembly', [run.bin / 'arm-none-eabi-objdump', '-dr', elf])
    symbols = run.command('symbols', [run.bin / 'arm-none-eabi-nm', '-n', elf])
    names = {line.split()[-1] for line in symbols.splitlines() if line.split()}
    require(not names & {'malloc', 'calloc', 'realloc', 'free', 'exit', '_exit',
                         '__libc_init_array', '__libc_start_main', '_sbrk'},
            'firmware imported a hosted runtime dependency')
    mapping = (run.out / 'firmware.elf.map').read_text()
    require('libc.a' not in mapping and 'crt0.o' not in mapping,
            'firmware linked an implicit hosted startup or libc')
    require(not run.command('undefined', [run.bin / 'arm-none-eabi-nm', '-u', elf]).strip(),
            'firmware contains unresolved symbols')
    (run.out / 'image.json').write_text(json.dumps(image_contract(elf), indent=2)+'\n')
    return elf


def cpu_levels(parent, refine):
    """Link the scoped CPU module through compiler-owned startup at each level."""
    root = Path(__file__).resolve().parents[2]
    program = """import platform/cpu
mut observed: u32 = 0
start: () -> none =
    saved := cpu.disable_interrupts()
    observed = cpu.interrupt_mask()
    cpu.compiler_barrier()
    cpu.device_barrier()
    cpu.completion_barrier()
    cpu.restore_interrupts(saved)
end start
"""
    inputs = {str(p.relative_to(root)): sha(p)
              for p in sorted((root / 'platform/cpu').glob('*.ldn'))}
    controls = []
    for level in ('armv6-m', 'armv7-m', 'armv7e-m'):
        out = parent.out / level
        out.mkdir()
        run = Run(out, parent.tools)
        build(run, refine, program, level=level, root=root)
        (out / 'inputs.json').write_text(json.dumps(inputs, indent=2)+'\n')
        controls.append({'kind': 'cpu-level', 'level': level, 'optimize': 'none',
                         'specialize': 'off', 'status': 'passed',
                         'lane': 'compile-link'})
    return controls


def interrupts(run, elf):
    execute(run, elf, [
        'break *start', 'continue', 'delete breakpoints',
        'python',
        'gdb.selected_inferior().write_memory(0x20003000, bytes([0xa5])*4096)',
        'end',
        'set $r8=0x88888888', 'set $r9=0x99999999',
        'set $r10=0xaaaaaaaa', 'set $r12=0xcccccccc',
        'break *svc_handler', 'continue', 'delete breakpoints', 'python',
        'assert v("$lr") == 0xfffffff9',
        'assert v("$xpsr") & 511 == 11',
        'assert v("*(unsigned*)44") == v("&svc_handler") | 1',
        'assert v("*(unsigned*)64") == v("&irq_handler") | 1',
        'assert v("$sp") % 8 == 0',
        'outersp = v("$sp")',
        'outer = [v("*(unsigned*)($sp+%d)" % (i*4)) for i in range(8)]',
        'callee = [v("$r%d" % i) for i in range(4,12)]',
        'assert outer[:5] == [17,34,51,68,0xcccccccc]',
        'assert outer[7] & 0xf00001ff == 0x60000000',
        'assert callee[:4] == [85,102,119,136]',
        'assert callee[4:7] == [0x88888888,0x99999999,0xaaaaaaaa]',
        'end', 'break *irq_handler', 'continue', 'delete breakpoints', 'python',
        'assert v("$lr") == 0xfffffff1',
        'assert v("$xpsr") & 511 == 16',
        'assert v("$sp") % 8 == 0 and v("$sp") >= 0x20003000',
        'assert v("*(unsigned*)($r11+4)") == 0xfffffff9',
        'inner = [v("*(unsigned*)($sp+%d)" % (i*4)) for i in range(8)]',
        'inner_callee = [v("$r%d" % i) for i in range(4,12)]',
        'assert inner[7] & 511 == 11',
        'gdb.execute("break *%d" % inner[6])', 'end',
        'continue', 'delete breakpoints', 'python',
        'assert [v("$r%d" % i) for i in (0,1,2,3,12)] == inner[:5]',
        'assert [v("$r%d" % i) for i in range(4,12)] == inner_callee',
        'assert v("$lr") == inner[5]',
        'assert v("$xpsr") & 0xf00001ff == inner[7] & 0xf00001ff',
        'gdb.execute("break *%d" % outer[6])', 'end',
        'continue', 'delete breakpoints', 'python',
        'assert [v("$r%d" % i) for i in (0,1,2,3,12)] == outer[:5]',
        'assert [v("$r%d" % i) for i in range(4,12)] == callee',
        'assert v("$lr") == outer[5] and v("$sp") == outersp+32',
        'assert v("$xpsr") & 0xf00001ff == outer[7] & 0xf00001ff',
        'end', 'break _landin_firmware_returned', 'continue', 'python',
        'assert v("*(unsigned*)&completed") == 4',
        'assert v("*(unsigned*)&seen") == 2',
        'assert v("*(unsigned*)&nested") == 1',
        'assert v("*(unsigned*)&helper_calls") == 1',
        'assert v("&retained") < 0x8000 and v("&retained") % 64 == 0',
        'assert v("&initialized") % 16 == 0 and v("&seen") % 32 == 0',
        'assert v("*(unsigned*)&handler_ref") == v("&address_only") | 1',
        'assert v("*(unsigned*)*(unsigned*)&message") == 0x746f6f62',
        'assert v("*(unsigned*)&shared_zero") == 0',
        'assert v("*(unsigned*)&shared_value") == 321',
        'assert v("&zero_array") < 0x8000 and v("&zero_array") % 32 == 0',
        'assert v("&zero_record") < 0x8000 and v("&zero_record") % 16 == 0',
        'assert bytes(gdb.selected_inferior().read_memory(v("&zero_array"),16)) == bytes(16)',
        'assert v("*(unsigned*)&zero_record") == 0',
        'assert v("$sp") == 0x20004000 and v("$r11") == 0',
        'assert v("$r9") == 0x99999999 and v("$r12") == 0',
        'stack = bytes(gdb.selected_inferior().read_memory(0x20003000, 4096))',
        'assert stack[:64] == bytes([0xa5])*64',
        'first = next(i for i, b in enumerate(stack) if b != 0xa5)',
        'print("R660_OBSERVED_STACK_BYTES %d" % (4096-first))',
        'print("R660_INTERRUPT_PASS")', 'end',
    ], 'R660_INTERRUPT_PASS')


def dma(run, refine, optimize="none", specialize="off"):
    here = Path(__file__).resolve().parent
    source = here / 'probes/firmware-dma.ldn'
    elf = build(run, refine, source.read_text(), optimize, specialize)
    dma_execute(run, elf)


def dma_execute(run, elf):
    text = run.command('dma-symbols', [run.bin / 'arm-none-eabi-nm', elf])
    symbols = {parts[2]: int(parts[0],16) for line in text.splitlines()
               if len(parts := line.split()) == 3}
    stage = symbols['stage']
    model = PrototypePeripheral()
    with Machine(run, elf, 'dma', poll=[stage]) as m:
        m.map(0x40020000, 0x7000, model)
        m.trap(symbols['_landin_firmware_unhandled'], 'unhandled exception')
        u32 = m.u32
        m.until(lambda: u32(stage) == 1)
        require(model.configuration == 0x80000407 and model.remaining == 4, 'ready: descriptor')
        require(model.transfers == 0 and model.errors == 0, 'ready: transfers')
        require(model.count_half_writes == 1 and model.count_word_writes == 0, 'ready: count width')
        model.feed(42)
        model.feed(43)
        m.settle()
        require(u32(symbols['notifications']) == 1, 'half: notifications')
        require(u32(symbols['completed']) == 0 and u32(symbols['result']) == 0, 'half: state')
        require(model.transfers == 2 and model.remaining == 2, 'half: model')
        m.write_u32(stage, 2)
        m.until(lambda: u32(stage) == 3)
        model.feed(44)
        model.feed(45)
        m.settle()
        require(u32(symbols['notifications']) == 1, 'masked: delivered while masked')
        require(u32(symbols['completed']) == 0, 'masked: completed while masked')
        require(model.transfers == 4 and model.remaining == 0, 'masked: model')
        require(u32(symbols['buffer']) == 0x2d2c2b2a, 'masked: buffer')
        m.write_u32(stage, 4)
        m.until(lambda: u32(stage) == 5)
        m.settle()
        require(u32(symbols['result']) == 174, 'done: result')
        require(u32(symbols['notifications']) == 2 and u32(symbols['completed']) == 1,
                'done: notifications')
    require(model.transfers == 4 and model.errors == 0 and model.remaining == 0, 'done: model')
    require(model.configuration == 0x80000406, 'done: configuration')
    require(model.count_half_reads == 1 and model.count_word_reads == 0, 'done: count reads')
    require(model.count_half_writes == 1 and model.count_word_writes == 0, 'done: count writes')
    require(model.reads == 3 and model.writes == 7, 'done: access counts')
    (run.out / 'dma-trace.txt').write_text('notifications=2;half-read=1;half-write=1;'
        'status-read=2;clear-write=2;transfers=4;sum=174\n')


def machine(run, refine, optimize="none", specialize="off"):
    source = Path(__file__).parent / 'probes/firmware-machine.ldn'
    elf = build(run, refine, source.read_text(), optimize, specialize)
    execute(run, elf, [
        'break *start', 'continue', 'delete breakpoints', 'python',
        'assert v("$sp") == 0x20004000 and v("$r11") == 0',
        'assert v("*(unsigned*)&assembly_data") == 18', 'end',
        'break *worker', 'continue', 'delete breakpoints', 'python',
        'assert v("$sp") == 0x20003800 and v("$r11") == 0', 'end',
        'break *naked_handler', 'continue', 'delete breakpoints', 'python',
        'assert v("$lr") == 0xfffffffd',
        'assert v("$sp") == 0x20004000',
        'assert 0x20003000 <= v("$r11") < 0x20003800',
        'assert v("*(unsigned*)$r11") == 0',
        'assert v("*(unsigned*)&assembly_data") == 99', 'end',
        'break _landin_firmware_returned', 'continue', 'python',
        'assert v("$sp") == 0x20003800 and v("$r11") == 0',
        'assert v("$xpsr") & 511 == 0',
        'assert v("*(unsigned*)&observed") == 124',
        'assert v("*(unsigned*)&naked_hits") == 1',
        'assert v("$r9") == 0 and v("$r12") == 0',
        'print("R660_NAKED_PSP_ASSEMBLY_PASS")', 'end',
    ], 'R660_NAKED_PSP_ASSEMBLY_PASS')


def veneers(run, refine, optimize="none", specialize="off"):
    source = Path(__file__).parent / 'probes/firmware-veneer.ldn'
    elf = build(run, refine, source.read_text(), optimize, specialize)
    disassembly = (run.out / 'disassembly.log').read_text()
    require('__ram_worker_veneer' in disassembly,
            'flash-to-RAM transfer did not exercise a linker veneer')
    require('__flash_helper_veneer' in disassembly,
            'RAM-to-flash transfer did not exercise a linker veneer')
    require('__aeabi_uldivmod' in disassembly,
            'firmware helper closure was not exercised')
    execute(run, elf, [
        'python',
        'low=v("&_landin_firmware_ramtext_start")',
        'high=v("&_landin_firmware_ramtext_end")',
        'assert high > low',
        'gdb.selected_inferior().write_memory(low, bytes([0xcc])*(high-low))',
        'end',
        'break *start', 'continue', 'delete breakpoints', 'python',
        'assert 0x20000000 <= v("&ram_worker") < 0x20003000',
        'assert 0x20000000 <= v("&ram_irq") < 0x20003000',
        'assert v("&flash_helper") < 0x8000',
        'assert v("*(unsigned*)44") == v("&ram_irq") | 1',
        'low=v("&_landin_firmware_ramtext_start")',
        'high=v("&_landin_firmware_ramtext_end")',
        'load=v("&_landin_firmware_ramtext_load")',
        'assert load < 0x8000 and low >= 0x20000000 and high > low',
        'mem=gdb.selected_inferior()',
        'assert mem.read_memory(low,high-low).tobytes() == mem.read_memory(load,high-low).tobytes()',
        'end', 'break _landin_firmware_returned', 'continue', 'python',
        'assert v("*(unsigned*)&observed") == 42',
        'assert v("*(unsigned*)&irq_seen") == 1',
        'assert v("$r12") == 0 and v("$r11") == 0',
        'assert v("$sp") == 0x20004000',
        'print("R660_FIRMWARE_VENEER_PASS")', 'end',
    ], 'R660_FIRMWARE_VENEER_PASS')


def fallthrough(run, refine, optimize, specialize):
    elf = build(run, refine, 'extern(naked) start: () -> none = '
                'assembler.block("nop") end start\n', optimize, specialize)
    execute(run, elf, [
        'break _landin_firmware_unhandled', 'continue', 'python',
        'assert v("$xpsr") & 511 == 3',
        'assert v("$sp") == 0x20003fe0 and v("$r11") == 0',
        'assert v("*(unsigned short*)*(unsigned*)($sp+24)") == 0xde01',
        'assert v("*(unsigned*)($sp+24)") == (v("&start") & ~1)+2',
        'print("R660_NAKED_FALLTHROUGH_PASS")', 'end',
    ], 'R660_NAKED_FALLTHROUGH_PASS')


def independent(run):
    here = Path(__file__).resolve().parent / 'probes'
    elf = run.out / 'control.elf'
    run.command('independent-build', [run.bin / 'arm-none-eabi-gcc',
        '-mcpu=cortex-m0', '-mthumb', '-mfloat-abi=soft', '-mabi=aapcs',
        '-Os', '-Wall', '-Wextra', '-Werror', '-ffreestanding',
        '-fno-builtin', '-ffunction-sections', '-fdata-sections',
        '-nostdlib', '-nostartfiles', '-nodefaultlibs',
        here / 'firmware-control.S', here / 'firmware-control.c',
        '-Wl,--gc-sections,--build-id=none,-T,' + str(here / 'firmware-control.ld'),
        '-Wl,-Map,control.map', '-o', elf])
    run.command('independent-elf', [run.bin / 'arm-none-eabi-readelf', '-h','-A','-S','-l','-r', elf])
    run.command('independent-disassembly', [run.bin / 'arm-none-eabi-objdump', '-dr', elf])
    execute(run, elf, [
        'set *(unsigned*)&control_initial = 0xaaaaaaaa',
        'set *(unsigned*)&control_calls = 0xbbbbbbbb',
        'break *control_svc', 'continue', 'delete breakpoints', 'python',
        'assert v("$lr") == 0xfffffffd and v("$sp") == 0x20004000',
        'assert v("*(unsigned*)&control_initial") == 18',
        'assert v("*(unsigned*)&control_calls") == 0',
        'assert v("*(unsigned*)0x200037f4") & 0x200',
        'assert v("*(unsigned*)0x200037f4") & 0xf00001ff == 0x60000000',
        'end', 'break *control_irq', 'continue', 'delete breakpoints', 'python',
        'assert v("$lr") == 0xfffffff1 and v("$sp") == 0x20003fd8',
        'assert v("*(unsigned*)($sp+28)") & 511 == 11',
        'assert v("*(unsigned*)&control_initial") == 25',
        'end', 'break control_done', 'continue', 'python',
        'assert v("$sp") == 0x200037fc and v("$xpsr") & 511 == 0',
        'assert v("$xpsr") & 0xf0000000 == 0x60000000',
        'assert [v("$r%d" % i) for i in range(8)] == [17,34,51,68,85,102,119,136]',
        'assert v("*(unsigned*)&control_initial") == 32',
        'assert v("*(unsigned*)&control_calls") == 2',
        'print("R660_INDEPENDENT_FRAME_PASS")', 'end',
    ], 'R660_INDEPENDENT_FRAME_PASS')


def failures(parent, refine):
    cases = [
        ('flash-overflow', 'link(keep) image: [33000]u8 = [of 1]', 'L0501', 'FLASH'),
        ('stack-overlap', 'link(keep) mut image: [12289]u8 = zeroed', 'L0501', 'reserved 4 KiB stack'),
        ('bounded-materialization', 'link(keep) image: [8388609]u8 = [of 1]', 'L0505', '8 MiB'),
        ('missing-symbol', 'link(keep) extern(naked) h: () -> none = assembler.block("bl missing_firmware_symbol") end h', 'L0501', 'missing_firmware_symbol'),
        ('unsupported-encoding', 'link(keep) h: () -> none = assembler.block("ldr r0, [r1, #4096]") end h', 'L0501', 'firmware assembly failed'),
        ('reserved-instruction', 'h: () -> none = assembler.block("ldrex r0, [r1]") end h', 'L0330', 'M0 instructions'),
        ('misplaced-vector', 'link(section: ".isr_vector", keep) image: [48]u32 = zeroed', 'L0347', 'placement'),
        ('owned-reset-vector', 'link(vector: 1) extern(interrupt) h: () -> none = end h', 'L0347', 'placement'),
        ('invalid-entry', 'start: (value: u32) -> none = end start', 'L0502', 'firmware-entry'),
        ('reserved-symbol', 'link(symbol: "_landin_firmware_reset") value: u32 = 1', 'L0347', 'datum symbol'),
    ]
    for name, program, code, detail in cases:
        out = parent.out / name
        out.mkdir()
        run = Run(out, parent.tools)
        source = out / 'refused.ldn'
        source.write_text(program + ('\n' if name == 'invalid-entry' else
                          '\nstart: () -> none = end start\n'))
        try:
            run.command('refusal', [refine, '--target=cortex-m0',
                '--firmware-entry=start', '--emit=exe',
                '--toolchain='+str(run.bin / 'arm-none-eabi-gcc'),
                '-o', 'refused.elf', source.name], timeout=60)
        except RuntimeError:
            record = run.commands[-1]
            require(record.get('exit') == 1 and not record.get('timed_out'),
                    'refusal was not a bounded reported compiler failure: ' + name)
        else:
            raise RuntimeError('invalid firmware was accepted: ' + name)
        diagnostic = (out / 'refusal.log').read_text()
        require(code in diagnostic and detail in diagnostic,
                'unexpected firmware refusal: ' + name)
        require(not (out / 'refused.elf').exists(), 'refusal left a firmware ELF')


def peripheral(run, refine, kind, optimize, specialize):
    here = Path(__file__).resolve().parent
    source = here / ('probes/packed-cortex-hole.ldn' if kind == 'hole' else
                     'probes/backend-byte.ldn' if kind == 'byte' else
                     'probes/packed-cortex.ldn')
    program = source.read_text() + '''
link(symbol: "firmware_fault") mut firmware_fault: u32 = 0
mut firmware_result: u32 = 0
link(vector: 3) extern(naked) firmware_hardfault: () -> none =
    assembler.block("""
        mrs r0, ipsr
        ldr r1, =firmware_fault
        str r0, [r1]
        cpsid i
        1:
        wfi
        b 1b
        """)
end firmware_hardfault
link(vector: 11) extern(interrupt) firmware_svc: () -> none =
    firmware_result = main()
end firmware_svc
start: () -> none =
    assembler.block("svc #0")
    loop do assembler.block("wfi") end loop
end start
'''
    elf = build(run, refine, program, optimize, specialize)
    text = run.command('peripheral-symbols', [run.bin / 'arm-none-eabi-nm', elf])
    symbols = {parts[2]: int(parts[0],16) for line in text.splitlines()
               if len(parts := line.split()) == 3}
    trace = ('r32:4:0000009b' if kind == 'hole' else
             'r8:18:a5;r8:18:00;w8:19:41;w8:1a:02;r8:1a:f1' if kind == 'byte' else TRACE)
    model = EncodingPeripheral()
    with Machine(run, elf, 'device') as m:
        m.map(0x40030000, 0x20, model)
        m.settle()
        fault, result = m.u32(symbols['firmware_fault']), m.u32(symbols['firmware_result'])
    require(fault == (3 if kind == 'hole' else 0), 'firmware device fault status')
    require(result == (0 if kind == 'hole' else 42 if kind == 'byte' else 0x640),
            'firmware device result')
    require(model.trace == trace, 'firmware device trace differs: ' + model.trace)
    if kind == 'images':
        require(model.normal == 0xa50000d0 and model.command == 0x51 and model.pending == 0xf1
                and model.count == 0xffff and model.ones == 0xffffff51, 'firmware device images')
    elif kind == 'byte':
        require(model.byte_command == 0x41 and model.byte_pending == 0xf1, 'firmware byte images')
    (run.out / 'device-trace.txt').write_text(model.trace + '\n')


def execute_suite(parent, refine, profiles=PROFILES):
    root = parent.out / 'firmware'
    root.mkdir()
    refine = refine.resolve(strict=True)
    compiler_hash = sha(refine)
    parent.command('firmware-refine-identity', [refine, '--identify'])
    helper = parent.command('firmware-runtime-archive', [
        parent.bin / 'arm-none-eabi-gcc', '-mcpu=cortex-m0', '-mthumb',
        '-mfloat-abi=soft', '-print-libgcc-file-name']).strip()
    require(helper.endswith('/thumb/v6-m/nofp/libgcc.a'),
            'firmware selected the wrong runtime archive')
    out = root / 'cpu-levels'
    out.mkdir()
    controls = cpu_levels(Run(out, parent.tools), refine)
    out = root / 'refusals'
    out.mkdir()
    failures(Run(out, parent.tools), refine)
    out = root / 'independent-c-assembly'
    out.mkdir()
    independent(Run(out, parent.tools))
    for optimize, specialize in profiles:
        profile = root / (optimize + '-' + specialize)
        profile.mkdir()
        images = []
        for name in ('first', 'fresh'):
            out = profile / name
            out.mkdir()
            run = Run(out, parent.tools)
            elf = build(run, refine, optimize=optimize, specialize=specialize)
            execute(run, elf)
            images.append(out)
        for suffix in ('', '.o', '.s', '.ld', '.map'):
            require((images[0] / ('firmware.elf' + suffix)).read_bytes() ==
                    (images[1] / ('firmware.elf' + suffix)).read_bytes(),
                    'fresh firmware artifact differs: ' + suffix)
        for kind in ('interrupts', 'dma', 'machine', 'veneers', 'fallthrough', 'images', 'hole', 'byte'):
            out = profile / kind
            out.mkdir()
            run = Run(out, parent.tools)
            if kind == 'interrupts':
                program = (Path(__file__).parent / 'probes/firmware-irq.ldn').read_text()
                elf = build(run, refine, program, optimize, specialize)
                symbols = (out / 'symbols.log').read_text().splitlines()
                present = {parts[-1] for line in symbols if (parts := line.split())}
                require('discarded' not in present and 'discarded_handler' not in present,
                        'unreferenced sections survived garbage collection')
                require({'retained','svc_handler','irq_handler'} <= present,
                        'retained/vector-referenced sections disappeared')
                interrupts(run, elf)
            elif kind == 'dma':
                dma(run, refine, optimize, specialize)
            elif kind == 'machine':
                machine(run, refine, optimize, specialize)
            elif kind == 'fallthrough':
                fallthrough(run, refine, optimize, specialize)
            elif kind == 'veneers':
                veneers(run, refine, optimize, specialize)
            else:
                peripheral(run, refine, kind, optimize, specialize)
            fresh = out / 'fresh'
            fresh.mkdir()
            build(Run(fresh, parent.tools), refine,
                  (out / 'boot.ldn').read_text(), optimize, specialize)
            for suffix in ('', '.o', '.s', '.ld', '.map'):
                require((out / ('firmware.elf' + suffix)).read_bytes() ==
                        (fresh / ('firmware.elf' + suffix)).read_bytes(),
                        'fresh ' + kind + ' artifact differs: ' + suffix)
            controls.append({'kind': kind, 'optimize': optimize,
                             'specialize': specialize, 'status': 'passed'})
        controls.append({'kind': 'cold-boot-reset-fresh', 'optimize': optimize,
                         'specialize': specialize, 'status': 'passed'})
        print('compiler firmware: ' + profile.name + ' passed', flush=True)
    require(sha(refine) == compiler_hash, 'compiler changed during firmware execution')
    record = {'status': 'passed', 'compiler_sha256': compiler_hash,
              'runtime_archive': helper, 'runtime_archive_sha256': sha(Path(helper)),
              'controls': controls,
              'artifacts': {str(p.relative_to(root)): sha(p)
                            for p in sorted(root.rglob('*')) if p.is_file()}}
    (root / 'result.json').write_text(json.dumps(record, indent=2)+'\n')
    return record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--refine', type=Path, required=True)
    parser.add_argument('--tools', type=Path, default=DEFAULT)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--all-profiles', action='store_true')
    args = parser.parse_args()
    supported_host()
    before = inventory(args.tools)
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=False)
    record = {'status': 'failed', 'tools': before,
              'scope': 'development compiler-owned firmware; not acceptance'}
    try:
        record['firmware'] = execute_suite(Run(args.output, args.tools.resolve()),
            args.refine, PROFILES if args.all_profiles else PROFILES[:1])
        require(inventory(args.tools) == before, 'embedded tool inventory changed')
        record['status'] = 'passed'
    finally:
        record['files'] = {str(p.relative_to(args.output)): sha(p)
                          for p in sorted(args.output.rglob('*')) if p.is_file()}
        (args.output / 'result.json').write_text(json.dumps(record, indent=2)+'\n')
    print('DEVELOPMENT / NOT ACCEPTANCE: compiler firmware controls passed')


if __name__ == '__main__':
    main()
