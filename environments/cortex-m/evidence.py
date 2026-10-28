"""Mandatory freestanding source-debugging and constrained firmware evidence."""
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import shutil
import struct

import driver
import firmware
import freestanding
from packed_native import PROFILES
from run import Run, require, workers
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
        return verify(executable,symbols,source_table,asm,elf.parent,
                      elf.parent/'source')
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
        'symbol-file '+str(elf), *source_debug.search(elf), *source_debug.PRELUDE,
        'break source/app/main.ldn:61','continue','python',
        'frame("start","source/app/main.ldn",61)',
        'print("R6100_SEPARATE_SYMBOLS_PASS")','end'],'R6100_SEPARATE_SYMBOLS_PASS')
    (run.out/'selection-controls.json').write_text(json.dumps(dict(
        refused=passed,matching_separate_symbols='passed'),indent=2)+'\n')


def child(parent, name):
    path=parent.out/name
    path.mkdir(parents=True)
    return Run(path,parent.tools)


def sized_symbols(listing):
    """Each sized symbol's address and size, from `nm -S`."""
    return {f[3]:(int(f[0],16),int(f[1],16)) for line in listing.splitlines()
            if len(f:=line.split())==4}


def accounting(elf, symbols, buffers=None):
    """The image's occupied extents, its startup regions, and, when
    `buffers` names them with their `nm -S` extents, where each of those
    static buffers lies: a fibre's backing is static RAM, counted once."""
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
    if buffers is not None:
        identified={}
        for name,(address,size) in buffers.items():
            region=next((k for k,c in components.items()
                         if c['address']<=address and address+size<=c['address']+c['size']),None)
            require(region is not None and address+size<=0x20000000+totals['static_ram_extent'],
                    'buffer outside static RAM: '+name)
            identified[name]=dict(address=address,size=size,region=region)
        totals['buffers']=identified
    return totals


#  The roadmap's retained profile: 32 KiB flash, 16 KiB RAM of which the main
#  stack reserves 4 KiB, and D461's one exception frame in a fibre's stack.
PROFILE=dict(flash=32768,ram=16384,main_stack=4096,exception_frame=36)
#  core/fibre's group (fibre.ldn): its alignment, and the ledger and each
#  record it keeps at the front of its backing and the base of each stack.
GROUP_ALIGNMENT,GROUP_LEDGER,GROUP_RECORD=16,32,32
FIBRES=('taker','answerer')


def fibre_capacity(run, refine, optimize, specialize):
    """Measure the stack-switch consumer (D470) on the retained profile.

    probes/fibre-capacity.ldn admits a taker and an answerer to a group
    over core/fibre's round of turns, both on stacks cut from one fixed
    module buffer.  Its flash and static RAM come from the linked image,
    the buffer's extent from its symbol, each fibre's stack from the
    group's own cut, which the records' saved stack pointers confirm, and
    each fibre's
    peak from paint: the main stack below the reset pointer and the whole
    buffer are painted at `start`, before the group cuts it, and read when
    the firmware returns.  Paint is the deepest observed write, not a
    bound (D447); a fibre fits when its peak and D461's exception frame
    lie within its stack, above its record.
    """
    program=(driver.HERE/'probes/fibre-capacity.ldn').read_text()
    elf=freestanding.build(run,refine,program,optimize,specialize)
    listing=run.command('symbol-extents',[run.bin/'arm-none-eabi-nm','-S','-n',elf])
    sized=sized_symbols(listing)
    symbols={f[2]:int(f[0],16) for line in listing.splitlines()
             if len(f:=line.split())>=3}
    buffers={name:sized[name] for name in ('fibre_backing','round_entries','round_state')}
    totals=accounting(elf,symbols,buffers)
    backing,length=buffers['fibre_backing']
    skip=(GROUP_ALIGNMENT-backing%GROUP_ALIGNMENT)%GROUP_ALIGNMENT
    front=backing+skip
    stack=(length-skip-GROUP_LEDGER)//len(FIBRES)
    stack-=stack%GROUP_ALIGNMENT
    records=[front+GROUP_LEDGER+i*stack for i in range(len(FIBRES))]
    report_path=run.out/'paint.json'
    firmware.execute(run,elf,[
        'break *start','continue','delete breakpoints','python',
        'import json',
        'mem=gdb.selected_inferior()',
        'assert v("$sp") == 0x20004000 and v("$control") & 2 == 0',
        'mem.write_memory(0x20003000, bytes([0xa5])*(v("$sp")-0x20003000))',
        'mem.write_memory(%d, bytes([0xa5])*%d)' % (backing,length),
        'end','break _landin_firmware_returned','continue','python',
        'assert v("*(unsigned*)&observed") == 42, "the consumer did not answer every request"',
        'assert v("*(unsigned*)&ticks") >= 6, "the taker did not wait for ticks"',
        'assert v("$sp") == 0x20004000 and v("$control") & 2 == 0',
        'main=bytes(mem.read_memory(0x20003000, 4096))',
        'back=bytes(mem.read_memory(%d, %d))' % (backing,length),
        'words=[[v("*(unsigned*)%%d" %% (r+4*i)) for i in range(2)] for r in %r]' % (records,),
        'json.dump({"main": main.hex(), "backing": back.hex(), "records": words},'
        ' open(%r, "w"))' % str(report_path),
        'print("R1420_FIBRE_CAPACITY_PASS")','end'],'R1420_FIBRE_CAPACITY_PASS')
    paint=json.loads(report_path.read_text())
    main=bytes.fromhex(paint['main'])
    back=bytes.fromhex(paint['backing'])
    main_peak=4096-next((i for i,b in enumerate(main) if b!=0xa5),4096)
    fibres=[]
    for index,(name,record) in enumerate(zip(FIBRES,records)):
        saved,status=paint['records'][index]
        #  D473: the record keeps where its stack pointer was saved, last
        #  as the task ended into the round, which lies in its own stack
        #  above the record: the cut is the group's.
        require(record+GROUP_RECORD<saved<record+stack and status & 255 == 0,
                'fibre %s: its record is not where the cut puts it' % name)
        low,high=record+GROUP_RECORD-backing,record+stack-backing
        first=next((i for i,b in enumerate(back[low:high]) if b!=0xa5),high-low)
        peak=(high-low)-first
        require(peak>0,'fibre %s: nothing was written to its stack' % name)
        fibres.append(dict(name=name,record=record,backing_bytes=stack,
            record_bytes=GROUP_RECORD,stack_bytes=stack-GROUP_RECORD,
            painted_peak_bytes=peak,
            peak_with_exception_frame=peak+PROFILE['exception_frame'],
            headroom_bytes=stack-GROUP_RECORD-peak-PROFILE['exception_frame'],
            fits=peak+PROFILE['exception_frame']<=stack-GROUP_RECORD))
    flash,static=totals['flash_load_extent'],totals['static_ram_extent']
    reserved=static+PROFILE['main_stack']
    fit=dict(flash=flash<=PROFILE['flash'],ram=reserved<=PROFILE['ram'],
             fibres=all(f['fits'] for f in fibres),
             main_stack=main_peak<=PROFILE['main_stack'])
    report=dict(profile=optimize+'-'+specialize,device=PROFILE,
        flash_bytes=flash,static_ram_bytes=static,
        static_ram_buffers=totals['buffers'],
        fibre_buffer=dict(address=backing,bytes=length,alignment_skip=skip,
                          ledger_bytes=GROUP_LEDGER),
        main_stack_reservation_bytes=PROFILE['main_stack'],
        main_stack_painted_peak_bytes=main_peak,
        fibres=fibres,
        peak_simultaneous_backing_bytes=stack*len(FIBRES),
        total_reserved_ram_bytes=reserved,
        counted_once='each fibre backing lies inside static RAM, in fibre_backing,'
                     ' and is not added to it again',
        fit=fit,verdict='fits' if all(fit.values()) else 'does not fit')
    (run.out/'capacity.json').write_text(json.dumps(report,indent=2)+'\n')
    (run.out/'capacity.txt').write_text(capacity_text(report))
    return report


def capacity_text(report):
    p=report['device']
    lines=['Stack-switch consumer (D470) on Cortex-M0, %s' % report['profile'],
        'flash                 %6d of %d' % (report['flash_bytes'],p['flash']),
        'static RAM            %6d' % report['static_ram_bytes']]
    for name,b in sorted(report['static_ram_buffers'].items()):
        lines.append('  %-19s %6d at %#x (.%s)' % (name,b['size'],b['address'],b['region']))
    lines.append('main-stack reservation %5d, painted peak %d' % (
        report['main_stack_reservation_bytes'],report['main_stack_painted_peak_bytes']))
    for f in report['fibres']:
        lines.append('fibre %-9s backing %d (record %d, stack %d), painted peak %d,'
                     ' with the %d-byte exception frame %d, headroom %d' % (
            f['name'],f['backing_bytes'],f['record_bytes'],f['stack_bytes'],
            f['painted_peak_bytes'],p['exception_frame'],
            f['peak_with_exception_frame'],f['headroom_bytes']))
    lines += ['peak simultaneous backing %d' % report['peak_simultaneous_backing_bytes'],
        'total reserved RAM    %6d of %d (static RAM, fibre backing within it,'
        ' plus the main stack)' % (report['total_reserved_ram_bytes'],p['ram']),
        'verdict: '+report['verdict']+' '+json.dumps(report['fit'],sort_keys=True)]
    return '\n'.join(lines)+'\n'


def execute_suite(parent, refine, profiles=PROFILES):
    refine=refine.resolve()
    root=child(parent,'evidence')
    compiler_hash=sha(refine)
    rows=[]
    parent.command('evidence-refine-identity',[refine,'--identify'])
    import stack_control
    stack_control.run(child(root,'independent-stack'))
    def program(item):
        optimize,specialize,name=item
        profile=optimize+'-'+specialize
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
            source_debug.application(child(run,'relayed-source'),elf)
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
        return dict(profile=profile,program=name,status='passed')

    def control(item):
        optimize,specialize,kind=item
        profile=optimize+'-'+specialize
        run=child(root,profile+'/controls/'+kind)
        if kind=='switch':
            source_debug.switch(run,refine,optimize,specialize)
            return dict(profile=profile,control=kind,status='passed')
        if kind=='capacity':
            report=fibre_capacity(run,refine,optimize,specialize)
            #  D470's consumer fits the retained profile; a change that
            #  no longer lets it fails here, with the report beside it.
            require(report['verdict']=='fits','the stack-switch consumer no longer'
                    ' fits the 32 KiB flash, 16 KiB RAM profile at '+profile+': see '
                    +str(run.out/'capacity.txt'))
            return dict(profile=profile,control=kind,status='passed',capacity=report)
        if kind in ('veneer','irq','machine','leaf'):
            elf=firmware.build(run,refine,(driver.HERE/('probes/firmware-'+kind+'.ldn')).read_text(),
                               optimize,specialize,'lines')
            if kind=='leaf':
                source_debug.leaf(run,elf)
            elif kind=='veneer':
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
        return dict(profile=profile,control=kind,status='passed')

    #  Every profile's programs and controls build in their own directories
    #  against their own emulators; rows report in the sequential order.
    work=[]
    for optimize,specialize in profiles:
        work+=[(program,(optimize,specialize,n)) for n in ('app','protocol','layout')]
        work+=[(control,(optimize,specialize,k)) for k in
               ('pool','vec','cpu','noreturn','panic','veneer','irq','machine','leaf',
                'switch','capacity')]
    with ThreadPoolExecutor(max_workers=workers()) as pool:
        for row in pool.map(lambda job: job[0](job[1]),work):
            rows.append(row)
            if 'program' in row:
                print('evidence: '+row['profile']+'/'+row['program']+' passed',flush=True)
    require(sha(refine)==compiler_hash,'evidence compiler drift')
    #  D470's capacity report, every profile's, retained beside the rows.
    capacity=[row.pop('capacity') for row in rows if 'capacity' in row]
    (root.out/'capacity.json').write_text(json.dumps(capacity,indent=2)+'\n')
    (root.out/'capacity.txt').write_text(''.join(capacity_text(r)+'\n' for r in capacity))
    record=dict(status='passed',compiler_sha256=compiler_hash,rows=rows,
        artifacts={str(p.relative_to(root.out)):sha(p)
                   for p in sorted(root.out.rglob('*')) if p.is_file()})
    (root.out/'result.json').write_text(json.dumps(record,indent=2)+'\n')
    return record
