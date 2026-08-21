# Shared fixtures

Fixtures live here rather than under `compiler/ada/` because they describe
Landin, not the Ada implementation that currently checks them. When a stage
is eventually rewritten, these must still be the tests it has to pass.

## Layout

```
compiler/tests/
  fixtures/<class>/<name>/fixture.meta   the fixture and its metadata
  harness-cases/malformed/               trees that must be rejected
```

Fixture classes, and the directory each uses:

| class | directory | what it covers |
|---|---|---|
| unit | `unit` | a note of one behaviour an implementation-side case covers |
| positive | `positive` | a program that must be accepted |
| negative | `negative` | a program that must be rejected, with the report it must produce |
| runtime | `runtime` | a program whose behaviour when run is the assertion |
| ABI | `abi` | a calling, layout or evidence-table contract |
| debugger | `debugger` | what a debugger must be able to show |
| end-to-end | `end-to-end` | the toolchain from source to result |

## Metadata

`fixture.meta` is `key: value` lines, with `#` comments and blank lines.

| key | required | meaning |
|---|---|---|
| `class` | yes | must match the directory the fixture sits in |
| `summary` | yes | one line, what the fixture proves |
| `program` | no | the `.ldn` program the fixture runs |
| `expect` | no | the file holding the expected bytes |
| `args` | no | the arguments `refine` is run with |
| `status` | no | the exit status `refine` must produce (default 0) |
| `stream` | no | `output` (the bytes must be on standard output, and standard error must be empty) or `merged` (default) |
| `targets` | no | comma-separated targets the fixture applies to |

`targets` is checked against the targets `ROADMAP.md` names: `linux-x86-64`,
`macos-arm64`, `cortex-m`, `synthetic-32`. A fixture may name a target the
chassis does not describe yet — `macos-arm64` arrives at R5 — but not one the
roadmap has never heard of, because that is how a fixture quietly stops
applying to anything.

`expect` and `args` come as a pair. An expectation with no way to produce it
is dead data that looks like coverage, and arguments with nothing to compare
against are a command nobody checks, so either one alone is a reported fault.

A fixture carrying both is **executed**: the harness runs `refine` with those
arguments through the real tool adapter, and compares the captured bytes and
the exit status with what the fixture claims. Standard output and standard
error are captured together, in the order the process wrote them.

Discovery is strict. An unknown key, a repeated key, a missing required key,
a class that disagrees with its directory, a line that is not a pair, a
fixture directory without metadata, and a plain file where a fixture belongs
are all reported, and the fixture is not accepted. A fixture that is
half-accepted is a fixture whose fault stops being visible.

Names beginning with `.` are skipped: host clutter is not a fixture and not a
fault.

Ordering is by class, then by name, so a run reports the same sequence
everywhere.

## What the harness does with them

| class | today |
|---|---|
| unit | a note of what an implementation-side case covers; the case itself lives in `compiler/ada/tests` |
| negative, end-to-end | executed: `refine` is run with `args`, and its bytes and exit status are compared with `expect` and `status` |
| positive, runtime, ABI, debugger | reserved; no fixture yet. A positive or runtime fixture needs a program the compiler can accept, so the first ones arrive with R1; ABI and debugger fixtures arrive with the work that produces an ABI and debug information |

A class with no fixtures is the normal state early in the roadmap, and an
empty class directory is not a fault. A fixture that records an expectation
nobody runs is.

## The grammar corpus

A `.ldn` file under `positive/` must be derivable from the grammar in
`tour.txt`; one under `negative/` must not. `check.py` enforces both on every
full run, and it enforces that every construct in the grammar section is
named by at least one fixture, so a production nothing pins is a reported
fault rather than a quiet one.

That is what makes the corpus useful before a compiler exists: the
specification and its examples check each other. When R1.40's parser
arrives, it has to agree with the same corpus, and a disagreement between
the parser and the grammar is a defect in one of them rather than a matter
of opinion.

Two rounds of reading the grammar by hand found sixty-eight defects between
them and still missed that a lone `_` parsed as a name. The corpus found
that in a second.

A negative fixture may add `lex: <complaint>` to pin why the scanner refused
it, not merely that it did. Refusing for the wrong reason means the wrong
span, and a span that names the wrong bytes is the defect rather than a
detail of the message.

Programs are read as bytes. Text mode would turn CR LF and a lone CR into
LF, so the terminator rule `[1750]` states could not be tested however many
fixtures were written for it; `positive/line-ends-crlf` carries a CR byte and
the checker asserts it is still there when read.

What the corpus cannot see, recorded so nobody assumes otherwise: it cannot
tell CR LF read as one terminator from CR and LF read as two, because both
produce the same tokens. The distinction belongs to the line map, and
`Landin.Source`'s own case for it is what holds that.

## Derived programs

The four prototype text files in the repository root stay exactly as they
are. Complete derived `.ldn` programs are separate artefacts and arrive with
the roadmap work that can compile them.
