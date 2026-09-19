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

    def test_an_owner_must_be_live_and_named(self):
        row = self.row("0150")
        self.refused(self.problems({row: row.replace("| R7.20 |", "| R2.20 |")}),
                     "still owned by finished R2.20")
        self.refused(self.problems({row: row.replace("| R7.20 |", "| none |")}),
                     "refused pending R7.20 and the row does not name it")
        self.refused(self.problems({row: row.replace("| R7.20 |", "| R9.90 |")}),
                     "names missing owner R9.90")
        self.refused(self.problems({row: row.replace("| R7.20 |", "| Somebody |")}),
                     "unknown owner")

    def test_a_finished_owner_makes_the_row_stale(self):
        heading = "### R7.20 — Close deferred normative behavior\n\nStatus: planned"
        self.refused(self.problems({heading: heading.replace("planned", "complete")}),
                     "still owned by finished R7.20")

    def test_phase_must_be_finished_implementation(self):
        row = self.row("0010")
        self.refused(self.problems({row: row.replace("| R1.20 |", "| R7.20 |")}),
                     "no finished implementing phase")

    def test_gaps_follow_the_corpus_both_ways(self):
        def lose(targets):
            targets["0010"].pop("cortex-m")
        self.refused(self.problems(targets=lose),
                     "[0010] records gaps none; the corpus leaves cortex-m")

        def gain(targets):
            targets["1860"]["cortex-m"] = "refused"
        self.refused(self.problems(targets=gain),
                     "[1860] records gaps cortex-m; the corpus leaves none")

    def test_a_gap_needs_an_owning_item(self):
        row = self.row("1860")
        self.refused(self.problems({row: row.replace("| R7.40 |", "| none |")}),
                     "target gaps and no owning item")

    def test_a_compiled_row_that_executes_is_stale(self):
        def run(targets):
            targets["1400"]["linux-x86-64"] = "executed"
        self.refused(self.problems(targets=run), "executes, so compiled is stale")

    def test_advisory_and_deferred_rows_carry_no_evidence(self):
        def claim(evidence):
            evidence["0490"] = {"accepted", "emitted"}
        self.refused(self.problems(evidence=claim),
                     "[0490] is advisory but fixtures claim it")

        def claim_deferred(targets):
            targets["0620"] = {"linux-x86-64": "compiled"}
        self.refused(self.problems(targets=claim_deferred),
                     "[0620] is deferred but fixtures claim it")

    def test_deferral_and_transfer_are_the_tour_s_first(self):
        def undefer(paragraphs):
            paragraphs["0620"] = paragraphs["0620"].replace("DEFERRED", "Deferred")
        self.refused(self.problems(paragraphs=undefer),
                     "deferred but the tour does not say so")

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

        row = self.row("0850")
        self.refused(self.problems({row: row.replace("| R7.20 |", "| none |")}),
                     "still promises finished R6.80")

        def boundary(refusals):
            refusals.append(("0010", "R7.20", "boundary", "table", "Probe"))
        self.refused(self.problems(refusals=boundary),
                     "boundary refusal names unfinished R7.20")

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
                         ("0850", "R6.80", "pending"),
                         ("0660", "R7.20", "pending")):
            self.assertIn(expected, wording)
        self.assertEqual(len(self.inputs["refusals"]), 21)

    def test_target_records_decide_where_a_fixture_runs(self):
        held = self.inputs["targets"]
        #  Darwin runs a native replacement for a Linux-only archive fixture,
        #  the firmware driver runs outside the hosted harness, and a
        #  hosted-only compile-time rule has no Cortex-M verdict at all.
        self.assertEqual(held["1590"]["macos-arm64"], "executed")
        self.assertEqual(held["1590"]["cortex-m"], "refused")
        self.assertEqual(held["1570"]["cortex-m"], "executed")
        self.assertEqual(held["1630"]["linux-x86-64"], "compiled")
        self.assertNotIn("cortex-m", held["1860"])


if __name__ == "__main__":
    unittest.main()
