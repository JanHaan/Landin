"""Schema-4 selection over the frozen full hosted schema-3 coverage contract."""
import tempfile
from pathlib import Path

from common import archive_inventory, file_hash, read_json, require, validate_policy as linux_policy
from darwin import validate_policy, validate_debugging
from darwin_parity import (validate_runtime, validate_diagnostics,
                           validate_bindings, validate_workloads)


def compatible(policy, linux):
    validate_policy(policy)
    linux_policy(linux)
    require(policy['schema'] == 4 and linux['schema'] == 2
            and policy['scope'] == linux['scope']
            and policy['debugger'] == linux['debugger'],
            'incompatible dual-native acceptance scope')


def validate(bundle, record):
    from macos_environment import harness_result
    policy = record['policy']
    with tempfile.TemporaryDirectory(prefix='landin-scoped-verify-') as temporary:
        source = Path(temporary) / 'source'
        archive_inventory((bundle / 'source.tar.gz').read_bytes(), source)
        compatible(policy, read_json(source / 'scripts/ci/policy.json'))
        source_path = Path(record['paths']['source'])
        for mode in policy['modes']:
            directory = bundle / mode
            for name in ('refine', 'source-manifest.txt', 'configuration.cgpr'):
                require((directory / name).is_file(), 'missing compiler mode identity')
            compiler_hash = file_hash(directory / 'refine')
            command = ['env', 'LANDIN_BUILD_MODE=' + mode, './scripts/test.sh', '--host']
            index = policy['commands'].index(command)
            harness_result(0, (bundle / f'evidence/step-{index}.stdout').read_text(), host_only=True)
            compiler = Path(record['paths']['{refine-' + mode + '}'])
            if mode in policy['hosted_modes']:
                validate_runtime(directory / 'executions', source, compiler_hash, source_path,
                                 Path(record['paths']['{executions-' + mode + '}']), compiler)
                validate_diagnostics(directory / 'diagnostics', source, compiler_hash, source_path, compiler)
                validate_bindings(directory / 'bindings', source, source_path, compiler_hash, compiler,
                                  Path(record['paths']['{bindings-' + mode + '}']))
            if mode in policy['debugger_modes']:
                local_record = {**record, 'files': {name.removeprefix(mode + '/'): digest
                                for name, digest in record['files'].items() if name.startswith(mode + '/')}}
                validate_debugging(directory, local_record)
                validate_workloads(directory / 'debugging', source, source_path, record, mode)
