#!/usr/bin/env python3
"""Controls for check.py's checks: each one is shown to fire.

Written after measuring that 34 of 37 checks had never been made to fail.
A check nobody has seen fail is a claim, not a check, and this repository
has already paid for that once: renaming tour.md made four of them vacuous
while the run still said `all clean`.

Each control states the property in its name, shows the check silent on a
tree that satisfies it, and shows it speaking on one that does not.  Where
a check reads content-addressed inputs the real files are copied and then
broken in one place, because a recorded sha256 cannot be invented.
"""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from check_controls import checker, faults, reasons   # noqa: E402

ORACLES = list(checker.BENCHMARK_GAME_ORACLES)


class BenchmarkGameOracles(unittest.TestCase):
    """The three correctness outputs stay byte-for-byte canonical."""

    def test_the_recorded_outputs_pass(self):
        self.assertEqual(
            faults(checker.check_benchmark_game_oracles, copied=ORACLES), [])

    def test_a_changed_byte_is_reported(self):
        def corrupt(root):
            target = root / ORACLES[0]
            target.write_bytes(target.read_bytes() + b"\n")
        with self.subTest(oracle=ORACLES[0]):
            from check_controls import tree
            with tree(copied=ORACLES) as root:
                corrupt(root)
                said = [why for _, _, why
                        in checker.check_benchmark_game_oracles(True)]
            self.assertTrue(said)
            self.assertIn("correctness oracle changed", said[0])

    def test_a_missing_oracle_is_reported_rather_than_skipped(self):
        #  The worst answer to "the file is not there" is silence: that is
        #  what absent() was written for.
        said = reasons(checker.check_benchmark_game_oracles,
                       copied=ORACLES[1:])
        self.assertTrue(said)
        self.assertIn("needed by a check", said[0])


class DocumentReachability(unittest.TestCase):
    """Every tracked document is reachable from README.md."""

    def test_a_linked_document_passes(self):
        self.assertEqual(
            faults(checker.check_document_reachability,
                   written={"README.md": "see [g](docs/g.md)\n",
                            "docs/g.md": "# G\n"}), [])

    def test_an_unlinked_document_is_reported(self):
        said = reasons(checker.check_document_reachability,
                       written={"README.md": "# Root\n",
                                "docs/orphan.md": "# Orphan\n"})
        self.assertEqual(len(said), 1)
        self.assertIn("nothing leads to it", said[0])


class NamedFiles(unittest.TestCase):
    """A document that names a repository file names one that exists."""

    def test_a_name_that_resolves_passes(self):
        self.assertEqual(
            faults(checker.check_named_files,
                   written={"README.md": "see `docs/guide.md`\n",
                            "docs/guide.md": "# Guide\n"}), [])

    def test_a_name_that_does_not_resolve_is_reported(self):
        said = reasons(checker.check_named_files,
                       written={"README.md": "see `docs/absent.md`\n"})
        self.assertTrue(any("not in the repository" in why for why in said))

    def test_the_two_directions_are_independent(self):
        #  check_named_files and check_document_reachability are opposite
        #  directions of the same edge, and neither implies the other.
        #  This tree satisfies naming and violates reachability, which is
        #  how six documents passed a clean run.
        written = {"README.md": "# Root\n", "docs/orphan.md": "# Orphan\n"}
        self.assertEqual(faults(checker.check_named_files, written=written), [])
        self.assertTrue(reasons(checker.check_document_reachability,
                                written=written))


PINS = ["environments/linux-amd64/Containerfile",
        "compiler/ada/TOOLCHAIN.md",
        "environments/pins.sh"]


class PinnedToolchain(unittest.TestCase):
    """Every file that installs or records the toolchain names the same one."""

    def test_the_real_pins_agree(self):
        self.assertEqual(
            faults(checker.check_pinned_toolchain, copied=PINS), [])

    def test_a_recipe_that_names_another_version_is_reported(self):
        from check_controls import tree
        with tree(copied=PINS) as root:
            recipe = root / PINS[0]
            recipe.write_text(
                recipe.read_text().replace("16.1.0", "16.2.0"))
            said = [why for _, _, why in checker.check_pinned_toolchain(True)]
        self.assertTrue(said)

    def test_a_missing_recipe_is_reported_rather_than_skipped(self):
        #  This check used to `return []` when the recipe or the record was
        #  absent, so renaming either made it vacuous while the run still
        #  said all clean -- the exact fault absent() exists to prevent.
        #  Found by writing this control, which is the point of writing it.
        said = reasons(checker.check_pinned_toolchain, copied=PINS[1:])
        self.assertTrue(said)
        self.assertIn("needed by a check", said[0])

    def test_a_missing_record_is_reported_rather_than_skipped(self):
        said = reasons(checker.check_pinned_toolchain,
                       copied=[PINS[0], PINS[2]])
        self.assertTrue(said)
        self.assertIn("needed by a check", said[0])


class SourceLocations(unittest.TestCase):
    """The offline decoder requires build matching and preserves path bytes."""

    def test_the_real_decoder_passes(self):
        self.assertEqual(
            faults(checker.check_source_locations,
                   copied=["scripts/source-location.py"]), [])

    def test_a_missing_decoder_is_reported_rather_than_skipped(self):
        said = reasons(checker.check_source_locations,
                       written={"README.md": "# Root\n"})
        self.assertTrue(said)
        self.assertIn("needed by a check", said[0])

    def test_a_decoder_that_stops_checking_is_reported(self):
        #  The check drives the real script with a mismatched build id and
        #  a path holding a quote and a non-UTF-8 byte. A decoder that
        #  accepted anything would pass a check that only ran it.
        from check_controls import tree
        with tree(copied=["scripts/source-location.py"]) as root:
            script = root / "scripts/source-location.py"
            script.write_text("#!/usr/bin/env python3\nimport sys\n"
                              "sys.exit(0)\n")
            said = [why for _, _, why in checker.check_source_locations(True)]
        self.assertTrue(said)


class Citations(unittest.TestCase):
    """Every construct citation resolves, and no id is defined twice."""

    def cited(self, tour, spec="# Spec\n"):
        from check_controls import tree
        with tree(written={"tour.md": tour, "spec.md": spec}) as root:
            return [why for _, _, why in checker.check_citations(
                [str(root / "tour.md"), str(root / "spec.md")])]

    def test_a_citation_with_a_definition_passes(self):
        self.assertEqual(
            self.cited("### [0010] A thing\n\nas [0010] says\n"), [])

    def test_a_citation_without_a_definition_is_reported(self):
        self.assertTrue(self.cited("### [0010] A thing\n\nas [0020] says\n"))

    def test_a_definition_in_both_documents_is_reported(self):
        #  A construct is defined in exactly one of the two. Merging the
        #  dictionaries is what makes this catch an id defined in both,
        #  which is the invariant the spec/tour split newly needed.
        self.assertTrue(
            self.cited("### [0010] A thing\n", spec="### [0010] Again\n"))

    def test_citing_nothing_passes(self):
        self.assertEqual(self.cited("# Tour\n\nprose only\n"), [])


QUALITY = ["compiler/tests/quality", "scripts/quality.sh",
           "compiler/ada/src/base/landin-optimization.ads",
           "compiler/ada/tests/src/landin-tests-fixture_execution_suite.adb",
           "compiler/tests/test_native_report_identity.py",
           "scripts/tests/test_build_inventory.py",
           "scripts/tests/test_build_lock.py",
           #  Reached through the quality checker this one runpy's.
           "scripts/build.sh", "scripts/env.sh", "environments/pins.sh",
           "compiler/ada/landin_lib.gpr", "compiler/ada/landin_common.gpr",
           "compiler/ada/refine.gpr", "compiler/tests",
           #  The quality checker reads the derived programs' own sources
           #  for routine evidence, so its reach is most of the tree.
           "examples", "core", "compiler/ada"]


class SplitSubjects(unittest.TestCase):
    """The four checks that were one.

    check_optimization_contract claimed the quality wiring and held three
    things: that, a roadmap validation, and a tour prose rule -- and the
    roadmap one in turn ran the repository's whole Python test suite. None
    could be controlled while they shared a function. Each is controlled
    here because each is now its own.
    """

    def test_the_optimization_wiring_passes(self):
        self.assertEqual(
            faults(checker.check_optimization_contract, copied=QUALITY), [])

    def test_a_dropped_runtime_profile_is_reported(self):
        from check_controls import tree
        with tree(copied=QUALITY) as root:
            harness = root / QUALITY[3]
            #  The check strips the Landin.Optimization. prefix before
            #  looking, so the file itself spells the profiles long.
            harness.write_text(harness.read_text().replace(
                "All_Eligible", "Off"))
            said = [why for _, _, why
                    in checker.check_optimization_contract(True)]
        self.assertTrue(any("runtime profile missing" in why
                            for why in said))

    def test_the_array_prose_passes(self):
        self.assertEqual(
            faults(checker.check_array_prose, copied=["tour.md"]), [])

    def test_array_prose_reviving_a_dropped_form_is_reported(self):
        from check_controls import tree
        with tree(copied=["tour.md"]) as root:
            tour = root / "tour.md"
            text = tour.read_text()
            tour.write_text(text.replace(
                "### [0590]", "### [0590]\n\nreduce_add( revived\n", 1))
            said = [why for _, _, why in checker.check_array_prose(True)]
        self.assertTrue(said)

    def test_a_missing_tour_is_reported_rather_than_skipped(self):
        said = reasons(checker.check_array_prose, copied=["spec.md"])
        self.assertTrue(said)
        self.assertIn("needed by a check", said[0])

    def test_the_roadmap_validation_passes(self):
        #  Controllable now that it is only the roadmap validation. It
        #  used to run eight test scripts as well, which made a control
        #  over it a second full run of everything.
        self.assertEqual(
            faults(checker.check_phase_handoff,
                   copied=["ROADMAP.md", "scripts"]), [])

    def test_a_roadmap_that_fails_validation_is_reported(self):
        from check_controls import tree
        with tree(copied=["ROADMAP.md", "scripts"]) as root:
            target = root / "ROADMAP.md"
            #  Every transferred record must name a listed successor;
            #  validate_endpoint refuses one that names nothing.
            target.write_text(target.read_text().replace(
                "## Successor roadmaps", "## Retired headings", 1))
            said = [why for _, _, why in checker.check_phase_handoff(True)]
        self.assertTrue(said)

    def test_a_missing_roadmap_is_reported_rather_than_skipped(self):
        said = reasons(checker.check_phase_handoff, copied=["scripts"])
        self.assertTrue(said)
        self.assertIn("needed by a check", said[0])

    def test_the_owned_tests_name_the_script_that_failed(self):
        #  They used to be run through two other checks and every failure
        #  was attributed to ROADMAP.md, whatever had actually failed.
        from check_controls import tree
        with tree(copied=["scripts", "devices", "environments", "check.py",
                          "ROADMAP.md", "spec.md", "tour.md", "compiler",
                          "core", "examples", "highlight", "assets",
                          "bindings"] + list(checker.LIVE_DOCS)) as root:
            broken = root / "devices/test.py"
            broken.write_text("import sys\nsys.exit(3)\n")
            said = [(where, why) for where, _, why
                    in checker.check_owned_tests(True)]
        self.assertTrue(any(where == "devices/test.py" for where, _ in said))


DEBUGGER = ["scripts/debug.sh", "compiler/tests/debugging"]

HOSTED = ["compiler/tests/fixtures/runtime/derived-hosted-memory/DERIVATION.md",
          "core/region/region.ldn", "examples/derived_hosted",
          #  The manifest names fixtures, and the check holds those to
          #  existing too: the mapping may not cite evidence that is gone.
          "compiler/tests/fixtures/runtime",
          "compiler/tests/fixtures/negative",
          #  And the roadmap, because the mapping is held to accounting
          #  for prototype 4's W1-W7 findings.
          "ROADMAP.md"]


class DebuggerContract(unittest.TestCase):
    """Every derived workload runs on both compiler modes, without GDB."""

    def test_the_real_schedule_passes(self):
        self.assertEqual(
            faults(checker.check_debugger_contract, copied=DEBUGGER), [])

    def test_a_missing_input_is_reported_rather_than_skipped(self):
        said = reasons(checker.check_debugger_contract, copied=DEBUGGER[:1])
        self.assertTrue(said)
        self.assertIn("needed by a check", said[0])

    def test_a_dropped_profile_is_reported(self):
        #  Nine workloads: parser, containers and hosted, each at none/off,
        #  size/auto and size/all. Losing one is coverage lost quietly,
        #  which is why this is checked without invoking GDB at all.
        from check_controls import tree
        with tree(copied=DEBUGGER) as root:
            target = root / "compiler/tests/debugging/check.py"
            target.write_text(target.read_text().replace(
                '"size-all", "size", "all"', '"size-all", "size", "auto"', 1))
            said = [why for _, _, why in checker.check_debugger_contract(True)]
        self.assertTrue(said)

    def test_a_schedule_that_cannot_be_driven_is_reported(self):
        from check_controls import tree
        with tree(copied=DEBUGGER) as root:
            (root / "compiler/tests/debugging/check.py").write_text(
                "# nothing to measure\n")
            said = [why for _, _, why in checker.check_debugger_contract(True)]
        self.assertTrue(said)
        self.assertIn("workload schedule", said[0])


class HostedDerivation(unittest.TestCase):
    """The complete P4 source inventory stays traceable to its manifest."""

    def test_the_real_manifest_passes(self):
        self.assertEqual(
            faults(checker.check_hosted_derivation, copied=HOSTED), [])

    def test_a_missing_manifest_is_reported_rather_than_skipped(self):
        #  Deleted rather than not copied: the manifest lives inside the
        #  runtime fixture tree, so leaving it out of the copy list puts
        #  it back. The first version of this control did exactly that and
        #  tested nothing.
        from check_controls import tree
        with tree(copied=HOSTED) as root:
            (root / HOSTED[0]).unlink()
            said = [why for _, _, why in checker.check_hosted_derivation(True)]
        self.assertTrue(said)
        self.assertIn("needed by a check", said[0])

    def test_a_source_the_manifest_omits_is_reported(self):
        #  A source added without updating the mapping must not vanish
        #  from it silently; this checks names, never behaviour.
        from check_controls import tree
        with tree(copied=HOSTED) as root:
            new = root / "examples/derived_hosted/invented.ldn"
            new.write_text("invented: () -> none =\nend invented\n")
            said = [why for _, _, why in checker.check_hosted_derivation(True)]
        self.assertTrue(any("omits source" in why for why in said))


class CodeRules(unittest.TestCase):
    """The six cheap rules over Landin shown in the documents.

    These cannot be replaced by running refine over the blocks, which was
    the plan until it was measured: of 259 fenced blocks, about two in
    five cannot compile by design.  They name things the surrounding prose
    declared, or carry the `...` omission marker, because the documents
    teach by showing a piece of a program.  A heuristic is the only thing
    that can say anything about a fragment, so these rules stay and are
    controlled instead.
    """

    def said(self, code):
        return [why for _, why in checker.check_code(code.splitlines(), 0)]

    def test_ordinary_code_passes(self):
        self.assertEqual(self.said("value: u32 = 7\n"), [])

    def test_a_keyword_where_a_name_belongs_is_reported(self):
        said = self.said("match: u32 = 7\n")
        self.assertTrue(any("keyword" in why for why in said))

    def test_when_outside_an_exit_statement_is_reported(self):
        said = self.said("    total = total + 1 when ready\n")
        self.assertTrue(said)

    def test_when_on_an_exit_statement_passes(self):
        self.assertEqual(self.said("    break when ready\n"), [])

    def test_one_name_declared_twice_in_a_module_is_reported(self):
        said = self.said("value: u32 = 1\nvalue: u32 = 2\n")
        self.assertTrue(any("twice" in why or "declared" in why
                            for why in said))

    def test_an_end_with_no_opener_is_reported(self):
        said = self.said("end invented\n")
        self.assertTrue(said)

    def test_a_fragment_that_cannot_compile_still_passes_these(self):
        #  The case for keeping them: refine refuses this with L0201
        #  because `first` is declared in the prose around it, and the
        #  cheap rules still have something to say about the line.
        self.assertEqual(self.said("mut cursor: ptr u32 = addr first\n"), [])


GRAMMAR = ["spec.md", "compiler/tests/fixtures",
           "compiler/tests/lexical.tokens",
           "compiler/ada/src/syntax", "compiler/ada/src/diagnostics"]


class GrammarCorpus(unittest.TestCase):
    """The specification's grammar derives every positive fixture.

    This is a SECOND implementation on purpose, and the reason it cannot
    be replaced by running refine: the Ada parser meets the same corpus
    from the other side, and a disagreement between the two locates a
    defect in one of them.  Deriving with the compiler instead would
    collapse two witnesses into one and check the parser against itself.
    """

    def test_the_real_grammar_and_corpus_agree(self):
        self.assertEqual(
            faults(checker.check_grammar_corpus, copied=GRAMMAR), [])

    def test_a_missing_specification_is_reported_rather_than_skipped(self):
        said = reasons(checker.check_grammar_corpus, copied=GRAMMAR[1:])
        self.assertTrue(said)
        self.assertIn("needed by a check", said[0])

    def test_a_positive_fixture_the_grammar_cannot_derive_is_reported(self):
        from check_controls import tree
        with tree(copied=GRAMMAR) as root:
            invented = root / "compiler/tests/fixtures/positive/invented-shape"
            invented.mkdir(parents=True)
            (invented / "program.ldn").write_text(
                "%%% this is not Landin %%%\n")
            (invented / "fixture.meta").write_text(
                "class: positive\nsummary: invented\nprogram: program.ldn\n")
            said = [why for _, _, why in checker.check_grammar_corpus(True)]
        self.assertTrue(said)

    def test_a_grammar_rule_nothing_reaches_is_reported(self):
        #  Every rule must be defined and reachable: an unreachable
        #  production is grammar nobody can be held to.
        from check_controls import tree
        with tree(copied=GRAMMAR) as root:
            spec = root / "spec.md"
            spec.write_text(spec.read_text().replace(
                "```landin-grammar\nprogram",
                "```landin-grammar\nstranded    ::= \"unreachable\"\nprogram",
                1))
            said = [why for _, _, why in checker.check_grammar_corpus(True)]
        self.assertTrue(said)


TOKENS = ["spec.md", "tour.md",
          "compiler/ada/src/syntax/landin-tokens.ads",
          "compiler/ada/src/syntax/landin-tokens.adb"]


class TokenVocabulary(unittest.TestCase):
    """The scanner's reserved words are the grammar's own.

    This is a transcription held to its source, not a duplicate waiting to
    be generated away.  ROADMAP.md's D3 keeps generated tables out of the
    repository and E3 counts the cases: a third kind of generated source
    triggers a D3 review, which a successor roadmap owns.  So the rule is
    "write it twice and compare", deliberately, and this control is what
    makes the comparison trustworthy.
    """

    def test_the_real_vocabulary_agrees(self):
        self.assertEqual(
            faults(checker.check_token_vocabulary, copied=TOKENS), [])

    def test_a_missing_scanner_is_reported_rather_than_skipped(self):
        said = reasons(checker.check_token_vocabulary, copied=TOKENS[:1])
        self.assertTrue(said)
        self.assertIn("needed by a check", said[0])

    def test_a_word_the_scanner_reserves_and_the_grammar_does_not(self):
        from check_controls import tree
        with tree(copied=TOKENS) as root:
            spec = root / TOKENS[2]
            spec.write_text(spec.read_text().replace(
                "Kw_Match", "Kw_Invented", 1))
            said = [why for _, _, why
                    in checker.check_token_vocabulary(True)]
        self.assertTrue(any("differ from the grammar" in why
                            for why in said))

    def test_a_word_the_grammar_reserves_and_the_scanner_does_not(self):
        #  The other direction, which is the one a language change causes:
        #  a keyword added to the grammar and not to the scanner.
        from check_controls import tree
        with tree(copied=TOKENS) as root:
            spec = root / "spec.md"
            text = spec.read_text()
            spec.write_text(text.replace('"match"', '"match" | "invented"', 1))
            said = [why for _, _, why
                    in checker.check_token_vocabulary(True)]
        self.assertTrue(any("differ from the grammar" in why
                            for why in said))


#  Every live document, read from check.py so this list cannot drift from
#  the one the checks actually walk.
LIVE = list(checker.LIVE_DOCS)


class DocumentForm(unittest.TestCase):
    """The four rules that hold the documents' form.

    Each exists because a conversion destroyed something no word count
    could see: prose that lost an em dash, Landin that fell out of its
    fence, a table row that grew a cell and broke an inline span, and the
    comment markers that ARE the demonstration in [0010] and [0020].
    """

    def broken(self, check, document, replace, with_):
        from check_controls import tree
        with tree(copied=LIVE) as root:
            target = root / document
            text = target.read_text()
            self.assertIn(replace, text, "the control's own anchor is gone")
            target.write_text(text.replace(replace, with_))
            return [why for _, _, why in check(True)]

    def test_the_real_documents_pass(self):
        for check in (checker.check_ascii_dashes, checker.check_unfenced_code,
                      checker.check_table_shape, checker.check_comment_forms):
            with self.subTest(check=check.__name__):
                self.assertEqual(faults(check, copied=LIVE), [])

    def test_a_spaced_ascii_dash_in_prose_is_reported(self):
        self.assertTrue(self.broken(
            checker.check_ascii_dashes, "README.md",
            "## Checking", "## Checking -- and why\n"))

    def test_landin_outside_a_fence_is_reported(self):
        self.assertTrue(self.broken(
            checker.check_unfenced_code, "tour.md",
            "## WHAT WAS TRIED AND DROPPED",
            "stray: u32 = 7\n\n## WHAT WAS TRIED AND DROPPED"))

    def test_a_table_row_with_an_extra_cell_is_reported(self):
        self.assertTrue(self.broken(
            checker.check_table_shape, "README.md",
            "## Checking",
            "| a | b |\n|---|---|\n| one | two | three |\n\n## Checking"))

    def test_a_comment_opener_the_tour_stops_showing_is_reported(self):
        #  The markers are the demonstration: [0010]'s marker IS a line
        #  comment. A conversion that read them as markup destroyed the
        #  section with every word intact.
        self.assertTrue(self.broken(
            checker.check_comment_forms, "tour.md", "--(", "-- ("))


ICONS = ["assets/icons.py", "assets/icon.svg", "assets/landin_icon.py",
         "docs/site/render_html.py", "assets/README.md"]

HIGHLIGHT = ["highlight", "assets/fonts.py", "docs/site/render_html.py"]

BINDINGS = ["bindings", "AGENTS.md", "README.md", "docs/targets.md",
            "compiler/ada/TOOLCHAIN.md", "spec.md", "tour.md"]


class Artifacts(unittest.TestCase):
    """The mark, the borrowed icons, the editor packages, the generator."""

    def test_the_real_artifacts_pass(self):
        for check, inputs in ((checker.check_borrowed_icons, ICONS),
                              (checker.check_icon, ICONS),
                              (checker.check_highlighters, HIGHLIGHT),
                              (checker.check_binding_generator, BINDINGS)):
            with self.subTest(check=check.__name__):
                self.assertEqual(faults(check, copied=inputs), [])

    def test_a_missing_drawing_is_reported_rather_than_skipped(self):
        #  This one returned [] when the drawing was renamed, so the mark
        #  stopped being checked while the run still said all clean. The
        #  second check found that way, after check_pinned_toolchain.
        said = reasons(checker.check_icon, copied=ICONS[2:])
        self.assertTrue(said)
        self.assertIn("needed by a check", said[0])

    def test_a_generated_rendering_that_drifted_is_reported(self):
        #  The copied editor files are deterministic renderings of one
        #  source; regenerating is the only way to change them.
        from check_controls import tree
        import runpy
        with tree(copied=HIGHLIGHT) as root:
            #  Asked of the generator rather than guessed: outputs() is
            #  the list the check compares, so this disturbs exactly one
            #  thing the check is looking at.
            #  The generator imports its own vocabulary module, the way
            #  check.py arranges for it.
            sys.path.insert(0, str(root / "highlight"))
            try:
                namespace = runpy.run_path(
                    str(root / "highlight/generate.py"),
                    run_name="outputs_probe")
            finally:
                sys.path.pop(0)
            generated = sorted(namespace["outputs"]())
            self.assertTrue(generated, "the generator renders nothing")
            target = root / generated[0]
            target.write_bytes(target.read_bytes() + b"\n#  drifted\n")
            said = [why for _, _, why in checker.check_highlighters(True)]
        self.assertTrue(said)

    def test_a_missing_generator_is_reported_rather_than_skipped(self):
        said = reasons(checker.check_binding_generator, copied=BINDINGS[1:])
        self.assertTrue(said)


LOOPS = ["scripts/build.sh", "scripts/clean.sh", "scripts/debug.sh",
         "scripts/dev-build.sh", "scripts/dev-test.sh",
         "scripts/linux-loop.sh", "scripts/quality.sh", "scripts/test.sh",
         "scripts/env.sh"]


class DeveloperLoops(unittest.TestCase):
    """Fast feedback stays separate from the complete build and suite.

    Not a CI check, which is what the audit first called it: these are
    the dispositions that keep a developer wrapper from quietly becoming
    the gate, or the gate from quietly becoming incremental.
    """

    def test_the_real_wrappers_pass(self):
        self.assertEqual(faults(checker.check_developer_loops, copied=LOOPS),
                         [])

    def test_a_missing_wrapper_is_reported_rather_than_skipped(self):
        said = reasons(checker.check_developer_loops, copied=LOOPS[1:])
        self.assertTrue(said)

    def test_an_incremental_setting_leaking_into_the_gate_is_reported(self):
        #  The quiet failure this exists for: one duplicated command
        #  restores minutes of repeated work, or checksum mode reaches
        #  the canonical build.
        from check_controls import tree
        with tree(copied=LOOPS) as root:
            build = root / "scripts/build.sh"
            build.write_text(build.read_text().replace(
                'Incremental="${LANDIN_BUILD_INCREMENTAL:-no}"',
                'Incremental="yes"', 1))
            said = [why for _, _, why in checker.check_developer_loops(True)]
        self.assertTrue(said)


class Vocabularies(unittest.TestCase):
    """The faces, the highlighting vocabulary and the examples page."""

    def test_the_real_inputs_pass(self):
        for check, inputs in (
                (checker.check_fonts,
                 ["assets/fonts.py", "assets/fonts", "docs/site/render_html.py"]
                 + list(checker.LIVE_DOCS)),
                (checker.check_highlight_vocabulary,
                 ["highlight", "spec.md", "tour.md"]),
                (checker.check_running_examples,
                 ["examples.md", "compiler/tests/fixtures"])):
            with self.subTest(check=check.__name__):
                self.assertEqual(faults(check, copied=inputs), [])

    def test_a_missing_vocabulary_is_reported_rather_than_skipped(self):
        said = reasons(checker.check_highlight_vocabulary,
                       copied=["spec.md", "tour.md"])
        self.assertTrue(said)

    def test_a_missing_examples_page_is_reported_rather_than_skipped(self):
        said = reasons(checker.check_running_examples,
                       copied=["compiler/tests/fixtures"])
        self.assertTrue(said)
        self.assertIn("needed by a check", said[0])


class Transcriptions(unittest.TestCase):
    """The tables the compiler transcribes from the grammar and the tour.

    Written twice and compared, deliberately: ROADMAP.md's D3 keeps
    generated tables out of the repository, and E3 makes a third kind of
    generated source the trigger for reopening that. So the comparison is
    the design, and these controls are what make it trustworthy.
    """

    def test_the_real_tables_agree(self):
        for check, inputs in (
                (checker.check_precedence_table,
                 ["spec.md", "tour.md", "compiler/ada/src/syntax"]),
                (checker.check_refused_constructs,
                 ["spec.md", "tour.md", "ROADMAP.md", "compiler/ada/src"]),
                (checker.check_diagnostic_matrix,
                 ["compiler/tests/diagnostics.matrix", "compiler/ada/src",
                  "compiler/ada/tests", "compiler/tests/fixtures",
                  "spec.md", "tour.md"])):
            with self.subTest(check=check.__name__):
                self.assertEqual(faults(check, copied=inputs), [])

    def test_a_precedence_level_out_of_order_is_reported(self):
        #  [1820]'s levels, in [1820]'s order, with the same operators at
        #  each. Reordering the Ada table is the drift this catches.
        from check_controls import tree
        with tree(copied=["spec.md", "tour.md", "compiler/ada/src/syntax"]) as root:
            table = root / "compiler/ada/src/syntax/landin-syntax-precedence.ads"
            text = table.read_text()
            #  Swap two adjacent levels: the order is [1820]'s order,
            #  and this is the drift a reordering causes.
            table.write_text(text.replace(
                "(Level_Expression,", "(Level_Logical_And,", 1).replace(
                "      Level_Logical_And,", "      Level_Expression,", 1))
            said = [why for _, _, why in checker.check_precedence_table(True)]
        self.assertTrue(said)

    def test_a_missing_precedence_table_is_reported_rather_than_skipped(self):
        said = reasons(checker.check_precedence_table,
                       copied=["spec.md", "tour.md"])
        self.assertTrue(said)

    def test_a_missing_diagnostic_matrix_is_reported_rather_than_skipped(self):
        said = reasons(checker.check_diagnostic_matrix,
                       copied=["compiler/ada/src", "compiler/ada/tests",
                               "spec.md", "tour.md"])
        self.assertTrue(said)


MACOS = ["environments/macos-arm64", "scripts/macos.sh",
         "scripts/macos_environment.py",
         "scripts/tests/test_macos_environment.py",
         "compiler/ada/TOOLCHAIN.md", "environments/pins.sh"]


class NativeEnvironment(unittest.TestCase):
    """The Apple tool identities stay equal to what TOOLCHAIN.md records.

    Not a CI check either, which the audit first assumed: the acceptance
    half of that environment is retired, but the pinned SDK, clang,
    assembler, linker and LLDB are what this machine still compiles and
    debugs with.
    """

    def test_the_real_identities_agree(self):
        self.assertEqual(
            faults(checker.check_macos_environment, copied=MACOS), [])

    def test_a_missing_policy_is_reported_rather_than_skipped(self):
        said = reasons(checker.check_macos_environment, copied=MACOS[1:])
        self.assertTrue(said)
        self.assertIn("needed by a check", said[0])

    def test_a_tool_identity_that_drifted_from_the_record_is_reported(self):
        from check_controls import tree
        import json
        with tree(copied=MACOS) as root:
            policy = root / "environments/macos-arm64/policy.json"
            recorded = json.loads(policy.read_text())
            recorded["clang"] = "clang version 0.0.0 (invented)"
            policy.write_text(json.dumps(recorded))
            said = [why for _, _, why
                    in checker.check_macos_environment(True)]
        self.assertTrue(any("differs from TOOLCHAIN.md" in why
                            for why in said))


#  check.py is in the list because the roadmap test scripts this check
#  drives import it, which is the widest reach of any check here.
ROADMAP_INPUTS = ["ROADMAP.md", "scripts", "check.py", "spec.md",
                  "tour.md", "compiler/tests",
                  "compiler/ada/src"] + list(checker.LIVE_DOCS)


class RoadmapStructure(unittest.TestCase):
    """The checks that hold ROADMAP.md's own shape.

    These retire with the roadmap they describe, and have no successor
    until the replacement exists. Controlled meanwhile because they are
    live: a roadmap that stops saying what it decided against, or a
    document that points at the retired work authority, still fails here.
    """

    def test_the_real_roadmap_passes(self):
        from check_controls import tree
        with tree(copied=ROADMAP_INPUTS) as root:
            self.assertEqual(
                list(checker.check_roadmap(str(root / "ROADMAP.md"))), [])

    def test_the_structural_checks_pass(self):
        #  check_phase_handoff is absent deliberately. It drives the
        #  roadmap test scripts, which run the whole of check.py, so its
        #  input surface is the repository and a control over it would be
        #  a second full run rather than a statement about one property.
        #  It retires with the roadmap; MOVING.md records it.
        for check in (checker.check_project_status,
                      checker.check_register_entries):
            with self.subTest(check=check.__name__):
                self.assertEqual(faults(check, copied=ROADMAP_INPUTS), [])

    def test_a_status_line_the_roadmap_does_not_carry_is_reported(self):
        from check_controls import tree
        with tree(copied=ROADMAP_INPUTS) as root:
            target = root / "ROADMAP.md"
            target.write_text(target.read_text().replace(
                "Status: complete", "Status: invented", 1))
            said = list(checker.check_roadmap(str(target)))
        self.assertTrue(said)

    def test_a_live_document_naming_the_retired_authority_is_reported(self):
        #  BACKLOG.md is allowlisted as a name so the documents can refuse
        #  it; pointing at it as an authority is the fault.
        from check_controls import tree
        with tree(copied=ROADMAP_INPUTS + list(checker.LIVE_DOCS)) as root:
            target = root / "README.md"
            target.write_text(target.read_text()
                              + "\nSee BACKLOG.md for open work.\n")
            said = [why for _, _, why
                    in checker.check_stale_backlog(
                        list(checker.LIVE_DOCS), True)]
        self.assertTrue(said)


REGISTERS = ["spec.md", "tour.md", "ROADMAP.md",
             "prototype-1-driver.md", "prototype-2-parser.md",
             "prototype-3-containers.md", "prototype-4-app.md",
             "compiler/tests", "compiler/ada/src", "compiler/ada/tests",
             "scripts", "check.py", "environments", "devices",
             "examples", "core", "bindings", "highlight"]


class Registers(unittest.TestCase):
    """The generated inventories and the catalogue they close over.

    check_matrix and check_coverage_registers are the hybrids the audit
    could not place: the construct inventory and the guarantee closure are
    language artifacts, while the evidence rows they carry are roadmap
    bookkeeping. Controlled as they stand, because the untangling is a
    later decision and the property is live now.
    """

    def test_the_real_registers_agree(self):
        for check in (checker.check_catalogue, checker.check_matrix,
                      checker.check_coverage_registers):
            with self.subTest(check=check.__name__):
                self.assertEqual(faults(check, copied=REGISTERS), [])

    def test_a_missing_catalogue_is_reported_rather_than_skipped(self):
        from check_controls import tree
        with tree(copied=REGISTERS) as root:
            (root / "compiler/tests/diagnostics.catalogue").unlink()
            said = [why for _, _, why in checker.check_catalogue(True)]
        self.assertTrue(said)

    def test_a_code_the_catalogue_stops_describing_is_reported(self):
        from check_controls import tree
        with tree(copied=REGISTERS) as root:
            target = root / "compiler/tests/diagnostics.catalogue"
            kept = [line for line in target.read_text().splitlines()
                    if not line.startswith("L0100")]
            target.write_text("\n".join(kept) + "\n")
            said = [why for _, _, why in checker.check_catalogue(True)]
        self.assertTrue(said)

    def test_a_stale_construct_inventory_is_reported(self):
        #  The matrix is generated; a hand edit is the drift this exists
        #  for, and regenerating is the only way to change it.
        from check_controls import tree
        with tree(copied=REGISTERS) as root:
            target = root / "compiler/tests/constructs.matrix"
            target.write_text(target.read_text() + "invented row\n")
            said = [why for _, _, why in checker.check_matrix(True)]
        self.assertTrue(said)


if __name__ == "__main__":
    unittest.main()
