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
| `traps` | no | `yes` if the program must end without returning a status |
| `stream` | no | `output` (the bytes must be on standard output, and standard error must be empty) or `merged` (default) |
| `lex` | no | the exact complaint the scanner must produce, for a fixture whose fault is lexical |
| `codes` | yes for a negative with a program | the diagnostic codes the report must carry, in order |
| `targets` | no | comma-separated targets the fixture applies to |

`codes` also says which stage refused the fixture, and that is what decides
whether the grammar must derive its program. The frontend refuses what the
grammar cannot derive, so a fixture whose first code the scan or the parse can
raise must not derive; a later stage refuses source that parsed, so a fixture
whose first code belongs to one of those must derive exactly as a positive
fixture does. `check.py` reads which codes the frontend raises out of
`Landin.Diagnostics.Lexical` and `Landin.Diagnostics.Syntactic` rather than out
of the number, because the catalogue's own header forbids reading a stage off a
code -- `L0010` is raised by the scanner and by the parser both.

`codes` is an ordered list and not a set. Two refused constructs in one file
are two reports, and a regression that doubles a count is invisible to a set,
so `float-literal-not-enabled` names `L0010, L0010` -- once for the type and
once for the literal. `check.py` holds every name in it to the catalogue, and
refuses a negative fixture with a program that names none; the parser suite
scans and parses the program and holds the report to the exact sequence.

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
| runtime | executed: `refine` compiles and links `program`, the result is run, and its own exit status is compared with `status` -- or, with `traps: yes`, it is held to having ended without returning one |
| positive | executed: the program is scanned and parsed with nothing reported, the grammar must derive it, and `refine` is asked to emit assembly for it |
| ABI, debugger | reserved; no fixture yet. They arrive with the work that produces an ABI and debug information |

A class with no fixtures is the normal state early in the roadmap, and an
empty class directory is not a fault. A fixture that records an expectation
nobody runs is.

That last sentence decides what a runtime fixture does on a host that cannot
finish the target, and the answer is that the run fails. A macOS host with no
ELF toolchain reports the fixture as a failure carrying `refine`'s own
report, which is where `L0500`'s note says which toolchain would satisfy it.
Skipping would be the quiet non-run the sentence refuses, and it would also
hide the gate losing its toolchain. This is the same rule `scripts/env.sh`
already applies one level up: a machine without the pinned GNAT is told so
and stops, rather than quietly building nothing.

A runtime fixture carries `program` and `status` and neither `expect` nor
`args`, because nothing compares `refine`'s own output -- what is asserted is
what the compiled program did. One without a `program` is a reported fault,
for the same reason `expect` without `args` is: a status nobody produces is
dead data.

Accepted, emitted and executed are three claims and not one, which is why
three classes make them. A positive fixture is a program the compiler must
accept, and asking only that was how four of [1810]'s statement forms reached
R1.80's audit having never been handed to a backend: every stage accepted
them and no case asked for a byte of assembly. So the positive class now
emits as well, and a construct that reaches a compiler defect on the way to
`.s` fails there rather than waiting for a runtime fixture to happen to use
it. It is still not executed -- most of the corpus is a fragment with no
entry point to run, and a claim about a machine belongs to the runtime class.

`traps: yes` replaces `status` rather than joining it. `spec.md` [1960] says a
trap is synchronous and non-returning and that its operating-system signal or
status is not stable program behaviour, so a fixture may assert that the
program ended without returning a status and may not assert which signal ended
it. Naming both is a reported fault: a program that trapped has no status, and
a fixture claiming one is claiming an answer nobody can observe. Nothing in the
format or in `Landin.Platform` carries a signal number, deliberately.

What that can and cannot tell apart is worth knowing before writing one.
`runtime/checked-overflow-traps` adds one to a `255u8` the compiler cannot
read: without the backend's own check the instruction keeps the low byte and
the program returns 42, so the fixture fails when the trap edge is removed --
which is measured, not assumed. `runtime/a-zero-divisor-traps` cannot make that
distinction, because x86-64 faults on a zero divisor whether or not the
compiler guarded it; it proves [1950]'s obligation is met and not which of the
two stopped the program. D11 is where the choice to emit a deliberate `ud2`
rather than inherit the incidental fault is recorded, and deterministic
assembly is what pins it.

## The grammar corpus

A `.ldn` file under `positive/` must be derivable from the grammar in
`tour.md`; one under `negative/` must not. `check.py` enforces both on every
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

## lexical.tokens

`compiler/tests/lexical.tokens` is generated: `python3 check.py --tokens`
writes it from `check.py`'s tokeniser, one line per token as `first last
spelling`. The Ada harness reads it and compares every token with what
`Landin.Tokens.Lexer` produced, and `check.py` regenerates it on every full
run and fails if the committed copy is stale.

Kinds are deliberately not in it. The two implementations have different
kind vocabularies, and what a disagreement actually looks like is a boundary
in a different place.

That is two independent implementations of one grammar, held to each other
over every program in the corpus. The first thing it caught was real: the
Ada scanner appended each file's tokens to the previous file's, because a
limited `out` parameter is passed by reference and `Lex` had not cleared it.

## diagnostics.catalogue

`compiler/tests/diagnostics.catalogue` is generated: `python3 check.py
--catalogue` writes it from `Landin.Diagnostics.Catalogue`, which is the only
place in the compiler where a code is written. `check.py` regenerates it on
every full run and fails if the committed copy is stale, and it refuses a code
literal written anywhere else under `compiler/ada/src`.

That check earned itself immediately: the driver had held `L0001` to `L0004`
as literals since R0.50, and moving them into the catalogue was the first
thing it demanded.

## lowering.ir

`compiler/tests/lowering.ir` is generated: `./scripts/test.sh --record`
writes it by lowering every positive fixture and rendering the Unit with
`Landin.IR.Dump`. It is the third recorded artefact and the only one
`check.py` does not touch, and that difference matters enough to state.
`check.py` generates the other two because it owns their sources — its own
tokeniser, and the catalogue's Ada text. It owns nothing here: producing
this file means running four compiler stages, so the Ada harness is what
can produce it and **`python3 check.py` will not tell you it is stale.**
`./scripts/test.sh` will, and so will the gate.

Recording runs no case, and no case ever writes. Two disjoint modes in one
binary, chosen only by an argument a human typed: there is no environment
variable, nothing writes the file when it is missing, and nothing rewrites
it when it does not match. A golden that repairs itself on a mismatch
records the defect instead of reporting it. The loop is closed by hand —
record, then run the suite again with no argument.

What the file is for is narrow, and `landin-ir-dump.ads` says it: it proves
the lowering has not changed its mind. That the corpus derives from the
grammar is `check.py`'s, and what the instructions mean is
`Landin.IR.Verifier`'s. No origin is printed, deliberately, so a comment
edit above an instruction does not rewrite the artefact.

## Derived programs

The four prototype text files in the repository root stay exactly as they
are. Complete derived `.ldn` programs are separate artefacts and arrive with
the roadmap work that can compile them.
