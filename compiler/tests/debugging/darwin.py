#!/usr/bin/env python3
"""Native Darwin DWARF, identity, unwind and LLDB source-debugging acceptance."""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import shutil
import sys

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
from macos_environment import Capture
import macho_identity
import check as linux

PROFILES = (('none', 'off'), ('size', 'auto'), ('size', 'all'))


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main():
    if sys.flags.optimize:
        raise RuntimeError("acceptance assertions require Python optimization disabled")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--refine', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--profile', choices=('none-off', 'size-auto', 'size-all',
                                              *(key for key, _, _ in linux.REGISTER_PROFILES)))
    parser.add_argument('--parity', action='store_true')
    parser.add_argument('--workload', choices=linux.WORKLOADS, help='development only')
    args = parser.parse_args()
    assert platform.system() == 'Darwin' and platform.machine() == 'arm64', 'native arm64 Mac required'
    import panic
    output = panic.fresh(args.output)
    capture = Capture(output)

    def run(label, argv, expected=0):
        code, _, timed_out = capture.run(label, argv, cwd=ROOT, timeout=180, check=False)
        assert code == expected and not timed_out, (label, code, 'see retained transcript')
        return (output / (label + '.stdout')).read_text()

    tools = {}
    for tool in ('clang', 'lldb', 'dwarfdump', 'dsymutil', 'strip', 'otool'):
        path = run(tool + '-path', ['xcrun', '--find', tool]).strip()
        tools[tool] = {'path': path, 'sha256': digest(path)}
    policy = json.loads((ROOT / 'environments/macos-arm64/policy.json').read_text())
    assert run('lldb-version', [tools['lldb']['path'], '--version']).splitlines()[0] == policy['debugger']
    assert run('clang-version', [tools['clang']['path'], '--version']).splitlines()[0] == policy['clang']
    for tool in ('dsymutil', 'dwarfdump'):
        assert run(tool + '-version', [tools[tool]['path'], '--version']).splitlines()[0] == policy[tool]
    assert run('sdk-version', ['xcrun', '--show-sdk-version']).strip() == policy['sdk_version']
    assert run('sdk-build', ['xcrun', '--show-sdk-build-version']).strip() == policy['sdk_build']
    sources = output / 'sources'
    sources.mkdir()
    # Preserve original source identities and odd filename bytes. The compilation
    # reads the repository snapshots, whose exact bytes are retained separately.
    scalar_source = HERE / 'darwin-scalars.ldn'
    all_sources = (*linux.SOURCES, scalar_source, linux.REGISTER_SOURCE)
    for source in all_sources:
        shutil.copyfile(source, sources / source.name)
    results = []
    if args.parity or args.workload:
        import darwin_workloads
        workloads = darwin_workloads.measure(args.refine, output, capture, tools, args.workload, args.profile)
        (output / 'workloads.json').write_text(json.dumps(workloads, indent=2) + '\n')
        if args.workload:
            print('FILTERED derived debugger development passed')
            return
    panic_evidence = panic.measure(args.refine, output / 'panic',
        debugger=tools['lldb']['path'], profile=args.profile)
    #  The stack switch's session (D469): the backtrace in a fibre
    #  and through each instruction of two switches, as on every target.
    import switch_frames
    switch_results = []
    for opt, spec in PROFILES:
        key = 'switch-' + opt + '-' + spec
        if args.profile and args.profile != opt + '-' + spec:
            continue
        executable = output / key
        run(key + '-compile', [args.refine.resolve(), str(switch_frames.FIXTURE.relative_to(ROOT)),
            '--root=.', '--target=darwin-arm64', '--debug=full', '--emit=exe', '-o', executable,
            '--optimize=' + opt, '--specialize=' + spec])
        run(key + '-execute', [executable], switch_frames.STATUS)
        #  Nothing else in the image may name the routines' addresses (D475).
        shadows = switch_frames.shadowing_symbols(
            run(key + '-symbols', ['xcrun', 'nm', '-n', executable]), 'mach-o')
        assert not shadows, (key, shadows)
        config = {'executable': str(executable), 'cwd': str(ROOT),
                  'result': str(output / (key + '-stops.json'))}
        config_path = output / (key + '-config.json')
        config_path.write_text(json.dumps(config, indent=2) + '\n')
        script = output / (key + '.lldb')
        script.write_text('command script import ' + json.dumps(str(HERE / 'lldb_switch.py')) + '\n'
                          + 'script lldb_switch.run(lldb.debugger, ' + repr(str(config_path)) + ')\nquit\n')
        transcript = run(key + '-lldb', [tools['lldb']['path'], '--no-lldbinit', '-b', '-s', script])
        assert 'LANDIN SWITCH LLDB STOPPED' in transcript, transcript[-6000:]
        recorded = json.loads(Path(config['result']).read_text())
        assert recorded['state'] and recorded['exit_status'] == switch_frames.STATUS, recorded
        shown = switch_frames.check(switch_frames.recorded_stops(recorded), 'arm64')
        switch_results.append({'profile': key, 'status': 'passed', 'frames': shown})
        print('Darwin stack switch debugger: ' + key + ' passed', flush=True)
    for opt, spec in PROFILES:
        key = opt + '-' + spec
        if args.profile and args.profile != key:
            continue
        executable = output / key
        compile_args = [args.refine.resolve(), *[str(s.relative_to(ROOT)) for s in linux.SOURCES],
                        '--target=darwin-arm64', '--debug=full', '--emit=exe', '-o', executable,
                        '--optimize=' + opt, '--specialize=' + spec,
                        '--build-report=' + str(executable) + '.report.json']
        run(key + '-compile', compile_args)
        run(key + '-execute', [executable], 42)
        assembly = Path(str(executable) + '.s')
        obj = Path(str(executable) + '.o')
        dsym = Path(str(executable) + '.dSYM/Contents/Resources/DWARF/' + key)
        for artifact in (assembly, obj, dsym):
            assert artifact.is_file(), artifact
        table_path = Path(str(executable) + '.sources.json')
        table = json.loads(table_path.read_text())
        linux.check_source_map(table_path, table['build_id'],
                               tuple(str(s.relative_to(ROOT)) for s in linux.SOURCES), assembly)
        identity = macho_identity.match(table, executable, dsym)
        verified = run(key + '-verify', [tools['dwarfdump']['path'], '--verify', dsym])
        assert 'No errors.' in verified and 'error:' not in verified
        run(key + '-object-verify', [tools['dwarfdump']['path'], '--verify', obj])
        run(key + '-uuid', [tools['dwarfdump']['path'], '--uuid', executable, dsym])
        run(key + '-debug-map', [tools['dsymutil']['path'], '--dump-debug-map', executable])
        run(key + '-dwarf', [tools['dwarfdump']['path'], '--all', dsym])
        unwind = run(key + '-unwind', [tools['dwarfdump']['path'], '--eh-frame', obj])
        assert 'CFA=W29+16' in unwind or 'CFA=reg29+16' in unwind, unwind
        run(key + '-load-commands', [tools['otool']['path'], '-l', executable])
        config = {'executable': str(executable), 'source': str(linux.MAIN_SOURCE),
                  'cwd': str(ROOT),
                  'lines': {**linux.SOURCE_LINES, **linux.ARM64_ASSEMBLY_LINES},
                  'caller_line': linux.CALLER_LINE, 'caller_column': linux.CALLER_COLUMN,
                  'result': str(output / (key + '-session.json'))}
        config_path = output / (key + '-session-config.json')
        config_path.write_text(json.dumps(config, indent=2) + '\n')
        script = output / (key + '.lldb')
        script.write_text('command script import ' + json.dumps(str(HERE / 'lldb_session.py')) + '\n'
                          + 'script lldb_session.run(lldb.debugger, ' + repr(str(config_path)) + ')\nquit\n')
        transcript = run(key + '-lldb', [tools['lldb']['path'], '--no-lldbinit', '-b', '-s', script])
        #  The transcript is the only record of which check failed.
        assert 'LANDIN LLDB ACCEPTANCE PASSED' in transcript, transcript[-6000:]
        session = json.loads(Path(config['result']).read_text())
        assert session['status'] == 'passed'
        stripped = output / (key + '-stripped')
        shutil.copyfile(executable, stripped)
        stripped.chmod(0o755)
        run(key + '-strip', [tools['strip']['path'], '-S', '-x', stripped])
        deployment = output / (key + '-deployment')
        deployment.mkdir()
        deployed = deployment / 'program'
        shutil.copy2(stripped, deployed)
        run(key + '-stripped-execute', [deployed], 42)
        assert list(deployment.iterdir()) == [deployed]
        stripped_session = run(key + '-stripped-lldb', [tools['lldb']['path'], '--no-lldbinit', '-b',
            '-o', 'settings set symbols.enable-external-lookup false',
            '-o', 'target create ' + json.dumps(str(deployed)),
            '-o', 'breakpoint set -f main.ldn -l ' + str(linux.SOURCE_LINES['inner-ready']),
            '-o', 'quit'])
        assert 'no locations (pending)' in stripped_session, stripped_session
        assert macho_identity.match(table, stripped, dsym) == identity
        assert b'__debug_info' not in stripped.read_bytes()
        #  D361: names only in trap reports, and only logical ones.
        deployed = linux.deployed_source_names(stripped.read_bytes(), linux.SOURCES)
        assert not deployed, deployed
        lookup = [sys.executable, ROOT / 'scripts/source-location.py', table_path,
                  '2', str(linux.CALLER_LINE), str(linux.CALLER_COLUMN), '--macho', stripped, '--dsym', dsym]
        resolved = run(key + '-lookup', lookup)
        assert resolved == str(linux.ODD_SOURCE.relative_to(ROOT)) + f':{linux.CALLER_LINE}:{linux.CALLER_COLUMN}\n'
        wrong = dict(table, build_id='0' * 64)
        mismatch = output / (key + '-wrong.sources.json')
        mismatch.write_text(json.dumps(wrong))
        run(key + '-mismatch', [*lookup[:2], mismatch, *lookup[3:]], 2)
        results.append({'optimize': opt, 'specialize': spec, 'status': 'passed',
                        'identity': identity, 'checks': len(session['checks'])})
        scalar_exe = output / (key + '-scalars')
        run(key + '-scalars-compile', [args.refine.resolve(), scalar_source,
            '--target=darwin-arm64', '--debug=full', '--emit=exe', '-o', scalar_exe,
            '--optimize=' + opt, '--specialize=' + spec])
        scalar_config = dict(config, executable=str(scalar_exe), source=str(scalar_source),
                             result=str(output / (key + '-scalars-session.json')))
        scalar_path = output / (key + '-scalars-config.json')
        scalar_path.write_text(json.dumps(scalar_config, indent=2) + '\n')
        scalar_script = output / (key + '-scalars.lldb')
        scalar_script.write_text('command script import ' + json.dumps(str(HERE / 'lldb_session.py')) + '\n'
            + 'script lldb_session.scalars(lldb.debugger, ' + repr(str(scalar_path)) + ')\nquit\n')
        scalar_transcript = run(key + '-scalars-lldb', [tools['lldb']['path'], '--no-lldbinit', '-b', '-s', scalar_script])
        assert 'LANDIN SCALAR LLDB PASSED' in scalar_transcript
        scalar_result = json.loads(Path(scalar_config['result']).read_text())
        assert scalar_result == {'status': 'passed', 'scalar_types': 13}
        print(key, 'passed', flush=True)
    # At speed, each variable read where its register still holds it past
    # its last use; registers.ldn alone runs there.
    register_results = []
    for name, opt, spec in linux.REGISTER_PROFILES:
        if args.profile and args.profile != name:
            continue
        label = 'registers-' + name
        executable = output / label
        run(label + '-compile', [args.refine.resolve(), str(linux.REGISTER_SOURCE.relative_to(ROOT)),
                                 '--target=darwin-arm64', '--debug=full', '--emit=exe', '-o', executable,
                                 '--optimize=' + opt, '--specialize=' + spec])
        run(label + '-execute', [executable], 42)
        config = {'executable': str(executable), 'source': str(linux.REGISTER_SOURCE),
                  'cwd': str(ROOT), 'lines': linux.REGISTER_LINES, 'stops': linux.REGISTER_STOPS,
                  'result': str(output / (label + '-session.json'))}
        config_path = output / (label + '-config.json')
        config_path.write_text(json.dumps(config, indent=2) + '\n')
        script = output / (label + '.lldb')
        script.write_text('command script import ' + json.dumps(str(HERE / 'lldb_session.py')) + '\n'
                          + 'script lldb_session.registers(lldb.debugger, ' + repr(str(config_path)) + ')\nquit\n')
        transcript = run(label + '-lldb', [tools['lldb']['path'], '--no-lldbinit', '-b', '-s', script])
        assert 'LANDIN REGISTER LLDB PASSED' in transcript, transcript[-6000:]
        session = json.loads(Path(config['result']).read_text())
        assert session['status'] == 'passed'
        register_results.append({'optimize': opt, 'specialize': spec, 'status': 'passed',
                                 'checks': len(session['checks'])})
        print(label, 'passed', flush=True)
    # Filename deployment is optional: no debugger artifacts are required by
    # the executable or its three-u32 caller coordinates. Default and explicit
    # none must produce identical compiler assembly and caller-only maps.
    identity_sources = output / "identity-sources"
    identity_sources.mkdir()
    for source in linux.SOURCES:
        shutil.copyfile(source, identity_sources / source.name)
    copied = [identity_sources / s.name for s in linux.SOURCES]
    plain = output / 'plain'
    plain_args = [args.refine.resolve(), *copied, '--target=darwin-arm64',
                  '--emit=exe', '-o', plain]
    run('plain-compile', plain_args)
    original_assembly = Path(str(plain) + '.s').read_bytes()
    original_table = json.loads(Path(str(plain) + '.sources.json').read_text())
    original_identity = macho_identity.match(original_table, plain)
    run('plain-none-compile', [*plain_args, '--debug=none'])
    assert Path(str(plain) + '.s').read_bytes() == original_assembly
    assert json.loads(Path(str(plain) + '.sources.json').read_text()) == original_table
    assert len(original_table['files']) == 1 and original_table['files'][0]['file_id'] == 2
    assert not Path(str(plain) + '.dSYM').exists()
    #  D361: names only in trap reports, and only logical ones.
    deployed = linux.deployed_source_names(plain.read_bytes(), copied)
    assert not deployed, deployed
    run('plain-execute', [plain], 42)
    shutil.copyfile(plain, output / 'before-comment')
    (output / 'before-comment.sources.json').write_text(json.dumps(original_table))
    # A trailing comment changes no source coordinates or machine operations.
    copied[1].write_bytes(copied[1].read_bytes() + b'\n-- identity-only change\n')
    run('comment-compile', plain_args)
    changed = json.loads(Path(str(plain) + '.sources.json').read_text())
    changed_identity = macho_identity.match(changed, plain)
    assert changed_identity['build_id'] != original_identity['build_id']
    assert changed_identity['uuid'] != original_identity['uuid']
    try:
        macho_identity.match(original_table, plain)
    except ValueError:
        pass
    else:
        raise AssertionError('comment-only mismatch accepted')
    run('comment-execute', [plain], 42)
    if len(results) > 1:
        left = output / 'none-off'
        wrong_dsym = output / 'size-auto.dSYM/Contents/Resources/DWARF/size-auto'
        try:
            macho_identity.match(json.loads(Path(str(left) + '.sources.json').read_text()), left, wrong_dsym)
        except ValueError:
            pass
        else:
            raise AssertionError('mismatched dSYM accepted')
        refusal = run('lldb-dsym-mismatch', [tools['lldb']['path'], '--no-lldbinit', '-b',
            '-o', 'target create ' + json.dumps(str(left)),
            '-o', 'target symbols add ' + json.dumps(str(wrong_dsym)), '-o', 'quit'], 1)
        refusal += (output / 'lldb-dsym-mismatch.stderr').read_text()
        assert 'does not match' in refusal or 'unable to find' in refusal, refusal
    (output / 'identity-checks.json').write_text(json.dumps({
        'default_none': 'passed', 'caller_only': 'passed', 'optional_filenames': 'passed',
        'comment_mismatch': 'passed', 'dsym_mismatch': 'passed' if len(results) > 1 else 'filtered'
    }, indent=2) + '\n')
    for tool in tools.values():
        assert digest(tool['path']) == tool['sha256'], 'tool changed during acceptance'
    summary = {'scope': 'source-debugging', 'status': 'passed', 'filtered': args.profile is not None,
               'refine_sha256': digest(args.refine), 'tools': tools, 'results': results,
               'registers': register_results,
               'panic': panic_evidence,
               'switch': switch_results,
               'sources': {str(s.relative_to(ROOT)): digest(s) for s in all_sources}}
    (output / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')


if __name__ == '__main__':
    main()
