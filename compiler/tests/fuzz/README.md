# Mutation fuzzing

A seeded mutation driver over the fixture corpus, the crashes it has found,
and the lane the gate runs. `fuzz.py` makes each mutant and gives it to
`refine lsp` as an editor would; its reproducers are a record of what it
found, not fixtures the harness runs.

## Running it

```sh
nix develop -c compiler/tests/fuzz/fuzz.py \
  --refine compiler/ada/build/nix/debug/bin/refine --seed 500000 --rounds 1
```

The seeds are every positive, negative, runtime and ABI fixture directory
with exactly one direct `.ldn` file, in class and directory order, then every
reproducer below: 1,971 today (269 positive, 1,137 negative, 520 runtime,
33 ABI and 12 reproducers). The seed is the source text, including for
target-specific or rooted fixtures and ABI fixtures with C companions. The
server sees that one document; it does not run the fixture or load its
companions as a module. Multi-source fixture directories are excluded, and
the discovery test checks this boundary for every class. Each seed is
mutated `--rounds` times, one mutant per seed number, counting up from
`--seed`. A mutation is one of seven kinds: truncate the file, delete a
line, duplicate a line, replace a word with a keyword, insert punctuation or
an oversized literal, delete a character, or swap two words. The seed number
picks the kind and every choice inside it through splitmix64, so a seed
number names one mutant on every host and every Python, against the same
fixture tree; `scripts/tests/test_fuzz_mutator.py` holds the generator to
splitmix64's published outputs and each kind to the bytes it makes. A source
is read as an editor shows it, a byte that is not UTF-8 as U+FFFD.

One server serves fifty mutants, each its own document. Each is opened as
its seed's source, changed to the mutant, then asked for a hover, a
definition, formatting and code actions at positions the seed picks, and
closed. A mutant is a hit when the server stops, does not answer within
`--seconds` (default 10), answers a request with anything but a result or a
protocol error, or reports a compiler defect, on its log or through
`showMessage`. The server runs under an address-space bound, `--memory`,
2 GiB by default, where the host allows one: Darwin refuses to lower
`RLIMIT_AS`, so there the bound is the host's own. A diagnostic is never a
hit: a refusal is the answer a mutant should get. Each hit is kept as
`OUT/hit-SEED.ldn` with the session that broke it as `OUT/hit-SEED.lsp`, a hit
restarts the server, and any hit fails the run.
The close of the last document is checked when a batch rolls over and at
final shutdown. A premature exit, failed shutdown response or timeout keeps
that document's mutant and transcript as a hit.

`--batch` runs the original oracle instead: `refine FILE` on each mutant,
where an exit other than 0 or 1, a run past the bound or a defect line is a
hit. `--reduce FILE` deletes runs of lines from a hit, sixteen down to one,
for as long as a fresh server given the text still breaks, and writes
`OUT/reduced.ldn`. Before trusting that the reduced file shows the same
defect as the original, compare the two server logs.

The gate's `compiler` job runs one round from seed 500000 with the debug
compiler, whose contracts are the stronger oracle. Its first run against the
server found a definition asked of a module whose names were refused raising
a defect; the server suite pins the fix.

The first driver was a Perl mutator, `mutate.pl`, run by `fuzz.sh`, with a
`reduce.sh` beside it. They made the two recorded runs below and are in the
history, last at commit `bb04329d`; a seed in those logs names a mutant only
under them.

## What it found

The runs date from the review before 0.2.1. In `runs/`:

| run | build | seeds | mutants | hits |
| --- | --- | --- | --- | --- |
| `debug-100000.log` | debug | 100000 and up, 4 rounds | 5,376 | 8 |
| `release-200000.log` | release | 200000 and up, 6 rounds | 8,064 | 5 |

Seed 103339 was a false flag. `refine` exited 1 with a proper refusal, but
a line of the report matched the driver's defect pattern. The pattern now
matches `raised ` only at the start of a line. The other twelve were internal
compiler defects: exit 70 with no diagnostic for the user's actual mistake. Most were a misspelled or
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

The gate's lane drives the frontend through the server, one file per
document, with the default target. A runtime or ABI seed tests the server's
handling of that source text; it does not check the fixture's runtime or ABI
behavior. Rooted imports and C companions are not assembled into the
document's module. It does not cover the driver's options,
a target other than the default, several files resolved as one module, or
emission, linking and running the mutants that are accepted. Its oracle is
"does not crash", not "gives the right verdict", and every mutant it makes
lies within one edit of a fixture. `ROADMAP.md` records what broader
coverage still needs.
