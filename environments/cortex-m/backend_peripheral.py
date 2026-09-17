"""Actual compiler-generated ARMv6-M instructions driving Renode devices."""
import argparse
import json
from pathlib import Path

from backend import build
from packed import TRACE
from packed_native import PROFILES
from run import Run, require
from setup import DEFAULT, HERE, sha, supported_host

PLATFORM = '''cpu: CPU.CortexM @ sysbus
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
'''


def execute(run, refine, hole, optimize, specialize):
    source = HERE / ('probes/packed-cortex-hole.ldn' if hole else 'probes/packed-cortex.ldn')
    elf = build(run, refine, [source], optimize, specialize)
    text = run.command('symbols', [run.bin / 'arm-none-eabi-nm', elf])
    symbols = {s[2]: int(s[0], 16) for line in text.splitlines() if len(s := line.split()) == 3}
    platform = run.out / 'platform.repl'
    platform.write_text(PLATFORM)
    checks = run.out / 'checks.py'
    checks.write_text('''bus = monitor.Machine.SystemBus
model = monitor.Machine["sysbus.model"]
''' + f'''assert bus.ReadDoubleWord({symbols['backend_fault']}) == {3 if hole else 0}
assert str(model.Trace) == {('r32:4:0000009b' if hole else TRACE)!r}
''' + ('' if hole else f'''assert bus.ReadDoubleWord({symbols['backend_result']}) == 0x640
assert bus.ReadDoubleWord({symbols['backend_result'] + 4}) == 0
assert model.Normal == 0xa50000d0
assert model.Command == 0x51 and model.Pending == 0xf1
assert model.Count == 0xffff and model.Ones == 0xffffff51
''') + '''print("R650_CORTEX_TRACE " + str(model.Trace))
print("R650_CORTEX_PERIPHERAL_PASS")
''')
    run.renode_script('peripheral', [
        f'include @{HERE}/probes/EncodingPeripheral.cs',
        'mach create "compiler-cortex-packed"',
        f'machine LoadPlatformDescription @{platform}',
        f'sysbus LoadELF @{elf}', 'emulation RunFor "0.1"',
        f'include @{checks}',
    ], 'R650_CORTEX_PERIPHERAL_PASS')
    return {'source_sha256': sha(source), 'execution': 'compiler Cortex-M0 / synthetic Renode',
            'optimize': optimize, 'specialize': specialize, 'hole': hole, 'status': 'passed'}


def byte(run, refine, optimize, specialize):
    source = HERE / 'probes/backend-byte.ldn'
    elf = build(run, refine, [source], optimize, specialize)
    text = run.command('symbols', [run.bin / 'arm-none-eabi-nm', elf])
    symbols = {s[2]: int(s[0], 16) for line in text.splitlines() if len(s := line.split()) == 3}
    platform = run.out / 'platform.repl'
    platform.write_text(PLATFORM)
    checks = run.out / 'checks.py'
    checks.write_text(f'''bus = monitor.Machine.SystemBus
model = monitor.Machine["sysbus.model"]
assert bus.ReadDoubleWord({symbols['backend_fault']}) == 0
assert bus.ReadDoubleWord({symbols['backend_result']}) == 42
assert bus.ReadDoubleWord({symbols['backend_result'] + 4}) == 0
assert str(model.Trace) == "r8:18:a5;r8:18:00;w8:19:41;w8:1a:02;r8:1a:f1"
assert model.ByteCommand == 0x41 and model.BytePending == 0xf1
print("R650_BYTE_TRACE " + str(model.Trace))
print("R650_CORTEX_BYTE_PASS")
''')
    run.renode_script('byte', [f'include @{HERE}/probes/EncodingPeripheral.cs',
        'mach create "compiler-cortex-byte"', f'machine LoadPlatformDescription @{platform}',
        f'sysbus LoadELF @{elf}', 'emulation RunFor "0.1"', f'include @{checks}',
    ], 'R650_CORTEX_BYTE_PASS')
    return {'status': 'passed', 'optimize': optimize, 'specialize': specialize,
            'source_sha256': sha(source)}


def dma(run, refine, optimize, specialize):
    elf = build(run, refine, [HERE / 'probes/backend-dma.ldn'], optimize, specialize)
    text = run.command('symbols', [run.bin / 'arm-none-eabi-nm', elf])
    symbols = {s[2]: int(s[0], 16) for line in text.splitlines() if len(s := line.split()) == 3}
    platform = run.out / 'platform.repl'
    platform.write_text(PLATFORM.replace('EncodingPeripheral @ sysbus 0x40030000',
                                        'PrototypePeripheral @ sysbus 0x40020000'))
    def check(name, text):
        path = run.out / (name + '.py')
        path.write_text('bus = monitor.Machine.SystemBus\nmodel = monitor.Machine["sysbus.model"]\n' + text + '\n')
        return f'include @{path}'
    ready = check('ready', f"""assert bus.ReadDoubleWord({symbols['backend_result']}) == 0
assert model.Transfers == 0 and model.Errors == 0
assert model.Remaining == 4 and model.Configuration == 0x80000401
assert model.CountHalfWrites == 1 and model.CountWordWrites == 0
""")
    half = check('half', f"""assert bus.ReadDoubleWord({symbols['backend_result']}) == 0
assert model.Transfers == 2 and model.Remaining == 2
""")
    done = check('done', f"""assert bus.ReadDoubleWord({symbols['backend_result']}) == 174
assert bus.ReadDoubleWord({symbols['backend_result'] + 4}) == 0
assert bus.ReadDoubleWord({symbols['backend_fault']}) == 0
assert model.Transfers == 4 and model.Errors == 0 and model.Remaining == 0
assert model.Configuration == 0x80000400
assert model.CountHalfReads == 1 and model.CountWordReads == 0
assert model.CountHalfWrites == 1 and model.CountWordWrites == 0
print("R650_DMA_TRACE half-write=1;half-read=1;word-count-access=0;transfers=4;sum=174")
print("R650_CORTEX_DMA_PASS")
""")
    run.renode_script('dma', [
        f'include @{HERE}/probes/PrototypePeripheral.cs',
        'mach create "compiler-cortex-dma"',
        f'machine LoadPlatformDescription @{platform}', f'sysbus LoadELF @{elf}',
        'emulation RunFor "0.01"', ready, 'sysbus.model Feed 42', 'sysbus.model Feed 43',
        'emulation RunFor "0.005"', half, 'sysbus.model Feed 44', 'sysbus.model Feed 45',
        'emulation RunFor "0.01"', done,
    ], 'R650_CORTEX_DMA_PASS')
    return {'status': 'passed', 'optimize': optimize, 'specialize': specialize,
            'source_sha256': sha(HERE / 'probes/backend-dma.ldn')}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--refine', type=Path, required=True)
    parser.add_argument('--tools', type=Path, default=DEFAULT)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--all-profiles', action='store_true')
    args = parser.parse_args()
    supported_host()
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=False)
    results = []
    for opt, spec in PROFILES if args.all_profiles else PROFILES[:1]:
        for hole in (False, True):
            out = args.output / f'{opt}-{spec}-{"hole" if hole else "images"}'
            out.mkdir()
            result = execute(Run(out, args.tools.resolve()), args.refine.resolve(), hole, opt, spec)
            result['artifacts'] = {str(p.relative_to(out)): sha(p) for p in sorted(out.rglob('*')) if p.is_file()}
            results.append(result)
            print('DEVELOPMENT / FILTERED / NOT ACCEPTANCE: ' + out.name + ' passed', flush=True)
        out = args.output / f'{opt}-{spec}-dma'
        out.mkdir()
        result = dma(Run(out, args.tools.resolve()), args.refine.resolve(), opt, spec)
        result['artifacts'] = {str(p.relative_to(out)): sha(p) for p in sorted(out.rglob('*')) if p.is_file()}
        results.append(result)
        print('DEVELOPMENT / FILTERED / NOT ACCEPTANCE: ' + out.name + ' passed', flush=True)
        out = args.output / f'{opt}-{spec}-byte'
        out.mkdir()
        result = byte(Run(out, args.tools.resolve()), args.refine.resolve(), opt, spec)
        result['artifacts'] = {str(p.relative_to(out)): sha(p) for p in sorted(out.rglob('*')) if p.is_file()}
        results.append(result)
        print('DEVELOPMENT / FILTERED / NOT ACCEPTANCE: ' + out.name + ' passed', flush=True)
    (args.output / 'result.json').write_text(json.dumps(results, indent=2)+'\n')


if __name__ == '__main__':
    main()
