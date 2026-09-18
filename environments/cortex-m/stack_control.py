"""Independent C/assembly-startup control for paint gaps and exception frames."""
from firmware import execute
from run import HERE


def run(control):
    elf=control.out/'stack.elf'
    control.command('compile',[control.bin/'arm-none-eabi-gcc','-mcpu=cortex-m0',
        '-mthumb','-mfloat-abi=soft','-nostdlib','-nostartfiles','-static',
        '-Wl,--build-id=none,-Map,stack.map,-T,'+str(HERE/'probes/memory.ld'),
        HERE/'probes/start.S',HERE/'probes/stack-control.S','-o',elf])
    control.command('elf',[control.bin/'arm-none-eabi-readelf','-h','-S','-l',elf])
    control.command('disassembly',[control.bin/'arm-none-eabi-objdump','-dr',elf])
    execute(control,elf,[
        'break *probe','continue','delete breakpoints','python',
        'assert v("$sp") == 0x20004000',
        'gdb.selected_inferior().write_memory(0x20003000,bytes([0xa5])*4096)','end',
        'break *unwritten_gap','continue','delete breakpoints','python',
        'assert v("$sp") == 0x20003f00',
        'assert bytes(gdb.selected_inferior().read_memory(0x20003000,4096)) == bytes([0xa5])*4096',
        'end','break *svc','continue','delete breakpoints','python',
        'assert v("$sp") == 0x20004000-40',
        'assert v("$lr") == 0xfffffff9 and v("$xpsr") & 511 == 11',
        'assert v("*(unsigned*)($sp+28)") & 512 == 512',
        'assert v("*(unsigned*)($sp+24)") == v("&after_svc")',
        'end','break *device_irq','continue','delete breakpoints','python',
        'assert v("$sp") == 0x20004000-80',
        'assert v("$lr") == 0xfffffff1 and v("$xpsr") & 511 == 16',
        'assert v("*(unsigned*)($sp+28)") & 1023 == 11',
        'end','break done','continue','python',
        'assert v("$sp") == 0x20004000',
        'paint=bytes(gdb.selected_inferior().read_memory(0x20003000,4096))',
        'assert 4096-next(i for i,b in enumerate(paint) if b != 0xa5) == 80',
        'assert paint[:256] == bytes([0xa5])*256',
        'print("R6100_STACK_CONTROL reserved=256;written=80;outer=36;save=8;inner=32")',
        'print("R6100_STACK_CONTROL_PASS")','end'],'R6100_STACK_CONTROL_PASS')
    # The independent program also calibrates the observer used for the
    # application: its deepest reservation deliberately writes no bytes.
    from resources import install
    check=control.out/'observer-control.py'
    check.write_text('''snapshot("independent-unwritten-gap")
assert snapshots[0]["written_bytes"] == 80
assert snapshots[0]["observed_reserved_bytes"] == 256
assert snapshots[0]["observations"]["interrupt_ipsr"]["11"] == 0x20004000-40
assert snapshots[0]["observations"]["interrupt_ipsr"]["16"] == 0x20004000-80
print("R6100_STACK_OBSERVER_PASS")
''')
    control.renode_script('observer-control',[
        f'include @{HERE}/probes/DriverPeripheral.cs', 'mach create "stack-control"',
        f'machine LoadPlatformDescription @{HERE}/probes/driver.repl',
        f'sysbus LoadELF @{elf}', f'include @{HERE}/probes/StackObserver.cs',
        install(control),'emulation RunFor "0.001"','include @'+str(check)],
        'R6100_STACK_OBSERVER_PASS')
