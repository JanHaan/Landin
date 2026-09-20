#!/usr/bin/env python3
"""Tiny malformed controls for R7.10's construct inventory.

Each control alters one input the inventory is generated from -- a register
row, a fixture's target evidence, a refusal or a tour paragraph -- and
requires `inventory_problems` to name the resulting missing, stale, unowned
or unexplained row.  The unaltered repository must produce none.
"""
import copy
import importlib.util
from pathlib import Path
import unittest
import unittest.mock


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("landin_check", ROOT / "check.py")
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)


class Inventory(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.inputs = CHECK.inventory_inputs()

    def row(self, construct):
        prefix = "| `[%s]` |" % construct
        text = self.inputs["roadmap"]
        inventory = text[text.index(CHECK.INVENTORY_HEADING):]
        return next(line for line in inventory.splitlines()
                    if line.startswith(prefix))

    def problems(self, replace=None, **changes):
        inputs = copy.deepcopy(self.inputs)
        for old, new in (replace or {}).items():
            self.assertIn(old, inputs["roadmap"])
            inputs["roadmap"] = inputs["roadmap"].replace(old, new, 1)
        for key, change in changes.items():
            change(inputs[key])
        return [message for _, _, message in CHECK.inventory_problems(inputs)]

    def refused(self, messages, fragment):
        self.assertTrue(any(fragment in message for message in messages),
                        "%r not in %r" % (fragment, messages))

    def test_the_repository_inventory_is_complete(self):
        self.assertEqual(self.problems(), [])

    def test_missing_and_duplicate_rows(self):
        row = self.row("0010")
        self.refused(self.problems({row + "\n": ""}),
                     "construct [0010] has no inventory row")
        self.refused(self.problems({row: row + "\n" + row}),
                     "[0010] has two inventory rows")

    def test_closed_vocabularies(self):
        row = self.row("0010")
        self.refused(self.problems({row: row.replace("| executed |", "| done |")}),
                     "unknown state")
        self.refused(self.problems({row: row.replace("| all |", "| hosts |")}),
                     "unknown targets")

    def gapped(self):
        """[1860] as it stood before R7.40 supplied its Cortex-M verdict.

        No row has a gap or a live roadmap owner after R7.40, so the rules
        about both are kept exercised by rebuilding the row that had them:
        clean as written against `without_cortex`, and refused once the
        owner finishes, goes missing or stops being named.
        """
        row = self.row("1860")
        return {row: "| `[1860]` | compiled | all | cortex-m | R1.50 | R7.70 |"
                     " Hosted compile-time rule audited by R4.90; R7.70 stands"
                     " here for the owner a recorded gap needs. |"}

    @staticmethod
    def without_cortex(targets):
        targets["1860"].pop("cortex-m")

    def test_an_owner_must_be_live_and_named(self):
        (row, synthetic), = self.gapped().items()
        self.assertEqual(self.problems(self.gapped(),
                                       targets=self.without_cortex), [])
        for owner, fragment in (("R2.20", "still owned by finished R2.20"),
                                ("R9.90", "names missing owner R9.90"),
                                ("Somebody", "unknown owner")):
            self.refused(self.problems(
                {row: synthetic.replace("| R7.70 |", "| %s |" % owner)},
                targets=self.without_cortex), fragment)
        self.refused(self.problems(
            {row: synthetic.replace("R7.70 stands", "nobody stands")},
            targets=self.without_cortex),
            "[1860] does not say what R7.70 owns")

        def pending(refusals):
            refusals.append(("1860", "R7.70", "pending", "table", "Probe"))
        self.refused(self.problems(refusals=pending),
                     "refused pending R7.70 and the row does not name it")

    def test_a_finished_owner_makes_the_row_stale(self):
        (row, synthetic), = self.gapped().items()
        heading = ("### R7.70 — Declare the roadmap"
                   " endpoint\n\nStatus: planned")
        self.refused(self.problems(
            {row: synthetic, heading: heading.replace("planned", "complete")},
            targets=self.without_cortex),
            "still owned by finished R7.70")

    def test_phase_must_be_finished_implementation(self):
        row = self.row("0010")
        self.refused(self.problems({row: row.replace("| R1.20 |", "| R7.70 |")}),
                     "no finished implementing phase")

    def test_gaps_follow_the_corpus_both_ways(self):
        def lose(targets):
            targets["0010"].pop("cortex-m")
        self.refused(self.problems(targets=lose),
                     "[0010] records gaps none; the corpus leaves cortex-m")

        self.refused(self.problems(self.gapped()),
                     "[1860] records gaps cortex-m; the corpus leaves none")

    def test_a_gap_needs_an_owning_item(self):
        (row, synthetic), = self.gapped().items()
        self.refused(self.problems(
            {row: synthetic.replace(
                "| R7.70 | Hosted compile-time rule audited by R4.90; R7.70"
                " stands here for the owner a recorded gap needs.",
                "| none | Hosted compile-time rule audited by R4.90.")},
            targets=self.without_cortex),
            "target gaps and no owning item")

    def test_a_compiled_row_that_executes_is_stale(self):
        def run(targets):
            targets["1400"]["linux-x86-64"] = "executed"
        self.refused(self.problems(targets=run), "executes, so compiled is stale")

    def deferred(self):
        """[0620] as it stood before R7.30 transferred it: the last deferred
        construct, now a synthetic control for the deferral rules."""
        row = self.row("0620")
        return {row: "| `[0620]` | deferred | none | none | none | R7.70 |"
                     " The tour keeps it DEFERRED and R7.70 owns the decision. |"}

    def test_advisory_deferred_and_transferred_rows_carry_no_evidence(self):
        def claim(evidence):
            evidence["0490"] = {"accepted", "emitted"}
        self.refused(self.problems(evidence=claim),
                     "[0490] is advisory but fixtures claim it")

        def claim_transferred(targets):
            targets["0620"] = {"linux-x86-64": "compiled"}
        self.refused(self.problems(targets=claim_transferred),
                     "[0620] is transferred but fixtures claim it")
        self.refused(self.problems(self.deferred(), targets=claim_transferred),
                     "[0620] is deferred but fixtures claim it")

    def test_deferral_and_transfer_are_the_tour_s_first(self):
        #  No construct is deferred after R7.30, so a synthetic row keeps the
        #  deferral rules exercised: it is clean as written, and refused once
        #  the tour stops saying DEFERRED or no live item owns it.
        self.assertEqual(self.problems(self.deferred()), [])

        def undefer(paragraphs):
            paragraphs["0620"] = paragraphs["0620"].replace("DEFERRED", "Deferred")
        self.refused(self.problems(self.deferred(), paragraphs=undefer),
                     "deferred but the tour does not say so")
        (row, synthetic), = self.deferred().items()
        self.refused(self.problems({row: synthetic.replace(
            "| R7.70 | The tour keeps it DEFERRED and R7.70 owns the decision.",
            "| none | The tour keeps it DEFERRED.")}),
            "[0620] is deferred with no owning item")
        self.refused(self.problems({row: synthetic.replace("| R7.70 |", "| R7.20 |")
                                    .replace("and R7.70 owns", "and R7.20 owns")}),
                     "still owned by finished R7.20")

        #  R7.30's transfer is the tour's first: [0620] names its successor.
        def unname(paragraphs):
            paragraphs["0620"] = paragraphs["0620"].replace(
                "Language evolution", "a later roadmap")
        self.refused(self.problems(paragraphs=unname),
                     "[0620] hands work to Language evolution")

        def unmark(paragraphs):
            for one in ("1470", "1420", "1480"):
                paragraphs[one] = paragraphs[one].replace(
                    "companion tool", "other tool")
        self.refused(self.problems(paragraphs=unmark),
                     "hands work to Companion tool and ecosystem")

        row = self.row("1470")
        self.refused(self.problems({row: row.replace(
            "| Companion tool and ecosystem |", "| R7.20 |")}),
            "transferred to no successor")

    def test_every_refusal_is_explained(self):
        row = self.row("0820")
        self.refused(self.problems({row: row.replace("R4.80", "the withdrawal")}),
                     "does not explain its refusal recorded by R4.80")

        #  R7.40 turned [1350]'s note from a promise into a boundary and
        #  removed [1580]'s entry outright, so no refusal promises a finished
        #  item any more; the control supplies one.
        def promised(refusals):
            refusals.append(("1350", "R2.40", "pending", "table", "Probe"))
        self.refused(self.problems(refusals=promised),
                     "still promises finished R2.40")

        def boundary(refusals):
            refusals.append(("0010", "R7.70", "boundary", "table", "Probe"))
        self.refused(self.problems(refusals=boundary),
                     "boundary refusal names unfinished R7.70")

    def test_a_transfer_names_its_successor(self):
        #  R7.20's transfers: the tour names each successor, and a refusal
        #  that says it transfers a form needs the row to hand it over.
        def unmark(paragraphs):
            paragraphs["0150"] = paragraphs["0150"].replace(
                "Language evolution", "a later roadmap")
        self.refused(self.problems(paragraphs=unmark),
                     "[0150] hands work to Language evolution")

        row = self.row("0170")
        self.refused(self.problems({row: row.replace(
            "| Language evolution |", "| none |")}),
            "[0170]'s refusal transfers it and the row hands work to no"
            " successor")

        row = self.row("1620")
        self.refused(self.problems({row: row.replace(
            "| Broader standard library |", "| Somebody |")}),
            "unknown owner")

    def test_owners_are_explained_in_the_row(self):
        row = self.row("0730")
        self.refused(self.problems({row: row.replace(
            "stays with Companion tool and ecosystem", "stays elsewhere")}),
            "does not say what Companion tool and ecosystem owns")

    def test_compiled_hosted_rows_match_the_audited_register(self):
        line = next(line for line in self.inputs["roadmap"].splitlines()
                    if line.startswith("| `[1730]` | `positive/range-subtypes`"))
        self.refused(self.problems({line + "\n": ""}),
                     "compiled hosted row [1730] has no audited compile-time oracle")

    def test_refusal_wording_is_read_from_each_report_body(self):
        wording = {(one, item, how) for one, item, how, _, _
                   in self.inputs["refusals"]}
        for expected in (("0100", "R7.20", "boundary"),
                         ("0120", "R2.20", "boundary"),
                         ("0820", "R4.80", "withdrawn"),
                         ("0850", "R7.20", "withdrawn"),
                         ("0150", "R7.20", "transferred"),
                         ("0170", "R7.20", "transferred"),
                         ("0660", "R7.20", "boundary"),
                         ("1350", "R2.40", "boundary")):
            self.assertIn(expected, wording)
        #  R7.40 turned [1350]'s note into a boundary and removed [1580]'s
        #  entry, which nothing raised, so no refusal is `pending` now.
        self.assertNotIn("pending", {how for _, _, how in wording})
        self.assertEqual(len(self.inputs["refusals"]), 19)

    def test_target_records_decide_where_a_fixture_runs(self):
        held = self.inputs["targets"]
        #  Darwin runs a native replacement for a Linux-only archive
        #  fixture, and the firmware driver runs outside the hosted harness.
        self.assertEqual(held["1590"]["macos-arm64"], "executed")
        self.assertEqual(held["1590"]["cortex-m"], "refused")
        self.assertEqual(held["1570"]["cortex-m"], "executed")
        self.assertEqual(held["1630"]["linux-x86-64"], "compiled")
        #  R7.40's two new Cortex-M records.  A compile-time fixture that
        #  selects --target=cortex-m0 carries its verdict there, and R6.60's
        #  machine probe carries [1610]'s link names, which no fixture claims.
        self.assertEqual(held["1860"]["cortex-m"], "refused")
        self.assertEqual(held["1730"]["cortex-m"], "compiled")
        self.assertEqual(held["1610"]["cortex-m"], "executed")

    def test_a_cortex_claim_must_be_the_run_that_was_made(self):
        """R7.40's own rule, without which the column is editable prose."""
        self.assertEqual(CHECK.cortex_target_problems(), [])
        records = CHECK.fixture_records()
        #  The two halves of [1860]'s evidence: the hosted fixture selects no
        #  target, and R7.40's sibling selects the one it names.
        self.assertTrue(CHECK.selects_cortex_target(
            records["negative/r740-cortex-name-declared-nowhere"][1]))
        self.assertFalse(CHECK.selects_cortex_target(
            records["negative/name-declared-nowhere"][1]))

    def test_a_probe_may_only_attribute_what_a_runner_runs(self):
        titles = CHECK.construct_titles() or ()
        self.assertEqual(CHECK.cortex_probe_problems(titles), [])
        probe, = CHECK.cortex_probe_records()
        for change, fragment in (
                ({"source": "environments/cortex-m/probes/nothing.ldn"},
                 "names a source that is not here"),
                ({"runner": "environments/cortex-m/devices.py"},
                 "and it does not name it"),
                ({"targets": "linux-x86-64"},
                 "is Cortex-M evidence and says otherwise"),
                ({"evidence": "   "}, "attributes evidence and says none"),
                ({"constructs": "9999"}, "which no document defines")):
            broken = dict(probe, **change)
            with unittest.mock.patch.object(
                    CHECK, "cortex_probe_records", lambda: [broken]):
                self.refused([message for _, _, message
                              in CHECK.cortex_probe_problems(titles)], fragment)


if __name__ == "__main__":
    unittest.main()
