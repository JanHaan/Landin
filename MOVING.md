# Moving

A register of what is knowingly broken, dead or deferred while the project
moves off SourceHut and off its first roadmap. **This file is deleted when
the move ends.** Nothing here is a permanent disposition; anything that
turns out to be permanent belongs in the new roadmap before this file goes.

It exists because a knowingly-broken check that is silently skipped is
indistinguishable from one that is quietly wrong. This repository learned
that when renaming `tour.md` made four checks vacuous and the run still
said `all clean`.

## Broken or absent

| what | since | trigger to fix |
|---|---|---|
| ~~No mechanical gate.~~ `gate.yml` builds the compiler and runs all 741 cases on every push: `documents` in about 90s, `compiler` in about 37 minutes at two workers. It is Linux only, debug only, with no Darwin, no Cortex-M execution, no debugger, no bindings and no retained evidence. | — | a fuller matrix, when the targets need one |
| ~~`scripts/ci/` is dead.~~ Removed, with its four test suites and `check_native_ci`. `ROADMAP.md` still names the controller in records of which policy accepted which revision; those names are allowlisted in `check.py` rather than the rule weakened, and that list is where the last references are found when the roadmap is replaced. | — | done |
| `check.py` still carries the roadmap-structure checks (~555 lines) whose subject is going away. | — | the new roadmap, which is what they would be checked against |
| The audit's largest bucket -- 2,173 lines said to be eliminable by generating the compiler's four transcription tables from `spec.md` -- is not a cleanup. `ROADMAP.md`'s D3 keeps generated tables out of the repository and E3 counts the cases; a third kind of generated source triggers a D3 review, which a successor roadmap owns. Writing the tables twice and comparing them is the recorded decision. | reading the inherited review register, which `AGENTS.md` says to read before reviving a rejected idea | nothing here: the checks stay and are controlled. The D3 review belongs to whoever opens it deliberately |
| `check_grammar_corpus` was slated to move to `refine`. It is a second implementation on purpose: it derives the corpus from `spec.md`'s grammar while the Ada parser meets the same corpus from the other side, and a disagreement locates a defect in one of them. Deriving with the compiler would check the parser against itself. | reading the code after reading the docstring | nothing: it stays, and is controlled. Bucket B is now empty |
| `check_code`'s 883 lines were slated for deletion in favour of running `refine` over the documents' Landin blocks. Measured: of 259 blocks about two in five cannot compile by design, naming what the surrounding prose declared or carrying the `...` omission. Only a heuristic can check a fragment. | measured while starting the replacement | nothing: the rules stay, and are controlled. `check_grammar_corpus` still moves, because fixtures are whole programs |
| `check_phase_handoff` has no control: it drives the roadmap test scripts, which run the whole of `check.py`, so its input surface is the repository and a control would be a second full run rather than a statement about one property. | found writing its control | it retires with the roadmap |
| `check_optimization_contract` does three unrelated things: the quality and object-reader wiring its docstring claims, a call into `check_phase_handoff` (a roadmap-structure check bound for deletion), and a tour prose rule about array comparison. It has no control because three subjects are not one property. | found writing its control | split it, in the audit |
| 2 of 36 checks in `check.py` have no control. `check_optimization_contract` does three unrelated things; `check_phase_handoff` runs the whole of `check.py`. Both need splitting before a control means anything. | the audit | split them, or let them retire |
| `ROADMAP.md` names 169 `.scratch` paths; 155 do not exist on any machine. | R4.91 onward | the roadmap replacement, which converts them to prose |

| The corpus at one worker measured 4523s on CI, against 3592s for the pre-parallelism sequential run. One job is still the default, so this is the path a developer gets. | the parallelism change | single CI samples on shared hardware cannot tell variance from a regression; a Mac run at one job against the recorded 2897s baseline would settle it |

## Deferred, with the reason

| what | why it is not simply done |
|---|---|
| The Cortex-M lane names `arm-none-eabi-gcc` 14.2.1, pinned through `environments/cortex-m/tools.lock.json`. The pinned publisher also ships `arm-eabi-gcc` 16.1.0, verified to build a valid image. | Adopting it is a two-major-version move that changes emitted firmware bytes and rebaselines every recorded Cortex-M hash and disassembly. It is a decision with an evidence cost, not a swap. |
| `spec.md` and `tour.md` are organised by discovery order rather than by structure. | The rewrite is 0.2.1 work and wants the implementation frozen so equivalence can be shown. |

## Already resolved, kept until the move ends

- The vendored code face was removed from all history; the thirty acceptance
  tags were re-issued with their content hashes intact.
- `ci/publication-lock` was deleted: it served a publisher that no longer runs.
- The SourceHut Pages sites for both domains were unpublished.
