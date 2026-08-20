# Deliberately malformed harness cases

These trees exist to be rejected. `compiler/ada/tests/src/landin-tests-fixture_suite.adb`
discovers `malformed/` and asserts that every fault below is reported and that
no fixture in it is accepted.

| case | fault |
|---|---|
| `unit/no-metadata` | a fixture directory with no `fixture.meta` |
| `unit/unknown-key` | a key the format does not define |
| `unit/duplicate-key` | one key given twice |
| `unit/missing-summary` | a required key omitted |
| `unit/wrong-class` | `class:` disagrees with the directory |
| `unit/not-a-pair` | a line that is not `key: value` |
| `unit/unknown-target` | `targets:` names a target the roadmap never named |
| `unit/stray.txt` | a plain file where a fixture directory belongs |

Nothing here is a Landin program, and nothing here is expected to pass.
