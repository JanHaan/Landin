"""Native LLDB execution of the shared complete prototype derivatives."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import sys

import check as shared
import macho_identity


def stops_for(workload):
    def stop(name, source, line, stack, values, **extra):
        return dict(name=name, source=str(source), line=line, stack=stack, values=values, **extra)
    if workload == 'parser':
        lines = shared.parser_lines()
        source = shared.PARSER_SOURCE
        return [
            stop('digits', source, lines['digits'],
                 ['parse_digits', 'parse_digits', 'parse_entry', 'parse_sequence'],
                 {'accumulated': 4, 'cursor.offset': 27, 'ends.offset': 28},
                 when={'accumulated': 4}, complete_parser=True,
                 caller_values={'accumulated': 0, 'cursor.offset': 26}),
            stop('recovery', source, lines['recovery'],
                 ['recover_to_boundary', 'parse_entry', 'parse_sequence'],
                 {'parser.depth': 0, 'parser.look.what': 1,
                  'parser.look.begins.offset': 36, 'parser.look.ends.offset': 38},
                 when={'parser.look.begins.offset': 36}, complete_parser=True),
            stop('nested', source, lines['nested'],
                 ['parse_sequence', 'parse_entry', 'parse_sequence'],
                 {'parser.depth': 1, 'parser.look.what': 6,
                  'parser.look.begins.offset': 48, 'source.1': 92},
                 when={'parser.depth': 1}, complete_parser=True),
            stop('done', shared.PARSER_FIXTURE / 'main.ldn', lines['done'], ['main'],
                 {'valid': 1, 'source_length': 92, 'saw_out_of_memory': 1, 'saw_io_failure': 1})]
    if workload == 'containers':
        lines = shared.container_lines()
        source = shared.CONTAINER_SOURCE
        return [
            stop('sorted', source, lines['sorted'], ['numbers_path', 'containers_run', 'main'],
                 {'count': 20, 'first': 1, 'last': 20}),
            stop('done', source, lines['done'], ['containers_run', 'main'],
                 dict.fromkeys(shared.CONTAINER_DONE_VALUES, 1)),
            *[stop(instance, source, lines['evidence'],
                   ['evidence_less', 'containers_run', 'main'],
                   {'left': left, 'right': 1}, when={'left': left}, steps=[
                       dict(action='in', function=provider, line=lines[instance + '-provider'],
                            stack=[provider, 'evidence_less', 'containers_run', 'main'],
                            values={'left': left, 'right': 1}),
                       dict(action='out', function='evidence_less', line=lines['evidence']),
                       dict(action='out', function='containers_run', line=lines[instance + '-call']),
                       dict(action='over', function='containers_run', line=lines[instance + '-ready'],
                            values={('signed_order' if instance == 'signed' else 'unsigned_order_ok'): 1})])
              for instance, provider, left in (('signed', 'less_i32', -1),
                                               ('unsigned', 'less_u32', 4294967295))]]
    assert workload == 'hosted'
    lines = shared.hosted_lines()
    source = shared.HOSTED_SOURCE.parent
    return [stop(name, source / filename, lines[name], stack, values)
            for name, filename, stack, values in (
                ('sample', 'filter.ldn', ['sample_keep', 'process', 'run_logged', 'run', 'main'],
                 {'self.*.seen': 0, 'self.*.every': 2}),
                ('sample-updated', 'filter.ldn', ['sample_keep', 'process', 'run_logged', 'run', 'main'],
                 {'self.*.seen': 1}),
                ('text', 'dest.ldn', ['text_emit', 'emit_retry', 'process', 'run_logged', 'run', 'main'],
                 {'line.delivered': 0}))]


def measure(refine, output, capture, tools, selected=None, profile=None):
    def run(label, argv, expected=0, timeout=180):
        code, _, expired = capture.run(label, argv, cwd=shared.ROOT, timeout=timeout, check=False)
        assert code == expected and not expired, (label, code, 'see retained transcript')
        return (output / (label + '.stdout')).read_text()

    results = []
    for workload in shared.WORKLOADS:
        if selected and selected != workload:
            continue
        fixture = {'parser': shared.PARSER_FIXTURE, 'containers': shared.CONTAINER_FIXTURE,
                   'hosted': shared.HOSTED_FIXTURE}[workload]
        arguments = [str(fixture / 'input.txt')] if workload == 'parser' else []
        expected_stderr = (fixture / 'output.txt').read_text() if workload == 'parser' else ''
        for suffix, opt, spec in shared.WORKLOAD_PROFILES:
            if profile and profile != suffix:
                continue
            key = workload + '-' + suffix
            print('Darwin debugger:', key, flush=True)
            executable = output / key
            run(key + '-compile', [refine.resolve(), str(fixture.relative_to(shared.ROOT)), '--root=.',
                '--target=darwin-arm64', '--debug=full', '--emit=exe', '-o', executable,
                '--optimize=' + opt, '--specialize=' + spec,
                '--build-report=' + str(executable) + '.report.json'], timeout=900)
            report = json.loads(Path(str(executable) + '.report.json').read_text())
            source_args = tuple(os.fsdecode(bytes.fromhex(s['path_hex'])) for s in report['sources'])
            shared.check_workload_sources(workload, source_args)
            sources = tuple((shared.ROOT / s).resolve() for s in source_args)
            assert fixture / 'main.ldn' in sources
            table_path = Path(str(executable) + '.sources.json')
            table = json.loads(table_path.read_text())
            shared.check_source_map(table_path, table['build_id'], source_args,
                                    Path(str(executable) + '.s'), sources)
            shared.check_specialization(Path(str(executable) + '.report.json'), opt, spec, 'darwin-arm64')
            dsym = Path(str(executable) + '.dSYM/Contents/Resources/DWARF/' + key)
            identity = macho_identity.match(table, executable, dsym)
            for kind, path in (('object', Path(str(executable) + '.o')), ('dsym', dsym)):
                transcript = run(key + '-' + kind + '-verify', [tools['dwarfdump']['path'], '--verify', path])
                assert 'No errors.' in transcript and 'error:' not in transcript
            run(key + '-uuid', [tools['dwarfdump']['path'], '--uuid', executable, dsym])
            unwind = run(key + '-unwind', [tools['dwarfdump']['path'], '--eh-frame', Path(str(executable) + '.o')])
            assert 'CFA=W29+16' in unwind or 'CFA=reg29+16' in unwind
            run(key + '-execute', [executable, *arguments], 42)
            assert (output / (key + '-execute.stdout')).read_text() == ''
            assert (output / (key + '-execute.stderr')).read_text() == expected_stderr
            config = dict(executable=str(executable), cwd=str(shared.ROOT), arguments=arguments,
                          stops=stops_for(workload), stdout=str(output / (key + '-inferior.stdout')),
                          stderr=str(output / (key + '-inferior.stderr')), expected_stdout='',
                          expected_stderr=expected_stderr, result=str(output / (key + '-session.json')))
            config_path = output / (key + '-config.json')
            config_path.write_text(json.dumps(config, indent=2) + '\n')
            script = output / (key + '.lldb')
            script.write_text('command script import ' + json.dumps(str(shared.HERE / 'lldb_workloads.py')) + '\n'
                              + 'script lldb_workloads.run(lldb.debugger, ' + repr(str(config_path)) + ')\nquit\n')
            transcript = run(key + '-lldb', [tools['lldb']['path'], '--no-lldbinit', '-b', '-s', script])
            assert 'LANDIN DERIVED LLDB PASSED' in transcript
            session = json.loads(Path(config['result']).read_text())
            assert session['status'] == 'passed'
            deployment = output / (key + '-deployment')
            deployment.mkdir()
            stripped = deployment / 'program'
            shutil.copy2(executable, stripped)
            run(key + '-strip', [tools['strip']['path'], '-S', '-x', stripped])
            assert macho_identity.match(table, stripped, dsym) == identity
            assert b'__debug_info' not in stripped.read_bytes()
            for source in sources:
                assert os.fsencode(source.name) not in stripped.read_bytes()
            run(key + '-stripped-execute', [stripped, *arguments], 42)
            assert (output / (key + '-stripped-execute.stdout')).read_text() == ''
            assert (output / (key + '-stripped-execute.stderr')).read_text() == expected_stderr
            stripped_session = run(key + '-stripped-lldb', [tools['lldb']['path'], '--no-lldbinit', '-b',
                '-o', 'settings set symbols.enable-external-lookup false',
                '-o', 'target create ' + json.dumps(str(stripped)),
                '-o', 'breakpoint set --file main.ldn --line 1', '-o', 'breakpoint list', '-o', 'quit'])
            assert 'no locations (pending)' in stripped_session
            first = table['files'][0]
            lookup = [sys.executable, shared.ROOT / 'scripts/source-location.py', table_path,
                      str(first['file_id']), '1', '1', '--macho', stripped, '--dsym', dsym]
            resolved = run(key + '-lookup', lookup)
            assert os.fsdecode(bytes.fromhex(first['path_hex'])) in resolved
            wrong = {**table, 'build_id': '0' * 64}
            mismatch = output / (key + '-wrong.sources.json')
            mismatch.write_text(json.dumps(wrong) + '\n')
            run(key + '-mismatch', [*lookup[:2], mismatch, *lookup[3:]], 2)
            assert list(deployment.iterdir()) == [stripped]
            results.append(dict(workload=workload, optimize=opt, specialize=spec, status='passed',
                                identity=identity, checks=len(session['checks']), sources=table['files'],
                                artifacts={suffix: hashlib.sha256((output / (key + suffix)).read_bytes()).hexdigest() for suffix in
                                           ('', '.s', '.o', '.sources.json', '.report.json',
                                            '.dSYM/Contents/Resources/DWARF/' + key, '-deployment/program')}))
    return results
