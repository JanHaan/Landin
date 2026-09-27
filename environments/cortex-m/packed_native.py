"""Native compiler-generated image operations against the synthetic device.

The C peer is a blocking line transport, with no register masks or oracle:
each line it writes is one device access, which the encoding model performs
and answers.  There is no CPU model behind it.  This lane runs Linux
instructions and is distinct from the M0 C control.
"""
import argparse
import json
from pathlib import Path
import subprocess
import time

from models import EncodingPeripheral
from packed import TRACE
from run import Run, require, stop
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
                  'execution': 'native Linux x86-64, line transport to the encoding model',
                  'profiles': PROFILES}
    (run.out / 'packed-native-inputs.json').write_text(
        json.dumps(identities, indent=2, sort_keys=True) + '\n')
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
        model = EncodingPeripheral()
        commands, status = transport(run, name, executable, model, 17)
        require(status == 0, name + ' exited %d' % status)
        require(commands[-1] == 'DONE 1600', name + ' reported ' + commands[-1])
        require(model.trace == TRACE, name + ' trace differs: ' + model.trace)
        require(model.normal == 0xa50000d0 and model.command == 0x51 and model.pending == 0xf1
                and model.count == 0xffff and model.ones == 0xffffff51, name + ' device images')
        (run.out / (name + '.trace')).write_text(';'.join(commands) + '\n' + model.trace + '\n')
        hole(run, refine, optimization, specialization)


def transport(run, name, executable, model, limit):
    """Serve the peer's line transport against MODEL until it exits.

    Returns the lines it wrote and its exit status.  The peer may write at
    most LIMIT lines; everything it writes to stderr fails the lane.
    """
    record = {'name': name, 'argv': [str(executable)], 'timeout_seconds': 10}
    run.commands.append(record)
    tick = time.monotonic()
    commands = []
    with (run.out / (name + '.stderr')).open('wb') as errors:
        peer = subprocess.Popen([str(executable)], cwd=run.out, env=run.env, text=True,
                                stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                stderr=errors, start_new_session=True)
        try:
            for line in peer.stdout:
                commands.append(line.rstrip('\n'))
                require(len(commands) <= limit, name + ': transport event limit')
                fields = line.split()
                if fields[0] == 'DONE':
                    break
                operation, offset = fields[0], int(fields[1])
                require(len(fields) == (3 if operation[0] == 'W' else 2) and
                        operation in ('R32', 'R16', 'W32', 'W16'),
                        name + ': unknown transport operation ' + line.strip())
                width = int(operation[1:]) // 8
                if operation[0] == 'R':
                    value = model.read(offset, width)
                else:
                    model.write(offset, width, int(fields[2]))
                    value = 1
                peer.stdin.write('%d\n' % value)
                peer.stdin.flush()
            peer.stdin.close()
            status = peer.wait(timeout=10)
        finally:
            stop(peer)
            record.update(seconds=round(time.monotonic() - tick, 3), exit=peer.returncode)
            (run.out / 'commands.json').write_text(json.dumps(run.commands, indent=2) + '\n')
    require((run.out / (name + '.stderr')).read_bytes() == b'', name + ' wrote to stderr')
    return commands, status


def hole(run, refine, optimization, specialization):
    name = 'packed-native-hole-' + optimization + '-' + specialization
    assembly, executable = run.out / (name + '.s'), run.out / name
    run.command(name + '-compile', [refine, '--target=linux-x86-64',
                '--optimize=' + optimization, '--specialize=' + specialization,
                '--emit=asm', '-o', assembly, HERE / 'probes/packed-native-hole.ldn'],
                timeout=60)
    run.command(name + '-link', ['gcc', '-std=c11', '-Wall', '-Wextra', '-Werror',
                '-g', '-fno-pie', '-no-pie', assembly,
                HERE / 'probes/packed-transport.c', '-o', executable])
    model = EncodingPeripheral()
    commands, status = transport(run, name, executable, model, 1)
    # The peer traps on the unnamed encoding after its one read (SIGILL).
    require(commands == ['R32 4'], name + ' wrote ' + repr(commands))
    require(status == -4, name + ' exited %d, not by SIGILL' % status)
    require(model.trace == 'r32:4:0000009b', name + ' trace differs: ' + model.trace)
    (run.out / (name + '.trace')).write_text(model.trace + '\n')


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
                for area in installed['files']}, 'installed tools changed')
        (out / 'tools.json').write_text(json.dumps(installed, sort_keys=True) + '\n')
        execute(Run(out, args.tools.resolve()), args.refine)
        require(installed['files'] == {area: inventory(args.tools / area)
                for area in installed['files']}, 'tools changed during execution')
        require(result['inputs'] == inventory(HERE), 'probe inputs changed')
        result['status'] = 'passed'
    finally:
        result['files'] = inventory(out)
        (out / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print('R640 native peripheral ' + result['status'])


if __name__ == '__main__':
    main()
