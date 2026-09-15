"""Schema-3 hosted parity verification; historical Darwin scopes stay separate."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import signal
import shlex
import sys
import tempfile

from common import archive_inventory, file_hash, read_json, require

ROOT = Path(__file__).resolve().parents[2]
PROFILES = [('none', 'off'), ('size', 'off'), ('size', 'auto'), ('speed', 'auto')]
DEBUG_PROFILES = [('none', 'off'), ('size', 'auto'), ('size', 'all')]
WORKLOADS = ('parser', 'containers', 'hosted')


def metadata(path):
    return dict(line.split(': ', 1) for line in path.read_text().splitlines()
                if ': ' in line and not line.startswith('#'))


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def runtime_schedule(source):
    differences = read_json(source / 'compiler/tests/darwin/parity.json')['differences']
    result = []
    for path in sorted(p for cls in ('runtime', 'abi')
                       for p in (source / 'compiler/tests/fixtures' / cls).glob('*/fixture.meta')):
        name = str(path.parent.relative_to(source / 'compiler/tests/fixtures'))
        meta = metadata(path)
        meta.setdefault('stream', 'merged')
        difference = differences.get(name, {})
        if 'replacement' in difference:
            continue
        meta.update({k: v for k, v in difference.items() if k != 'reason'})
        profiles = PROFILES + ([('none', 'all'), ('speed', 'all')]
                               if meta['profiles'] == 'specialization' else [])
        result.extend((name, opt, spec, meta, path.parent) for opt, spec in profiles)
    manifest = read_json(source / 'compiler/tests/darwin/cases.json')
    for case in manifest['darwin']:
        result.extend((case['name'], opt, spec, {**case, 'class': case.get('class', 'abi'), 'c-sources': case.get('c', '')}, source / 'compiler/tests/darwin')
                      for opt, spec in PROFILES)
    known = {str(p.parent.relative_to(source / 'compiler/tests/fixtures'))
             for cls in ('runtime', 'abi') for p in (source / 'compiler/tests/fixtures' / cls).glob('*/fixture.meta')}
    require(set(differences) <= known and all(d.get('reason') for d in differences.values()),
            'unknown or unexplained target difference')
    replacements = {n: d['replacement'] for n, d in differences.items() if 'replacement' in d}
    require(replacements == {'runtime/r430-static-library': 'bindings/archive-selection',
                            'abi/r440-bindings-generated': 'bindings/generated',
                            'abi/r440-native-varargs': 'varargs',
                            'abi/r440-sret-pointer-observation': 'transport'}, 'uncovered native replacement')
    return result


def commands_in(directory):
    commands = read_json(directory / 'commands.json')
    result = {}
    for command in commands:
        name = command['stdout'].removesuffix('.stdout')
        require(name not in result and not command['timeout'], 'duplicate/timed-out native command')
        result[name] = command
    return result


def validate_runtime(directory, source, compiler_hash, source_path, original_directory, compiler_path):
    summary = read_json(directory / 'summary.json')
    require(summary['scope'] == 'R5.50' and summary['status'] == 'passed'
            and summary['refine_sha256'] == compiler_hash, 'incomplete Darwin runtime scope')
    require(summary['differences'] == read_json(source / 'compiler/tests/darwin/parity.json')['differences'],
            'uncommitted target differences')
    schedule = runtime_schedule(source)
    require([(r['case'], r['optimize'], r['specialize']) for r in summary['results']]
            == [(name, opt, spec) for name, opt, spec, _, _ in schedule], 'missing Darwin hosted coverage')
    commands = commands_in(directory)
    consumed = set()
    for row, (name, opt, spec, meta, base) in zip(summary['results'], schedule):
        key = name.replace('/', '-') + '-' + opt + '-' + spec
        for suffix, field in (('.s', 'assembly'), ('.o', 'object'), ('', 'executable')):
            require(row[field] == file_hash(directory / (key + suffix)), 'substituted runtime ' + field)
        execution = commands[key + '-execute']
        expected_arguments = [str(original_directory / key), *shlex.split(meta.get('run_args', ''))]
        require(execution['argv'] == expected_arguments and execution['cwd'] == str(source_path / 'compiler/ada'),
                'substituted runtime execution command')
        stdout = (directory / execution['stdout']).read_bytes()
        stderr = (directory / execution['stderr']).read_bytes()
        status = execution['status']
        require(row['exit'] == status, 'runtime result differs from command')
        if meta.get('limit') == 'darwin-shared-region':
            control = commands[key + '-control-execute']
            message = b'syscall to map cache into shared region failed'
            require(row['status'] == 'platform-limited' and status == control['status'] == -signal.SIGABRT
                    and message in stdout + stderr
                    and message in (directory / control['stdout']).read_bytes(),
                    'unexplained large-image result')
            require(control['argv'] == [str(original_directory / (key + '-control'))], 'wrong loader control')
        else:
            expected = -signal.SIGTRAP if meta.get('traps') == 'yes' else int(meta['status'])
            require(row['status'] == 'passed' and status == expected, 'failed native hosted execution')
            oracle = ((base / meta['run_expect']).read_bytes() if 'run_expect' in meta else
                      meta['stdout'].encode() if 'stdout' in meta else None)
            actual = stdout + stderr if meta.get('stream', 'merged') == 'merged' else stdout
            require(oracle is None or actual == oracle, 'native output differs from shared oracle')
            require(meta.get('stream', 'merged') == 'merged' or not stderr, 'unexpected native stderr')
        # Reconstruct producer and consumer commands from the committed inputs.
        # Evidence labels alone never authorize another source or executable.
        worker_base = source_path / base.relative_to(source)
        worker_source = worker_base / meta['program']
        inputs = (['--root=' + str((source_path / (base / meta['root']).resolve().relative_to(source)).resolve()),
                   str(worker_source.parent)] if 'root' in meta else [str(worker_source)])
        inputs += [str(worker_base / n.strip()) for n in meta.get('with', '').split(',') if n.strip()]
        prefix = [str(compiler_path), '--target=darwin-arm64', '--optimize=' + opt,
                  '--specialize=' + spec, *inputs]
        exe = original_directory / key
        asm = original_directory / (key + '.s')
        obj = original_directory / (key + '.o')
        expected_commands = {}
        if meta['class'] == 'runtime' and not meta.get('c-sources'):
            expected_commands['build'] = [*prefix, '--toolchain=' + str(original_directory / 'retain-clang'),
                                          '--emit=exe', '-o', str(exe)]
            require((directory / 'retain-clang').read_text() ==
                    '#!/bin/sh\nexec /usr/bin/clang -save-temps=obj -x assembler "$@"\n', 'substituted retention driver')
        else:
            expected_commands['emit'] = [*prefix, '--emit=asm', '-o', str(asm)]
            expected_commands['assemble'] = ['/usr/bin/clang', '-arch', 'arm64', '-c', str(asm), '-o', str(obj)]
            c_args = shlex.split(meta.get('c-args', ''))
            c_args = [a.replace('-Wl,--wrap=', '-Wl,-alias,___wrap_') + ',_' + a.split('=')[1]
                      if a.startswith('-Wl,--wrap=') else a for a in c_args]
            peers = []
            for index, part in enumerate(meta['c-sources'].split(',')):
                peer = original_directory / (key + f'-peer-{index}.o')
                require((directory / peer.name).is_file(), 'missing native C peer object')
                expected_commands[f'peer-{index}'] = ['/usr/bin/clang', '-arch', 'arm64', '-std=c11', '-O2',
                    '-Wall', '-Wextra', '-Werror', *[a for a in c_args if not a.startswith('-Wl,')],
                    '-c', str(worker_base / part.strip()), '-o', str(peer)]
                peers.append(str(peer))
            expected_commands['link'] = ['/usr/bin/clang', '-arch', 'arm64', '-std=c11', '-O2',
                    '-Wall', '-Wextra', '-Werror', *c_args, str(obj), *peers, '-o', str(exe)]
        expected_commands['file'] = ['/usr/bin/file', str(exe)]
        if meta.get('limit') == 'darwin-shared-region':
            control = original_directory / (key + '-control')
            control_obj = original_directory / (key + '-control.o')
            expected_commands['control-compile'] = ['/usr/bin/clang', '-arch', 'arm64', '-O2', '-c',
                str(source_path / 'compiler/tests/darwin/large_image.c'), '-o', str(control_obj)]
            expected_commands['control-link'] = ['/usr/bin/clang', '-arch', 'arm64', str(control_obj), '-o', str(control)]
            require((directory / control.name).is_file() and (directory / control_obj.name).is_file(),
                    'missing native loader control artifacts')
            consumed.add(key + '-control-execute')
        for suffix, argv in expected_commands.items():
            label = key + '-' + suffix
            command = commands[label]
            require(command['argv'] == argv and command['cwd'] == str(source_path / 'compiler/ada')
                    and command['status'] == 0, 'failed/substituted native producer: ' + label)
            consumed.add(label)
        require(b'Mach-O 64-bit executable arm64' in (directory / (key + '-file.stdout')).read_bytes(),
                'wrong native runtime architecture')
        consumed.add(key + '-execute')
    require(set(commands) == consumed, 'unexpected native runtime commands')


def validate_diagnostics(directory, source, compiler_hash, source_path, compiler_path):
    summary = read_json(directory / 'summary.json')
    require(summary['scope'] == 'R5.50' and summary['status'] == 'passed'
            and summary['refine_sha256'] == compiler_hash, 'incomplete target diagnostic scope')
    differences = read_json(source / 'compiler/tests/darwin/parity.json')['diagnostics']
    require(summary['differences'] == differences, 'uncommitted diagnostic differences')
    expected = []
    for cls in ('negative', 'positive'):
        for path in sorted((source / 'compiler/tests/fixtures' / cls).glob('*/fixture.meta')):
            meta = metadata(path)
            if 'macos-arm64' in meta['targets'].split(', ') and ('program' in meta or 'args' in meta):
                name = str(path.parent.relative_to(source / 'compiler/tests/fixtures'))
                expected.append((name, {**meta, **differences.get(name, {})}, path.parent))
    require([r['case'] for r in summary['results']] == [n for n, _, _ in expected],
            'missing target source verdicts')
    commands = commands_in(directory)
    for row, (name, meta, base) in zip(summary['results'], expected):
        command = commands[name.replace('/', '-')]
        relative = Path('../tests/fixtures') / name
        if 'args' in meta:
            argv = meta['args'].split()
        elif 'root' in meta:
            argv = ['--root=' + str(relative / meta['root']), str(relative)]
        else:
            argv = [str(relative / meta['program'])]
            argv += [str(relative / part.strip()) for part in meta.get('with', '').split(',') if part.strip()]
        argv = [a.replace('--target=linux-x86-64', '--target=darwin-arm64') for a in argv]
        if not any(a.startswith('--target=') for a in argv):
            argv.append('--target=darwin-arm64')
        require(command['argv'] == [str(compiler_path), *argv]
                and command['cwd'] == str(source_path / 'compiler/ada'), 'substituted diagnostic source/compiler')
        status = int(meta.get('status', '1' if meta['class'] == 'negative' else '0'))
        require(row['status'] == 'passed' and row['exit'] == command['status'] == status,
                'failed target source verdict')
        actual = (directory / command['stdout']).read_bytes() + (directory / command['stderr']).read_bytes()
        require(row['output_sha256'] == hashlib.sha256(actual).hexdigest(), 'substituted diagnostic output')
        require(re.findall(rb'error\[(L[0-9]{4})\]', actual)
                == [c.strip().encode() for c in meta.get('codes', '').split(',') if c.strip()],
                'wrong target diagnostic codes')
        if 'expect' in meta:
            require(actual == (base / meta['expect']).read_bytes(), 'wrong exact target diagnostic')


def validate_session(session, stops, stderr):
    required = {'stops': sorted(s['name'] for s in stops), 'inferior state': 10,
                'inferior status': 42, 'stdout': '', 'stderr': stderr}
    for stop in stops:
        prefix = stop['name'] + '.'
        required.update({prefix + 'function': stop['stack'][0], prefix + 'line': stop['line'],
                         prefix + 'file': stop['source'], prefix + 'stack': stop['stack']})
        required.update({prefix + path: value for path, value in stop['values'].items()})
        required.update({prefix + 'caller.' + path: value for path, value in stop.get('caller_values', {}).items()})
        if stop.get('complete_parser'):
            required[prefix + 'application'] = True
        for index, step in enumerate(stop.get('steps', [])):
            part = prefix + f'step-{index}.'
            required.update({part + 'state': 5, part + 'function': step['function'], part + 'line': step['line']})
            required.update({part + path: value for path, value in step.get('values', {}).items()})
            if 'stack' in step:
                required[part + 'stack'] = step['stack']
    require(session['status'] == 'passed'
            and all(c['actual'] == c['expected'] for c in session['checks'])
            and len(session['checks']) == len(required)
            and {c['label']: c['actual'] for c in session['checks']} == required,
            'missing or weakened derivative debugger assertions')


def validate_workloads(directory, source, source_path, record, mode):
    import macho_identity
    # Use trusted verifier code while deriving marker lines from the accepted
    # archive, including when verifying an older schema-3 source revision.
    shared = load_module('parity_shared_debug', ROOT / 'compiler/tests/debugging/check.py')
    shared.ROOT = source
    for kind, library, fixture in (
            ('PARSER', 'examples/config_parser/parser/parser.ldn', 'derived-parser'),
            ('CONTAINER', 'examples/derived_containers/workload/workload.ldn', 'derived-containers'),
            ('HOSTED', 'examples/derived_hosted/app/app.ldn', 'derived-hosted-memory')):
        setattr(shared, kind + '_SOURCE', source / library)
        setattr(shared, kind + '_FIXTURE', source / 'compiler/tests/fixtures/runtime' / fixture)
    sys.path.insert(0, str(ROOT / 'compiler/tests/debugging'))
    workload_code = load_module('parity_workloads', ROOT / 'compiler/tests/debugging/darwin_workloads.py')
    workload_code.shared = shared
    commands = {c['name']: c for c in read_json(directory / 'commands.json')}
    original = Path(record['paths']['{debugging-' + mode + '}'])
    compiler = record['paths']['{refine-' + mode + '}']
    tools = read_json(directory / 'summary.json')['tools']
    rows = read_json(directory / 'workloads.json')
    require([(r['workload'], r['optimize'], r['specialize']) for r in rows]
            == [(w, o, s) for w in WORKLOADS for o, s in DEBUG_PROFILES], 'missing complete derivative LLDB profiles')
    for row in rows:
        key = row['workload'] + '-' + row['optimize'] + '-' + row['specialize']
        config = read_json(directory / (key + '-config.json'))
        expected_stops = workload_code.stops_for(row['workload'])
        for stop in expected_stops:
            stop['source'] = str(source_path / Path(stop['source']).relative_to(source))
        require(config['stops'] == expected_stops, 'substituted derivative debugger oracle')
        session = read_json(directory / (key + '-session.json'))
        require(row['status'] == session['status'] == 'passed'
                and len(session['checks']) == row['checks']
                and all(c['actual'] == c['expected'] for c in session['checks']), 'failed derivative LLDB assertions')
        fixture = source / 'compiler/tests/fixtures/runtime' / {
            'parser': 'derived-parser', 'containers': 'derived-containers', 'hosted': 'derived-hosted-memory'}[row['workload']]
        arguments = [str(source_path / (fixture / 'input.txt').relative_to(source))] if row['workload'] == 'parser' else []
        stderr = (fixture / 'output.txt').read_text() if row['workload'] == 'parser' else ''
        expected_config = dict(executable=str(original / key), cwd=str(source_path), arguments=arguments,
            stops=expected_stops, stdout=str(original / (key + '-inferior.stdout')),
            stderr=str(original / (key + '-inferior.stderr')), expected_stdout='', expected_stderr=stderr,
            result=str(original / (key + '-session.json')))
        require(config == expected_config, 'substituted derivative launch or output oracle')
        validate_session(session, expected_stops, stderr)
        artifact_names = ('', '.s', '.o', '.sources.json', '.report.json',
                          '.dSYM/Contents/Resources/DWARF/' + key, '-deployment/program')
        require(row['artifacts'] == {suffix: file_hash(directory / (key + suffix)) for suffix in artifact_names},
                'substituted derivative artifact')
        report = read_json(directory / (key + '.report.json'))
        require(report['build']['target'] == 'darwin-arm64'
                and report['build']['optimize'] == row['optimize']
                and report['build']['specialize'] == row['specialize'], 'wrong derivative compiler profile')
        expected_commands = {
            'compile': [compiler, str(fixture.relative_to(source)), '--root=.', '--target=darwin-arm64',
                '--debug=full', '--emit=exe', '-o', str(original / key), '--optimize=' + row['optimize'],
                '--specialize=' + row['specialize'], '--build-report=' + str(original / (key + '.report.json'))],
            'lldb': [tools['lldb']['path'], '--no-lldbinit', '-b', '-s', str(original / (key + '.lldb'))],
            'execute': [str(original / key), *arguments],
            'stripped-execute': [str(original / (key + '-deployment/program')), *arguments],
            'strip': [tools['strip']['path'], '-S', '-x', str(original / (key + '-deployment/program'))]}
        for suffix, argv in expected_commands.items():
            command = commands[key + '-' + suffix]
            require(command['argv'] == argv and command['cwd'] == str(source_path)
                    and not command['timeout'] and command['returncode'] == (42 if suffix.endswith('execute') else 0),
                    'failed/substituted derivative command: ' + suffix)
        for suffix in ('execute', 'stripped-execute', 'inferior'):
            require((directory / (key + '-' + suffix + '.stdout')).read_text() == ''
                    and (directory / (key + '-' + suffix + '.stderr')).read_text() == stderr,
                    'failed derivative runtime output: ' + suffix)
        for suffix in ('object-verify', 'dsym-verify', 'uuid', 'unwind', 'stripped-lldb', 'lookup', 'mismatch'):
            command = commands[key + '-' + suffix]
            require(not command['timeout'] and command['returncode'] == (2 if suffix == 'mismatch' else 0),
                    'failed derivative identity command: ' + suffix)
        require('no locations (pending)' in (directory / (key + '-stripped-lldb.stdout')).read_text(),
                'stripped derivative resolves a source breakpoint')
        table = read_json(directory / (key + '.sources.json'))
        require(table['assembly_sha256'] == file_hash(directory / (key + '.s'))
                and table['files'] == row['sources'], 'derivative source identity differs')
        expected_sources = read_json(source / 'compiler/tests/debugging/workload-sources.json')[row['workload']]
        require(sorted(str(Path(os.fsdecode(bytes.fromhex(f['path_hex'])))) for f in table['files']) == expected_sources,
                'incomplete derivative source closure')
        require([(f['path_hex'], f['source_sha256']) for f in table['files']]
                == [(f['path_hex'], f['sha256']) for f in report['sources']], 'debug/report source identities differ')
        for entry in table['files']:
            path = os.fsdecode(bytes.fromhex(entry['path_hex']))
            require(entry['source_sha256'] == file_hash(source / path), 'uncommitted derivative source')
        identity = macho_identity.match(table, directory / key,
                    directory / (key + '.dSYM/Contents/Resources/DWARF/' + key))
        require(identity == row['identity'] == macho_identity.match(table, directory / (key + '-deployment/program')),
                'substituted derivative debug artifact')
        require('LANDIN DERIVED LLDB PASSED' in (directory / (key + '-lldb.stdout')).read_text(),
                'derivative LLDB session did not finish')
        for suffix in ('-object-verify.stdout', '-dsym-verify.stdout'):
            require('No errors.' in (directory / (key + suffix)).read_text(), 'invalid derivative DWARF')


def validate_bindings(directory, source, source_path, compiler_hash, compiler_path, original):
    summary = read_json(directory / 'summary.json')
    require(summary['status'] == summary['archive_selection'] == 'passed'
            and summary['scope'] == 'R5.50' and summary['refine_sha256'] == compiler_hash,
            'missing native binding/archive evidence')
    require([(r['optimize'], r['specialize']) for r in summary['profiles']] == PROFILES,
            'missing generated binding profiles')
    fixture = source / 'compiler/tests/fixtures/abi/r440-bindings-generated'
    for name in ('program.ldn', 'peer.c', 'r440-bindings.h'):
        require(file_hash(directory / 'inputs' / name) == file_hash(fixture / name), 'substituted binding input')
    policy = read_json(fixture / 'policy.json')
    policy['abi']['target'] = 'arm64-apple-macos26.0.0'
    require(read_json(directory / 'inputs/policy.json') == policy, 'unreviewed binding policy')
    require('compiler.assert(compiler.c_darwin_lp64)' in (directory / 'generated/bindings.ldn').read_text(),
            'missing native binding ABI guard')
    commands = commands_in(directory)
    for name, command in commands.items():
        expected = 1 if name == 'archive-missing' else 42 if name.endswith('-execute') else 0
        require(command['status'] == expected, 'failed native binding command: ' + name)
    for row in summary['profiles']:
        key = 'bindings-' + row['optimize'] + '-' + row['specialize']
        require(row['assembly'] == file_hash(directory / (key + '.s'))
                and row['objects'] == [file_hash(directory / (key + '-' + str(i) + '.o')) for i in range(3)]
                and row['executable'] == file_hash(directory / (key + '-native')), 'substituted native bindings')
        compile = commands[key + '-emit']
        require(compile['argv'] == [str(compiler_path), '--target=darwin-arm64', '--root=' + str(source_path),
                '--optimize=' + row['optimize'], '--specialize=' + row['specialize'], '--emit=asm', '-o',
                str(original / (key + '.s')), str(original / 'generated')], 'substituted binding compiler/input')
        require(commands[key + '-execute']['argv'] == [str(original / (key + '-native'))],
                'substituted binding execution')
        require(not (directory / (key + '-execute.stdout')).read_bytes()
                and not (directory / (key + '-execute.stderr')).read_bytes(), 'unexpected binding output')
    for key in ('archive', 'selected'):
        require(commands[key + '-execute']['argv'] == [str(original / (key + '-native'))], 'wrong native archive execution')
        require(all((directory / (key + '-native' + suffix)).is_file() for suffix in ('.s', '.o')),
                'missing retained archive assembly/object')
    require(b'cannot resolve Darwin archive' in (directory / 'archive-missing.stderr').read_bytes()
            and not (directory / 'missing-native').exists(), 'missing-archive refusal absent')


def validate(bundle, record):
    from darwin import validate_debugging
    from macos_environment import harness_result
    with tempfile.TemporaryDirectory(prefix='landin-parity-verify-') as temporary:
        source = Path(temporary) / 'source'
        archive_inventory((bundle / 'source.tar.gz').read_bytes(), source)
        require(read_json(source / 'scripts/ci/policy.json')['scope'] == 'milestone',
                'R5.50 requires the committed Linux milestone matrix')
        source_path = Path(record['paths']['source'])
        for index, mode in enumerate(('debug', 'release')):
            directory = bundle / mode
            for name in ('refine', 'source-manifest.txt', 'configuration.cgpr'):
                require((directory / name).is_file(), 'missing compiler mode identity')
            compiler_hash = file_hash(directory / 'refine')
            harness_result(0, (bundle / f'evidence/step-{index * 6 + 1}.stdout').read_text(), host_only=True)
            validate_runtime(directory / 'executions', source, compiler_hash, source_path,
                             Path(record['paths']['{executions-' + mode + '}']),
                             Path(record['paths']['{refine-' + mode + '}']))
            validate_diagnostics(directory / 'diagnostics', source, compiler_hash, source_path,
                                 Path(record['paths']['{refine-' + mode + '}']))
            validate_bindings(directory / 'bindings', source, source_path, compiler_hash,
                              Path(record['paths']['{refine-' + mode + '}']),
                              Path(record['paths']['{bindings-' + mode + '}']))
            local_record = {**record, 'files': {name.removeprefix(mode + '/'): digest
                            for name, digest in record['files'].items() if name.startswith(mode + '/')}}
            validate_debugging(directory, local_record)
            validate_workloads(directory / 'debugging', source, source_path, record, mode)
