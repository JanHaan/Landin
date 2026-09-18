"""Mandatory R6.100 source-debugging and constrained firmware evidence."""
import json
from pathlib import Path
import shutil
import struct

import driver
import firmware
import freestanding
from packed_native import PROFILES
from run import Run, require
from setup import sha
import source_debug
from cortex_debug import Image, verify
import resources


def selection_controls(run, elf):
    """Mismatches must fail before debugger selection, including equal code
    paired with stale source metadata. No intentional-forgery claim follows.
    """
    table, assembly = Path(str(elf)+'.sources.json'), Path(str(elf)+'.s')
    def check(executable=elf, symbols=elf, source_table=table, asm=assembly):
        return verify(executable,symbols,source_table,asm,elf.parent)
    passed = []
    def refuses(name, **kwargs):
        try:
            check(**kwargs)
        except (ValueError, OSError):
            passed.append(name)
        else:
            raise RuntimeError('debug selector accepted '+name)
    stripped=run.out/'stripped.elf'
    run.command('strip-debug',[run.bin/'arm-none-eabi-objcopy','--strip-debug',elf,stripped])
    check(executable=stripped)
    refuses('missing-debug',symbols=stripped)
    bad=run.out/'mismatched.elf'
    data=bytearray(elf.read_bytes())
    header=struct.unpack_from('<16sHHIIIIIHHHHHH',data)
    # Change an actual flash load byte, retaining valid ELF and debug identity.
    first=struct.unpack_from('<8I',data,header[5])
    data[first[1]+100] ^= 1
    bad.write_bytes(data)
    refuses('mismatched-load-image',executable=bad)
    stale_id=run.out/'stale-identity.elf'
    data=bytearray(elf.read_bytes())
    identity=Image(elf).sections['.landin_id']['payload']
    at=data.index(identity)
    data[at]=ord('1') if data[at]==ord('0') else ord('0')
    stale_id.write_bytes(data)
    refuses('same-code-mismatched-identity',executable=stale_id)
    anonymous=run.out/'missing-identity.elf'
    run.command('remove-identity',[run.bin/'arm-none-eabi-objcopy',
        '--remove-section=.landin_id',elf,anonymous])
    refuses('missing-executable-identity',executable=anonymous)
    altered=run.out/'stale.sources.json'
    mapping=json.loads(table.read_text())
    mapping['build_id']='0'*64
    altered.write_text(json.dumps(mapping))
    refuses('mismatched-source-table',source_table=altered)
    altered_asm=run.out/'stale.s'
    altered_asm.write_bytes(assembly.read_bytes()+b'\n')
    refuses('mismatched-assembly',asm=altered_asm)
    first_source=elf.parent/Path(bytes.fromhex(mapping['files'][0]['path_hex']).decode())
    original=first_source.read_bytes()
    try:
        first_source.write_bytes(original+b'\n-- stale snapshot\n')
        refuses('stale-source')
    finally:
        first_source.write_bytes(original)
    check()
    # Execute a stripped image with the separately verified symbol ELF.
    firmware.execute(run,stripped,[
        'symbol-file '+str(elf), 'directory '+str(elf.parent), *source_debug.PRELUDE,
        'break source/app/main.ldn:61','continue','python',
        'frame("start","source/app/main.ldn",61)',
        'print("R6100_SEPARATE_SYMBOLS_PASS")','end'],'R6100_SEPARATE_SYMBOLS_PASS')
    (run.out/'selection-controls.json').write_text(json.dumps(dict(
        refused=passed,matching_separate_symbols='passed'),indent=2)+'\n')


def child(parent, name):
    path=parent.out/name
    path.mkdir(parents=True)
    return Run(path,parent.tools)


def accounting(elf, symbols):
    image=Image(elf)
    totals=image.resources()
    def symbol(suffix): return symbols['_landin_firmware_'+suffix]
    require(symbol('stack_top')==0x20004000 and symbol('stack_bottom')==0x20003000,
            'stack reservation symbols changed')
    require(max(symbol(k+'_end') for k in ('data','ramtext','bss'))-0x20000000
            == totals['static_ram_extent'],'RAM symbols disagree with ELF headers')
    ends=[s['address']+s['size'] for s in image.sections.values()
          if s['flags'] & 2 and s['kind'] != 8 and s['size'] and s['address']<32768]
    components={}
    for kind in ('data','ramtext','bss'):
        size=symbol(kind+'_end')-symbol(kind+'_start')
        components[kind]=dict(address=symbol(kind+'_start'),size=size)
        if kind!='bss':
            components[kind]['load']=symbol(kind+'_load')
            if size: ends.append(symbol(kind+'_load')+size)
        if size:
            section=image.sections['.'+kind]
            require(section['address']==symbol(kind+'_start') and section['size']==size,
                    'section and linker symbols disagree: '+kind)
    require(max(ends)==totals['flash_load_extent'],'flash sections/symbols disagree with LOAD extent')
    totals['startup_regions']=components
    totals['allocated_sections']={n:s['size'] for n,s in image.sections.items() if s['flags'] & 2}
    return totals


def execute_suite(parent, refine, profiles=PROFILES):
    refine=refine.resolve()
    root=child(parent,'evidence')
    compiler_hash=sha(refine)
    rows=[]
    parent.command('evidence-refine-identity',[refine,'--identify'])
    import stack_control
    stack_control.run(child(root,'independent-stack'))
    for optimize,specialize in profiles:
        profile=optimize+'-'+specialize
        for name in ('app','protocol','layout'):
            run=child(root,profile+'/'+name)
            elf,symbols=driver.build(run,refine,name,optimize,specialize,'lines')
            baseline=parent.out/'driver'/profile/name/'core.elf'
            require(Image(elf).loaded_identity() == Image(baseline).loaded_identity(),
                    'debugging altered firmware load or initialization: '+profile+'/'+name)
            record=source_debug.checked(run,elf)
            record['resources']=accounting(elf,symbols)
            run.command('symbol-extents',[run.bin/'arm-none-eabi-nm','-S','--size-sort',elf])
            run.command('debug-records',[run.bin/'arm-none-eabi-readelf',
                        '--debug-dump=info,decodedline,frames',elf])
            record.update(profile=profile,program=name,
                baseline_sha256=sha(baseline),load_identity='identical',
                closure=json.loads((run.out/'closure.json').read_text()),
                build=json.loads((run.out/'build.json').read_text()))
            if name=='app':
                driver.cpu(child(run,'qemu-boot'),elf,symbols,name)
                source_debug.cpu(child(run,'qemu-source'),elf)
                source_debug.application(child(run,'renode-source'),elf)
                selection_controls(child(run,'selection'),elf)
                record['scenarios']={}
                for scenario in ('receive','open-failure','transfer-fault','exhaustion'):
                    lane=child(run,scenario)
                    shutil.copy(run.out/'disassembly.log',lane.out)
                    record['scenarios'][scenario]=resources.application(lane,elf,symbols,scenario)
            elif name=='protocol':
                driver.cpu(run,elf,symbols,name)
                driver.protocol(run,elf,symbols)
            else:
                driver.layout_cpu(run,elf,symbols)
                lane=child(run,'helper-resources')
                shutil.copy(run.out/'disassembly.log',lane.out)
                record['helper_resources']=resources.terminated(lane,elf,
                    {'layout':[4,24,4,48,8,12,16,20,21,22,23]})
            fresh=child(run,'first-emission')
            # The debug CU intentionally records its compilation directory.
            # Repeat in that same directory; relocated builds retain distinct
            # source identities, while their target load bytes must agree.
            for suffix in ('','.s','.o','.ld','.map','.sources.json'):
                shutil.copy(Path(str(elf)+suffix),fresh.out)
            run.command('compile-again',run.commands[0]['argv'],timeout=60)
            for suffix in ('','.s','.o','.ld','.map','.sources.json'):
                require(Path(str(elf)+suffix).read_bytes() ==
                        (fresh.out/('core.elf'+suffix)).read_bytes(),
                        'nondeterministic debug firmware '+profile+'/'+name+suffix)
            (run.out/'evidence.json').write_text(json.dumps(record,indent=2)+'\n')
            rows.append(dict(profile=profile,program=name,status='passed'))
            print('evidence: '+profile+'/'+name+' passed',flush=True)
        for kind in ('pool','vec','noreturn','panic','veneer','irq','machine'):
            run=child(root,profile+'/controls/'+kind)
            if kind in ('veneer','irq','machine'):
                elf=firmware.build(run,refine,(driver.HERE/('probes/firmware-'+kind+'.ldn')).read_text(),
                                   optimize,specialize,'lines')
                if kind=='veneer':
                    source_debug.veneer(run,elf)
                    lane=child(run,'resources')
                    shutil.copy(run.out/'disassembly.log',lane.out)
                    resources.terminated(lane,elf,{'observed':[42],'irq_seen':[1]})
                else:
                    source_debug.interrupt(run,elf,kind=='machine')
            else:
                elf=freestanding.build(run,refine,
                    (driver.HERE/('probes/core-'+kind+'.ldn')).read_text(),
                    optimize,specialize,'lines')
                source_debug.library(run,elf,kind)
            rows.append(dict(profile=profile,control=kind,status='passed'))
    require(sha(refine)==compiler_hash,'evidence compiler drift')
    record=dict(status='passed',compiler_sha256=compiler_hash,rows=rows,
        artifacts={str(p.relative_to(root.out)):sha(p)
                   for p in sorted(root.out.rglob('*')) if p.is_file()})
    (root.out/'result.json').write_text(json.dumps(record,indent=2)+'\n')
    return record
