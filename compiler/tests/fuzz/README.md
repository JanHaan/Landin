# Mutation fuzzing

A seeded mutation driver over the fixture corpus, and the crashes it has
found. Nothing runs it automatically: it is a tool you run by hand, and its
reproducers are a record of what it found, not fixtures the harness runs.

## Running it

```sh
nix develop -c compiler/tests/fuzz/fuzz.sh compiler/ada/build/nix/debug/bin/refine 4 100000
```

`fuzz.sh REFINE ROUNDS SEED [OUT]` takes every positive and negative fixture
with exactly one `.ldn` file and writes `ROUNDS` mutants of it, one seed each,
counting up from `SEED`. `mutate.pl SEED IN OUT` makes one mutation, chosen by
the seed from seven kinds: truncate the file, delete a line, duplicate a line,
replace a word with a keyword, insert punctuation or an oversized literal,
delete a character, or swap two words.

A mutant is a hit when `refine` exits with anything but 0 or 1, runs past
`LANDIN_FUZZ_SECONDS` (default 30), or prints a defect or exhaustion line. A
refusal is the answer a mutant should get, so it is never a hit. Each hit is
kept as `OUT/hit-SEED.ldn`, and `OUT` is a new temporary directory unless it
is given.

A seed names the same mutant only against the same fixture tree, because the
seeds are handed out in the sorted order of the fixtures. The recorded runs
below used the tree at `06f748f1`.

`reduce.sh REFINE IN OUT [STATUS]` deletes runs of lines, from sixteen lines
down to one, for as long as `refine` still exits with `STATUS` (default 70).
The exit status is the only signature it keeps. Before trusting that the
reduced file shows the same defect as the original, compare the two under
`gdb -ex 'catch exception'`.

Both scripts need `perl` and `timeout` on the path.

## What it found

The runs date from the review before 0.2.1. In `runs/`:

| run | build | seeds | mutants | hits |
| --- | --- | --- | --- | --- |
| `debug-100000.log` | debug | 100000 and up, 4 rounds | 5,376 | 8 |
| `release-200000.log` | release | 200000 and up, 6 rounds | 8,064 | 5 |

Seed 103339 was a false flag. `refine` exited 1 with a proper refusal, but
a line of the report matched the driver's defect pattern. The pattern now
matches `raised ` only at the start of a line. The other twelve were internal compiler defects: exit 70 with
no diagnostic for the user's actual mistake. Most were a misspelled or
refused field type in a struct whose field was then written, a fallible
function with an undeclared result type, or a loop without `break with`
standing where a function value belongs.

The twelve reduced reproducers are in `reproducers/`, each named by the seed
that found it. All twelve now exit 1 with a diagnostic, and a later round of
1,369 mutants (seed 300000, one round) found nothing. The defects behind them
fell into a few classes, and each class was fixed and is pinned by a negative
fixture: `refused-field-type-in-written-struct`,
`refused-result-beside-error-set`, `loop-value-in-every-value-context` and
`refused-results-answered-by-control`. These files are the fuzzer's record,
not a second copy of those tests:

| reproducer | mutated fixture | exit | codes |
| --- | --- | --- | --- |
| `min-100299.ldn` | `negative/caller-parameter-read-only` | 1 | L0301, L0303 |
| `min-100930.ldn` | `negative/function-field-unassigned` | 1 | L0201, L0302 |
| `min-102470.ldn` | `negative/r440-origin-guarded-fail-value` | 1 | L0201, L0301 |
| `min-103330.ldn` | `negative/r640-zero-field` | 1 | L0201, L0302 |
| `min-103712.ldn` | `negative/struct-array-field-element-zeroed-immutable` | 1 | L0301, L0303 |
| `min-103790.ldn` | `negative/struct-array-field-repetition-element-mismatch` | 1 | L0201 |
| `min-104991.ldn` | `positive/r440-origin-forwarding-positions` | 1 | L0302, L0201, L0301, L0316 |
| `min-201739.ldn` | `negative/immutable-struct-field` | 1 | L0201, L0303 |
| `min-205764.ldn` | `negative/struct-copy-across-types` | 1 | L0201 |
| `min-207488.ldn` | `positive/r440-origin-untaken-cleanups` | 1 | L0201, L0301 |
| `min-207711.ldn` | `positive/r720-labelled-bare-blocks` | 1 | L0301 |
| `min-207836.ldn` | `positive/struct-array-field-element-zeroed` | 1 | L0201, L0302 |

## What it is not

This covers one process and one file per mutant. It does not cover the
driver's options, several files resolved as one module, a target other than
the default, or emission and linking of the mutants that are accepted. It
never runs the executables it builds. Its oracle is "does not crash", not
"gives the right verdict". Every mutant it writes lies within one edit of a
fixture. `ROADMAP.md` records what broader coverage still needs.
