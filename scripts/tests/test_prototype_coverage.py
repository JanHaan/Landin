#!/usr/bin/env python3
"""Tiny malformed controls for the derivation inputs, outputs and results.

Every prototype derivation row carries three generated columns.  The
decision that makes them worth having is that all three are derived from
committed records rather than asserted beside them, and that decision is only
true while something refuses a row whose derivation has gone empty, stale or
unbacked.  The editor grammar drifted precisely because no gate ran, so
each control here alters one input -- a fixture's record, a golden, a target
record or a firmware derivation's oracle -- and requires `prototype_result_problems` to
name the resulting row.  The unaltered repository must produce none.

These controls never run a compiler, an emulator or a debugger.  They check
that the coverage register cannot lie, not that a program works; the runtime,
quality, debugger and embedded lanes own behaviour.
"""
import copy
import importlib.util
from pathlib import Path
import tempfile
import unittest
import unittest.mock


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("landin_check", ROOT / "check.py")
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)

PARSER = "runtime/derived-parser"
DRIVER = "firmware/derived-driver"
COUNTERPART = "firmware/derived-counterpart"
FIRMWARE = [one.name for one in CHECK.FIRMWARE_DERIVATIONS]
NEGATIVE = "negative/r470-container-entry-live-map"


class Derivations(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.rows = CHECK.prototype_rows()
        cls.records = CHECK.prototype_evidence_records()
        cls.claims = CHECK.fixture_target_claims()
        cls.scopes = CHECK.target_scope_rows()

    def problems(self, records=None, claims=None):
        """`prototype_result_problems` over possibly altered inputs."""
        records = self.records if records is None else records
        claims = self.claims if claims is None else claims
        with unittest.mock.patch.object(CHECK, "fixture_target_claims",
                                        return_value=claims):
            return [message for _, _, message
                    in CHECK.prototype_result_problems(self.rows, records)]

    def altered(self, fixture, **changes):
        """A copy of the records with one fixture's fields changed.

        A field set to None is removed, which is how a record that stopped
        naming its program, status or oracle is modelled.
        """
        records = copy.deepcopy(self.records)
        meta, fields = records[fixture]
        for key, value in changes.items():
            if value is None:
                fields.pop(key, None)
            else:
                fields[key] = value
        records[fixture] = (meta, fields)
        return records

    def scope_problems(self, claims=None):
        """`prototype_scope_problems` over possibly altered target records."""
        claims = self.claims if claims is None else claims
        with unittest.mock.patch.object(CHECK, "fixture_target_claims",
                                        return_value=claims):
            return [message for _, _, message in CHECK.prototype_scope_problems(
                self.rows, self.scopes, self.records)]

    def refused(self, messages, fragment):
        self.assertTrue(any(fragment in message for message in messages),
                        "%r not in %r" % (fragment, messages))

    #  ------------------------------------------------------------ the tree
    def test_the_repository_derivations_are_complete(self):
        self.assertEqual(self.problems(), [])

    def test_every_row_renders_all_three_columns(self):
        for _, row in self.rows:
            name = row["Fixture"].strip("`")
            fields = self.records[name][1]
            inputs, outputs, results = CHECK.prototype_row_evidence(name, fields)
            for label, value in (("inputs", inputs), ("outputs", outputs),
                                 ("results", results)):
                self.assertNotEqual(value, "-", "%s has no %s" % (name, label))

    #  ------------------------------------------------------------- inputs
    def test_a_row_that_names_no_input_is_refused(self):
        self.refused(self.problems(self.altered(PARSER, program=None)),
                     "derivation runtime/derived-parser names no program")
        self.refused(self.problems(self.altered(
            PARSER, program=None, root=None, run_files=None)),
            "derivation runtime/derived-parser records no inputs")
        self.refused(self.problems(self.altered(
            DRIVER, source=None, driver=None, protocol=None, layout=None)),
            "derivation firmware/derived-driver records no inputs")
        self.refused(self.problems(self.altered(
            COUNTERPART, source=None, board=None, tick=None, protocol=None)),
            "derivation firmware/derived-counterpart records no inputs")

    def test_an_input_the_record_stops_naming_leaves_the_column(self):
        inputs, _, _ = CHECK.prototype_row_evidence(
            PARSER, self.altered(PARSER, run_files=None)[PARSER][1])
        self.assertNotIn("run_files", inputs)
        self.assertIn("main.ldn", inputs)

    #  ------------------------------------------------------------ outputs
    def test_a_row_that_names_no_oracle_is_refused(self):
        self.refused(self.problems(self.altered(
            PARSER, status=None, run_expect=None)),
            "derivation runtime/derived-parser records no outputs")
        self.refused(self.problems(self.altered(DRIVER, oracle=None)),
                     "derivation firmware/derived-driver records no outputs")
        self.refused(self.problems(self.altered(COUNTERPART, oracle=None)),
                     "derivation firmware/derived-counterpart records no outputs")

    def test_an_absent_golden_is_refused_rather_than_skipped(self):
        self.refused(self.problems(self.altered(PARSER, run_expect="absent.txt")),
                     "derivation runtime/derived-parser names an absent oracle")

    def test_a_changed_golden_moves_the_digest(self):
        """An edited expected output must not survive in the same column."""
        path = ROOT / "compiler/tests/fixtures" / PARSER / "output.txt"
        original = CHECK.golden_digest(str(path.relative_to(ROOT)))
        self.assertIsNotNone(original)
        data = path.read_bytes()
        try:
            path.write_bytes(data + b"drift\n")
            self.assertNotEqual(CHECK.golden_digest(
                str(path.relative_to(ROOT))), original)
        finally:
            path.write_bytes(data)
        self.assertEqual(CHECK.golden_digest(
            str(path.relative_to(ROOT))), original)

    def test_a_changed_status_or_code_list_moves_the_column(self):
        _, outputs, _ = CHECK.prototype_row_evidence(
            NEGATIVE, self.altered(NEGATIVE, codes="L0315")[NEGATIVE][1])
        self.assertEqual(outputs, "refused status 1; codes L0315")
        _, outputs, _ = CHECK.prototype_row_evidence(
            PARSER, self.altered(PARSER, status="0")[PARSER][1])
        self.assertTrue(outputs.startswith("status 0"))

    #  ------------------------------------------------------------ results
    def test_a_row_no_target_record_places_is_refused(self):
        claims = copy.deepcopy(self.claims)
        claims.pop(PARSER)
        messages = self.problems(claims=claims)
        self.refused(messages,
                     "derivation runtime/derived-parser records no target results")
        self.refused(messages, "claims linux-x86-64 and no record places it")

    def test_a_target_claimed_without_a_record_is_refused(self):
        claims = copy.deepcopy(self.claims)
        del claims[PARSER]["darwin-arm64"]
        self.refused(self.problems(claims=claims),
                     "derivation runtime/derived-parser claims darwin-arm64"
                     " and no record places it")

    def test_synthetic_32_is_never_a_target_result(self):
        for _, row in self.rows:
            name = row["Fixture"].strip("`")
            _, _, results = CHECK.prototype_row_evidence(
                name, self.records[name][1])
            self.assertNotIn("synthetic-32", results, name)
        #  The model that preceded Cortex-M applies to no construct, so the
        #  column must not report a verdict under it even when one is offered.
        claims = copy.deepcopy(self.claims)
        claims[NEGATIVE]["synthetic-32"] = "executed"
        with unittest.mock.patch.object(CHECK, "fixture_target_claims",
                                        return_value=claims):
            _, _, results = CHECK.prototype_row_evidence(
                NEGATIVE, self.records[NEGATIVE][1])
        self.assertNotIn("synthetic-32", results)
        self.assertEqual(results,
                         "linux-x86-64=refused, linux-arm64=refused,"
                         " darwin-arm64=refused, freebsd-x86-64=refused,"
                         " freebsd-arm64=refused, linux-rv64=refused")

    def test_a_recorded_cortex_refusal_is_reported_rather_than_dropped(self):
        """The hosted derivatives' Cortex verdict is a result, not a silence.

        Prototype coverage does not demand a hosted I/O program on Cortex-M,
        and the corpus records why each complete hosted derivative is refused there.
        Reporting that refusal is what distinguishes a recorded scope
        decision from a row nobody looked at.
        """
        for name in (PARSER, "runtime/derived-containers",
                     "runtime/derived-hosted-memory"):
            _, _, results = CHECK.prototype_row_evidence(
                name, self.records[name][1])
            self.assertIn("cortex-m0=refused", results, name)

    #  ---------------------------------------------------- scope backing
    def test_every_scope_claim_is_reached_by_one_of_its_derivations(self):
        self.assertEqual(self.scope_problems(), [])

    def test_a_scope_claim_no_derivation_reaches_is_refused(self):
        """prototype-3's Cortex claim is reached by nine of its own rows.

        Take the corpus records those rows read away and the claim has
        nothing behind it, which is the case this rule exists for.
        """
        claims = copy.deepcopy(self.claims)
        for reached in claims.values():
            reached.pop("cortex-m0", None)
        self.refused(self.scope_problems(claims=claims),
                     "prototype-3 claims cortex-m0 and no derivation of it"
                     " reaches that target")
        self.refused(self.scope_problems(claims=claims),
                     "prototype-1 claims cortex-m0 and no derivation of it"
                     " reaches that target")

    def test_rows_may_reach_further_than_a_scope_row_claims(self):
        """The recorded relationship, kept from being quietly reversed.

        prototype-1's scope is Cortex-M while two of its derivations are
        hosted, and prototype 2 and 4 rows carry Cortex verdicts their scope
        rows do not name.  That direction is deliberate and must stay clean.
        """
        self.assertEqual(self.scope_problems(), [])
        reached = set()
        for _, row in self.rows:
            if row["Prototype"].strip("`Pp ") != "1":
                continue
            name = row["Fixture"].strip("`")
            _, _, results = CHECK.prototype_row_evidence(
                name, self.records[name][1])
            reached |= {one.split("=")[0]
                        for one in results.split(", ") if "=" in one}
        self.assertEqual(reached, {"cortex-m0", "linux-x86-64", "linux-arm64",
                                   "darwin-arm64", "freebsd-x86-64",
                                   "freebsd-arm64", "linux-rv64"})

    #  ------------------------------------------------------- driver oracle
    def test_a_driver_oracle_the_runner_does_not_define_is_refused(self):
        self.refused(self.problems(self.altered(DRIVER, oracle="not_a_routine")),
                     "oracle not_a_routine is not a routine in")
        self.refused(self.problems(self.altered(DRIVER, runner="")),
                     "is not a routine in nothing")

    def test_each_named_driver_oracle_is_a_routine_today(self):
        fields = self.records[DRIVER][1]
        named = [one.strip() for one in fields["oracle"].split(",")]
        self.assertTrue(named)
        source = (ROOT / fields["runner"]).read_text(encoding="utf-8")
        for oracle in named:
            self.assertIn("\ndef %s(" % oracle, source, oracle)

    #  -------------------------------------------- every firmware derivation
    def firmware_problems(self, records=None, mandatory=None):
        """`firmware_derivation_problems` over possibly altered inputs."""
        records = self.records if records is None else records
        if mandatory is None:
            mandatory = (ROOT / "environments/cortex-m/run.py").read_text(
                encoding="utf-8")
        return [message for _, _, message
                in CHECK.firmware_derivation_problems(records, mandatory)]

    def test_the_table_names_both_firmware_derivations(self):
        """The driver stays registered beside the counterpart, not replaced."""
        self.assertEqual(FIRMWARE, [DRIVER, COUNTERPART])

    def test_every_firmware_derivation_is_a_record_and_a_row(self):
        named = {row["Fixture"].strip("`") for _, row in self.rows}
        for name in FIRMWARE:
            self.assertIn(name, self.records, name)
            self.assertIn(name, named, name)
            self.assertIn("cortex-m0", self.claims.get(name, {}), name)

    def test_the_repository_firmware_derivations_are_complete(self):
        self.assertEqual(self.firmware_problems(), [])

    def test_a_counterpart_oracle_the_runner_does_not_define_is_refused(self):
        self.refused(self.problems(self.altered(
            COUNTERPART, oracle="judge, not_a_routine")),
            "oracle not_a_routine is not a routine in"
            " environments/cortex-m/counterpart.py")
        self.refused(self.problems(self.altered(COUNTERPART, runner="")),
                     "is not a routine in nothing")

    def test_each_named_firmware_oracle_is_a_routine_today(self):
        for name in FIRMWARE:
            fields = self.records[name][1]
            named = [one.strip() for one in fields["oracle"].split(",")]
            self.assertTrue(named, name)
            source = (ROOT / fields["runner"]).read_text(encoding="utf-8")
            for oracle in named:
                self.assertIn("\ndef %s(" % oracle, source,
                              "%s: %s" % (name, oracle))

    def test_the_inputs_column_follows_the_table(self):
        for one in CHECK.FIRMWARE_DERIVATIONS:
            fields = self.records[one.name][1]
            inputs, _, _ = CHECK.prototype_row_evidence(one.name, fields)
            self.assertEqual(inputs, "; ".join(fields[field]
                                               for field in one.inputs))

    def test_a_required_file_that_is_gone_is_refused(self):
        for one in CHECK.FIRMWARE_DERIVATIONS:
            for field in one.inputs + one.files:
                self.refused(self.firmware_problems(self.altered(
                    one.name, **{field: "absent/" + field})),
                    "%s derivation lacks %s" % (one.what, field))
                self.refused(self.firmware_problems(self.altered(
                    one.name, **{field: None})),
                    "%s derivation lacks %s" % (one.what, field))

    def test_a_lane_run_py_does_not_call_is_refused(self):
        mandatory = (ROOT / "environments/cortex-m/run.py").read_text(
            encoding="utf-8")
        for one in CHECK.FIRMWARE_DERIVATIONS:
            self.assertIn(one.lane, mandatory)
            self.refused(self.firmware_problems(
                mandatory=mandatory.replace(one.lane, "skipped()")),
                "%s evidence is not in the mandatory lane" % one.what)

    def test_a_mapping_no_live_document_check_reads_is_refused(self):
        for one in CHECK.FIRMWARE_DERIVATIONS:
            mapping = self.records[one.name][1]["mapping"]
            self.assertIn(mapping, CHECK.LIVE_DOCS)
            live = [doc for doc in CHECK.LIVE_DOCS if doc != mapping]
            with unittest.mock.patch.object(CHECK, "LIVE_DOCS", live):
                self.refused(self.firmware_problems(),
                             "%s derivation's mapping %s is no live document"
                             % (one.what, mapping))

    def test_every_derivation_map_is_a_live_document_by_its_name(self):
        #  The list was kept by hand, and four hosted maps were in no
        #  live-document check.  Every tracked map is one now.
        maps = sorted(path.relative_to(ROOT).as_posix() for path in
                      (ROOT / "compiler/tests").rglob("DERIVATION.md"))
        self.assertGreaterEqual(len(maps), 6)
        for name in maps:
            self.assertIn(name, CHECK.LIVE_DOCS)
        for name in ("derived-parser", "derived-containers",
                     "derived-hosted-memory", "derived-server-two-process"):
            self.assertIn("compiler/tests/fixtures/runtime/%s/DERIVATION.md"
                          % name, maps)
        #  And the next one is, without an edit to check.py.
        with tempfile.TemporaryDirectory() as directory:
            new = Path(directory, "compiler/tests/fixtures/runtime/new-one")
            new.mkdir(parents=True)
            (new / "DERIVATION.md").write_text("# A map\n")
            (new / "README.md").write_text("# Not a map\n")
            with unittest.mock.patch.object(CHECK, "ROOT", directory):
                self.assertEqual(
                    CHECK.derivation_maps(),
                    ["compiler/tests/fixtures/runtime/new-one/DERIVATION.md"])

    def test_an_absent_record_is_refused(self):
        for one in CHECK.FIRMWARE_DERIVATIONS:
            records = copy.deepcopy(self.records)
            del records[one.name]
            self.refused(self.firmware_problems(records),
                         "%s derivation's record %s is not here"
                         % (one.what, one.record))


if __name__ == "__main__":
    unittest.main(verbosity=0)
