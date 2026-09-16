"""Native compiler-generated image operations against an actual Renode device.

The C peer is a blocking line transport, with no register masks or oracle.
Renode's outer process-group timeout bounds the peer as well as the model.
This lane runs Linux instructions and is distinct from the M0 C control.
"""
import argparse
import json
from pathlib import Path

from packed import TRACE
from run import Run, require
from setup import DEFAULT, HERE, inventory, sha, supported_host

PROFILES = [('none', 'off'), ('size', 'off'), ('size', 'auto'),
            ('speed', 'auto'), ('none', 'all'), ('speed', 'all')]


def execute(run, refine):
    refine = refine.resolve(strict=True)
    run.command('native-refine-identity', [refine, '--identify'])
    run.command('native-cc-identity', ['gcc', '--version'])
    identities = {'compiler': str(refine), 'compiler_sha256': sha(refine),
                  'source_sha256': sha(HERE / 'probes/packed-native.ldn'),
                  'hole_source_sha256': sha(HERE / 'probes/packed-native-hole.ldn'),
                  'transport_sha256': sha(HERE / 'probes/packed-transport.c'),
                  'execution': 'native Linux x86-64, Renode bus transport',
                  'profiles': PROFILES}
    (run.out / 'packed-native-inputs.json').write_text(
        json.dumps(identities, indent=2, sort_keys=True) + '\n')
    platform = run.out / 'packed-native.repl'
    platform.write_text('model: Miscellaneous.EncodingPeripheral @ sysbus 0x40030000\n')
    for optimization, specialization in PROFILES:
        name = 'packed-native-' + optimization + '-' + specialization
        assembly, executable = run.out / (name + '.s'), run.out / name
        run.command(name + '-compile', [refine, '--target=linux-x86-64',
                    '--optimize=' + optimization, '--specialize=' + specialization,
                    '--emit=asm', '-o', assembly, HERE / 'probes/packed-native.ldn'],
                    timeout=60)
        run.command(name + '-link', ['gcc', '-std=c11', '-Wall', '-Wextra', '-Werror',
                    '-g', '-fno-pie', '-no-pie', assembly,
                    HERE / 'probes/packed-transport.c', '-o', executable])
        checks = run.out / (name + '.py')
        checks.write_text('''import clr
clr.AddReference("System.Diagnostics.Process")
from System.Diagnostics import Process, ProcessStartInfo
bus = monitor.Machine.SystemBus
model = monitor.Machine["sysbus.model"]
info = ProcessStartInfo()
info.FileName = ''' + repr(str(executable)) + '''
info.UseShellExecute = False
info.RedirectStandardInput = True
info.RedirectStandardOutput = True
info.RedirectStandardError = True
peer = Process.Start(info)
commands = []
try:
    for event in range(17):
        line = peer.StandardOutput.ReadLine()
        assert line is not None
        fields = str(line).split()
        commands.append(str(line))
        if fields[0] == "DONE":
            assert event == 16 and fields == ["DONE", "1600"]
            break
        offset = int(fields[1])
        address = 0x40030000 + offset
        if fields[0] == "R32":
            assert len(fields) == 2
            value = bus.ReadDoubleWord(address)
        elif fields[0] == "R16":
            assert len(fields) == 2
            value = bus.ReadWord(address)
        elif fields[0] == "W32":
            assert len(fields) == 3
            bus.WriteDoubleWord(address, int(fields[2]))
            value = 1
        elif fields[0] == "W16":
            assert len(fields) == 3
            bus.WriteWord(address, int(fields[2]))
            value = 1
        else:
            raise AssertionError("unknown transport operation")
        peer.StandardInput.WriteLine(str(value))
        peer.StandardInput.Flush()
    else:
        raise AssertionError("transport event limit")
    assert peer.WaitForExit(2000)
    assert peer.ExitCode == 0
    assert peer.StandardError.ReadToEnd() == ""
    assert str(model.Trace) == ''' + repr(TRACE) + '''
    assert model.Normal == 0xa50000d0
    assert model.Command == 0x51 and model.Pending == 0xf1
    assert model.Count == 0xffff
    assert model.Ones == 0xffffff51
    print("R640_NATIVE_COMMANDS " + ";".join(commands))
    print("R640_NATIVE_TRACE " + str(model.Trace))
    print("R640_NATIVE_PASS")
finally:
    if not peer.HasExited:
        peer.Kill()
        peer.WaitForExit()
''')
        run.renode_script(name, [
            f'include @{HERE}/probes/EncodingPeripheral.cs',
            'mach create "native-packed-contract"',
            f'machine LoadPlatformDescription @{platform}',
            f'include @{checks}',
        ], 'R640_NATIVE_PASS')
        hole(run, refine, platform, optimization, specialization)


def hole(run, refine, platform, optimization, specialization):
    name = 'packed-native-hole-' + optimization + '-' + specialization
    assembly, executable = run.out / (name + '.s'), run.out / name
    run.command(name + '-compile', [refine, '--target=linux-x86-64',
                '--optimize=' + optimization, '--specialize=' + specialization,
                '--emit=asm', '-o', assembly, HERE / 'probes/packed-native-hole.ldn'],
                timeout=60)
    run.command(name + '-link', ['gcc', '-std=c11', '-Wall', '-Wextra', '-Werror',
                '-g', '-fno-pie', '-no-pie', assembly,
                HERE / 'probes/packed-transport.c', '-o', executable])
    checks = run.out / (name + '.py')
    checks.write_text('''import clr
clr.AddReference("System.Diagnostics.Process")
from System.Diagnostics import Process, ProcessStartInfo
bus = monitor.Machine.SystemBus
model = monitor.Machine["sysbus.model"]
info = ProcessStartInfo()
info.FileName = ''' + repr(str(executable)) + '''
info.UseShellExecute = False
info.RedirectStandardInput = True
info.RedirectStandardOutput = True
info.RedirectStandardError = True
peer = Process.Start(info)
try:
    assert str(peer.StandardOutput.ReadLine()) == "R32 4"
    value = bus.ReadDoubleWord(0x40030004)
    assert value == 0x9b
    peer.StandardInput.WriteLine(str(value))
    peer.StandardInput.Flush()
    assert peer.StandardOutput.ReadLine() is None
    assert peer.WaitForExit(2000)
    print("R640_NATIVE_HOLE_EXIT " + str(peer.ExitCode))
    assert peer.ExitCode == 132
    assert peer.StandardError.ReadToEnd() == ""
    assert str(model.Trace) == "r32:4:0000009b"
    print("R640_NATIVE_HOLE_TRACE " + str(model.Trace))
    print("R640_NATIVE_HOLE_PASS")
finally:
    if not peer.HasExited:
        peer.Kill()
        peer.WaitForExit()
''')
    run.renode_script(name, [
        f'include @{HERE}/probes/EncodingPeripheral.cs',
        'mach create "native-packed-hole-contract"',
        f'machine LoadPlatformDescription @{platform}',
        f'include @{checks}',
    ], 'R640_NATIVE_HOLE_PASS')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--refine', type=Path, required=True)
    parser.add_argument('--tools', type=Path, default=DEFAULT)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    supported_host()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    result = {'status': 'failed', 'inputs': inventory(HERE)}
    installed = json.loads((args.tools / 'installation.json').read_text())
    try:
        require(installed['lock_sha256'] == sha(HERE / 'tools.lock.json'),
                'tool lock mismatch')
        require(installed['files'] == {area: inventory(args.tools / area)
                for area in ('root', 'renode')}, 'installed tools changed')
        (out / 'tools.json').write_text(json.dumps(installed, sort_keys=True) + '\n')
        execute(Run(out, args.tools.resolve()), args.refine)
        require(installed['files'] == {area: inventory(args.tools / area)
                for area in ('root', 'renode')}, 'tools changed during execution')
        require(result['inputs'] == inventory(HERE), 'probe inputs changed')
        result['status'] = 'passed'
    finally:
        result['files'] = inventory(out)
        (out / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print('R640 native peripheral ' + result['status'])


if __name__ == '__main__':
    main()
