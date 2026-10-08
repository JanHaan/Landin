#!/usr/bin/env python3
"""Complete derived driver CPU/application/protocol execution, independent oracles."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import shutil
import struct
import sys
from backend import image_contract
from devices import linker_closure
from firmware import execute
from machine import Machine
from models import DriverPeripheral
from packed_native import PROFILES
from run import Run, require, workers
from setup import DEFAULT, inventory, sha, supported_host

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
SOURCE = ROOT / 'compiler/tests/driver'
MODULES = ('drivers/uart', 'rp2040/io_bank0', 'rp2040/uart0', 'rp2040/dma',
           'rp2040/sio', 'rp2040/timer', 'platform/cpu')


def build(run, refine, name, optimize, specialize, debug='none'):
    source = run.out / 'source'
    source.mkdir()
    shutil.copytree(SOURCE / name, source / 'app')
    for module in MODULES:
        origin = (SOURCE if module.startswith('drivers/') else
                  ROOT / 'devices/generated' if module.startswith('rp2040/') else ROOT)
        shutil.copytree(origin / module, source / module)
    elf = run.out / 'core.elf'
    run.command('compile', [refine, '--root=source', '--target=cortex-m0',
        '--firmware-entry=start', '--emit=exe', '--debug='+debug,
        '--toolchain='+str(run.bin / 'arm-none-eabi-gcc'),
        '--optimize='+optimize, '--specialize='+specialize, '--build-report=build.json',
        'source/app', '-o', elf.name], timeout=60)
    attributes=run.command('elf', [run.bin/'arm-none-eabi-readelf','-h','-A','-S','-l','-r',elf])
    require('Tag_CPU_arch: v6S-M' in attributes and 'Tag_THUMB_ISA_use: Thumb-1' in attributes
            and 'Tag_ARM_ISA_use: Yes' not in attributes and 'VFP registers' not in attributes,
            'driver ELF is not the selected ARMv6-M profile')
    run.command('disassembly',[run.bin/'arm-none-eabi-objdump','-dr',elf])
    names = run.command('symbols',[run.bin/'arm-none-eabi-nm','-n',elf])
    require(not run.command('undefined',[run.bin/'arm-none-eabi-nm','-u',elf]).strip(),
            'unresolved driver symbol')
    helper = run.command('runtime-archive',[run.bin/'arm-none-eabi-gcc',
        '-mcpu=cortex-m0','-mthumb','-mfloat-abi=soft','-print-libgcc-file-name']).strip()
    require(helper.endswith('/thumb/v6-m/nofp/libgcc.a'),'wrong private runtime')
    loads,members=linker_closure((run.out/'core.elf.map').read_text(),helper)
    symbols={s[2]:int(s[0],16) for line in names.splitlines() if len(s:=line.split())==3}
    data=elf.read_bytes()
    header=struct.unpack_from('<16sHHIIIIIHHHHHH',data)
    for index in range(header[10]):
        kind,_,virtual,physical,file_size,memory_size,_,_=struct.unpack_from('<8I',data,header[5]+index*32)
        if kind == 1 and file_size == 0 and memory_size:
            require(physical == virtual and 0x20000000 <= physical < 0x20003000,
                    'zero-fill segment has a spurious flash load address')
    report=json.loads((run.out/'build.json').read_text())['build']
    require(all(r['frame_bytes'] <= 4096 for r in report['routines']),
            'individual driver frame exceeds stack reservation')
    require(not symbols.keys() & {'malloc','calloc','realloc','free','exit','_exit','__libc_init_array','__libc_start_main','_sbrk'},'hosted driver closure')
    imported = {'app'}
    for path in source.rglob('*.ldn'):
        imported.update(line[7:] for line in path.read_text().splitlines()
                        if line.startswith('import '))
    record={'image':image_contract(elf),'modules':sorted(imported),
        'inputs':{str(p.relative_to(source)):sha(p) for p in sorted(source.rglob('*.ldn'))},
        'linker_inputs':loads,'runtime_members':members,'runtime_archive':helper,
        'runtime_archive_sha256':sha(Path(helper)),'symbols':symbols}
    (run.out/'closure.json').write_text(json.dumps(record,indent=2)+'\n')
    return elf,symbols


def cpu(run, elf, s, name):
    commands = ['python',
        'assert v("$sp") == 0x20004000',
        'assert v("*(unsigned*)0") == 0x20004000',
        'assert v("$pc") == v("*(unsigned*)4") & ~1',
        'mem=gdb.selected_inferior()',
        'end']
    for reset in range(2):
        commands += ['python',
            'mem.write_memory(0x20000000, bytes([0xa5])*0x4000)',
            'end', 'break *start', 'continue', 'delete breakpoints', 'python',
            'assert v("$sp") == 0x20004000 and v("$r11") == 0 and v("$r9") == 0',
            'assert v("*(unsigned*)64") == '+str(s['dma_irq' if name == 'app' else 'irq']|1),
            'assert v("*(unsigned*)68") == '+str((s['timer_irq'] if name == 'app' else s['_landin_firmware_unhandled'])|1),
            'for slot in (4,5,6,7,8,9,10,12,13,21,42,43,44,45,46,47):',
            '    assert v("*(unsigned*)%d" % (slot*4)) == 0']
        if name == 'app':
            commands += ['assert v("*(unsigned*)&initialized") == 0x690',
                'assert v("*(unsigned*)&cleared") == 0',
                'assert v("*(unsigned*)&immutable") == 0x690',
                'assert v("&immutable") < 0x8000',
                'low=v("&_landin_firmware_ramtext_start")',
                'high=v("&_landin_firmware_ramtext_end")',
                'load=v("&_landin_firmware_ramtext_load")',
                'assert 0x20000000 <= low < high < 0x20003000 and load < 0x8000',
                'assert bytes(mem.read_memory(low,high-low)) == bytes(mem.read_memory(load,high-low))',
                'assert bytes(mem.read_memory(v("&rx_storage"),256)) == bytes(256)',
                'end', 'break *open', 'continue', 'delete breakpoints', 'python',
                'assert v("$sp") % 8 == 0 and v("$sp") >= 0x20003000',
                'assert v("$r11") >= v("$sp") and v("$r11") < 0x20004000',
                'assert v("*(unsigned*)$r11") == 0',
                'assert v("*(unsigned*)&app_state") == 0x690']
        else:
            commands += ['assert v("*(unsigned*)&capacity") == 8',
                'assert v("*(unsigned*)&budget") == 32',
                'assert v("*(unsigned*)&stage") == 0',
                'assert bytes(mem.read_memory(v("&storage"),512)) == bytes(512)']
        commands += ['end']
        if reset == 0:
            commands += ['monitor system_reset', 'maintenance flush register-cache']
    commands += ['python', 'print("R690_CPU_PASS")', 'end']
    commands = [line + ', '+repr(line.strip()) if line.lstrip().startswith('assert ') else line
                for line in commands]
    execute(run, elf, commands, 'R690_CPU_PASS')


def layout_cpu(run,elf,s):
    execute(run,elf,['break _landin_firmware_returned','continue','python',
        'assert [v("*(unsigned*)%%d" %% a) for a in range(%d,%d,4)] == [4,24,4,48,8,12,16,20,21,22,23]' % (s['layout'],s['layout']+44),
        'assert v("$sp") == 0x20004000 and v("$r11") == 0 and v("$r9") == 0',
        'print("R690_LAYOUT_PASS")','end'],'R690_LAYOUT_PASS')


def machine(run, elf, s, name, poll=()):
    """The driver image on QEMU with its synthetic device, ending at a fault."""
    m = Machine(run, elf, name, poll)
    model = DriverPeripheral()
    m.map(0x40070000, 0x2000, model)
    m.trap(s['_landin_firmware_unhandled'], 'unhandled exception')
    return m, model


def application(run,elf,s):
    trace = ('r32:100c:00000000;r32:4:3000001f;w32:4:30000002;'
        'r32:c:3000001f;w32:c:30000002;w32:224:0000001a;'
        'w32:228:00000003;w32:22c:00000070;w32:248:00000001;'
        'w32:100c:000a8620;w32:1000:40070200;w32:1004:%08x;' % s['rx_storage'] +
        'w32:1008:0000ffff;w32:1400:00000001;w32:1404:00000001;'
        'w32:100c:000a8621;r32:328:00000000;w32:310:000003e8;'
        'w32:100c:000a8620;r32:100c:000a8620;r32:100c:000a8620;'
        'r32:1008:0000ffff;w32:100c:000a8621;'
        'dma8:0:31;dma8:1:41;dma8:2:30;'
        'w32:334:00000001;r32:328:000003e8;w32:310:000007d0;'
        'w32:100c:000a8620;r32:100c:000a8620;r32:100c:000a8620;'
        'r32:1008:0000fffc;w32:100c:000a8621;'
        'w32:114:00000001;w32:200:00000031;w32:200:00000041;'
        'w32:118:00000001;w32:200:00000030')
    m, model = machine(run, elf, s, 'application')
    with m:
        u32 = m.u32
        m.write(0x20003000, bytes([165]) * 4096)
        m.settle()
        require(u32(s['app_state']) == 2, 'ready: state')
        require(model.integer_divisor == 26 and model.fraction_divisor == 3, 'ready: baud')
        require(model.line_control == 112 and model.dma_control == 1, 'ready: line')
        require(model.gpio0 == 0x30000002 and model.gpio1 == 0x30000002, 'ready: pins')
        require(model.remaining == 65535 and model.busy, 'ready: ring')
        require(model.alarm == 1000, 'ready: alarm')
        require(u32(s['initialized']) == 0x690 and u32(s['cleared']) == 0, 'ready: data')
        for value in (49, 65, 48):
            model.feed(value)
        model.tick(999)
        require(not model.alarm_pending, 'early: alarm')
        require(u32(s['handled']) == 0, 'early: handled')
        model.tick(1)
        m.settle()
        require(u32(s['handled']) == 3 and u32(s['recoveries']) == 0, 'done: handled')
        require(model.output_text == '49,65,48', 'done: output')
        require(model.output == 0 and model.remaining == 65532, 'done: model')
        require(u32(s['app_state']) == 2, 'done: state')
        require(model.trace == trace, 'application trace differs: ' + model.trace)
        paint = m.read(0x20003000, 4096)
        require(paint[:256] == bytes([165]) * 256, 'done: stack guard')
        observed = 4096 - next(i for i, b in enumerate(paint) if b != 165)
        for _ in range(300):
            model.feed(70)
        m.settle()
        require(u32(s['recoveries']) == 1 and u32(s['handled']) == 3, 'recovered: counts')
        require(u32(s['app_state']) == 2, 'recovered: state')
        require(model.remaining == 65535 and model.transfers == 0 and model.busy,
                'recovered: ring')
        require(model.output_text == '49,65,48', 'recovered: output')
        model.delay_stop(20, -1)
        model.feed(65)
        model.tick(1000)
        m.settle()
        require(u32(s['handled']) == 3 and u32(s['recoveries']) == 1, 'terminal: counts')
        require(u32(s['app_state']) == 3, 'terminal: state')
        require(model.busy and model.remaining == 65534, 'terminal: ring')
        require(model.output_text == '49,65,48', 'terminal: output')
        paint = m.read(0x20003000, 4096)
        require(paint[:256] == bytes([165]) * 256, 'terminal: stack guard')
        final = 4096 - next(i for i, b in enumerate(paint) if b != 165)
    (run.out / 'application.json').write_text(json.dumps(
        dict(trace=trace, stack_observed=observed, stack_final=final), indent=2) + '\n')


def protocol(run,elf,s):
    m, model = machine(run, elf, s, 'protocol', poll=[s['command']])
    steps = []
    with m:
        u32, u8 = m.u32, m.u8
        def settle():
            m.settle()
        def feed(values):
            for value in values:
                model.feed(value)
            settle()
        stage = [2]
        def op(code, result=0, outcome=0, data=None, extra=None, trace=None):
            model.clear_trace()
            m.write_u32(s['command'], code)
            settle()
            stage[0] += 1
            require(u32(s['stage']) == stage[0], 'step %d: stage %d' % (stage[0], u32(s['stage'])))
            require(u32(s['command']) == 0, 'step %d: command' % stage[0])
            require(u32(s['result']) == result,
                    'step %d: result %d, not %d' % (stage[0], u32(s['result']), result))
            require(u32(s['outcome']) == outcome,
                    'step %d: outcome %d, not %d' % (stage[0], u32(s['outcome']), outcome))
            if data is not None:
                require(list(m.read(s['destination'], len(data))) == data, 'step %d: data' % stage[0])
            if trace is not None:
                require(model.trace == trace, 'step %d: trace %s' % (stage[0], model.trace))
            if extra is not None:
                require(extra(), 'step %d: device state' % stage[0])
            steps.append('R690_STEP_%d %s' % (stage[0], model.trace))
        def stable(remaining, resume=True):
            return ('w32:100c:000a84e0;r32:100c:000a84e0;'
                    'r32:100c:000a84e0;r32:1008:%08x' % remaining +
                    (';w32:100c:000a84e1' if resume else ''))
        settle()
        require(u32(s['stage']) == 1, 'open: waiting')
        m.write_u32(s['command'], 1)
        settle()
        require(u32(s['stage']) == 2, 'open: stage')
        require(model.remaining == 32 and model.configuration == 0xa84e1, 'open: ring')
        require(model.integer_divisor == 26 and model.fraction_divisor == 3, 'open: baud')
        op(1, trace=stable(32))
        feed([10, 11, 12])
        require(u32(s['events']) == 0, 'events before limit')
        m.write_u32(s['limit'], 2)
        op(2, 2, data=[10, 11], trace=stable(29))
        op(2, 1, data=[12], trace=stable(29))
        op(2, 0, trace=stable(29))
        feed([20])
        require(u32(s['events']) == 1 and model.remaining == 28 and model.busy
                and model.pending == 0, 'half event')
        feed([21, 22, 23, 24])
        require(u32(s['events']) == 2 and model.remaining == 24 and model.busy
                and model.pending == 0, 'full event')
        feed([25, 26, 27])
        require(u32(s['events']) == 2 and model.remaining == 21, 'coalesced')
        op(1, 8, trace=stable(21))
        m.write_u32(s['limit'], 3)
        op(2, 3, data=[20, 21, 22], trace=stable(21))
        m.write_u32(s['limit'], 256)
        op(2, 5, data=[23, 24, 25, 26, 27], trace=stable(21))
        op(2, 0, trace=stable(21))
        op(5, trace='')
        before = u32(s['events'])
        model.clear_trace()
        feed(list(range(30, 47)))
        require(u32(s['events']) == before, 'masked: delivered')
        require(model.remaining == 4 and model.transfers == 28 and model.pending == 1, 'masked: ring')
        require(list(m.read(s['storage'], 8)) == [43, 44, 45, 46, 39, 40, 41, 42], 'masked: wrap')
        op(6, extra=lambda: u32(s['events']) == before + 1,
           trace='r32:1400:00000001;w32:1400:00000001')
        op(2, outcome=6, data=[23, 24, 25, 26, 27], trace=stable(4, False),
           extra=lambda: u32(s['quiet']) == 1 and u32(s['consumed']) == 28)
        op(2, outcome=6, trace=stable(4, False))
        op(4, extra=lambda: model.remaining == 32 and model.busy)
        feed([50, 51, 52, 53])
        require(u32(s['events']) == 4 and model.remaining == 28 and model.busy
                and model.pending == 0, 'restart: event')
        feed([54])
        require(u32(s['events']) == 4 and model.remaining == 27, 'restart: count')
        model.delay_stop(2, 99)
        op(2, 6, data=[50, 51, 52, 53, 54, 99], extra=lambda: model.remaining == 26)
        model.delay_stop(0, -1)
        op(3, extra=lambda: u32(s['quiet']) == 1 and not model.busy,
           trace='w32:100c:000a84e0;r32:100c:000a84e0')
        op(7, trace='')
        feed([60])
        require(model.rejected == 1 and u8(s['storage']) == 165, 'stopped: rejected')
        op(4)
        op(1, 0, trace=stable(32))
        feed([61])
        m.write_u32(s['limit'], 0)
        op(2, 0, trace=stable(31))
        m.write_u32(s['limit'], 256)
        op(2, 1, data=[61], trace=stable(31))
        model.inject_error()
        settle()
        require(u32(s['events']) == 5 and model.remaining == 31 and not model.busy
                and model.pending == 0, 'error: event')
        op(2, outcome=7, data=[61], extra=lambda: not model.busy)
        op(4, outcome=7, extra=lambda: model.remaining == 31)
        model.repair()
        op(4)
        for values in ([1, 2, 3, 4, 5, 6, 7, 8], [9, 10, 11, 12, 13, 14, 15, 16],
                       [17, 18, 19, 20, 21, 22, 23, 24], [25, 26, 27, 28, 29, 30, 31, 32]):
            feed(values)
            op(2, 8, data=values)
        require(u32(s['events']) == 9 and model.remaining == 0 and not model.busy
                and model.pending == 0, 'exhausted: ring')
        op(2, outcome=8, extra=lambda: model.remaining == 0 and not model.busy)
        feed([70])
        require(model.rejected == 2, 'exhausted: rejected')
        op(4)
        feed([80])
        model.delay_stop(20, -1)
        op(3, outcome=9, extra=lambda: u32(s['quiet']) == 0 and model.busy)
        op(2, outcome=9, data=[25, 26, 27, 28, 29, 30, 31, 32])
        op(3, extra=lambda: u32(s['quiet']) == 1 and not model.busy)
        op(7, trace='')
        require(u8(s['storage']) == 165, 'quiet: storage reused')
    (run.out / 'protocol-steps.txt').write_text('\n'.join(steps) + '\n')


def configurations(run, elf, symbols):
    # Literal boundary expectations; every refusal precedes device writes and
    # descriptor publication. Each run starts from a fresh reset image.
    cases = [
        ('empty', {'capacity':0},3), ('oversized',{'capacity':257},4),
        ('one',{'capacity':1},5), ('non-power',{'capacity':3},5),
        ('unaligned',{'offset':1},5), ('budget-short',{'budget':7},5),
        ('budget-zero',{'budget':0},5), ('budget-large',{'budget':65536},5),
        ('baud-zero',{'rate':0},2), ('baud-other',{'rate':9600},2),
        ('faulted',{},1), ('busy',{},1)]
    for name, values, outcome in cases:
        m, model = machine(run, elf, symbols, 'config-' + name, poll=[symbols['command']])
        with m:
            m.settle()
            for key, value in values.items():
                m.write_u32(symbols[key], value)
            if name == 'faulted':
                model.inject_error()
            elif name == 'busy':
                model.write(0x1000, 4, 0x40070200)
                model.write(0x1004, 4, symbols['storage'])
                model.write(0x1008, 4, 8)
                model.write(0x100c, 4, 0xa84e1)
                model.clear_trace()
            m.write_u32(symbols['command'], 1)
            m.settle()
            require(m.u32(symbols['stage']) == 99, name + ': stage')
            require(m.u32(symbols['outcome']) == outcome, name + ': outcome %d'
                    % m.u32(symbols['outcome']))
            require((model.configuration, model.remaining) ==
                    ((0xa84e1, 8) if name == 'busy' else (0, 0)), name + ': ring')
            require(model.gpio0 == 0x3000001f and model.integer_divisor == 0, name + ': untouched')
            require(model.trace == ('r32:100c:20000000' if name == 'faulted' else
                                    'r32:100c:010a84e1' if name == 'busy' else ''),
                    name + ': trace ' + model.trace)
            require(m.u32(symbols['quiet']) == 0, name + ': quiet')
    return len(cases)


def capacity_boundaries(run, elf, s):
    for capacity, payload, image in ((2,[0,255],0xa8461),(256,[7]*256,0xa8621)):
        m, model = machine(run, elf, s, 'capacity-%d' % capacity, poll=[s['command']])
        with m:
            m.settle()
            m.write_u32(s['capacity'], capacity)
            m.write_u32(s['budget'], capacity)
            m.write_u32(s['command'], 1)
            m.settle()
            require(m.u32(s['stage']) == 2, 'capacity %d: open' % capacity)
            require(model.configuration == image and model.remaining == capacity,
                    'capacity %d: ring' % capacity)
            for value in payload:
                model.feed(value)
            m.write_u32(s['command'], 2)
            m.settle()
            require(m.u32(s['stage']) == 3, 'capacity %d: read' % capacity)
            require(m.u32(s['result']) == capacity and m.u32(s['outcome']) == 0,
                    'capacity %d: result' % capacity)
            require(list(m.read(s['destination'], capacity)) == payload,
                    'capacity %d: data' % capacity)
            require(model.remaining == 0 and not model.busy, 'capacity %d: drained' % capacity)
            require(m.u32(s['quiet']) == 1, 'capacity %d: quiet' % capacity)
    return 2


def execute_suite(parent,refine,profiles=PROFILES,cases=None):
    refine=refine.resolve()
    root=parent.out/'driver';root.mkdir()
    controls=[]
    compiler_hash=sha(refine)
    parent.command('driver-refine-identity',[refine,'--identify'])
    parent.command('driver-source-refusals',[sys.executable,SOURCE/'check_sources.py',
        '--refine',refine,'--output',root/'source-refusals'])
    def one(item):
        optimize,specialize,name=item
        out=root/(optimize+'-'+specialize)/name;out.mkdir(parents=True)
        run=Run(out,parent.tools)
        elf,symbols=build(run,refine,name,optimize,specialize)
        if name == 'layout':
            layout_cpu(run,elf,symbols)
        else:
            cpu(run,elf,symbols,name)
            (application if name == "app" else protocol)(run,elf,symbols)
        config_count=0
        if name == 'protocol':
            config_count=configurations(run,elf,symbols)+capacity_boundaries(run,elf,symbols)
        fresh=out/'fresh';fresh.mkdir()
        build(Run(fresh,parent.tools),refine,name,optimize,specialize)
        for suffix in ('','.s','.o','.ld','.map'):
            require((out/('core.elf'+suffix)).read_bytes() ==
                    (fresh/('core.elf'+suffix)).read_bytes(),
                    'nondeterministic driver artifact '+suffix)
        return {'profile':optimize+'-'+specialize,'kind':name,'status':'passed',
                'qemu_sessions':1,'device_runs':(0 if name == 'layout' else 1+config_count),'artifact_comparisons':5}
    work=[(o,s,n) for o,s in profiles for n in (cases or ['app','protocol','layout'])]
    #  Each profile and case builds in its own directory against its own
    #  emulators; results report in the sequential order.
    with ThreadPoolExecutor(max_workers=workers()) as pool:
        for control in pool.map(one,work):
            controls.append(control)
            print('driver: '+control['profile']+'/'+control['kind']+' passed',flush=True)
    require(sha(refine)==compiler_hash,'driver compiler drift')
    record={'status':'passed','compiler_sha256':compiler_hash,'controls':controls,
            'artifacts':{str(p.relative_to(root)):sha(p) for p in sorted(root.rglob('*')) if p.is_file()}}
    (root/'result.json').write_text(json.dumps(record,indent=2)+'\n')
    return record


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--refine',type=Path,required=True)
    p.add_argument('--output',type=Path,required=True)
    p.add_argument('--tools',type=Path,default=DEFAULT)
    p.add_argument('--all-profiles',action='store_true')
    p.add_argument('--case',action='append')
    p.add_argument('--profile', choices=[o+'-'+s for o,s in PROFILES])
    a=p.parse_args();supported_host();before=inventory(a.tools)
    require(a.case is None or set(a.case) <= {'app','protocol','layout'},'unknown driver case')
    a.output.mkdir(parents=True,exist_ok=False)
    record={'status':'failed','tools':before,'scope':'development; not acceptance'}
    try:
        record['driver']=execute_suite(Run(a.output.resolve(),a.tools.resolve()),
            a.refine.resolve(),([tuple(a.profile.split('-'))] if a.profile else PROFILES if a.all_profiles else PROFILES[:1]),a.case)
        require(inventory(a.tools)==before,'embedded tool drift');record['status']='passed'
    finally:
        record['files']={str(p.relative_to(a.output)):sha(p) for p in sorted(a.output.rglob('*')) if p.is_file()}
        (a.output/'result.json').write_text(json.dumps(record,indent=2)+'\n')

if __name__=='__main__': main()
