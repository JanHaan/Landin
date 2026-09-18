#!/usr/bin/env python3
"""Bounded native source/frame acceptance for D231/D232 panic calls."""
import argparse
import hashlib
import json
import sys
import os
from pathlib import Path
import platform
import re
import shutil
import signal
import subprocess

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
SOURCE = HERE / 'panic/app/main.ldn'
PROFILES = (('none', 'off'), ('size', 'auto'), ('size', 'all'))


if sys.flags.optimize:
    raise RuntimeError("panic debugger assertions require Python optimization disabled")


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def measure(refine, output, *, debugger=None, toolchain=None, profile=None):
    assert (platform.system(), platform.machine()) in (('Darwin', 'arm64'), ('Linux', 'x86_64'))
    darwin = platform.system() == 'Darwin'
    target = 'darwin-arm64' if darwin else 'linux-x86-64'
    output = Path(output).resolve()
    output.mkdir(parents=True, exist_ok=False)
    refine = Path(refine).resolve(strict=True)
    debugger = debugger or shutil.which('lldb' if darwin else 'gdb')
    assert debugger and Path(debugger).is_file()
    commands = []

    def run(name, args, expected=0, cwd=ROOT):
        args = list(map(str, args))
        with (output / (name+'.stdout')).open('wb') as stdout, (output / (name+'.stderr')).open('wb') as stderr:
            process = subprocess.Popen(args, cwd=cwd, stdout=stdout, stderr=stderr,
                                       start_new_session=True)
            expired = False
            try:
                status = process.wait(timeout=120)
            except subprocess.TimeoutExpired:
                expired = True
                os.killpg(process.pid, signal.SIGKILL)
                status = process.wait()
        commands.append({'name': name, 'argv': args, 'cwd': str(cwd),
                         'status': status, 'timed_out': expired})
        (output / 'commands.json').write_text(json.dumps(commands, indent=2)+'\n')
        assert not expired and status == expected, (name, status, output)
        return (output / (name+'.stdout')).read_text()+(output / (name+'.stderr')).read_text()

    compiler_hash = digest(refine)
    debugger_hash = digest(debugger)
    run('compiler', [refine, '--identify'])
    run('debugger', [debugger, '--version'])
    text = SOURCE.read_text()
    offset = text.index('high += value')
    operation_line = text[:offset].count('\n')+1
    handler_line = text[:text.index('observed_site = site')].count('\n')+1
    site = 4*offset+2
    retained = output / 'sources'
    retained.mkdir()
    shutil.copyfile(SOURCE, retained / 'main.ldn')
    shutil.copyfile(ROOT / 'core/panic/panic.ldn', retained / 'panic.ldn')
    results = []
    for opt, specialize in PROFILES:
        key = opt+'-'+specialize
        if profile and profile != key:
            continue
        executable = output / key
        run(key+'-compile', [refine, '--root=.', '--target='+target,
            '--debug=full', '--panic-map', '--emit=exe', '--optimize='+opt,
            '--specialize='+specialize,
            *(['--toolchain='+str(toolchain)] if toolchain else []),
            SOURCE.parent.relative_to(ROOT), '-o', executable])
        run(key+'-execute', [executable], 42)
        if darwin:
            config = {'executable': str(executable), 'cwd': str(ROOT),
                      'source': str(SOURCE), 'operation_line': operation_line,
                      'handler_line': handler_line, 'site': site,
                      'result': str(output / (key+'-session.json'))}
            path = output / (key+'-config.json')
            path.write_text(json.dumps(config, indent=2)+'\n')
            script = output / (key+'.lldb')
            script.write_text('command script import '+json.dumps(str(HERE / 'panic_session.py'))+'\n'
                + 'script panic_session.run(lldb.debugger, '+repr(str(path))+')\nquit\n')
            transcript = run(key+'-debugger', [debugger, '--no-lldbinit', '-b', '-s', script], cwd=output)
            assert transcript.count('LANDIN PANIC LLDB PASSED') == 1
            assert json.loads(Path(config['result']).read_text())['status'] == 'passed'
        else:
            script = output / (key+'.gdb')
            script.write_text('\n'.join([
                'set pagination off', 'set confirm off', 'set disable-randomization off',
                'set width 0', 'set height 0',
                f'break {SOURCE}:{operation_line}', f'break {SOURCE}:{handler_line}', 'run',
                'printf "PANIC_INPUT %u %u\\n", value, high',
                'delete 1', 'continue',
                'printf "PANIC_VALUES %u %u\\n", kind, site',
                'printf "PANIC_STACK_BEGIN\\n"', 'bt 8', 'printf "PANIC_STACK_END\\n"',
                'delete 2', 'continue', 'printf "PANIC_EXIT %d\\n", $_exitcode', 'quit', '']))
            transcript = run(key+'-debugger', [debugger, '-q', '-nx', '-batch',
                executable, '-x', script], cwd=output)
            assert 'PANIC_INPUT 1 255\n' in transcript
            assert f'PANIC_VALUES 2 {site}\n' in transcript
            assert 'PANIC_EXIT 42\n' in transcript
            stack = transcript.split('PANIC_STACK_BEGIN\n')[1].split('PANIC_STACK_END')[0]
            for index, name in enumerate(('panic_handler', 'crash', 'invoke', 'run_thing', 'main')):
                assert re.search(rf'^#{index}\s+.*\b{name}\b', stack, re.M), stack
            for index, line in ((0, handler_line), (1, operation_line)):
                assert re.search(rf'^#{index}\s+.*main.ldn:{line}\s*$', stack, re.M), stack
        mapped = run(key+'-map', ['python3', ROOT / 'scripts/source-location.py',
            str(executable)+'.sources.json', '--panic-site', site,
            '--assembly', str(executable)+'.s'])
        assert f'main.ldn:{operation_line}:5 (overflow)' in mapped
        results.append({'profile': key, 'status': 'passed', 'site': site})
        print('native panic debugger: '+target+'/'+key+' passed', flush=True)
    assert digest(refine) == compiler_hash and digest(debugger) == debugger_hash
    result = {'status': 'passed', 'target': target, 'filtered': profile is not None,
              'compiler_sha256': compiler_hash, 'debugger_sha256': debugger_hash,
              'results': results, 'artifacts': {str(p.relative_to(output)): digest(p)
                 for p in sorted(output.rglob('*')) if p.is_file()}}
    (output / 'result.json').write_text(json.dumps(result, indent=2)+'\n')
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--refine', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--debugger')
    parser.add_argument('--toolchain')
    parser.add_argument('--profile', choices=tuple(a+'-'+b for a,b in PROFILES))
    args = parser.parse_args()
    measure(**vars(args))
