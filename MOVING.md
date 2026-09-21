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
| No mechanical gate. Nothing builds the compiler or runs the fixture corpus on a push. `determinism.yml` checks host-independence and `pages.yml` publishes; neither runs a compiler test. | the SourceHut gate was retired | a replacement gate is designed; it is not the old eight-job matrix ported over |
| ~~`scripts/ci/` is dead.~~ Removed, with its four test suites and `check_native_ci`. `ROADMAP.md` still names the controller in records of which policy accepted which revision; those names are allowlisted in `check.py` rather than the rule weakened, and that list is where the last references are found when the roadmap is replaced. | — | done |
| `check.py` still carries the roadmap-structure checks (~555 lines) whose subject is going away. | — | the new roadmap, which is what they would be checked against |
| 34 of 37 checks in `check.py` have no control proving they can fail. | — | the check.py audit, whose first step this is: a property cannot be shown to have moved home if neither holder can be made to fail |
| `ROADMAP.md` names 169 `.scratch` paths; 155 do not exist on any machine. | R4.91 onward | the roadmap replacement, which converts them to prose |

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
