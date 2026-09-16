"""Independent C image algebra and actual Renode transaction controls."""
from setup import HERE


# Literal oracle, deliberately not generated from the firmware or model.
TRACE = ('r32:0:a50000f0;w32:0:a50000d0;r32:0:a50000d0;'
         'r32:4:0000009b;r32:4:00000000;w32:8:00000051;'
         'w32:c:00000002;r32:c:000000f1;w32:c:00000000;r32:c:000000f1;'
         'r16:10:ffff;w16:10:0000;r16:10:0000;w16:10:ffff')


def execute(run):
    symbols = run.build('packed')
    run.command('disassembly-packed',
                [run.bin / 'arm-none-eabi-objdump', '-dr', 'packed.elf'])
    platform = run.out / 'packed.repl'
    platform.write_text('''cpu: CPU.CortexM @ sysbus
    cpuType: "cortex-m0"
    nvic: nvic
    PerformanceInMips: 16
nvic: IRQControllers.NVIC @ sysbus 0xe000e000
    systickFrequency: 16000000
    IRQ -> cpu@0
flash: Memory.MappedMemory @ sysbus 0x0
    size: 0x8000
ram: Memory.MappedMemory @ sysbus 0x20000000
    size: 0x4000
model: Miscellaneous.EncodingPeripheral @ sysbus 0x40030000
''')
    checks = run.out / 'packed-checks.py'
    checks.write_text(f'''bus = monitor.Machine.SystemBus
model = monitor.Machine["sysbus.model"]
assert bus.ReadDoubleWord({symbols['result']}) == 0x640
assert bus.ReadDoubleWord({symbols['stage']}) == 1
assert str(model.Trace) == {TRACE!r}
assert model.Normal == 0xa50000d0
assert model.Command == 0x51
assert model.Pending == 0xf1
assert model.Count == 0xffff
print("R640_PACKED_TRACE " + str(model.Trace))
# Invalid accesses are attempted only after the successful trace assertion.
# The model independently refuses direction, width and reserved-bit faults.
refused = 0
for action in [lambda: model.ReadDoubleWord(8),
               lambda: model.WriteDoubleWord(4, 0),
               lambda: model.ReadWord(0),
               lambda: model.ReadDoubleWord(16),
               lambda: model.WriteDoubleWord(0, 0),
               lambda: model.WriteDoubleWord(8, 0x100),
               lambda: model.WriteDoubleWord(12, 0x100)]:
    try:
        action()
    except Exception:
        refused += 1
assert refused == 7
assert str(model.Trace) == {TRACE!r}
print("R640_PACKED_PASS")
''')
    run.renode_script('packed', [
        f'include @{HERE}/probes/EncodingPeripheral.cs',
        'mach create "packed-contract"',
        f'machine LoadPlatformDescription @{platform}',
        f'sysbus LoadELF @{run.out}/packed.elf',
        'emulation RunFor "0.1"',
        f'include @{checks}',
    ], 'R640_PACKED_PASS')
