"""Off-target SP observations and complete-application resource scenarios.

Paint measures written bytes. Hooks also observe unwritten stack reservations,
at every statically decoded SP change's successor and every function entry.
They read CPU registers and ordinary stack RAM only, never device registers.
"""
import json
import re

from driver import HERE
from run import require


def hook_addresses(disassembly):
    addresses = set()
    instructions = []
    for line in disassembly.splitlines():
        label = re.match(r'^([0-9a-f]+) <[^>]+>:', line)
        if label:
            addresses.add(int(label[1], 16))
        match = re.match(r'^\s*([0-9a-f]+):\s+((?:[0-9a-f]{4}\s+)+)\s*(\S+)\s*(.*)', line)
        if match:
            pc, raw, op, args = match.groups()
            if op.startswith('.'):
                continue
            instructions.append((int(pc,16), len(raw.split())*2, op, args))
    changes = []
    for pc, size, op, args in instructions:
        if op in ('push','pop') or re.match(r'(?:sp|r13)\b', args) or (
                op == 'msr' and args.startswith(('MSP','PSP','msp','psp'))):
            addresses.add(pc+size)
            changes.append(dict(pc=pc, successor=pc+size, opcode=op, operands=args))
    require(changes, 'no independently decoded stack changes')
    return sorted(addresses), changes


def install(run):
    addresses, changes = hook_addresses((run.out/'disassembly.log').read_text())
    (run.out/'stack-hooks.json').write_text(json.dumps(dict(
        addresses=addresses, instructions=changes),indent=2)+'\n')
    script = run.out/'stack-install.py'
    script.write_text('''import json
bus=monitor.Machine.SystemBus
cpu=monitor.Machine["sysbus.cpu"]
model=monitor.Machine["sysbus.model"]
import clr
from System import AppDomain
for assembly in AppDomain.CurrentDomain.GetAssemblies():
    if assembly.GetType("Antmicro.Renode.Peripherals.Miscellaneous.StackObserver"):
        clr.AddReference(assembly)
from Antmicro.Renode.Peripherals.Miscellaneous import StackObserver
tracker=StackObserver(monitor.Machine,cpu)
for slot in range(2,48):
    address=int(bus.ReadDoubleWord(slot*4)) & ~1
    if address: tracker.Handler(address)
for address in '''+repr(addresses)+''': tracker.Add(address)
for address in range(0x20003000,0x20004000): bus.WriteByte(address,165)
snapshots=[]
def snapshot(name):
    observations=json.loads(str(tracker.Record))
    paint=[bus.ReadByte(a) for a in range(0x20003000,0x20004000)]
    assert paint[:256] == [165]*256, "low stack guard changed"
    written=4096-next((i for i,b in enumerate(paint) if b != 165),4096)
    observed=0x20004000-observations["minimum_sp"]
    assert written <= observed, "SP coverage missed a stack write"
    row={"scenario":name,"written_bytes":written,"observed_reserved_bytes":observed,
         "sp":int(cpu.GetRegister(13).RawValue),"observations":json.loads(json.dumps(observations))}
    snapshots.append(row)
    print("R6100_STACK "+json.dumps(row,sort_keys=True))
''')
    return 'include @'+str(script)


def application(run, elf, symbols, scenario):
    """Run the unchanged complete application, with an independent host oracle."""
    def check(name, text):
        path=run.out/('resource-'+name+'.py')
        path.write_text(text+'\n')
        return 'include @'+str(path)
    s=symbols
    commands=[f'include @{HERE}/probes/DriverPeripheral.cs',
        'mach create "application-resources"',
        f'machine LoadPlatformDescription @{HERE}/probes/driver.repl',
        f'sysbus LoadELF @{elf}',
        f'include @{HERE}/probes/StackObserver.cs', install(run)]
    def run_for(): commands.append('emulation RunFor "0.025"')
    def state(name, handled, recoveries=0, status=2, extra=''):
        commands.append(check(name,f'''assert bus.ReadDoubleWord({s['handled']}) == {handled}, ("handled",bus.ReadDoubleWord({s['handled']}),{handled})
assert bus.ReadDoubleWord({s['recoveries']}) == {recoveries}
assert bus.ReadDoubleWord({s['app_state']}) == {status}
{extra}
snapshot({name!r})'''))
    if scenario == 'open-failure':
        commands.append('sysbus.model InjectError')
        run_for()
        state('open-failure',0,status=1)
    else:
        run_for()
        state('cold-boot',0,extra='assert model.Remaining == 65535 and model.Busy')
        if scenario == 'receive':
            commands.append(check('feed-partial','for i in range(200): model.Feed(65+i%26)'))
            run_for()
            state('partial-and-coalesced',200,extra='assert model.Remaining == 65335')
            commands.append(check('feed-wrap','for i in range(128): model.Feed(97+i%26)'))
            run_for()
            state('wrapped',328,extra='''expected=[65+i%26 for i in range(200)]+[97+i%26 for i in range(128)]
assert str(model.OutputBytes) == ",".join(str(x) for x in expected)
assert model.Remaining == 65207''')
            commands += ['sysbus.model DelayStop 3 90','sysbus.model Feed 49',
                         'sysbus.model Tick 1000']
            run_for()
            state('delayed-drain',330,extra='assert str(model.OutputBytes).endswith(",49,90")')
            commands += ['sysbus.model DelayStop 0 -1',
                check('feed-overrun','for i in range(300): model.Feed(70)')]
            run_for()
            state('overrun-recovered',330,1,extra='assert model.Remaining == 65535')
            commands += ['sysbus.model Feed 48','sysbus.model Tick 1000']
            run_for()
            state('echo-after-recovery',331,1,extra='assert str(model.OutputBytes).endswith(",48")')
            commands += ['sysbus.model DelayStop 20 -1','sysbus.model Feed 65',
                         'sysbus.model Tick 1000']
            run_for()
            state('timeout-retains-storage',331,1,3,extra='assert model.Busy')
        elif scenario == 'transfer-fault':
            commands.append('sysbus.model InjectError')
            run_for()
            state('external-repair-required',0,1,3,extra='assert not model.Busy')
        elif scenario == 'exhaustion':
            # Service every 256 bytes, retaining all 65535 monotone production
            # counts. The final short read is echoed before exhaustion fails.
            feed=check('epoch-feed','for i in range(256): model.Feed(65)')
            commands.append(check('epoch-count','epoch_count=0'))
            audit=check('epoch-audit',f'''epoch_count+=1
assert model.Remaining == 65535-epoch_count*256
assert bus.ReadDoubleWord({s['handled']}) == epoch_count*256
model.ClearTrace()''')
            for _ in range(255):
                commands.append(feed)
                run_for()
                commands.append(audit)
            commands.append(check('epoch-final','for i in range(255): model.Feed(66)'))
            run_for()
            state('final-epoch-bytes',65535,extra='assert model.Remaining == 0')
            commands.append('sysbus.model Tick 1000')
            run_for()
            state('finite-epoch-exhaustion',65535,1,extra='''assert model.Remaining == 65535
assert str(model.OutputBytes) == ",".join(["65"]*65280+["66"]*255)''')
        else:
            raise ValueError(scenario)
    path=run.out/('resources-'+scenario+'.json')
    commands.append(check('finish',f'''assert json.loads(str(tracker.Record))["samples"] > 0
with open({str(path)!r},"w") as output: json.dump(snapshots,output,sort_keys=True,indent=2)
print("R6100_APPLICATION_RESOURCES_PASS")'''))
    run.renode_script('resources-'+scenario,commands,'R6100_APPLICATION_RESOURCES_PASS',
                     timeout=180 if scenario == 'exhaustion' else 90)
    require(path.is_file(),'missing SP evidence')
    return json.loads(path.read_text())


def terminated(control, elf, expected):
    """Separate helper/veneer controls, including the default return trap."""
    names=control.command('control-symbols',[control.bin/'arm-none-eabi-nm','-n',elf])
    symbols={s[2]:int(s[0],16) for line in names.splitlines() if len(s:=line.split())==3}
    check=control.out/'control-observations.py'
    body=[]
    for name, values in expected.items():
        for i,value in enumerate(values):
            body.append(f'assert bus.ReadDoubleWord({symbols[name]+i*4}) == {value}')
    path=control.out/'control-resources.json'
    check.write_text('\n'.join(body+[
        'assert int(cpu.GetRegister(25).RawValue) & 511 == 3',
        'snapshot("control-through-terminal-trap")',
        f'with open({str(path)!r},"w") as output: json.dump(snapshots,output,indent=2)',
        'print("R6100_CONTROL_RESOURCES_PASS")','']))
    control.renode_script('control-resources',[
        f'include @{HERE}/probes/DriverPeripheral.cs','mach create "control-resources"',
        f'machine LoadPlatformDescription @{HERE}/probes/driver.repl',
        f'sysbus LoadELF @{elf}',f'include @{HERE}/probes/StackObserver.cs',
        install(control),'emulation RunFor "0.005"','include @'+str(check)],
        'R6100_CONTROL_RESOURCES_PASS')
    return json.loads(path.read_text())
