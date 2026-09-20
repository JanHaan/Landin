"""Schema-4 mode selection, cross-policy refusal and frozen oracle controls."""
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts/ci'))
import common
import darwin
import darwin_parity
import darwin_scoped
import darwin_oracles_v3


class ScopedTests(unittest.TestCase):
    def test_modes_and_compatible_policies(self):
        for scope, debugger, hosted, debugging in (
                ('routine', False, ['release'], []),
                ('routine', True, ['release'], ['release']),
                ('milestone', False, ['debug', 'release'], ['debug', 'release'])):
            policy = darwin.scoped_policy(scope, debugger)
            darwin_scoped.compatible(policy, common.required_policy(scope, debugger))
            self.assertEqual(policy['hosted_modes'], hosted)
            self.assertEqual(policy['debugger_modes'], debugging)
            #  Two per mode are R7.50's determinism contract and its controls.
            self.assertEqual(len(policy['commands']),
                             4 + 2 * len(policy['modes'])
                             + 3 * len(hosted) + len(debugging))
            for mode in ('debug', 'release'):
                self.assertIn(['env', 'LANDIN_BUILD_MODE=' + mode, './scripts/test.sh', '--host'], policy['commands'])

    def test_scope_mode_debugger_and_command_substitution(self):
        original = darwin.scoped_policy('routine', True)
        for key, value in (('schema', 4.0), ('scope', 'milestone'), ('debugger', False),
                           ('debugger', 1), ('modes', ['release']), ('hosted_modes', []),
                           ('debugger_modes', []), ('commands', original['commands'][:-1]),
                           ('commands', [['true']])):
            policy = dict(original, **{key: value})
            with self.subTest(key=key, value=value), self.assertRaises(common.Invalid):
                darwin.validate_policy(policy)
        for linux in (common.required_policy('routine'), common.required_policy('milestone'),
                      common.required_policy()):
            with self.assertRaises(common.Invalid):
                darwin_scoped.compatible(original, linux)

    def test_committed_pair(self):
        darwin_scoped.compatible(common.read_json(ROOT / darwin.MARKER),
                                 common.read_json(ROOT / 'scripts/ci/policy.json'))

    def test_each_selected_mode_reaches_full_validators(self):
        for scope, debugger in (('routine', False), ('routine', True), ('milestone', True)):
            with self.subTest(scope=scope, debugger=debugger), tempfile.TemporaryDirectory() as tmp:
                bundle = Path(tmp)
                policy = darwin.scoped_policy(scope, debugger)
                record = dict(policy=policy, paths={'source': '/source'}, files={})
                (bundle / 'source.tar.gz').write_bytes(b'archive')
                (bundle / 'evidence').mkdir()
                for mode in policy['modes']:
                    (bundle / mode).mkdir()
                    for name in ('refine', 'source-manifest.txt', 'configuration.cgpr'):
                        (bundle / mode / name).write_text('identity')
                    for name in ('refine', 'executions', 'bindings', 'debugging'):
                        record['paths']['{' + name + '-' + mode + '}'] = '/' + mode + '/' + name
                    index = policy['commands'].index(['env', 'LANDIN_BUILD_MODE=' + mode, './scripts/test.sh', '--host'])
                    (bundle / f'evidence/step-{index}.stdout').write_text('HOST-ONLY compiler checks; target workload emission/execution excluded\ncases 1, passed 1, failed 0, checks 1\n')
                def unpack(data, source):
                    (source / 'scripts/ci').mkdir(parents=True)
                    (source / 'scripts/ci/policy.json').write_text(json.dumps(common.required_policy(scope, debugger)))
                from contextlib import ExitStack
                with ExitStack() as stack:
                    stack.enter_context(patch.object(darwin_scoped, 'archive_inventory', side_effect=unpack))
                    validators = {name: stack.enter_context(patch.object(darwin_scoped, 'validate_' + name))
                                  for name in ('runtime', 'diagnostics', 'bindings', 'debugging', 'workloads')}
                    darwin_scoped.validate(bundle, record)
                    for name, validator in validators.items():
                        modes = policy['debugger_modes' if name in ('debugging', 'workloads') else 'hosted_modes']
                        self.assertEqual(validator.call_count, len(modes))
                    # Required coverage failure propagates, even with other successful consumers.
                    validators['runtime'].side_effect = common.Invalid('missing profile')
                    with self.assertRaises(common.Invalid):
                        darwin_scoped.validate(bundle, record)
                    validators['runtime'].side_effect = None
                    (bundle / 'debug/refine').unlink()
                    with self.assertRaises(common.Invalid):
                        darwin_scoped.validate(bundle, record)

    def test_schema3_still_requires_archived_milestone(self):
        with tempfile.TemporaryDirectory() as tmp:
            bundle = Path(tmp)
            (bundle / 'source.tar.gz').write_bytes(b'archive')
            def unpack(data, source):
                (source / 'scripts/ci').mkdir(parents=True)
                (source / 'scripts/ci/policy.json').write_text(json.dumps(common.required_policy('routine', True)))
            with patch.object(darwin_parity, 'archive_inventory', side_effect=unpack):
                with self.assertRaisesRegex(common.Invalid, 'R5.50 requires.*milestone'):
                    darwin_parity.validate(bundle, {})

    def test_frozen_oracles_match_live_contract_today(self):
        shared = darwin_parity.load_module('live_shared', ROOT / 'compiler/tests/debugging/check.py')
        sys.path.insert(0, str(ROOT / 'compiler/tests/debugging'))
        live = darwin_parity.load_module('live_workloads', ROOT / 'compiler/tests/debugging/darwin_workloads.py')
        live.shared = shared
        for workload in ('parser', 'containers', 'hosted'):
            self.assertEqual(darwin_oracles_v3.stops_for(workload, ROOT), live.stops_for(workload))
        with patch.object(live, 'stops_for', return_value=[]):
            self.assertTrue(darwin_oracles_v3.stops_for('parser', ROOT))


if __name__ == '__main__':
    unittest.main()
