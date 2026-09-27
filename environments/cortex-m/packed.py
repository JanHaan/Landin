"""Independent C image algebra against the synthetic encoding device."""
from machine import Machine, Refused
from models import EncodingPeripheral
from run import require


# Literal oracle, deliberately not generated from the firmware or model.
TRACE = ('r32:0:a50000f0;w32:0:a50000d0;r32:0:a50000d0;'
         'r32:4:0000009b;r32:4:00000000;w32:8:00000051;'
         'w32:c:00000002;r32:c:000000f1;w32:c:00000000;r32:c:000000f1;'
         'r16:10:ffff;w16:10:0000;r16:10:0000;w16:10:ffff;'
         'w32:14:ffffff51;r32:14:ffffff51')


def execute(run):
    symbols = run.build('packed')
    run.command('disassembly-packed',
                [run.bin / 'arm-none-eabi-objdump', '-dr', 'packed.elf'])
    model = EncodingPeripheral()
    with Machine(run, run.out / 'packed.elf', 'packed') as m:
        m.map(0x40030000, 0x20, model)
        m.trap(symbols['fault_done'], 'hard fault')
        m.settle()
        require(m.u32(symbols['result']) == 0x640, 'packed: result')
        require(m.u32(symbols['stage']) == 1, 'packed: stage')
    require(model.trace == TRACE, 'packed trace differs: ' + model.trace)
    require(model.normal == 0xa50000d0 and model.command == 0x51 and model.pending == 0xf1
            and model.count == 0xffff and model.ones == 0xffffff51, 'packed device images')
    # Invalid accesses only after the trace holds: the model independently
    # refuses direction, width and reserved-bit faults.
    refused = 0
    for action in [lambda: model.read(8, 4), lambda: model.write(4, 4, 0),
                   lambda: model.read(0, 2), lambda: model.read(16, 4),
                   lambda: model.write(0, 4, 0), lambda: model.write(8, 4, 0x100),
                   lambda: model.write(12, 4, 0x100), lambda: model.write(20, 4, 0x51)]:
        try:
            action()
        except Refused:
            refused += 1
    require(refused == 8 and model.trace == TRACE, 'packed model accepted a refused access')
    (run.out / 'packed-trace.txt').write_text(model.trace + '\n')
