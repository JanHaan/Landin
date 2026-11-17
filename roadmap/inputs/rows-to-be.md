# Rows-to-be for the register

*A frozen input of the third roadmap, placed under `roadmap/inputs/` at the
exchange. R17.10 filed each row here under the number its allocation
script gave, in the first column; R18.30 closes the ones it names. It is
not edited once R17.10 is complete.*

Friction met while planning the third roadmap, on 2026-11-16 over
`origin/main` 29d4f681f, in the register's short typed form. The exchange
added the last four rows.

| Row | Type | Family | What stands | Activation | Completion |
|---|---|---|---|---|---|
| SR-1282 | usability | Usability | `check.py` requires phases from R8 with no gap and a gate for each (`FIRST_ROADMAP_PHASES`, `check_roadmap`); the Mechanics text says neither, and retiring R15 depends on both. | R17.30 | The Mechanics text states the rule, with R15's stub exempt. |
| SR-1283 | limit | Usability | The site's front page (`render_html.roadmap_progress`) fails with an error when more than one item is active, so a continuous lane cannot be shown. | R17.30 | The progress track shows the serial lane's item and the active continuous items. |
| SR-1284 | usability | Usability | The compiler recognises `iterable` and `fallible_iterable` by name; no library module defines them, and the tour does not say a program must declare its own. | R19.10's answer on SC-05, or R20.30 | Either the library declares them or the tour says to. |
| SR-1285 | usability | Usability | `docs/diagnostics.md` cites few construct identities per code, so the diagnostics a construct owns cannot be found from the construct. | The next change to the diagnostics catalogue | Each code cites the constructs it enforces. |
| SR-1286 | proposal | Usability | Nothing counts how often a construct is used: grep cannot see an operator on an array-typed value or a literal that reads its own destination, so an audit estimates where it could measure. | SC-27's measurement, or the next construct audit | A `refine` query, or a checker report, that counts constructs over a tree. |
| SR-1287 | usability | Usability | Calling an entry through `any` needs the entry's first parameter to be named `self`. [1390] states it in its list of conditions, but [1230] and [1240], where entries are declared and supplied, do not. | The next change to [1230] or [1390] | The rule is stated where an entry is declared. |
| SR-1288 | usability | Usability | A decision's history ("remains outside this slice", "D… later admits") reads as a live rule, and nothing marks a boundary that a later decision lifted, so finding today's rule means following the chain to D241. | SC-24 in R19.10 | Superseded boundaries are folded or marked. |
| SR-1289 | usability | Usability | `docs/capabilities.md` says `refine targets --identify` keeps the older summary; it is refused (L0002), and only bare `refine --identify` prints it. | R18.30 | The document and the tool say the same. |
| SR-1290 | usability | Usability | L0004's and L0009's explanations, `docs/diagnostics.md` and `docs/targets.md` send the reader to `refine --identify`; help says `refine targets`, which prints less. | R18.30 | One form named everywhere, printing what the explanations promise. |
| SR-1291 | usability | Usability | README's command table has no row for `targets`, `completion` or `help`, and shows only one form of `refine site`. | R18.30 | Every command in the table, or the table generated from help. |
| SR-1292 | usability | Usability | The `Explain_Command` comment says it reads no file; it reads `citations.txt` from the library (D1240). | R18.30 | The comment says what the command reads. |
| SR-1293 | usability | Usability | The `Format_Command` comment says an operand is never a directory; `fmt` formats every `.ldn` under a directory operand. | R18.30 | The comment matches the help. |
| SR-1294 | usability | Usability | `refine help reference` is held to the documents by nothing outside the `commands` suite; no check compares the two. | R18.30 | A check refuses a command or flag the documents do not name. |
| SR-1295 | usability | Usability | `check.py` reads a roadmap reference only where no `.` follows it, so an item cited at the end of a sentence, "R19.21.", is never resolved; the exchange met it when the Mechanics' example passed and the same identity before a comma failed. | R17.30 | A reference before a full stop is resolved like any other. |
| SR-1296 | limit | Usability | The release-build cache's key names the runner image version, and one run is served two image versions, so a job finds the saved entry only by chance: run 44030898347's `linux-release-build` ran on 20261111.370.1, missed main's entry from 20261111.127.1 and took as long as the clean build. Added at the exchange. | R17.50 | The key names the C library headers' and the C compiler's versions, and a second run of an unchanged tree restores the entry. |
| SR-1297 | proposal | Usability | The cached Darwin release build is prepared on the local branch `ci-darwin-cached-release` (whole-file identity through `ZERO_AR_DATE=1`, a modelled Darwin end of 25 to 30 minutes) and is on no remote: it needs a rebase onto main, the cache key's brace fix and the key decision. Added at the exchange. | R17.50 | The branch rebased, its gate passed and promoted, or the reason it is dropped recorded. |
| SR-1298 | usability | Usability | A decision whose **Chosen** text names `ROADMAP.md` or `roadmap/` fails `test_gate_inputs.py`'s readers case, because `check.py --generate` copies the whole Chosen part into `citations.txt`, which a lane reads; the refusal names `citations.txt` and not the decision, and the way out is to reword the decision. Met writing D1373 at the exchange. | The next change to how `citations.txt` is generated | The readers case names the decision, or the generator carries only the title. |
