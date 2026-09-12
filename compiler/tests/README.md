# Shared fixtures

Fixtures live here rather than under `compiler/ada/` because they describe
Landin, not the Ada implementation that currently checks them. When a stage
is eventually rewritten, these must still be the tests it has to pass.

## Layout

```text
compiler/tests/
  fixtures/<class>/<name>/fixture.meta   the fixture and its metadata
  harness-cases/malformed/               trees that must be rejected
  constructs.matrix                      generated: every [NNNN] and its evidence
  diagnostics.catalogue                  generated: every code and its rule
  diagnostics.matrix                     generated: code contracts, emitters and owners
  guarantees.matrix                      generated: classified semantic boundaries
  conformances.matrix                    generated: conformance/evidence mechanisms
  prototypes.matrix                      generated: completed prototype derivations
  targets.matrix                         generated: applicability of every fixture
  lexical.tokens                         generated: the scanned corpus
  layout.targets                         recorded: what each target measures
  lowering.ir                            recorded: every positive fixture, lowered
```

Generated and recorded are not the same word here. `check.py` writes the
generated files and refuses each when it is stale; the last two are written
by `./scripts/test.sh --record`, because producing them means running compiler
stages and asking the target model, which `check.py` cannot do. It will not
tell you those two are stale — the harness and the gate will. `constructs.matrix`
is R1.90's: it lists every construct either document defines against what
the corpus says about it, and a construct with neither evidence nor a
by-name refusal is a row that item has to answer for. Regenerate it with
`python3 check.py --matrix`.

Fixture classes, and the directory each uses:

| class | directory | what it covers |
| --- | --- | --- |
| unit | `unit` | a note of one behaviour an implementation-side case covers |
| positive | `positive` | a program that must be accepted |
| negative | `negative` | a program that must be rejected, with the codes it must produce and, where a code alone could hide a wrong refusal, the exact report |
| runtime | `runtime` | a program whose behaviour when run is the assertion |
| ABI | `abi` | emitted Landin assembly compiled with ordered C11 companions, then executed |
| end-to-end | `end-to-end` | the toolchain from source to result |

R4.60's scripted debugger programs live in `debugging/` and run through
`scripts/debug.sh`, independently of the Ada fixture harness. The `debugger`
metadata class has no directory; these sessions use debugger assertions
rather than the harness's process-output fixture contract.

## Focused developer runs

The harness can select one suite, one case, or one recorded fixture by exact
name. The developer wrapper combines that with checksum-based minimum
recompilation:

```sh
./scripts/dev-test.sh --suite='fixture execution'
./scripts/dev-test.sh --case='harness/filters select exact cases'
./scripts/dev-test.sh --fixture=positive/variant-match-exhaustive
./scripts/dev-test.sh --fixture=negative/variant-match-duplicate
./scripts/dev-test.sh --fixture=runtime/variant-match-selects-tag
./scripts/dev-test.sh --fixture=abi/r440-smoke
```

A fixture selector accepts `positive`, `negative`, `runtime`, `abi`, or any
other discovered class whose fixture has a recorded `expect`. It invokes the
real scanner-through-backend path appropriate to that class, including
assembling, linking and executing a runtime or ABI fixture. Every selected
transcript begins with `FILTERED`, and an unknown selection fails: focused
feedback cannot look like the complete suite by accident. Run
`./scripts/test.sh` with no selector for the complete local gate.

D213's `r490-distinct-*` fixtures cover exact base construction/extraction,
opaque identity, no inherited operators or conformances, ordinary identifiers,
generic/fixed identity keys, erased dispatch, origins and module image cycles.
The two generic runtime fixtures run all six profiles; the module-image
fixture checks scalar/float/atom images, arrays, nested records, slices, text
and callback relocations. `abi/r490-distinct-c-roundtrip` crosses the native C
boundary in both directions for integer, float, pointer and mixed C-record
bases. The IR atom-image unit case accepts a member identity and rejects a
stored identity absent from the field's set.

The R4.91 construction regressions distinguish runtime field/payload/fill
arguments from static type arguments. `negative/r491-construction-type-arguments`
pins value diagnostics in module and local contexts.
`negative/r491-construction-type-fills` pins expression diagnostics for
type-only trailing fills and preserves recovery through later declarations.
`negative/r491-construction-static-address` preserves the existing static-image
address exclusion. `positive/r491-construction-static-arguments` retains generic
type arguments, local addresses, value fills and a callback body that takes a
local address. `runtime/r491-variant-array-construction` exercises small root,
nested and wrapped arrays, repetition and later variant replacement. The
checker and lowering seam cases separately assert case identities and verified
storage paths; driver cases assert that refused source writes no output and
invokes no tool.

## Optimization profiles and object quality

Every runtime and ABI fixture runs separately under `none/off`, `size/off`,
`size/auto` and `speed/auto` (objective/specialization). Focused names containing
`generic`, `any-`, `r450` or `r480`, plus `allocator-vec-pressure`,
`diagnostic-loggers-dispatch`, `core-io-erased-system`, `derived-containers`
and the complete derived hosted application fixtures,
also run `none/all`
and `speed/all`. A selected runtime/ABI fixture uses the same matrix. Artifact
names and assertion labels include the profile. Each profile independently
checks the original exact status, trap and output oracle; agreement with another
profile alone is never success. Timeout never satisfies `traps: yes`.

The harness adds compiler controls directly, not through a fixture's `args` or
`run_args`; metadata remains the program's original request and oracle.
`--build-mode` is a separate source-configuration axis, and building the Ada
compiler in debug/release does not select an emitted-code objective either.

After the compiler build, `./scripts/quality.sh` runs the Linux x86-64 numeric
acceptance in `quality/check.py`. It requires `LANDIN_GNAT_HOME` and takes gcc,
objdump and size from that checksum-pinned installation, not an arbitrary host
PATH. It compiles and repeats each request, parses factual JSON, assembles the
same output to ELF objects, measures sections, function bytes, prologue frames
and disassembled instruction sites, and executes that same assembly against
exact exit/stdout/stderr oracles. Its probes cover scalar chains
and loops, a tiny leaf, compact large-array arithmetic with real stack-page
touches, explicit optimal layout, single-instance evidence specialization,
a source-level two-instance size/speed threshold and final private-body
folding. The specialization and folding probes also run none/all and speed/all.
The complete `derived-parser` client runs all six quality profiles with its
original input path, three ordered diagnostics and status 42. Repeated requests
must produce byte-identical assembly and build reports, and the measured object
must execute that original oracle. Its source inventory reaches the real parser
and lexer; object measurements add no size or timing threshold.
The complete `derived-containers` client runs all six profiles, preserving its
status-42 and empty-output oracle. Its reports must identify real `core`
container instances and factual specialization actions with retained evidence
ABIs; forced specialization must actually select a container entry. Its object
measurements are observations, not a new size budget or timing claim.
The complete `derived-hosted-memory` application also runs all six quality
profiles with its status-42 and empty-output oracle. Source inventories must
reach its real application module; factual specialization reports and emitted
indirect machine calls must preserve runtime provider dispatch even with
forced specialization. Measurements remain object observations without a
new size or timing threshold.
The quality and debugger runners give these large rooted workloads a separate
900-second compiler-subprocess limit: its full-debug compilation already
exceeds the ordinary 120-second limit on a native development host. Executable
and debugger timeouts remain 120 seconds; slow compilation does not excuse a
hung program or debugger.
Existing insertion-sort and sieve-of-eratosthenes sources retain their original
status-42 oracles; the other probes return zero. Scalar acceptance requires
substantial stack-site, frame and instruction reductions, with no tiny-leaf
growth or gratuitous callee-save overhead; existing workload text has a bounded
regression allowance. Source threshold decisions are checked against both
measured cost inputs and actual direct/indirect machine sites, including shared
fallback bodies. The runner retains disassembly, symbol and size output and
compiler/assembly/object hashes in JSON after all acceptance checks pass.
`ROADMAP.md` R4.50 owns the numeric bounds and completion evidence. The script
writes actual observations to the selected build tree's
`quality/measurements.json`; it never updates an acceptance bound or recorded
fixture. Acceptance is the current command's zero exit, not the presence of
this file: a failed rerun leaves an earlier successful observation untouched.
This is structural/object smoke evidence, not timing or competitive
benchmark evidence. A non-Linux host fails rather than claiming a skip as a pass.

## Source debugger acceptance

After building the compiler, `./scripts/debug.sh` runs the Linux x86-64
source-debugger acceptance in `debugging/check.py`. It uses GDB to test the
emitted program's line information, breakpoints, stepping, stack frames and
selected parameters and locals. The native gate runs it separately with debug
and release builds of the Ada compiler. The script fails if its tools or
debugger operations are unavailable; missing debugger evidence is not a pass.

The complete `derived-parser` program runs in the same runner using none/off,
size/auto and size/all. It receives the fixture's original input path and must
produce its exact ordered diagnostics and status 42, including after stripping.
GDB inspects initialized parser state, recursive source frames, recovery,
nesting depth and the final success/failure flags. Its whole reached source
inventory receives the same source-map, line-table and build-identity checks.
`check.py` holds the complete P2/P3/P4 workload schedule to all three profiles.

The complete `derived-containers` program is another workload in that same
runner, using none/off, size/auto and size/all. Source markers in its real
`containers_run` path locate the sorted list and completed composition. Two
concrete `evidence_less` calls use the same high-bit operand as signed and
unsigned values, requiring opposite comparison results. GDB must identify each
selected provider's frame and source line, verify the two unwind steps back to
`evidence_less` and `containers_run`, and inspect the caller's completed result
binding. The stack includes the application and entry point; acceptance does
not depend on GDB automatically printing return values. The runner retains
source maps, build reports and transcripts;
it checks source hashes, line tables, stripping and exact executable identity
for the whole reached library closure, not a fixture-only copy of it.
The complete `derived-hosted-memory` application is another workload, using
none/off, size/auto and size/all. GDB stops inside the runtime-selected
`sample_keep` and `text_emit` providers, identifies their actual source lines,
inspects the sampling state before and after its increment and the destination
delivery cursor, and requires the caller stack to include `process`, `run_logged`,
`run` and the fixture entry point. The text destination also retains its
`emit_retry` caller frame. The whole
memory-world application then completes its status-42 oracle. The same full
source inventory, assembly hashes, executable identity, line-table, stripping
and source-map checks apply to this application and its reached library
closure. These sessions exercise ordinary `any` dispatch in the application;
the real hosted I/O fixtures separately assert native process behavior.
`python3 compiler/tests/debugging/test_check.py` exercises transcript refusals
without GDB; `scripts/debug.sh` runs those regressions before the real sessions.

The default transport is native GDB. For the Mac's translated local Linux
loop, use `./scripts/linux-loop.sh ./scripts/debug.sh --runner=qemu`;
`--qemu=PATH` selects the emulator explicitly. This uses QEMU's GDB remote
stub with the same assertions and reports its transport. It never turns a
failed native session into a pass by automatically falling back to emulation.

## Native report identity and build inventory

`python3 compiler/tests/test_native_report_identity.py --refine ABSOLUTE_PATH`
checks real destination identities without substituting the fake filesystem.
It retains the original collision/refusal and successful-output oracles for
source and artifact links, absent leaves, actual symlink parents, case rules,
dangling links and indeterminate identities. `--directory` optionally chooses
another filesystem for the temporary cases. The native gate runs it with both
compiler build modes. `python3 scripts/tests/test_build_inventory.py` exercises
the production developer-build inventory decision, including C/header
addition, removal and renaming, without invoking a builder; it is also gated.

Absent names on an unknown filesystem remain conservatively indeterminate.
In particular, a Linux container cannot infer the host volume's case rules
from its virtiofs mount. For local object-quality measurements, put the
runner's `--output` on the container's own filesystem (for example `/tmp`),
then retain its `measurements.json` in the host build tree. This changes no
source, profile, execution oracle or acceptance threshold; the native gate's
ordinary `scripts/quality.sh` output already resides on its Linux filesystem.

## Complete programs to try

The runtime fixtures include small, complete programs rather than only
single-construct probes. Ten of them are collected in `examples.md` and use
the language and hosted library implemented through R4.20:

- [FizzBuzz](fixtures/runtime/fizzbuzz/main.ldn) traverses one through 100,
  prints the traditional lines and tallies their atom classifications;
- [greatest common divisor](fixtures/runtime/greatest-common-divisor/main.ldn)
  implements Euclid's remainder reduction;
- [insertion sort](fixtures/runtime/insertion-sort/main.ldn) sorts
  caller-owned storage through `inout` and a writable slice;
- [binary search](fixtures/runtime/binary-search/main.ldn) searches a read-only
  slice and returns a found-or-missing variant;
- [the sieve of Eratosthenes](fixtures/runtime/sieve-of-eratosthenes/main.ldn)
  marks composites in caller-owned fixed storage;
- [run-length encoding](fixtures/runtime/run-length-encoding/main.ldn)
  transforms a read-only slice into caller-owned structured output;
- [merge sort](fixtures/runtime/merge-sort/main.ldn) divides recursively and
  loops over caller-owned storage and a local work array;
- [fannkuch-redux](fixtures/runtime/benchmark-game-fannkuch-redux/main.ldn)
  enumerates all permutations of seven values and reports the official
  checksum and maximum flip count;
- [Mandelbrot](fixtures/runtime/benchmark-game-mandelbrot/main.ldn) plots the
  official 200-by-200 correctness image as a binary portable bitmap;
- [FASTA](fixtures/runtime/benchmark-game-fasta/main.ldn) emits the official
  1,000-unit repeated and weighted-random DNA sequences.

The examples use loops for ordinary traversal, reserve recursion for merge
sort's divide-and-conquer step, and verify their results through status 42;
FizzBuzz and the three Benchmark Game programs additionally have exact output
oracles. Together they exercise aggregate parameters, fixed arrays, slices,
`inout`, atoms, variants,
pattern matching, computed indexing, valued loop exits, text literals,
floating-point arithmetic, binary output and hosted I/O. The Benchmark Game
ports use its published algorithms and small correctness inputs, not its
performance inputs; they are correctness and compiler-pressure workloads, not
competitive benchmark targets. Their generated oracles were compared byte for
byte with the official
[fannkuch-redux](https://benchmarksgame-team.pages.debian.net/benchmarksgame/description/fannkuchredux.html),
[Mandelbrot](https://benchmarksgame-team.pages.debian.net/benchmarksgame/description/mandelbrot.html),
and [FASTA](https://benchmarksgame-team.pages.debian.net/benchmarksgame/description/fasta.html)
outputs.

The narrower runtime fixtures retain the single-construct and composition
coverage behind those examples. On Linux x86-64, compile one from the
repository root with:

```sh
refine --root=. --target=linux-x86-64 --emit=exe \
  -o /tmp/landin-insertion-sort \
  compiler/tests/fixtures/runtime/insertion-sort
/tmp/landin-insertion-sort
test $? -eq 42
```

Each program returns 42 when its result is the expected one. They are runtime
fixtures as well as examples, so the authoritative Linux gate compiles, runs
and checks all ten during explicit complete native acceptance.

## Metadata

`fixture.meta` is `key: value` lines, with `#` comments and blank lines.

| key | required | meaning |
| --- | --- | --- |
| `class` | yes | must match the directory the fixture sits in |
| `summary` | yes | one line, what the fixture proves |
| `program` | yes for runtime, ABI, and a rooted positive or negative | the `.ldn` program the fixture runs or uses as its compile-only corpus file |
| `with` | no | the rest of the Landin module, when one file is not enough; never a C source |
| `root` | no | a positive, negative, runtime or ABI fixture's import root, relative to its directory; the directory itself becomes the entry module |
| `c-sources` | yes for ABI | comma-separated, ordered C companion sources relative to the fixture directory |
| `c-args` | no | whitespace-separated C compiler and linker arguments for an ABI fixture |
| `expect` | no | the file holding the expected bytes |
| `args` | no | the arguments `refine` is run with |
| `run_args` | no | the arguments handed to a compiled runtime or ABI program |
| `run_expect` | no | the file holding a runtime or ABI program's expected merged output |
| `status` | no | the exit status `refine` or a compiled program must produce (default 0) |
| `traps` | no | `yes` if a runtime or ABI program must end without returning a status |
| `stream` | no | `output` (the bytes must be on standard output, and standard error must be empty) or `merged` (default) |
| `lex` | no | the exact complaint the scanner must produce, for a fixture whose fault is lexical |
| `codes` | yes for a negative with a program | the diagnostic codes the report must carry, in order |
| `constructs` | yes for a fixture with a program | the `[NNNN]` ids, without brackets, this fixture is evidence about |
| `targets` | yes | comma-separated targets the fixture applies to |

`codes` also says which stage refused the fixture, and that is what decides
whether the grammar must derive its program. The frontend refuses what the
grammar cannot derive, so a fixture whose first code the scan or the parse can
raise must not derive; a later stage refuses source that parsed, so a fixture
whose first code belongs to one of those must derive exactly as a positive
fixture does. `check.py` reads which codes the frontend raises out of
`Landin.Diagnostics.Lexical` and `Landin.Diagnostics.Syntactic` rather than out
of the number, because the catalogue's own header forbids reading a stage off a
code — `L0010` began in lexical refusal and is now raised only by the parser.

`codes` is an ordered list and not a set. Two refused constructs in one file
are two reports, and a regression that doubles a count is invisible to a set,
so a fixture that contains two refused uses names its code twice in source
order. Spaces around comma boundaries are insignificant; the harness
canonicalizes them without sorting the codes or removing duplicates.
`float-literal-not-enabled` names one `L0301`: its one literal is a
float in an integer context, refused by the checker, so the grammar must
derive it. `check.py` holds every name in `codes` to
the catalogue, and
refuses a negative fixture with a program that names none; the parser suite
scans and parses the program and holds the report to the exact sequence.

`with` is how a fixture is more than one file. [1840] says the module scope
is "every file compiled together", so a claim about it cannot be made by a
fixture that can only name one; `program` stays the file the fixture is named
for and `with` is handed to `refine` after it, in the order written. Naming
the rest of a module with no `program` to be the rest of is a reported fault,
and `check.py` holds every file either key names to being there — a name
pointing at nothing would compile one file while claiming to have compiled
two. Every `.ldn` in a fixture directory is held to the grammar already, so
the extra files are derived like any other. C companions never belong in
`with`; an ABI fixture names them only with `c-sources`.

`root` is the directory-module counterpart for a positive, negative, runtime or
ABI program. It is relative to the fixture directory; when present, the
fixture directory is passed to `refine` as the entry module and the root is
passed first with `--root`. It cannot be combined with `with`, because rooted
discovery owns the source membership. A rooted positive or negative fixture
must also name a nonempty `program`: that is the corpus file whose compile-only
acceptance or refusal is counted. This is how compile-only fixtures and
executable fixtures alike import repository-owned modules such as `core/*`
without keeping fixture-only copies. The parser's exact-code case retains its
fake filesystem for ordinary negative fixtures, but reads the real module
closure for a rooted negative because its pinned report depends on those
imports resolving.

An ABI fixture requires `program`, `c-sources`, `constructs`, and `targets`.
`c-sources` is a comma-separated ordered list. Every entry must be a portable,
slash-separated relative path ending in `.c`, must contain no backslash or
colon, must remain below the fixture directory (no absolute, empty, `.` or
`..` component), and must name a file that exists. The list is passed to the
target driver in the order written. `c-args`, when present, is a
whitespace-separated argument-vector suffix; no shell interprets it. Both keys
belong only to ABI fixtures, duplicate keys or C source paths are faults, and C
source files in `with` are faults.

The ABI harness runs `refine` for Linux x86-64 with the Landin inputs followed
by `--target=linux-x86-64 --emit=asm -o <assembly>`. It then selects
`Driver_For (Linux_X86_64, "")` and invokes that driver once with arguments in
this exact order:

```text
<assembly> <c-sources in metadata order>
-std=c11 -Wall -Wextra -Werror -no-pie
<c-args in metadata order> -o <executable>
```

The resulting executable may get `main` from Landin or from a C companion.
The harness passes `run_args`, compares `run_expect` with merged standard
output and standard error when it is present, and then compares either the
exit `status` or the non-returning `traps: yes` verdict. Thus a C `main` can
drive exported Landin routines, and a Landin `main` can drive imported C
routines, without adding C inputs to the product compiler.

`constructs` is what R1.90 indexes the corpus by, and it is a written list
rather than a reading of the summary. A citation in prose is prose: it is
there to explain the fixture to a person, it may name a paragraph the fixture
merely mentions, and a heuristic over English is how a check ends up
believing 114 lines of it were code. `check.py` holds every id to a paragraph
`tour.md` or `spec.md` actually defines, and the harness holds it to being
four digits — the two halves of the question, asked by the side that can
answer each.

The decision register's `Pinned by` paragraphs are different: those paths are
the current evidence they promise a reader, so `check.py` holds every named
fixture directory to existing. Historical prose may still name a retired
fixture when the retirement is the point; a live evidence list may not.

Name a construct when the fixture's *passing* would change if that construct
were implemented wrong, and not when the construct merely appears in the
text. Every runtime program contains literals, so naming [1770] everywhere
would make that row read "covered" while saying nothing; a fixture whose
asserted values come from literals earns it. The failure this rule prevents
is the one a matrix is most prone to: a full column that means nothing. When
a claim turns out not to be earned, the honest repairs are to drop it or to
make it true — `runtime/statements-run-as-they-read` claimed [1840] before
it declared anything inside an arm, and grew a function that does.

A fixture with a `program` must name at least one, because a `.ldn` program
is written in the language and is therefore evidence about some construct of
it. A fixture without one is about the tool rather than the language — an
unknown option, the identity text, an implementation-side note — and names
none for the same reason. A construct the kernel does not enable yet is
perfectly good: `negative/convention-not-enabled` names [1830] for the
refusal and [0900] for the thing being refused, and [0900] is a paragraph
about a construct no fixture can yet use.

`targets` is required by R2.90 and checked against the targets `ROADMAP.md`
names: `linux-x86-64`, `macos-arm64`, `cortex-m`, `synthetic-32`. A fixture
may name a target the
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
| --- | --- |
| unit | a note of what an implementation-side case covers; the case itself lives in `compiler/ada/tests` |
| negative, end-to-end | executed: `refine` is run with `args`, and its bytes and exit status are compared with `expect` and `status` |
| runtime | executed: `refine` compiles and links `program`, the result is run, and its own exit status is compared with `status` — or, with `traps: yes`, it is held to having ended without returning one |
| ABI | executed in the existing `runtime fixtures execute` case: `refine` emits assembly, the selected Linux x86-64 C driver compiles it with `c-sources`, and the result's output/status/trap verdict is checked |
| positive | executed: the grammar must derive the program, `refine` must accept it through checking, lowering and verification, and the Linux x86-64 backend must emit assembly for it |
| debugger | sessions in `debugging/` run separately through `scripts/debug.sh` |

A class with no fixtures is the normal state early in the roadmap, and an
empty class directory is not a fault. A fixture that records an expectation
nobody runs is.

That last sentence decides what a runtime or ABI fixture does on a host that
cannot finish the target, and the answer is that the run fails. A macOS host
with no ELF toolchain reports the existing `runtime fixtures execute` case as
one failing case: runtime fixtures carry `refine`'s own L0500 report, and ABI
fixtures name the triplet-selected C driver that could not be run. Skipping
would be the quiet non-run the sentence refuses, and it would also hide the
gate losing its toolchain. This is the same rule `scripts/env.sh` already
applies one level up: a machine without the pinned GNAT is told so and stops,
rather than quietly building nothing.

A runtime or ABI fixture carries `program` and either an exit `status` (zero by
default) or `traps: yes`, and neither `expect` nor `args`, because nothing
compares `refine`'s own output — what is asserted is what the compiled program
did. One without a `program` is a reported fault, for the same reason `expect`
without `args` is: a status nobody produces is dead data. ABI additionally
requires `c-sources`; `c-args`, `run_args`, and `run_expect` remain optional.

Accepted, emitted and executed are three claims and not one, which is why
three classes make them. A positive fixture is a program the compiler must
accept, and asking only that was how four of [1810]'s statement forms reached
R1.80's audit having never been handed to a backend: every stage accepted
them and no case asked for a byte of assembly. So the positive class now
emits as well, and a construct that reaches a compiler defect on the way to
`.s` fails there rather than waiting for a runtime fixture to happen to use
it. It is still not executed — most of the corpus is a fragment with no
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
the program returns 42, so the fixture fails when the trap edge is removed —
which is measured, not assumed. `runtime/a-zero-divisor-traps` cannot make that
distinction, because x86-64 faults on a zero divisor whether or not the
compiler guarded it; it proves [1950]'s obligation is met and not which of the
two stopped the program. D11 is where the choice to emit a deliberate `ud2`
rather than inherit the incidental fault is recorded, and deterministic
assembly is what pins it.

## The grammar corpus

A `.ldn` file under `positive/` must be derivable from the enabled grammar in
`spec.md`. A negative program a later stage refuses must derive too; one whose
first diagnostic comes from the scanner or parser must not. `check.py`
enforces those stage-sensitive verdicts on every full run, and it enforces
that every construct in the grammar section is named by at least one fixture,
so a production nothing pins is a reported fault rather than a quiet one.

The corpus made the specification and its examples check each other before a
compiler existed. R1.40's parser now has to agree with the same corpus, and a
disagreement between the parser and the grammar is a defect in one of them
rather than a matter of opinion.

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

## Diagnostic and semantic coverage registers

`python3 check.py --catalogue` writes both `diagnostics.catalogue` and
`diagnostics.matrix`. The compact catalogue comes from
`Landin.Diagnostics.Catalogue`, which is the only place in the compiler where
a code is written. The matrix crosses every row's source/span/label/note
contract with its emitter and fixture or fake-host test owner. A live code with
no emitter or owner, a retired code still emitted, and a source diagnostic with
no negative-program owner are gate failures; L0111's deliberate parser limit
has its implementation-side unit owner instead.

`python3 check.py --coverage` writes `guarantees.matrix`,
`conformances.matrix`, `prototypes.matrix` and `targets.matrix`. Their source
registers are D148 in `spec.md` and R2.90 in `ROADMAP.md`. The checker closes
the guarantee rows over every construct the independent construct matrix says
is accepted or emitted, validates every fixture, diagnostic, decision and
prototype finding they cite, requires every fixture to name applicable targets,
and recovers prototype finding line numbers from the prototype sources. The
copies are generated for reading; editing one cannot change its source.

Every full `check.py` run fails if any generated copy is stale, and it refuses
a code literal written anywhere else under `compiler/ada/src`.

The catalogue check earned itself immediately: the driver had held `L0001` to `L0004`
as literals since R0.50, and moving them into the catalogue was the first
thing it demanded.

## lowering.ir and layout.targets

`compiler/tests/lowering.ir` is generated: `./scripts/test.sh --record`
writes it by lowering every positive fixture and rendering the Unit with
`Landin.IR.Dump`. `compiler/tests/layout.targets` is written by the same
command, and records what `Landin.Targets` says scalar and aggregate shapes
measure, align to and offset their fields by on each described target. Its D74
rows also work the tag-first variant part and one containing aggregate on each
description. Both are recorded artefacts `check.py`
does not touch, and that difference matters enough to state.
`check.py` generates the other two because it owns their sources — its own
tokeniser, and the catalogue's Ada text. It owns nothing here: producing
these files means running compiler stages and asking the target model, so the
Ada harness is what can produce them and **`python3 check.py` will not tell
you either is stale.** `./scripts/test.sh` will, and so will the gate.

`layout.targets` exists for an ordering reason R2.10 states: a description is
the only thing a compiler with no such machine can be held to, and the
synthetic 32-bit target has no backend and will not have one until a Cortex-M
slice arrives. Recording both targets rather than that one is deliberate —
what a reader needs is not "the 32-bit model says four" but the two columns
beside each other, because the defect being guarded against is a description
quietly inheriting the development host's answers. A `usize` that read eight
in both would be exactly that, and it is a one-line change away at any time.

Recording runs no case, and no case ever writes. Two disjoint modes in one
binary, chosen only by an argument a human typed: there is no environment
variable, nothing writes the file when it is missing, and nothing rewrites
it when it does not match. A golden that repairs itself on a mismatch
records the defect instead of reporting it. The loop is closed by hand —
record, then run the suite again with no argument — or by
`./scripts/test.sh --record-and-run`, whose shell wrapper makes both explicit
binary invocations after one build.

What the file is for is narrow, and `landin-ir-dump.ads` says it: it proves
the lowering has not changed its mind. That the corpus derives from the
grammar is `check.py`'s, and what the instructions mean is
`Landin.IR.Verifier`'s. No origin is printed, deliberately, so a comment
edit above an instruction does not rewrite the artefact.

## Derived programs

The four prototype text files in the repository root remain design-stress
sketches, including their omissions and historical findings. Complete derived
`.ldn` programs are separate artefacts and arrive with the roadmap work that
can compile them.

`runtime/derived-parser` hosts the complete prototype-2-derived lexer and
recovering configuration parser in `examples/config_parser`. Its derivation
manifest maps the executable behavior and negative controls to the prototype.

`runtime/derived-containers` hosts `examples/derived_containers/workload` as the
complete prototype-3-derived workload. Its `DERIVATION.md` maps every prototype
section and Z finding to the ordinary `core` modules, executable paths and
negative corpus. The runtime entry requires every path to succeed before
returning 42, with no stdout or stderr: list growth and sorting, direct fixed
array mutation, nested-array field ranges, initialized raw storage, vector and
small-vector failure/retry, map collisions/compaction/enumeration, each of the
three map acquisition failures, tree traversal and heterogeneous dispatch.
Providers remain explicit capabilities and cleanup is observable; no
fixture-private replacement container library or implicit resource ownership
stands in for the prototype. This same workload is mandatory in the six-profile
runtime matrix, object-quality measurements and source-debugger acceptance
above. These local runners do not replace the exact-revision native gate in
`ROADMAP.md`.

`runtime/derived-hosted-memory` hosts the complete prototype-4-derived
application in `examples/derived_hosted/app`. The runnable hosted entry and
its derivation map live in `examples/derived_hosted`. Runtime configuration
constructs heterogeneous filters and either a counting or text destination;
the processing loop calls their ordinary `any` evidence entries. The reader
retains partial lines across chunks and emits a final unterminated line.
Copied arguments and message storage survive helper returns, and delivery
retains its committed byte cursor across an explicit retry. The memory world
makes input fragmentation, output contents and failure cleanup deterministic;
the hosted fixtures use the same application with actual native Linux I/O.
The memory composition is also mandatory in all six quality profiles and the
three debugger workload profiles described above.

`runtime/r480-generic-provider-entry` pins the bound entry required when a
concept provider itself has constrained generic parameters. Two nested
providers execute through direct evidence and `any` calls, forwarding a
by-value aggregate, an aggregate result, an inout array and a declared failure.
The table entry supplies the provider's concrete evidence arguments to the
ordinary generic body; its source calling convention and the two-word `any`
representation remain unchanged.

R4.90 strengthens hosted parity closure beyond a populated construct column.
Every hosted row must cite a Linux runtime or ABI program, except the explicitly
registered compile-time rules whose exact acceptance/refusal is the oracle.
`check.py` enforces this boundary when the parity item closes; it does not infer
semantic adequacy from metadata. The audit adds distinct and inline nominal
types, exact once-evaluated field fills, atom comparisons across structural
sets, atom-bearing arrays/fields/payloads, parameterized union aliases,
conformance-key controls and recovered-error generic deduction. Review probes
include static distinct Boolean/pointer images, type-name misuse, exact union
application diagnostics and unused symbolic pointer obligations. Original
refusal sources promoted to enabled grammar remain byte-for-byte positive
fixtures, and all unchanged R4.80 recovery and provider oracles remain required.
D212's
ordinary allocator authority and all existing workload profiles remain required.
