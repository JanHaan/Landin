#!/usr/bin/env python3
"""R6.90 complete driver CPU/application/protocol execution, independent oracles."""
import argparse
import json
from pathlib import Path
import shutil
import struct
import sys
from backend import image_contract
from devices import linker_closure
from firmware import execute
from packed_native import PROFILES
from run import Run, require
from setup import DEFAULT, inventory, sha, supported_host

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
SOURCE = ROOT / 'compiler/tests/driver'
MODULES = ('drivers/uart', 'rp2040/io_bank0', 'rp2040/uart0', 'rp2040/dma',
           'rp2040/sio', 'rp2040/timer', 'core/cpu')


def build(run, refine, name, optimize, specialize):
    source = run.out / 'source'
    source.mkdir()
    shutil.copytree(SOURCE / name, source / 'app')
    for module in MODULES:
        origin = (SOURCE if module.startswith('drivers/') else
                  ROOT / 'devices/generated' if module.startswith('rp2040/') else ROOT)
        shutil.copytree(origin / module, source / module)
    elf = run.out / 'core.elf'
    run.command('compile', [refine, '--root=source', '--target=cortex-m0',
        '--firmware-entry=start', '--emit=exe',
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


def application(run,elf,s):
    def check(name,body):
        p=run.out/(name+'.py')
        p.write_text('bus=monitor.Machine.SystemBus\nmodel=monitor.Machine["sysbus.model"]\n'+body+'\n')
        return 'include @'+str(p)
    boot=check('boot', '''for address in range(0x20003000,0x20004000): bus.WriteByte(address,165)
''')
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
    ready=check('ready',f'''assert bus.ReadDoubleWord({s['app_state']}) == 2
assert model.IntegerDivisor == 26 and model.FractionDivisor == 3
assert model.LineControl == 112 and model.DMAControl == 1
assert model.GPIO0 == 0x30000002 and model.GPIO1 == 0x30000002
assert model.Remaining == 65535 and model.Busy
assert model.Alarm == 1000
assert bus.ReadDoubleWord({s['initialized']}) == 0x690
assert bus.ReadDoubleWord({s['cleared']}) == 0
''')
    early=check('early',f'''assert not model.AlarmPending
assert bus.ReadDoubleWord({s['handled']}) == 0
''')
    done=check('done',f'''assert bus.ReadDoubleWord({s['handled']}) == 3
assert bus.ReadDoubleWord({s['recoveries']}) == 0
assert str(model.OutputBytes) == "49,65,48"
assert model.Output == 0 and model.Remaining == 65532
assert bus.ReadDoubleWord({s['app_state']}) == 2
assert str(model.Trace) == {trace!r}
paint=[bus.ReadByte(a) for a in range(0x20003000,0x20004000)]
assert paint[:256] == [165]*256
print("R690_STACK_OBSERVED "+str(4096-next(i for i,b in enumerate(paint) if b != 165)))
print("R690_APP_TRACE "+str(model.Trace))
print("R690_APP_INITIAL_PASS")
''')
    recovered=check('recovered',f'''assert bus.ReadDoubleWord({s['recoveries']}) == 1
assert bus.ReadDoubleWord({s['handled']}) == 3
assert bus.ReadDoubleWord({s['app_state']}) == 2
assert model.Remaining == 65535 and model.Transfers == 0 and model.Busy
assert str(model.OutputBytes) == "49,65,48"
''')
    terminal=check('terminal',f'''assert bus.ReadDoubleWord({s['handled']}) == 3
assert bus.ReadDoubleWord({s['recoveries']}) == 1
assert bus.ReadDoubleWord({s['app_state']}) == 3
assert model.Busy and model.Remaining == 65534
assert str(model.OutputBytes) == "49,65,48"
paint=[bus.ReadByte(a) for a in range(0x20003000,0x20004000)]
assert paint[:256] == [165]*256
print("R690_STACK_FINAL "+str(4096-next(i for i,b in enumerate(paint) if b != 165)))
print("R690_APP_PASS")
''')
    overflow=check('overflow','for i in range(300): model.Feed(70)')
    run.renode_script('application',[
        f'include @{HERE}/probes/DriverPeripheral.cs','mach create "derived-driver"',
        f'machine LoadPlatformDescription @{HERE}/probes/driver.repl',
        f'sysbus LoadELF @{elf}',boot,'emulation RunFor "0.01"',ready,
        'sysbus.model Feed 49','sysbus.model Feed 65','sysbus.model Feed 48',
        'sysbus.model Tick 999',early,'sysbus.model Tick 1','emulation RunFor "0.01"',done,overflow,
        'emulation RunFor "0.01"',recovered,'sysbus.model DelayStop 20 -1',
        'sysbus.model Feed 65','sysbus.model Tick 1000',
        'emulation RunFor "0.01"',terminal],'R690_APP_PASS')


def protocol(run,elf,s):
    commands=[f'include @{HERE}/probes/DriverPeripheral.cs',
        'mach create "driver-protocol"',
        f'machine LoadPlatformDescription @{HERE}/probes/driver.repl',
        f'sysbus LoadELF @{elf}','emulation RunFor "0.01"']
    serial=0
    def check(body):
        nonlocal serial
        serial+=1
        p=run.out/('check-%03d.py'%serial)
        p.write_text('bus=monitor.Machine.SystemBus\nmodel=monitor.Machine["sysbus.model"]\n'+body+'\n')
        commands.append('include @'+str(p))
    def feed(values):
        check('for value in '+repr(values)+': model.Feed(value)')
        commands.append('emulation RunFor "0.01"')
    stage=2
    def op(code,result=0,outcome=0,data=None,extra='',trace=None):
        nonlocal stage
        check('model.ClearTrace()\nbus.WriteDoubleWord(%d,%d)'%(s['command'],code))
        commands.append('emulation RunFor "0.01"');stage+=1
        body=f'''assert bus.ReadDoubleWord({s['stage']}) == {stage}
assert bus.ReadDoubleWord({s['command']}) == 0
assert bus.ReadDoubleWord({s['result']}) == {result}
assert bus.ReadDoubleWord({s['outcome']}) == {outcome}
'''
        if data is not None:
            body+='assert [bus.ReadByte(%d+i) for i in range(%d)] == %r\n'%(s['destination'],len(data),data)
        if trace is not None: body+='assert str(model.Trace) == '+repr(trace)+'\n'
        body+=extra+'\nprint("R690_STEP_%d "+str(model.Trace))'%stage
        check(body)
    def stable(remaining,resume=True):
        return ('w32:100c:000a84e0;r32:100c:000a84e0;'
                'r32:100c:000a84e0;r32:1008:%08x'%remaining+
                (';w32:100c:000a84e1' if resume else ''))
    check(f'assert bus.ReadDoubleWord({s["stage"]}) == 1\nbus.WriteDoubleWord({s["command"]},1)')
    commands.append('emulation RunFor "0.01"')
    check(f'''assert bus.ReadDoubleWord({s['stage']}) == 2
assert model.Remaining == 32 and model.Configuration == 0xa84e1
assert model.IntegerDivisor == 26 and model.FractionDivisor == 3
''')
    op(1,trace=stable(32))
    feed([10,11,12])
    check(f'assert bus.ReadDoubleWord({s["events"]}) == 0\nbus.WriteDoubleWord({s["limit"]},2)')
    op(2,2,data=[10,11],trace=stable(29))
    op(2,1,data=[12],trace=stable(29))
    op(2,0,trace=stable(29))
    feed([20,21,22,23,24,25,26,27])
    check(f'assert bus.ReadDoubleWord({s["events"]}) == 1')
    op(1,8,trace=stable(21))
    check(f'bus.WriteDoubleWord({s["limit"]},3)')
    op(2,3,data=[20,21,22],trace=stable(21))
    check(f'bus.WriteDoubleWord({s["limit"]},256)')
    op(2,5,data=[23,24,25,26,27],trace=stable(21))
    op(2,0,trace=stable(21))
    op(5,trace='')
    check(f'before=bus.ReadDoubleWord({s["events"]})\nmodel.ClearTrace()')
    feed(list(range(30,47)))
    check(f'''assert bus.ReadDoubleWord({s['events']}) == before
assert model.Remaining == 4 and model.Transfers == 28 and model.Pending == 1
assert [bus.ReadByte({s['storage']}+i) for i in range(8)] == [43,44,45,46,39,40,41,42]
''')
    op(6,extra=f'assert bus.ReadDoubleWord({s["events"]}) == before+1',
       trace='r32:1400:00000001;w32:1400:00000001')
    op(2,outcome=6,data=[23,24,25,26,27],trace=stable(4,False),
       extra=f'assert bus.ReadDoubleWord({s["quiet"]}) == 1\nassert bus.ReadDoubleWord({s["consumed"]}) == 28')
    op(2,outcome=6,trace=stable(4,False))
    op(4,extra='assert model.Remaining == 32 and model.Busy')
    feed([50,51,52,53,54])
    check('model.DelayStop(2,99)')
    op(2,6,data=[50,51,52,53,54,99],extra='assert model.Remaining == 26')
    check('model.DelayStop(0,-1)')
    op(3,extra=f'assert bus.ReadDoubleWord({s["quiet"]}) == 1 and not model.Busy',
       trace='w32:100c:000a84e0;r32:100c:000a84e0')
    op(7,trace='')
    feed([60])
    check(f'assert model.Rejected == 1\nassert bus.ReadByte({s["storage"]}) == 165')
    op(4)
    op(1,0,trace=stable(32))
    feed([61])
    check(f'bus.WriteDoubleWord({s["limit"]},0)')
    op(2,0,trace=stable(31))
    check(f'bus.WriteDoubleWord({s["limit"]},256)')
    op(2,1,data=[61],trace=stable(31))
    check('model.InjectError()');commands.append('emulation RunFor "0.01"')
    op(2,outcome=7,data=[61],extra='assert not model.Busy')
    op(4,outcome=7,extra='assert model.Remaining == 31')
    check('model.Repair()')
    op(4)
    for values in ([1,2,3,4,5,6,7,8],[9,10,11,12,13,14,15,16],
                   [17,18,19,20,21,22,23,24],[25,26,27,28,29,30,31,32]):
        feed(values)
        op(2,8,data=values)
    op(2,outcome=8,extra='assert model.Remaining == 0 and not model.Busy')
    feed([70]);check('assert model.Rejected == 2')
    op(4)
    feed([80]);check('model.DelayStop(20,-1)')
    op(3,outcome=9,extra=f'assert bus.ReadDoubleWord({s["quiet"]}) == 0 and model.Busy')
    op(2,outcome=9,data=[25,26,27,28,29,30,31,32])
    op(3,extra=f'assert bus.ReadDoubleWord({s["quiet"]}) == 1 and not model.Busy')
    op(7,trace='')
    check(f'''assert bus.ReadByte({s['storage']}) == 165
print("R690_PROTOCOL_PASS")''')
    run.renode_script('protocol',commands,'R690_PROTOCOL_PASS')


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
        configure = run.out/('config-'+name+'.py')
        configure.write_text('bus=monitor.Machine.SystemBus\nmodel=monitor.Machine["sysbus.model"]\n'+
            ''.join('bus.WriteDoubleWord(%d,%d)\n'%(symbols[key],value) for key,value in values.items())+
            ('model.InjectError()\n' if name == 'faulted' else
             'model.WriteDoubleWord(0x1000,0x40070200)\n'
             'model.WriteDoubleWord(0x1004,%d)\n'%symbols['storage']+
             'model.WriteDoubleWord(0x1008,8)\n'
             'model.WriteDoubleWord(0x100c,0xa84e1)\nmodel.ClearTrace()\n'
             if name == 'busy' else '')+
            'bus.WriteDoubleWord(%d,1)\n'%symbols['command'])
        assertion = run.out/('assert-'+name+'.py')
        assertion.write_text('bus=monitor.Machine.SystemBus\nmodel=monitor.Machine["sysbus.model"]\n'+
            'assert bus.ReadDoubleWord(%d) == 99\n'%symbols['stage']+
            'assert bus.ReadDoubleWord(%d) == %d\n'%(symbols['outcome'],outcome)+
            ('assert model.Configuration == 0xa84e1 and model.Remaining == 8\n' if name == 'busy'
             else 'assert model.Configuration == 0 and model.Remaining == 0\n')+
            'assert model.GPIO0 == 0x3000001f and model.IntegerDivisor == 0\n'+
            'assert str(model.Trace) == '+repr('r32:100c:20000000' if name == 'faulted' else
                                            'r32:100c:010a84e1' if name == 'busy' else '')+'\n'+
            'assert bus.ReadDoubleWord(%d) == 0\n'%symbols['quiet']+
            'print("R690_CONFIG_PASS")\n')
        run.renode_script('config-'+name,[f'include @{HERE}/probes/DriverPeripheral.cs',
            'mach create "configuration"',f'machine LoadPlatformDescription @{HERE}/probes/driver.repl',
            f'sysbus LoadELF @{elf}','emulation RunFor "0.01"',f'include @{configure}',
            'emulation RunFor "0.01"',f'include @{assertion}'],'R690_CONFIG_PASS')
    return len(cases)


def capacity_boundaries(run, elf, s):
    for capacity, payload, image in ((2,[0,255],0xa8461),(256,[7]*256,0xa8621)):
        setup=run.out/('boundary-%d.py'%capacity)
        setup.write_text('bus=monitor.Machine.SystemBus\n'+
            'bus.WriteDoubleWord(%d,%d)\n'%(s['capacity'],capacity)+
            'bus.WriteDoubleWord(%d,%d)\n'%(s['budget'],capacity)+
            'bus.WriteDoubleWord(%d,1)\n'%s['command'])
        feed=run.out/('boundary-feed-%d.py'%capacity)
        feed.write_text('bus=monitor.Machine.SystemBus\nmodel=monitor.Machine["sysbus.model"]\n'+
            'assert bus.ReadDoubleWord(%d) == 2\n'%s['stage']+
            'assert model.Configuration == %d and model.Remaining == %d\n'%(image,capacity)+
            'for value in '+repr(payload)+': model.Feed(value)\n'+
            'bus.WriteDoubleWord(%d,2)\n'%s['command'])
        done=run.out/('boundary-done-%d.py'%capacity)
        done.write_text('bus=monitor.Machine.SystemBus\nmodel=monitor.Machine["sysbus.model"]\n'+
            'assert bus.ReadDoubleWord(%d) == 3\n'%s['stage']+
            'assert bus.ReadDoubleWord(%d) == %d\n'%(s['result'],capacity)+
            'assert bus.ReadDoubleWord(%d) == 0\n'%s['outcome']+
            'assert [bus.ReadByte(%d+i) for i in range(%d)] == %r\n'%(s['destination'],capacity,payload)+
            'assert model.Remaining == 0 and not model.Busy\n'+
            'assert bus.ReadDoubleWord(%d) == 1\n'%s['quiet']+
            'print("R690_CAPACITY_PASS")\n')
        run.renode_script('capacity-%d'%capacity,[f'include @{HERE}/probes/DriverPeripheral.cs',
            'mach create "capacity"',f'machine LoadPlatformDescription @{HERE}/probes/driver.repl',
            f'sysbus LoadELF @{elf}','emulation RunFor "0.01"',f'include @{setup}',
            'emulation RunFor "0.01"',f'include @{feed}',
            'emulation RunFor "0.01"',f'include @{done}'],'R690_CAPACITY_PASS')
    return 2


def execute_suite(parent,refine,profiles=PROFILES,cases=None):
    root=parent.out/'driver';root.mkdir()
    controls=[]
    compiler_hash=sha(refine)
    parent.command('driver-refine-identity',[refine,'--identify'])
    parent.command('driver-source-refusals',[sys.executable,SOURCE/'check_sources.py',
        '--refine',refine,'--output',root/'source-refusals'])
    for optimize,specialize in profiles:
        for name in (cases or ['app','protocol','layout']):
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
            controls.append({'profile':optimize+'-'+specialize,'kind':name,'status':'passed',
                             'qemu_sessions':1,'renode_runs':(0 if name == 'layout' else 1+config_count),'artifact_comparisons':5})
            print('driver: '+optimize+'-'+specialize+'/'+name+' passed',flush=True)
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
