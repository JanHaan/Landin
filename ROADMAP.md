# Landin roadmap

## Authority and scope

`spec.md` decides the language and `tour.md` explains it. This file is the
sole authority for open work: its phases, dependencies and gates, and the
register of work that waits for a trigger. A work item cannot overrule the
specification. A semantic change updates `tour.md` or `spec.md`, the fixtures
that pin it and this file together.

The first roadmap, R0 to R7, built the bootstrap compiler from an empty
repository to a feature-complete pre-v1 slice for Linux x86-64, macOS arm64
and Cortex-M0, and closed when its last item declared that endpoint. Its full
text is in the history, last at commit `335b0814`, and what it left open is in
the register below.

This roadmap takes the compiler from that slice to one that other people can
use on the machines they have: a frontend that scales and serves an editor,
assembly with operands, more hosted targets, the microcontrollers people
actually buy, a library split along the line the capability model already
draws, concurrency and measured optimization. Windows is deferred outside the
active scope; its existing identities below preserve the proposal for a future
explicit scope decision.

The stated 32 TB hosted endpoint remains an unverified project goal. What
quantity it measures and what evidence would prove it are still open.
Current hosted execution and the large-image work in the register below do
not establish a 32 TB bound. Define the measure and proof criterion before
claiming that endpoint as demonstrated.

Outside it, and staying outside: a build tool and a package manager, which
the Companion tool and ecosystem family owns; self-hosting; and every release
or version decision, each of which needs an explicit decision of its own.
Landin does not assume SemVer.

Work item and register identities stay in this file. Code, diagnostics,
fixtures, generated files and the other documents never cite a work item or
a register record of either roadmap, save the one status pointer `README.md`
and `handoff.md` carry, because an item is finished long before the text
that cites it is, and a citation that outlives its item is a question nobody
can answer. `check.py` refuses such a citation anywhere else.

`README.md` maintains the current compiler capability inventory. `handoff.md`
and `AGENTS.md` point to it instead of maintaining parallel inventories;
the `Done:` paragraphs here record completion evidence, not a second
current-capability summary.

## Mechanics

Phases are `R8`, `R9` and onward, stored in identity order, and each ends in
one gate. Work items are `R8.10`, `R8.20` and so on, spaced in tens, so work found
necessary between two items is inserted with a unit identity: between R8.20
and R8.30 it is numbered 21. Identities are never reused or renumbered,
including the first roadmap's.
Every item has exactly one status line and one dependency line:

```text
Status: planned
Depends on: R8.10, R8.20
```

A status is `planned`, `active`, `blocked` or `complete`. `blocked` means the
item cannot proceed for a reason other than its dependencies, and the reason
is one nonempty `Blocked because:` line in the item. A complete item's
dependencies are all complete. `none` is the only empty dependency value.
Work follows the execution order declared below. A phase selector expands to
its items in document order; an item selector selects only that item. Every
item appears exactly once and follows its dependencies. A phase's gate cannot
be claimed until all its items have their exit evidence, even when its work
straddles another phase. A phase explicitly deferred by a scope decision
does not hold up later independent work. Its items stay
blocked with their reasons, and its gate is inactive until scope is restored.
The next item is the first dependency-ready planned item in execution order,
and `README.md` and `handoff.md` name it.
There are no dates, estimates or versions here.

Execution order: R8, R9, R10, R11, R13.10, R13.11, R13.12, R13.13, R13.14, R13.15, R13.16, R13.17, R13.30, R13.18, R13.19, R13.31, R13.32, R13.60, R13.33, R13.34, R13.36, R13.61, R13.35, R13.70, R13.71, R13.72, R13.73, R14.10, R14.20, R14.30, R14.40, R12, R13.20, R14.25, R15, R16

The library availability split and hosted facilities precede microcontrollers.
R12.10 depends on R13.35 to hold the first boundary, and on R13.70 for the
lanes it changes. The freestanding
facilities retain R12.30's prerequisite and also depend on R12.60 to hold
the boundary after the whole microcontroller phase. R12 stays in scope, and
its gates and R13's gate retain their requirements, and no identity is renumbered. Each new R12 target repeats
the shared-library consumer matrix established by R13.10. The
microcontrollers wait behind R14's hosted items, by the maintainer's choice
when R13.70 began; R14.25 still follows R13.20, so R14's gate waits for R12.

An item is complete when its exit evidence exists: the gate green on the
completing commit for every host the gate runs, and, for a claim about a host
it does not run, a named run recorded in the item. Completing an item adds a
short `Done:` paragraph saying what landed and where its evidence is. The
reasoning belongs in the commits and in `spec.md`'s register of decisions,
not here; the first roadmap grew to thirteen thousand lines narrating itself.

Nothing accepts a revision. The gate is a safety net, not a verdict, and no
item claims otherwise.

## R8 — Stand on its own

Pay what the move off the first roadmap left owing: the citations it left in
the tree, a frontend whose time grows with roughly the cube of a program's
size, and a gate that runs one of the three targets.

### R8.10 — Remove the first roadmap's citations

Status: complete
Depends on: none

About eighteen hundred citations of R0 to R7 items, in about two hundred
and eighty files, and some fifty of the first roadmap's ledger records sit in
compiler sources and comments, diagnostic text and the goldens that record
it, fixtures, `spec.md`, `tour.md`, the prototypes, the evidence registers
and the guides, and nearly two hundred lines name `ROADMAP.md`, many of them
sending a reader there for closure evidence and acceptance records that are
now only in the history. Each is rewritten to say what it meant, or removed
where it said nothing. A refusal that names the work enabling its construct
names the construct's state instead, which amends [1830]'s note and the two
refusal tables. The construct inventory loses its Phase column.

Exit evidence: no file outside `ROADMAP.md` cites a work item or register
identity of either roadmap beyond the status pointer, `check.py` refuses one, the first roadmap's index
is deleted from this file, and every changed diagnostic is pinned by its
recorded report.

Done: about 1,700 lines in some 280 files now say what their citation
meant. A refusal's second note states the form's standing, a recorded
boundary, a withdrawal or a transfer, from a table in place of an item (D246
and [1830]); L0305 and the tool and call notes cite a rule. The 22 goldens
that record them are re-recorded. The inventory has no Phase column and the
hosted parity rule no longer reads item statuses. `check_roadmap_citations`
refuses an item of either roadmap and a record of the two debt ledgers and
SR, and its controls show it; the inherited letter records collide with
bytes, decisions and errata and stay with review. Fixture directory names
are unchanged. The index is gone.

### R8.20 — Make the frontend scale

Status: complete
Depends on: none

Measured with the release compiler on one Linux host: a synthetic file of 250,
500, 1,000 and 2,000 trivial functions compiles in 0.36, 1.9, 12 and 89
seconds, and 85.7 of the 89 are spent before lowering. The derived log filter
and the `core` it uses, about 3,500 lines, spend 6.6 of 7.9 seconds there.
Nothing larger than a prototype can be written against that, and no editor can
wait for it. Find the superlinear passes and replace them. This takes on
register records R551-06 and R551-10 and the corpus timing question SR-02.

Exit evidence: a scaling benchmark in the repository, generated inputs of
growing size up to at least 16,000 declarations plus the derived programs,
whose frontend time, the median of five runs, grows by no more than 2.5 times
per doubling across the range; the derived log filter checks in under half a
second with the release compiler on the host that measured the numbers above;
the same inputs, and a struct of 20,000 fields, check without exhausting the
host, with each stage's storage measured and a named refusal past a stated
bound; and the gate runs the benchmark and fails when a ratio exceeds 2.5,
which does not depend on the runner's speed.

Done: `scripts/scaling.py` generates eight families from 1,000 to 16,000
declarations and times the derived programs, each five times, from
`--stage-report`'s per-stage processor time and peak storage. Emission is
held to the bound as well as the frontend, because the backend's scans were
the same records' work. The gate also refuses a peak-memory ratio above 2.5
per doubling, using the largest peak reported across the five runs at each
size. On the host that measured the numbers above, with
the release compiler, the largest ratio is 2.19, the 2,000-function input
checks in 0.41 seconds of the 89 it took, and the log filter's frontend
takes 0.17 of 6.6. D247 refuses a routine of more than 16,384 declarations or a struct
of more than 16,384 fields with L0325; at that bound a routine with a loop
peaks at 130 MiB, and the 20,000-field struct is refused rather than
exhausting the host. Every change kept every verdict, diagnostic and emitted
byte of the corpus, checked program by program against its parent. The
`scaling` gate job runs the benchmark.

### R8.30 — Run every existing target in the gate

Status: complete
Depends on: none

The gate builds and tests on Linux x86-64 in debug mode and nothing else.
Add macOS arm64 on GitHub's arm64 macOS runners, the release build, the
Cortex-M QEMU and Renode lanes on Linux, the GDB and LLDB sessions, and the
structural editor grammar's integration pass. Add the runners nothing runs
today: the determinism closures and their controls, the bindings tests, the
object-quality lane, `scripts/tests`, and `check.py`'s control suite; and run
the fixture execution suite with many workers, which is how a race in the
harness's reads went unseen. This takes on R730-22 and R730-25.

Exit evidence: `gate.yml` runs each of those on every push or meets the R8
gate's explanatory-only reuse exception; a failure in any required job fails
the gate, every end-to-end target claim is a verdict in a record the
coverage readers read rather than a run, and the documents stop describing
the gate as Linux and debug only.

Done: `gate.yml` initially ran its worker jobs on every push and a final `gate` job
that fails unless all succeeded: `check.py`, every `scripts/tests` module with its
controls, the debug and the release corpus at eight workers with the
determinism closures and report identity, object quality and GDB, the
bindings, the editor grammar with a pinned CLI, every Cortex-M lane, the
scaling benchmark, and on `macos-26` the host suite in both modes, native
hosted parity and LLDB. Cortex-M runs on any glibc 2.38 host from a lock
that carries its tools' whole runtime; one GDB per worker and parallel
programs took it from 2,309 to 836 seconds, and Darwin parity from 1,465 to
755, where macOS's vetting of each new program bounds it. The Darwin
diagnostics runner runs end-to-end fixtures, and `check.py` refuses a
fixture whose named target no record places. Every job was first green at
`6b17c109`, after two runner-only faults were fixed at their cause: a
process-timeout witness whose deadline a cold interpreter could miss, and a
Renode scheduler notice the Cortex-M oracle took for a model warning. The
completing commit's own gate then found a third: Renode's log thread wrote
into the middle of a script's result marker on the console they shared, so
a script's output and Renode's log are now separate files.

The current gate keeps those verification lanes separate while two release
build jobs supply same-run executables to the other release lanes on their
respective hosts. Each consumer verifies the build's source and native
toolchain manifest before using it; the final job still requires every build
and verification verdict.

### R8.40 — Move the peripheral models onto QEMU

Status: complete
Depends on: R8.30

Renode carries every Cortex-M check that needs a peripheral: the derived
driver's protocol, the device fixtures' access and refusal checks, the
firmware and backend DMA lanes, the stack observer, one source-debugging
session, and the hosted lane that drives a device model from x86-64 code over
a line transport. It is the largest dependency the gate installs, a portable
build with its own .NET runtime driving four C# models and a stack observer
in 559 lines; it is absent from the flake; its threads and log have twice
put text on the console a lane's result was read from; and the Cortex-M job
that runs it sets the gate's length. Its CPU adds nothing QEMU's does not:
both descend from QEMU.

Run the models on the QEMU the CPU lane already pins. Its microbit machine
leaves the model addresses unimplemented, and an Arm watchpoint stops before
the access, so a harness on QEMU's debugger stub, in Python's standard
library, stops at every access to a model's window, decodes the Thumb load or
store there, performs it against a Python model and steps past it; DMA
writes RAM while the CPU is stopped, and an interrupt is a write to the
NVIC's pending register. The harness is single-threaded, QEMU's clock runs
from its instruction count, and a lane stops at a named firmware event
rather than after an interval. The models keep the contracts the C# models
state, including refusing an unknown, misdirected or wrongly sized access,
and the decoder refuses every form that is not a single load or store. The
hosted lane speaks the same line protocol to a model with no CPU behind it.
The source-debugging session moves to the QEMU sessions, and R12's boards
take the claims about a real device. A spike outside the tree ran the
generated peripheral consumer this way in all six profiles and matched the
Renode lane's trace oracle exactly.

Exit evidence: every Renode lane except the stock STM32 control passes on the
harness with its oracles unchanged; that control tests Renode's own models and
is removed with Renode rather than migrated; the decoder agrees with the
pinned disassembler on every load and store in every image the lanes build;
a refused access, an interrupt never delivered and a wrong device reply each
fail a named control; the gate's Cortex-M job runs the harness in Renode's
place; and Renode, its lock
entries and the C# models are gone from the tree, with every document that
cites Renode as evidence saying what now carries it.

Done: `environments/cortex-m/machine.py` serves the Python models in
`models.py` from the pinned QEMU's debugger stub, single-threaded, and runs
the firmware until it is idle rather than for an interval. Against a Renode
run of the same tree on one host, all six profiles gave identical device,
prototype, packed, transport and driver traces, the same 33 protocol steps,
2,068 executed corpus cases and the same stack observations. The hosted lane
is a Python line transport, the Renode source session runs through the
harness's relay to GDB, and the stack observer samples at debugger
breakpoints, except in the four-million-sample exhaustion scenario, which
paint measures. The stock STM32 control tested Renode's own models and went
with it. Every harness session holds the decoder to `objdump` over its
image, and a refused access, an undelivered interrupt and a wrong reply each
fail by name. The gate's `cortex-m` job runs it: its lanes took 612 seconds
against 1,281 with Renode, and the job 15.5 minutes against 26.7, at
`4465ffcd`.

### R8 gate

- Nothing outside `ROADMAP.md` cites a work item but the status pointer.
- The frontend's scaling benchmark holds in the gate.
- Every target the compiler has runs in the gate on every push, or, for an
  edit declared explanatory to four documents no target lane reads, passed
  on `main` within the week.
- Every Cortex-M peripheral check runs on QEMU in the gate, and Renode is
  gone.

## R9 — Inline assembly

Assembly with operands, early, because the microcontroller work needs it and
because every tool written after it has to know it exists.

### R9.10 — Specify assembly with operands

Status: complete
Depends on: none

Today `assembler.block` exists on Cortex-M0 only, with one `u32` passed through
`r0`, and the hosted targets refuse assembly. Specify typed operands bound to a
register or a target's register class, as inputs, outputs or both, with
declared clobbers and memory effects, in [1630] and a register decision. Not
GCC's constraint strings: a target-specific language inside a string literal is
exactly what a type checker cannot see into. The form must keep the verified
IR's view of the block as one instruction with declared effects, keep the
frame pointer, and reserve no register, which the stackful-fibre direction
needs.

Exit evidence: [1630] and the grammar amended, the decision recorded with its
alternative, and positive and negative fixtures the grammar derives.

Done: an operand is `in`, `out` or `inout`, a name, an integer type and a
register `at` a name the target's table answers for, or the class `general`;
outputs are the block's value, and the text writes `{name}`. [1630], [1990]'s
register table and D248 say it, with the rejected alternatives: constraint
strings, output places, pointer operands, clobber-nothing defaults and a
declared memory effect. Memory effects are the one departure from this item's
text: they are fixed rather than declared, because the default is always
right and nothing here would use a narrower promise. The parser reads
operands after any call, as the grammar derives them, and the checker holds
them to every rule on all three targets, refuses them off `assembler.block`,
and then refuses the block at the lowering limit [1990] states; so
`negative/assembly-operands-not-lowered`, `core/cpu` on the new form, fails
only there. `positive/assembly-operand-forms` and 21 negative fixtures pin it,
four of them refused by the parser and underivable; D230's form stays as the
shorthand, and float operands are SR-04's. The gate ran every job green at
`77d89e08`.

### R9.20 — Implement assembly with operands on every target

Status: complete
Depends on: R9.10

Lower the specified form on Cortex-M0, x86-64 and arm64, allocate its operands
and honour its clobbers, and describe it to the debugger. That removes the
lowering limit [1990] states, moves D230's shorthand onto the same
instruction, and lowers operand-free hosted blocks; the fixtures that pin the
limit become executed ones.

Exit evidence: executed fixtures on all three targets, including one per
target that the IR verifier refuses, and `core/cpu` written on the new form.

Done: every `assembler.block` form, named operands, D230's shorthand and the
operand-free block, is one `Assembly` IR instruction whose entries carry each
operand's direction, name, type, register and output slot, and every target
emits it: Cortex-M0 and arm64 load inputs through their own registers and
set one output aside when every register holds one, and x86-64 keeps
declared registers out of allocation and saves them. The lowering limit is
gone. Five runtime `assembly-*` fixtures execute on Linux, natively on macOS
arm64 and under QEMU at every profile; the verifier refuses r8, rbp and x18
in `cortex ABI/assembly IR` and the two backend cases; `core/cpu` runs on
`general` operands; the GDB and LLDB sessions stop on a block's line, read
its output and unwind the register it declares, and the Cortex source lane
steps over `core/cpu`'s block. The checker now refuses Apple's `%%` separator
and counts `general` against the registers a block names. The Mac was
unreachable, so Darwin execution and LLDB are the gate's: every job green on
`05069afb`.

### R9 gate

- One source form of assembly with operands runs on every target.

## R10 — A frontend for tools

A language server that runs inside the compiler, a formatter, and diagnostics
that say how to fix what they found. The compiler is already a library behind
tested stage seams and a host interface, so the server is its third client
after `refine` and the test program.

### R10.10 — Reclaim a compilation's memory

Status: complete
Depends on: R8.20

Sources, trees and every stage table are allocated for the life of the
process and never freed, which is right for a batch compiler and wrong for a
server that checks on every edit. Give a compilation its own storage and free
it as one.

Exit evidence: a test that checks the same program many times in one process
with memory that stays flat, and a driver that behaves identically.

Done: the stage tables are aliased components of a tagged `Compilation`, the
forest frees its trees and the source set its snapshots, which are limited
and handed out by reference; every accessor takes an aliased parameter, so a
reference that could outlive its compilation is refused where it is written.
Checking and resolution recognise their own trees and keys by a serial, not
by an address a freed table's successor could reuse. Checking the derived log
filter left 13.1 MB allocated per check and per emission; the `memory` suite
now runs twenty checks and four emissions with debugging information in one
process, permits at most 64 KiB of bounded settling, and rejects growth
continuing across both parts of each measured tail. A control verifies that
three kept compilations are counted. The count is the allocator's live bytes:
`mallinfo2` on Linux, and on Darwin the zones' enumerated in-use ranges,
because a GNAT-linked binary records SDK 10.21 and under it `size_in_use` keeps freed
blocks counted. `scripts/driver_manifest.py` held every commit to its parent:
all 8,127 entries agree — status, report, assembly, build report and source
map for every fixture on every target — and the largest scaling ratio is 2.19
against the parent's 2.18. The Mac ran the host suite, 754 cases, and the
gate was green on every job on the code of `434b2477`, run before it was
rebased onto a commit that changed only `flake.nix`.

### R10.20 — Keep comments and layout

Status: complete
Depends on: none

Comments produce no token and layout is discarded. Keep both in a side table
beside the token stream without changing what the parser sees.

Exit evidence: every source in the corpus and `core` reproduced byte for byte
from its tokens and the side table.

Done: the scan keeps every byte that is not a token as a piece of space in the
stream: a run of blanks, each line end with its own bytes, and the line, doc
and block comments, one never closed running to the end of the file beside
its fault. Doc comments are a kind of piece rather than a table of their own,
and a token's pieces are found by offset, never recorded twice. A byte-order
mark and every other byte no rule spells stay tokens. The syntax stage copies
each stream's pieces into `Landin.Tokens.Spacing`, a table of the compilation
beside the forest, after the parse; the parser and every later stage read
none. A test-side check written from [1750] and [1780] requires tokens and
pieces to tile each file exactly: all 2,098 `.ldn` files in the repository,
faulty ones included, and every corpus program, truncation, mutant and random
stream the parser suite reads. A piece is 12 bytes, and the derived log
filter's 28 sources keep 185 KB of it, 1.4% of what one check allocates; the
memory suite stays flat. `scripts/driver_manifest.py` held every commit to
its parent: all 8,127 entries agree, and the largest scaling ratio is 2.20
against the parent's 2.17. The Mac ran the host suite in debug and release,
757 cases each, and the gate was green on every job on `3687cfbe`.

### R10.30 — Make diagnostics say how to fix it

Status: complete
Depends on: R8.10

Suggestions for misspelt names and near misses; machine-applicable edits
attached to a diagnostic; `refine explain` for every catalogue code; and lints
as warnings in the catalogue, with codes, rather than a second tool with a
second opinion.

Exit evidence: each kind of edit and every alternative offered by a pinned
fixture is applied and compiles clean, every catalogue code is explained, and
every lint is a catalogued code with a negative fixture.

Done: a diagnostic carries fixes beside its notes, each a kind, an exact or
likely applicability, a help sentence and edits: byte spans of one or several
sources and their replacements, ordered and never overlapping, which is an
editor's workspace edit with its coordinates still to convert. The catalogue's
`Fixes` column says which codes may carry one and which must, the driver hands
the report back as data beside its text, and the compiler never applies a fix.
Suggestions rank what a position could have named by bounded optimal string
alignment distance, innermost scope first, and never offer a name out of scope
or inaccessible: L0201 for values, types, module members and selected imports,
L0308, a misspelt argument label, a misspelt keyword and a missing module.
L0109 is offered its declared name exactly, L0303 `mut`, L0105 `==`. Eleven
negative fixtures apply every kind of fix and every offered alternative through
the `fixes` suite and compile each result clean; one fixture offers three tied
spellings. `refine explain` is a subcommand printing
`docs/diagnostics.md`, generated into the compiler as an exhaustive case, so
every code is explained and each example is compiled to its own code. D251
admits a warning only as the compiler's judgement with the exact fix that
settles it; L0326 diagnoses a local `mut` nothing needed, and L0349 diagnoses
an unused local with a direct scalar literal initializer. The fixtures
`negative/mut-never-written` and `negative/unused-pure-local` pin them, and
`codes:` pins warnings on every
fixture that compiles a program. `scripts/driver_manifest.py` held every
commit to its parent: status, assembly, build report and source map agree for
all 8,169 entries, and the only report differences are added help lines and
warnings. The largest scaling ratio is 2.21. The Mac ran the host suite in
debug and release, 766 cases each, and the gate was green on every job on
`f7ab10af`.

### R10.40 — Format source

Status: complete
Depends on: R10.20

`refine fmt`: one style and no options.

Exit evidence: formatting is idempotent and preserves every comment over the
whole corpus, and `core` and the examples are formatted, which the gate holds.

Done: D252 records one layout decided by the compiler: space only, never a
token, a comment's bytes or a line broken or joined, LF line ends, and
continuation lines placed by the tree. Its rules were measured on `core` and
the examples before any was written, and `docs/format.md` shows each with a
program as written and as formatted, which the `formatting` suite holds
`Landin.Formatting` to. The formatter returns space-only edits in byte order,
the shape R10.50's formatting request answers with, and refuses a source that
does not parse with its own report; it scans a changed result and raises a
defect if a token or comment moved, while byte-identical output needs no
second scan. A line comment now ends at its last
visible byte, so no trailing blank belongs to a comment. `refine fmt` rewrites
files and `refine fmt --check` reports L0008. Over all 2,114 sources in the
repository the 80 that fail to scan or parse are refused and every other keeps
its tokens and comments, adds no line, and offers nothing when formatted again;
`core`, the examples and the running examples are formatted, which the gate's
`formatting` case holds. Seventy lines moved and no line number anything pins.
`scripts/driver_manifest.py` held the four formatter commits equal to the parent
at all 8,169 entries, and the reformat equal under `--layout-only` from one
checkout: 316 entries moved, all in fixtures that read a formatted source, none
in status, output or report. The largest scaling ratio is 2.19. The Mac ran the
host suite in debug and release, 773 cases each, and the gate was green on every
job on `af14ff10`.

### R10.50 — Serve an editor

Status: complete
Depends on: R10.10, R10.30, R10.40

A language server linked against the compiler library, over standard input
and output: diagnostics, definitions, hover types, formatting and the edits of
R10.30 as code actions. When syntax errors are confined to eligible routine
bodies, analysis checks the rest of the module using stand-ins for those
bodies. An error elsewhere stops further analysis even if the parser recovers
later declarations. Whether it is `refine lsp` or its own executable is
decided here.

Exit evidence: scripted sessions in the gate for each capability, and a
bounded run over mutated corpus sources that never crashes the server, which
takes on the frontend part of R551-19.

Done: `refine lsp` is a language server over standard input and output, a
subcommand like `explain` and `fmt`, with incremental synchronisation:
diagnostics with their codes, explanations and related information,
definitions, hover with types as the checker spells them and doc comments,
D252's formatting as edits, and R10.30's fixes as quick fixes, preferred
when exact. It reads with the driver's own loader and checks with its own
stages, now `Landin.Driver.Loading` and `Landin.Driver.Checking`, through
buffers held over the filesystem; a file belongs to its directory's module
under the editor's roots. Checked modules remain available for navigation
until a document opens, changes or closes, or a watched disk file changes;
the cache holds at most one
compilation per open module, not a fixed byte budget. A sound analysis uses
one compilation; an eligible broken body causes a second compilation that
takes unchanged syntax trees from the first. The original is then released;
the checked result may remain cached. A burst of edits is analysed once.
One multi-module publication round may additionally cache exact parsed
shared imports; that temporary cache is released when the round ends.
D253 answers past a hole only inside a routine body: the server checks a
stand-in with each broken body blanked and `loop do end loop` written in it,
so no stage changed and `refine` reports as before.
[2000] and D254 say what a doc comment is about. JSON is read strictly and
bounded, framing is bounded, and positions are converted in one package, in
UTF-8 or UTF-16. The scripted sessions under `compiler/tests/server/`
run in the test program and through the executable on Linux and macOS; the
memory suite runs eight sessions of twenty edits, with no net growth across
the last three measured sessions.
`compiler/tests/fuzz/fuzz.py` gives the single direct source from every
one-source positive, negative, runtime and ABI fixture directory, plus every
reproducer, mutated, to the server with the checkout as import root.
Fixtures use their real file URIs; reproducers use separate temporary
modules. An unchanged imported fixture and an isolated reproducer must
report their expected checker diagnostics before the mutants run. This is
source-text crash coverage; the lane does not execute the fixtures or their
C companions. Its first run found a query of a module refused before the
checker raising, which is fixed and pinned. Neovim, Helix, Emacs, Zed,
VS Code, Vim, Sublime Text and Kate
start the server, and Neovim and Emacs were run against it.
`scripts/driver_manifest.py` held every commit to its parent at all 8,169
entries, and the largest scaling ratio is 2.10. The Mac ran the host suite
in debug and release, 793 cases each, the sessions and the fuzz lane, and
the gate was green on every job on `14a89242`.

### R10 gate

- An editor gets diagnostics, navigation, types, formatting and fixes from a
  server running the compiler's own stages.

## R11 — More hosted targets

The targets GitHub's runners reach, with the target description growing
feature levels before it grows targets.

### R11.10 — Describe CPU feature levels

Status: complete
Depends on: none

A target description carries a feature level: x86-64 v1 to v4, arm64's
architecture extensions, the Cortex-M profiles, RISC-V's extensions. It is
selected per build and visible to `fixed if`.

Exit evidence: feature levels selectable on every target, visible as
compiler facts, and one feature-dependent lowering per target family executed
at two levels.

Done: a build assumes a CPU feature level of its target's family, selected
with `--level=` or the server's `level` option through the one target mapping
both now share; an unknown or foreign level is L0009. D255 records the
levels, x86-64 v1 to v4, `armv8-a` and `armv8.1-a`, and `armv6-m`, `armv7-m`
and `armv7e-m`, each a feature set whose default is what the backend always
emitted. A level is a value beside `Target_Facts`, so layout, checking, the
IR and every ABI see none, and `compiler.feature.NAME` reads one in
`fixed if`. Three lowerings run at two levels: BMI2 shifts at `x86-64-v3` on
Linux, whose lane refuses a level the processor lacks and requires the level
in the executable's ISA note; LSE atomics at `armv8.1-a` on macOS, whose lane
asks for FEAT_LSE and requires the executed image to hold the LSE instructions
and no exclusive loop; and hardware division at `armv7-m` on QEMU's MPS2 AN385
Cortex-M3 from the locked binary, whose lane requires the image to divide in
hardware and call no 32-bit helper. The x86-64 assembler is held to the level
at the baseline too, so an assembly block cannot outrun the build. A runtime
fixture's `levels:` names the levels each lane runs. `scripts/driver_manifest.py`
held every commit to its parent at all 8,169 original entries, the only
differences being the new fixtures' own; the largest scaling ratio is 2.19.
The Mac ran the LSE lane and the host suite, 798 cases in release, from a
fresh clone of the branch, and the gate was green on every job on `f43e2858`.

### R11.20 — Linux arm64

Status: complete
Depends on: R11.10

The arm64 backend with the standard AAPCS64 and ELF, and a pinned toolchain so
`refine` itself runs there.

Exit evidence: the corpus and the GDB sessions on GitHub's arm64 Linux
runners in the gate.

Done: `linux-arm64` is the arm64 backend's second description, with the
standard AAPCS64, ELF objects and DWARF, and Linux's libc, beside Darwin's
under one instruction selector: an object-format layer spells relocations,
sections and symbols, one planner holds both AAPCS64 conventions, and the
hosted bridge asks the operating system its libc spellings. D256 makes it a
third C ABI with its own `compiler.c_aapcs64_lp64` and an unsigned plain
`char`, which `core/c` and the binding generator follow; D257 makes a build
target the compiler's own host and cross-compilation explicit. The pinned
GNAT 16.1.0 and GPRbuild 26.0.0 have aarch64-linux checksums, the flake an
`aarch64-linux` system and the release an aarch64-linux row. The test
program runs one target's corpus per lane, the host's own or a named one
under an emulator; 1,950 fixtures name `linux-arm64`, and every Linux x86-64
runtime or ABI fixture that does not has a record and a counterpart that
runs. Six ABI peers that chose x86-64 by "not Apple" now choose by
architecture. The gate's `arm64-compiler` and `arm64-release` jobs run both
compilers' corpus, the GDB sessions with the bundled GDB and the bindings on
`ubuntu-24.04-arm`, and determinism gained the host. `driver_manifest.py`
held every compiler commit to its parent, the existing targets unchanged; the
largest scaling ratio is 2.18. A `linux/arm64` container on the Mac ran the
corpus, the GDB sessions and the bindings natively before the push, and the
gate was green on every job on `6750dfcb`.

### R11.25 — Linux arm64 feature-level evidence

Status: complete
Depends on: R11.20

Add recurring Linux arm64 checks for the baseline `armv8-a` and selected
`armv8.1-a` levels without reopening the completed target implementation.
The Darwin level lane does not establish Linux evidence. Linux arm64 emits
no ISA-level note and has no loader-refusal protection for unsupported
levels; D255 scopes that guarantee to Linux x86-64.

Exit evidence: default and explicit `--level=armv8-a` builds agree in
instructions and ABI. `fixed if` observes the documented feature facts at
each level, including false/true `compiler.feature.lse`; atomic add,
exchange and compare-exchange use exclusive-monitor loops at baseline and
LSE instructions at `armv8.1-a`. Assembler controls accept a level-specific
instruction only at the level that permits it. Run the baseline corpus and
GDB sessions, and execute the higher-level consumers only on a runner whose
support for all selected features is confirmed. Missing higher-level runtime
evidence is unverified, never supplied by baseline or Darwin success.

Audit the completed Linux arm64 lane for an executed assembly block with an
integer operand and an IR verifier refusal for an invalid arm64 register.
Retain both as recurring gate checks; this audit does not reopen R11.20.

Done: a level now runs only on a processor that confirms every feature of
it. A native Linux lane reads its own `/proc/cpuinfo`; a cross lane asks its
runner, through a C program its driver links, rather than assuming an
emulator has everything, since QEMU's `-cpu cortex-a53` has no LSE. A level
nothing confirmed fails as unverified and is never inferred from the
default's run or from Darwin. The arm64 image check could not fail, looking
for `ldaxr`/`stxr` where the baseline loop is `ldxr`/`stxr`; it now refuses
the loop at `armv8.1-a` and any LSE instruction in the default's image, and
catches an exchange left as a loop. linux-arm64 gained `fixed if` fixtures for
`lse`, `crc32` and `rdm` at the default, an explicit `armv8-a` and `armv8.1-a`;
a driver case requiring the default and explicit `armv8-a` to emit the same
assembly, link command and build report for atomics, a `layout(c)` record
across the C boundary and a variadic call; Linux add, exchange and
compare-exchange held to exclusive loops and LSE; and an LSE assembly block
selected by `compiler.feature.lse`. Each Linux lane's own assembler refuses
`ldaddal` below `armv8.1-a` and `shlx` below `x86-64-v3`, at the default and
the named lower levels, and runs the block at its level. Every hosted lane
must execute `assembly-operands`, and the verifier refuses x18, x29, x30, sp
and x31 under both arm64 descriptions. No compiler source changed, and
`driver_manifest.py` agreed at all 11,729 entries. The Mac ran the Darwin
parity corpus and host suite, and its `linux/arm64` container the whole test
program and GDB sessions, confirming `armv8.1-a` natively. The gate was green
on every job on `b2a51df7`, where `arm64-compiler` and `arm64-release`
confirmed `armv8.1-a` from the runner's own `/proc/cpuinfo`.

### R11.26 — Make one mistake one diagnostic

Status: complete
Depends on: R10.30

R10.30 gave diagnostics fixes; it did not make them find the mistake. One
misplaced word in a body, `v: u32 mut = 41`, gives eight reports, none
naming `mut`. With each body line of the clean positive fixtures changed by
one token (deleted, doubled, swapped or a stray word inserted), 694 refused
mutants gave one report in 32%. In 65% the parser left the function and read
the rest of the file as declarations ("this begins no declaration"), and 24%
claimed a function closed two lines later was never closed. The first report
was on the changed line in 99%: the parser finds the mistake and then
abandons the construct it is in. An audit of every agent session since
R10.30, 228 refused compiles of which about 75 were accidental, found
agents giving up, misreading the cause or claiming success past printed
errors. The reports that worked were written for one mistake, said what was
found and gave the corrected form.

Fix the mechanisms rather than each mistake:

- Recovery respects structure. Openers and named closers are matched before
  a body is parsed; a broken statement resumes at the next statement of its
  own block and never leaves the enclosing construct; "never closed" is said
  only when no closer exists; declaration resync skips balanced brackets.
- A refused statement is diagnosed by the smallest repair that makes it
  parse: one token deleted, inserted, swapped with its neighbour or moved to
  the statement's start, tried on that statement alone. A repair found is the
  report and an exact R10.30 fix; none found says what token was found and
  after what, never only what belonged at the gap.
- A report's primary span is the token it is about, never whitespace or a
  line end; a secondary label never repeats it; one cause repeated is one
  report with a count. A note cites the rule that failed, not the construct's
  general paragraph or a grammar production.
- A checker refusal poisons what it refuses, so a dependent error is not
  reported: an unknown label before the parameter it leaves unfilled, an
  unresolved import before its uses. A type error names both types and where
  the deciding one came from; checker vocabulary that names no source
  construct stays out of messages.
- An import that resolves to nothing is refused at the import, not accepted.
  A local that shadows a named return is reported at the shadowing binding.
- Driver reports carry no source line when they have no source, distinguish
  misuse of a known option from an unknown one, and suggest near options and
  targets. An internal compiler defect names its stage and source span. An
  assembler refusal of an assembly block is reported at that block.

Negative fixtures that pin today's cascades as expected codes are re-pinned to
the single report, not defended.

Exit evidence: the single-token mutation suite runs in the gate over the
positive corpus with a fixed seed. No mutant inside a body reports outside its
enclosing function, none claims an existing closer is missing, and at least
90% give exactly one report on the changed line. Every primary span is on a
token. The accidental refusals the session audit found are negative fixtures,
each pinning one report and, where the repair is mechanical, a fix the `fixes`
suite compiles clean.

Done: a mistake is reported once, inside the construct it is in, on the
token it is about. Recovery keeps to the structure a program writes and never
reads past the closer of the function it is in; a refused statement keeps its
own line, the lines continuing it and the lines indented under it quiet, and
at the top level a refused declaration's body and `end` too (D260). A
refused line is reported as the smallest change that mends it — a token
removed, written, swapped or moved, a line break where a value was left out —
which the report shows and offers as a fix, likely except for removing one
copy of a doubled token (D261). Where a form is another construct in the
wrong place, `sizeof(t)`, `name: concept (...)`, `else (_)`, `(a, b) = value`,
`f().x`, `addr 3` or `end struct`, the parser names that construct. A
checker refusal poisons what it refuses: an unknown argument label hides the
parameter it leaves unfilled, a refused write still assigns its place, a
binding's refused writes report once and a control expression's missing value
once (D263). An import with no root is refused at the import (D262), a local
shadowing a named return is reported at the binding, and the driver names the
near option, target or source, its defect's stage, and an assembler's refusal
at its block. The `mutation` suite runs every body line of the positive corpus
changed by one token with a fixed seed: of 1,829 refused mutants 1,659 give
one report on the changed line, 90 per cent, and 1,758 exactly one; none
reports outside its function, leaves its body, claims a written closer
missing or has a primary span off a token, and those are held at zero. The
session audit's accidental refusals are 36 negative fixtures pinning one
report each, with the fix applied where it is mechanical; its eight foreign
spellings are SR-13's. `driver_manifest.py` against `9d9f615c` differed at
437 of 11,898 entries, every one in its report alone: no status, output,
assembly, build report or map changed. The largest scaling ratio is 2.19.
These measurements are local results. The full cross-host gate was green on
[`5a088ec6`](https://github.com/JanHaan/Landin/actions/runs/37623707168).

### R11.30 — FreeBSD x86-64 and arm64

Status: complete
Depends on: R11.20

The hosted layer and platform driver for FreeBSD x86-64 and arm64, emitted
from Linux and run in FreeBSD virtual machines on Linux runners, one for each
architecture. R11.30 also owns source debugging on both architectures:
scripted debugger sessions must check source-line stops, frames, local values
and unwinding.

Exit evidence: separate gate verdicts for the runtime corpus and scripted
source-debugger sessions in the FreeBSD x86-64 and FreeBSD arm64 virtual
machines.

Each FreeBSD architecture must execute an assembly block with an integer
operand and have an IR verifier refusal for an invalid target register.

On a FreeBSD x86-64 guest with verified `x86-64-v3` support, execute the
variable-shift fixture at both `x86-64-v1` and `x86-64-v3`. Inspect its shift
code in each linked executable: require BMI2 (`shlx`, `shrx` or `sarx`) at v3
and none at v1. Missing guest support fails this lane rather than skipping it.

The FreeBSD arm64 lane selects both `armv8-a` and `armv8.1-a`, verifies that
the baseline assembler refuses an LSE instruction, and checks that an atomic
fixture uses an exclusive loop at baseline and LSE without that loop at the
higher level. Confirm LSE support before executing the higher-level fixture.
If the usual VM lacks it, a named LSE-capable FreeBSD arm64 host supplies the
higher-level execution verdict on every recurring gate run; a one-time run
or a skipped higher-level verdict cannot satisfy completion.

A nonempty C ABI fixture set must execute separately on FreeBSD x86-64 and
FreeBSD arm64 against independently compiled C peers for each architecture.
Cover imported and exported calls, integer and floating-point values,
`layout(c)` aggregates, callbacks and variadic calls. Report each architecture's
ABI verdict separately from its runtime and debugger verdicts, and fail if
its ABI fixture selection is empty.

Done: Linux emits both targets through the existing ELF backends and locked
FreeBSD 14.4 sysroots; Linux-hosted FreeBSD 15.1 KVM guests execute them.
The [full gate on `efeb38fe`](https://github.com/JanHaan/Landin/actions/runs/37638872998)
passed all 34 jobs, including separate architecture runtime, LLDB and ABI
verdicts: 2,468/2,472 runtime outcomes, four debugger profiles each, and
158/150 ABI outcomes against 162/150 independently compiled C objects.
Both lanes execute integer assembly operands and refuse invalid IR registers.
Guest probes confirmed x86-64-v3 and LSE; linked v1/v3 shifts, baseline/LSE
atomics, baseline assembler refusals and higher-level execution passed.
All six execution verdicts and their Linux emission checks recur in the gate.

### R11.40 — RISC-V rv64 Linux

Status: complete
Depends on: R11.10

A RISC-V backend, RV64GC with the LP64D convention, whose instruction selection
R12.40 reuses for rv32. Its levels are ISA strings, `rv64gc` the default,
whose single-letter and `Z` extensions are the feature set D255 already
models as a set rather than a rank.

Exit evidence: the corpus and GDB sessions on RISC-V hardware in the gate,
through the RISE project's runners, with QEMU user emulation as the fallback
if that service goes away. The same gate also selects `rv64gc` and at least
one nondefault RV64 ISA string with a different extension set, executes a
`fixed if compiler.feature.NAME` program at both levels to show the added
extension's fact is false at `rv64gc` and true at the extended level, and
checks that the same operation emits and executes an extension instruction
at the extended level and its baseline sequence at `rv64gc`. An
`assembler.block` using that instruction must assemble at the extended level
and be refused at `rv64gc`. The selected execution lane must support the
extension.

Execute an assembly block with an integer operand and require an IR verifier
refusal for an invalid RV64 register in the same gate. Record the selected
RV64 Linux LP64D C calling, layout and capability facts in `spec.md`, and
expose the matching scalar aliases through `core/c`. A nonempty C ABI fixture
set must execute against independently compiled C peers, covering calls in
both directions, integer and floating-point values, aggregates, callbacks
and variadic calls. Report its ABI verdict separately and refuse an empty
selection.

Done: the native RV64 Linux backend uses LP64D, shared ELF/DWARF and an
XLEN-parametric instruction selector with independent ISA extension sets.
`spec.md` records its C transport, layout and capability contracts; `core/c`
exposes matching aliases. The
[full gate](https://github.com/JanHaan/Landin/actions/runs/37673902236) passed on
[`501996ec6bc872eb1f7680308c55708805ac61f8`](https://github.com/JanHaan/Landin/commit/501996ec6bc872eb1f7680308c55708805ac61f8),
including four separate physical RISE verdicts: 537 runtime fixtures and
2,460 executed images; four GDB profiles covering source lines, frames,
local values and unwinding; 35 C ABI fixtures and 158 executed images
against 158 independently compiled C peers; and 24 ISA-level images.
Hardware execution confirmed XTheadBa support. The `rv64gc` and
`rv64gc_xtheadba` feature verdicts, inspected and executed baseline shift/add
and extended `th.addsl` sequences, extended assembly execution and baseline
assembler refusal all passed. Integer assembly operands execute, and the IR
verifier refuses invalid RV64 registers. All four execution verdicts and
their compiler-host emission and verifier checks recur in the full gate.

### R11.50 — Convert to a written type

Status: complete
Depends on: none

A conversion is a type applied to a value [0310], but only a name can stand
in front of its `(`, so converting `utf8` to its byte view needs an alias
such as `byte_view: type = []u8` or `core/text.bytes`. Let a type expression
stand there, so that `[]u8(text)` is the conversion that alias spells. The
grammar must decide what `[` and `ptr` begin, since `[]` is also the empty
slice, `[4, 5]` an array literal and `ptr(...)` the pointer conversion, and the
admitted conversions stay exactly those an alias reaches today.

Exit evidence: `spec.md`'s grammar and a register decision, every conversion
an alias reaches spelled with its type expression in positive and runtime
fixtures on every target, and the ambiguous prefixes pinned by fixtures that
derive or refuse as decided.

Done: D266 defines written conversion heads and their boundaries while
preserving alias admission. Positive, runtime and refusal fixtures cover
the existing conversion families, literal and pointer syntax, folding,
origins and traps. The [full candidate gate](https://github.com/JanHaan/Landin/actions/runs/37702617097)
passed all 42 jobs with no skips, including every target, physical RV64
runtime, GDB, ABI and ISA execution, formatting, editor grammar and
cross-host determinism.

### R11 gate

- R11.25 passes recurring Linux arm64 baseline and higher-level feature,
  instruction-selection, assembler and confirmed-runner execution checks.
- A single-token mistake in a body gives one report at the mistake, held in
  the gate by R11.26's mutation suite.
- Linux arm64, FreeBSD x86-64, FreeBSD arm64 and rv64 Linux each run the
  corpus in the gate, with a separate verdict for each architecture.
- A conversion names its type as written, without an alias.
- FreeBSD x86-64 and FreeBSD arm64 each pass scripted source-debugger
  sessions in the gate, with a separate verdict for each architecture.
- RISC-V passes the baseline and nondefault extension-level evidence in
  R11.40 on its selected execution lane.

- Each new hosted target executes an assembly block with an integer operand
  and has an IR verifier refusal for its register rules. R11.25 audits and
  retains that evidence for completed Linux arm64 support.
- FreeBSD x86-64 passes baseline/v3 execution and linked BMI2-selection checks;
  FreeBSD arm64 passes baseline/LSE checks with recurring capable-host execution.
- FreeBSD x86-64, FreeBSD arm64 and RV64 Linux each have a separate nonempty,
  executing C ABI verdict against independently compiled C peers.

## Command-line preparation before microcontrollers

The public compilation command is `refine compile`; `build` is reserved for
future project orchestration. Shared options work before or after commands,
and their names do not overlap command-specific options except intentional
contextual actions such as help. Command help has equivalent command-local
and `help COMMAND` forms. Existing direct compilation spellings remain
compatible.

The first phase covers this interface, help and completion from one catalogue,
source/build identification without assigning a release version, presentation
and tool tracing, response files, dry-run planning and source dependency files.
Its evidence is the command and existing driver suites, plus native CLI and
build-consumer checks.

Done: The first-phase interface, generated build identity, catalogue-derived
help and scoped completion, diagnostic presentation and tool tracing,
response files, dry-run plans and dependency files are implemented. Native
Linux x86-64 command, driver and optimization-driver suites and CLI/Make
integration checks passed. These filtered developer checks are not gate
evidence.

The second phase examines the content behind the interface: warning coverage
and actionable repairs, diagnostic completeness and useful execution detail.
The warning survey found two existing families, unnecessary local `mut` and
unused immutable locals with inert literal initializers. Their requirement
for an exact fix hid the same observation when comments or layout prevented
an edit. D251 now separates advisory observations from exact repairs and
allows explicit invocation policy: named warning baselines and ordered
per-code allow, warn and deny controls. Denial must stop artifact production,
retain the original diagnostic data and never suppress a language error.

The comparison informs the policy rather than prescribing one compiler's
flags. [Rust](https://doc.rust-lang.org/stable/rustc/lints/levels.html) separates
allow, warn and deny and supports ordered command-line overrides;
[Clang](https://clang.llvm.org/docs/UsersManual.html#options-to-control-error-and-warning-messages)
supports enabling, disabling and promoting individual warnings.
[Go](https://go.dev/doc/faq#unused_variables_and_imports) makes unused locals
and imports errors and keeps advisory analysis in
[vet](https://pkg.go.dev/cmd/vet). [Zig](https://ziglang.org/documentation/0.16.0/)
treats unmutated local variables as errors. Those policies are evidence that
there is no universal warning interface, not grounds to change Landin's
language legality.

| Survey subject | Disposition |
|---|---|
| Unnecessary declarations with comments or multiline layout | Report the established fact without a fix; retain exact edits where safe. |
| Unused signed numeric literals | Include a single negation of an integer or float literal; do not generalize to arbitrary constant expressions. |
| Uninitialized reads, incompatible types, invalid reference escapes | Keep the existing language errors; warning controls cannot weaken them. |
| Unused imports and shadowing | Keep the retained decisions: imports add conformances, and inner shadowing is explicitly permitted without a warning. |
| Unused parameters | Require evidence about deliberate interface parameters before admitting a new warning family. |
| Dead stores and unreachable code | Require source-level control-flow, alias and effect evidence, including volatile accesses and configured branches, before admitting a new warning family. |
| Local suppression and dependency-specific policy | Invocation controls are the initial mechanism; add source or package scope only when a concrete use case needs it. |

Diagnostic transport must preserve labels, notes and every alternative fix.
Real diagnostics carrying edits exposed an incorrectly closed JSON fix object;
warning and error cases must parse as independent JSON records and retain
their edit data. This work precedes the microcontroller phase and changes no
language or target scope.

Done: The survey and initial content improvements implement named warning
baselines and ordered per-code allow, warn and deny controls. Denial stops
artifact production; advisories retain observations without unsafe edits,
and unused signed numeric literals are covered. The language server uses
recommended warnings and offers no edit for an advisory without a fix.
Fix-bearing JSON diagnostics preserve every alternative edit. A strict
native Linux debug build, 242 affected filtered cases with 13,499 checks,
six native CLI tests and 32 executable language-server sessions passed.
Document checks and 112 checker controls passed. These developer checks
are not gate evidence.

## R12 — Microcontrollers

The chips people buy: RP2040 and RP2350, STM32, and Espressif's ESP32,
ESP32-S and ESP32-C series. Emulators first, as before, and boards beside
them rather than instead of them.

An item may describe a noncoherent cached memory profile without admitting
it for firmware. Before the first R12 item claims support for such a profile,
it must provide platform-specific DMA cache maintenance and evidence for
cache levels, aliases, cache-line ownership and device visibility points.
Require target execution of transmit and receive consumers and bounded
failure oracles for stale reads and lost dirty bytes when maintenance is
omitted. Cacheless profiles need no such provider. A cached profile without
this evidence remains unsupported through the R12 gate; R12.10, R12.30,
R12.40 and R12.50 each apply this rule to any profile they first admit.

### R12.10 — Describe devices

Status: planned
Depends on: R11.10, R13.35, R13.70

A general SVD generator, memory profiles, linker configuration and firmware
vector mappings selected per device instead of the fixed constrained profile,
and boot image formats as target facts. The selected device's interrupt numbers
must map to absolute vector slots (external IRQ0 is slot 16), with its reserved
slots kept zero and its implemented slots available to typed handlers. This
schedules the SVD and linker halves of R551-33, R730-05's larger profiles,
R551-08's bounded emission policy and the Cortex-M toolchain move SR-01.
The emission policy must be in force before admitting images larger than
32 KiB; the retained constrained profile remains available while that policy
is established. When device selection lands, [1990]/D229's
fixed vector slot exclusions must become profile-specific; the current
constrained profile remains a reference.

Exit evidence: the RP2040 fixture regenerated byte for byte by the general
generator; a second device family generated from pinned inputs, with every
selected register and field's address, layout, reset and encoding checked
against vendor headers or reviewed literals independent of the generator and
its SVD input; its read and write access policies checked against separately
reviewed expectations; and a generated-module consumer checked against a
separate peripheral model or independent control. Each distinct SVD form used
by the selected registers, including structural expansion and inheritance
where present, is exercised by these checks; unsupported forms have negative
refusal controls. Every capacity verdict is rerun against each selected
profile with the 32 KiB reference retained.

The Cortex-M gate runs with SR-01's migrated `arm-eabi-gcc` toolchain. Every
affected Cortex-M record, including firmware hashes and disassemblies, is
regenerated and reviewed in the same toolchain change.

Check the RP2040 SVD interrupt-to-vector mapping against the linked firmware
image:
`USBCTRL_IRQ` is IRQ5, so a typed handler at absolute slot 21 must compile,
occupy that vector word and execute when IRQ5 is delivered. Verify the
constrained reference profile still refuses slot 21 and emits zero there.

Fixture checks select RP2040 and the second generated family by device identity and
compare each selected boot image format fact with an independently recorded
expectation for that device; a wrong or absent format fails the checks. The
firmware ELF alone does not establish this selection.

Small source/IR shapes must demonstrate that compact inputs cannot cause
unbounded assembler repetition or object growth under the emission policy,
with the forbidden giant-fixture boundary retained. Check this bound before
enabling a larger profile; this schedules the policy and its evidence without
choosing a new numeric compiler limit here.

### R12.20 — The first board

Status: planned
Depends on: R12.10

Raspberry Pi Pico, an RP2040 with the ARMv6-M the backend already emits: its
second-stage boot and flashing through a debug probe. Port the prototype-1
UART/DMA application to real RP2040 peripheral addresses, clock, reset and
pad setup, and DMA/interrupt and stop semantics. Define a device-specific
physical trace oracle for injected UART data, echo and GPIO effects, and
observable DMA/interrupt progress. This item owns R730-01's first pinned
physical-board run and smoke procedure.

The existing derived driver retains its synthetic peripheral map and drain
contract in the emulator lane; only source-level scenarios whose premises
hold on both devices are shared.

Exit evidence: check the flashed RP2040 image's second-stage bytes and
checksum, then record a power-cycle boot from that image, without a probe-set
program counter or RAM-loaded program. It must reach compiler-owned startup
through the ROM-loaded second stage and execute the board smoke test. Check
the captured board-port trace against its physical oracle and record the run
here. The synthetic driver and its own emulator oracle remain in the gate;
compare shared scenario outcomes only where their contracts overlap. The
board run also delivers IRQ5 and observes the typed handler whose absolute
slot-21 placement is required by R12.10.

### R12.30 — Thumb-2, Cortex-M33 and M4F

Status: planned
Depends on: R12.20

The ARMv7-M and ARMv8-M instruction sets and the hardware floating point of
the M4F, for RP2350 and an STM32 Nucleo board, with QEMU's M33 machine as the
emulator lane. `armv7-m` and `armv7e-m` exist as D255 levels with hardware
division only; this adds `armv8-m.main`, Thumb-2 selection beyond division,
and the M4F's float registers, which change the C ABI and so are a
description rather than a level. This item also closes SR-04: extend assembly
operands to float registers on M4F and the hosted targets that have them,
including the register class and clobber set in [1630] and D248.

Exit evidence: the Cortex-M corpus on the emulator lane in the gate, and a
recorded run on each board. On the M4F board, a nonconstant source f32
arithmetic and comparison fixture must execute with results checked against
its oracle; linked disassembly must show compiler-generated hardware float
operations rather than software arithmetic helpers. Direct target-description
and C ABI-planner checks must establish the M4F's VFP argument and result
registers, call-preserved registers and stack fallback against AAPCS32's VFP
variant, and check the linked image's float ABI attributes. Executable C
source interoperation remains in R13.20. [1630] and D248 must also be amended for float
operands, with executed float-operand fixtures on every target with float
registers.

The recurring emulator gate must also execute a compiler-generated,
non-division Thumb-2 operation at `armv8-m.main` and check its result. Linked
disassembly must locate the selected instruction in the fixture's compiled
function. The same source at default `armv6-m` must retain its baseline
lowering without that instruction. This evidence supplements the M4F float,
ABI and assembly-operand requirements above.

### R12.40 — RISC-V microcontrollers

Status: planned
Depends on: R11.40, R12.10

RP2350's Hazard3 cores and ESP32-C6 use `rv32imac`; ESP32-C3 uses `rv32imc`
without A. The ESP targets also need their application image format. The
C3 default level and assembler limit must omit A. Under D227, support aligned
one-, two- and four-byte atomic loads/stores and thread fences, and statically
refuse read-modify-write atomics and eight-byte operations with L0344. There
is no implicit library or interrupt-masking fallback.

Exit evidence: the freestanding corpus on an emulator lane in the gate, and a
recorded run on each board.

C3 emulator and board cases execute its admitted atomic operations. The C3
lane checks the `rv32imc` assembler setting and absence of A-extension
instructions in linked firmware, and requires refusal of exchange, add,
compare-exchange and eight-byte atomics. Hazard3 and C6 lanes execute an
A-extension read-modify-write operation.

### R12.50 — Xtensa, ESP32 and ESP32-S3

Status: planned
Depends on: R12.10

A backend for the Xtensa LX6 and LX7, assembled with Espressif's toolchain and
run on Espressif's QEMU, which emulates both chips. Decided here: the windowed
calling convention, whose window overflow and underflow handlers compiler-owned
startup then provides, or CALL0 throughout, which has none.

Exit evidence: the freestanding corpus on Espressif's QEMU in the gate, and a
recorded run on each board.

Extend D255 with one Xtensa family and two selectable levels: the ESP32 LX6
configuration `xtensa-esp32` as default and the ESP32-S3 LX7 configuration
`xtensa-esp32s3`. Backend design must establish their compatibility and one
shared layout and C ABI, choosing the calling convention here rather than
assuming it now. Record their feature sets when implemented, including a
feature present only in the S3 configuration.

Select levels through `--level=` and the server's `level` option, expose the
features through `fixed if compiler.feature.NAME`, and refuse unknown or
other-family selections with L0009. Pin assembler configurations that reject
instructions outside each selected level, including the default, for both
`assembler.block` and generated code.

Completion requires CLI and server selection checks, a feature-dependent
source taking different branches at the two levels, and unknown/foreign-level
refusals. Execute the same source at both selected levels only on compatible
chips, recording the baseline compatibility evidence before relying on an S3
run for an LX6-level build. At each level, require assembly acceptance of an
available instruction and refusal of a valid Xtensa instruction absent from
that level. Record the assembler commands and refusals; a corpus run alone
does not satisfy the item. Neither level is added to today's compiler table
by this plan.

### R12.60 — Boards in the gate

Status: planned
Depends on: R12.20, R12.30, R12.40, R12.50

A self-hosted runner with the boards attached, run for `main` and by hand and
never for a pull request from a fork. This extends R12.20's first-board
readiness evidence to recurring smoke runs on every supported board.

Exit evidence: every board this phase supports runs its smoke procedure
against a device-specific physical oracle in the gate, beside the emulator
lanes it does not replace.

### R12 gate

- RP2040, RP2350, an STM32 board, ESP32, ESP32-S3 and ESP32-C run
  compiler-owned firmware in emulation and on hardware, each against an oracle
  valid for that device or emulator model. The synthetic driver remains an
  emulator lane.

- Each new freestanding target/profile executes an assembly block with an
  integer operand and has an IR verifier refusal for an invalid register in
  its target gate: each new Cortex-M profile, each RV32 target, and both
  Xtensa LX6 and LX7. This evidence is required before its milestone completes.

- The RP2040 board run starts at power-on from the flashed boot image and
  reaches compiler-owned startup through its checked second stage.

- Every admitted noncoherent cached profile has its platform maintenance
  provider and DMA visibility-point evidence from its first admitting item.
- R12.10's bounded emission policy and small-shape controls pass before any
  profile larger than the retained 32 KiB image is admitted.

- Xtensa LX6 and LX7 pass level selection, feature-fact and assembler-limit
  checks, with execution on compatible chips as required by R12.50.
- R12.30 passes non-division Thumb-2 execution, linked instruction-selection
  inspection and the same-source ARMv6-M baseline control.

## R13 — The library

A standard library split where the capability model already splits it.

### R13.10 — Separate library availability classes

Status: complete
Depends on: none

`core/*` becomes the shared freestanding library: each module and its public
interface must be selectable on every supported target, though its
implementation may use target-specific paths. Hosted-only modules move under
a sibling root so that firmware cannot import them by accident.
Target-specific freestanding modules move under a separate sibling root;
each declares the target families or profiles on which it is available, and
an import outside that scope is refused during target checking. They require
no hosted runtime or services. A module mixing these availability classes is
split so importing one class does not select declarations from another. The
existing `core/cpu` belongs in this root for the M-profile family, including
its later feature levels, rather than in either the shared or hosted root. The
chosen sibling roots are `hosted/*` and `platform/*`, with [1480] and [1660]
amended. Availability follows the source namespace independently of which
project-first root supplies its contents; the names are not lexical keywords.

Migration inventory:

| Existing modules | Destination | Availability |
|---|---|---|
| `core/diag`, `core/failing`, `core/io`, `core/map`, `core/mem`, `core/panic`, `core/pool`, `core/region`, `core/small`, `core/sort`, `core/text`, `core/tree`, `core/vec` | retain `core/*` | Every supported hosted and firmware target |
| `core/heap`, `core/io/hosted` | `hosted/heap`, `hosted/io` | Hosted targets only |
| `core/cpu` | `platform/cpu` | M-profile family, including its higher levels |
| `core/c` | `platform/c` | Currently supported LP64 C ABI descriptions; no hosted services required |

The C spelling layer's scope remains explicit until a later consumer extends
it. This migration does not enable Cortex-M C signatures or bind the library
split to R13.20's interoperation work.

Exit evidence: the amended paragraphs and an inventory assigning every
existing module to the shared, target-specific freestanding or hosted root;
the resulting imports and consumers check on their supported targets. A
module under `core/*` checks on every supported target, `platform/cpu` checks on
M-profile levels and is refused on other families, and a firmware build
refuses a hosted import by name.

Record the shared-root module inventory and supported-target matrix at
closure. For every shared module, a small consumer must import and use it,
then compile and link on every supported hosted and firmware target. Execute
the consumers on native or emulator lanes where behavior needs target
evidence, with success and failure oracles. Keep consumers separate where a
combined image would exceed a constrained target's budget; an image-size
refusal is not positive evidence that a shared module works. Every later
target's gate must repeat this matrix for that target.

Done: the three roots exist and the thirteen shared modules, `hosted/heap`,
`hosted/io`, `platform/c` and `platform/cpu` sit under them (D267, [1480],
[1660]). `Landin.Modules.Availability` decides a written namespace from target
facts before name resolution, and an unavailable import is L0015 once, at the
import. The thirteen `runtime/library-shared-*` consumers compile, link and
return their status on Linux x86-64, Linux arm64, Darwin, both FreeBSD
targets, RV64 and Cortex-M0; `negative/library-platform-cpu-hosted` and 37
Cortex-M corpus rows pin the refusals; `environments/cortex-m` links
`platform/cpu` at armv6-m, armv7-m and armv7e-m. The firmware return halt is
Thumb code, which the higher levels needed.

### R13.11 — Library interface conventions

Status: complete
Depends on: R13.10

The split left four shapes in the library that six hosted targets would
cement. `core/io`'s one `world` concept becomes four narrow concepts, `reader`,
`writer`, `files` and `process`, with `world` their composition and an adapter
lending a world's writer, so a sink implements two entries and `core/diag`
streams through `any io.writer`; this is the split [1260] waited for and
closes E2. One naming convention: a module's principal type is constructed
with `new`, a view over caller bytes with `over`, every container's storage
is given back with `release`, and the index and emptiness atoms are
`core/mem`'s `out_of_bounds` and `empty` for every core container, while key
lookups keep `missing` and `no_such_node`. The library ships the evidence
the scalars were always going to need: `equatable` and `hashable` for the
integer scalars, `bool` and `[]u8`, `ordered` for the integer scalars, and
all three for `utf8`; a program wanting another reading wraps the type in
`distinct` [1280]. The vector, small vector and map keep `get` as a copy and
gain `at`, a writable
slot under [0800]'s binding lock, with `contains`, `clear` and `reserve` on
the map and `last` on the vector; the tree's node is private and gets none.

The library reference is generated from public signatures and attached doc
comments, with module overviews, source links, search and existing executable
examples. Documentation completeness and generated links are checked with
the site build.

Exit evidence: D268 to D271 with their fixtures; a writer-only provider
driving a streaming log; a program keying a map by `[]u8` and `utf8` and
sorting `utf8` with no evidence of its own; a program updating a vector, a
small vector and a map through `at`; a program re-declaring `u32 is
map.hashable` refused as the collision it is; every renamed consumer, the
derived programs and the debugger workloads passing on every target.

Done: D268 to D271 and the library consumers pin the capability split,
uniform names, shipped evidence and writable accessors. The generated
reference documents 245 public names in seventeen modules, with executable
examples, search and source links. All 42 jobs in
[the complete gate](https://github.com/JanHaan/Landin/actions/runs/37926146788)
passed on `7e4cd1f3`, including the constrained consumers and source debugger
checks; selected-image-limit verdicts remain distinct from executions. The
same commit reached main and its library reference was published by
[Pages](https://github.com/JanHaan/Landin/actions/runs/37929115605). E2 is
closed: [1260]'s split is realized by the four narrow I/O concepts and their
`world` composition.

### R13.12 — Answer the first outside reading

Status: complete
Depends on: R13.11

The first reader from outside the project to read the published reference
found four things R13.11 left. A closed set of named values is carried in a
`u8` where [0640] has an enumeration for it: `core/diag`'s severity, which
D216 has since made storable as an atom, and the map's private slot state.
The comparison concepts live in the modules that consume them, `equatable`
and `hashable` in `core/map` and `ordered` in `core/sort`, so `core/text`
imports a hash map and a sort to say that `utf8` compares, and any later key
type would have to as well. `platform/c` reads as though LP64 were one
architecture's term and the C ABI an architecture's alone: its reference names
four facts on three different axes and does not say which target selects which,
that LP64 is the data model, or that the operating system takes part, as
`c_char` on Linux and Darwin arm64 shows.

Exit evidence: severity an atom set that a bounded and a streaming log receive
through erased dispatch and a program matches on, on every target; the map's
slot state an atom set with its consumers unchanged; `equatable`, `hashable`
and `ordered` with their shipped evidence in one shared module that map, sort
and text import, with its own shared consumer on every target and the
collision refusal pinned at its new home; and a `platform/c` reference that
says per target which fact holds, what LP64 is and where the OS enters. The
reader's remark that some names are odd goes to R13.13 with names attached.

Done: D272 makes the severity and the map's slot state atom sets, pinned by
`library-diag-severity` and the map consumers; D273 moves the three
comparison concepts and their evidence into `core/cmp`, with its own shared
consumer and the collision refusal at its new home; the `platform/c`
reference names each target's C ABI fact, the LP64 data model and where the
operating system enters. All 42 jobs in
[the complete gate](https://github.com/JanHaan/Landin/actions/runs/38076543394)
passed on `759dbb7e`, which also carries R13.13.

### R13.13 — Review the library

Status: complete
Depends on: R13.12

R13.11 held the library to conventions it wrote down; nobody has read the
whole of it as a user would since. Read every public declaration of `core`,
`hosted` and `platform` against its own module, the conventions and the
reference, for names that say something other than what the declaration does,
facilities that exist twice, integers standing in for closed sets, contracts
the doc comment and the source disagree on, and evidence a facility has
without a consumer. The outside reader's names are the first entries:
`core/mem.failing` and `core/failing.counted`, two deterministic failure
injectors that count different things, the first of them a budgeted arena
not called one; the equality concept's name; and module names that abbreviate
in `map` and `vec` but spell out an adjective or a noun in `failing` and
`region`.

Exit evidence: each finding either fixed with the fixtures that pin it and a
decision where it changes an interface, or recorded in the register below with
its trigger; the generated reference rebuilt and every renamed consumer, the
derived programs and the debugger workloads passing on every target.

Done: D274 records the fixes: `core/spill` and `core/fault` for the two
adjective-named modules, one fault injector instead of two, the renames in
`core/README.md`'s migration table, a map that counts tombstones towards
growth and rebuilds in place only while its live entries fit in half its
capacity, spread hashes, `capacity` beside `slots` and an exact `reserve`.
A generic signature that applies its own parameter, or names nothing, is
refused at the declaration instead of crashing. SR-14 holds what the review
left, SR-15 the hosted gaps for R13.30, SR-16 atom display in debuggers and
SR-17 unprivileged formatting. The gate's server fuzz round found two older
defects on the reviewed corpus, a lowering crash and a hover crash, both
fixed and pinned. All 42 jobs in
[the complete gate](https://github.com/JanHaan/Landin/actions/runs/38076543394)
passed on `759dbb7e`, with every renamed consumer, the derived programs and
the debugger workloads on every target.

### R13.14 — The compiler finds its library

Status: complete
Depends on: R13.13

`core`, `hosted` and `platform` ship with no installed compiler: the flake's
two packages and the release asset hold `refine` alone, and a program outside
the checkout compiles only with `--root` naming a clone of the repository.
These namespaces are not packages. The compiler names them, decides their
availability by target (D267) and matches its hosted contracts against them,
so a compiler and a library from different revisions are a fault, not a
choice. The compiler finds its own library relative to its executable, as
Go, Zig and rustc find theirs, through a host interface the test program can
fake; the library root follows every `--root`, and the repository-owned
namespaces resolve from it alone. An explicit option replaces it for an
unusual installation, `refine version` reports which root is in use, and
the language server finds it the same way. The user's home root and every
other default root stay the Companion tool and ecosystem family's.

Exit evidence: a decision amending [1480]'s bootstrap paragraph; the flake's
packages and the release asset installing the library beside `refine`; and a
gate job that installs the toolchain as the documentation says, outside the
checkout, and compiles and runs the README's first program and every
`examples.md` program with no option and no environment, on every hosted
target the release publishes for.

Done: D275 finds the library beside the executable, installed or in a
checkout, with `--library` for a staged tree; `core`, `hosted` and `platform`
resolve from it alone, also for named files, and `refine version` and the
language server name it. `scripts/package.sh` lays out the flake's packages
and the release archive as an installed prefix. The README's first program
is `runtime/first-program`, held to the README by `check.py`, and each
release job installs the archive outside the checkout and runs it and the
eleven `examples.md` programs with no option. All 42 jobs in
[the complete gate](https://github.com/JanHaan/Landin/actions/runs/38123255895)
passed on `13eb4918`. The path showed what a newcomer still meets: SR-22's
linker driver name, SR-23's missing suggestion, SR-24's installed paths in
debug information and SR-25's shell.

### R13.15 — The OS boundary in source

Status: complete
Depends on: R13.14

The compiler owns the hosted operating-system boundary: fourteen
`_landin_host_*` helpers that the checker holds to a special contract, that
each of the x86-64, arm64 and RV64 backends emits as libc trampolines, with
the libc facts per OS in the compiler and `strlen`, `open`, `read` and their
neighbours reserved from source. Move that boundary into the library as
ordinary source, on libc for every hosted target as now: one public
`hosted/libc` module holds the `extern(c)` declarations and per-OS records,
as `hosted/io/stat.ldn` already does, with errno read through the C
library's own accessor, and `hosted/io` and `hosted/heap` import it. The
argument root's startup function is library source the hosted entry calls.
`open` is variadic, and Darwin arm64 passes every variadic argument on the
stack, where no outgoing variadic call is pinned yet, so that comes first.
What stays in the compiler is the hosted entry and the link.

Exit evidence: no hosted helper, helper contract, bridge emitter or libc fact
left in the compiler; Darwin arm64 variadic calls pinned against a C peer;
every hosted fixture, the derived programs, the debugger sessions and the C
ABI fixtures passing unchanged on every hosted target; and decisions
superseding D153's scalar seam and D195's shim.

Done: D276 leaves the compiler one hosted contract, the call to `hosted/io`'s
argument initializer, and removes the fourteen helpers, their checker
contract and every backend's libc bridge, about 1,180 lines of Ada.
`hosted/libc` declares the C library with `open` variadic, and D277 moves the
heap's over-allocation into source. Library source can now say a path must
not run: D278's `compiler.unreachable()` raises `unreachable` at its own site,
so startup misuse reports what the bridge did. Darwin arm64's variadic tail
is pinned against a C peer. The mutation campaign now seeds each fixture
alone, and the ten reporting defects that seeding exposed are fixed and
pinned. All 42 jobs in
[the complete gate](https://github.com/JanHaan/Landin/actions/runs/38162781050)
passed on `a0a4b8fc`, executing the moved boundary natively on Darwin,
FreeBSD and RV64.

### R13.16 — Linux without the C library

Status: complete
Depends on: R13.15

Linux promises its system-call interface, so a Linux program needs no C
library to reach it. Darwin's system calls change between releases and
FreeBSD documents its C library as the interface, so both stay on libc, and
a Windows target would use kernel32. Write the Linux provider as system calls
in source on x86-64, arm64 and RV64, using the `*at` calls and `statx` so the
three share one layout, in a `hosted/linux` module scoped to Linux, with a
program-owned entry that reads the arguments, environment and auxiliary
vector from the initial stack, a static executable and a heap of size classes
over `mmap`. `--link=static` is the default on Linux; `--link=libc` keeps the
C runtime's startup and libc for a program that links C, with the same
provider beneath it, and a static link that meets a C symbol says so. RV64's
assembly checker refuses `ecall` as a control transfer while x86-64 admits
`syscall` and arm64 `svc`; a decision gives the system-call instruction one
standing on every hosted target first.

Exit evidence: decisions for the system-call instruction, the two Linux link
modes, and the replacements of D207's errno capture and D208's startup root;
static Linux executables with no dynamic dependency running the whole hosted
corpus, the derived programs and the debugger sessions on all three
architectures; and the C ABI fixtures passing in the C-linked mode.

Done: D279's `hosted/linux` makes Linux's system calls in source on all
three architectures, and its `_landin_start` reads the initial stack, holds
the processor to the executable's level (D284) and calls `main`; D281 gives
RV64's `ecall` the standing of `syscall` and `svc`. D280 links Linux
executables statically by default, with `--link=libc` for a program that
links C and a refusal that names it, and D282 gives the Linux heap size
classes over its own mappings. Two older defects surfaced and are fixed: a
mutable module binding folded to its zero image, and data placed out of
reach after a 2 GiB object (D283). All 42 jobs in
[the complete gate](https://github.com/JanHaan/Landin/actions/runs/38221083205)
passed on `ae0b3eaf`, running static executables natively on Linux x86-64,
arm64 and physical RV64.

### R13.20 — The freestanding library

Status: planned
Depends on: R13.10, R13.11, R12.30, R12.60

What firmware on the R12 boards needs, each facility driven by a complete
consumer: peripheral configuration beyond one baud rate, a reusable
freestanding cache-maintenance interface over the platform providers required
when cached profiles were admitted in R12, C on Cortex-M, and `core/text`'s
missing half for working with `utf8` in place. This schedules R551-34's freestanding part, and B5's,
and R730-02, R730-07, R730-09 and SR-05.

Exit evidence: each facility's consumer running on its targets with failure
oracles and measured cost on the constrained profiles. For Cortex-M C, this
includes generating bindings from a pinned device C header for the Cortex-M0
ABI and running a firmware consumer through those generated declarations and
adapters.

### R13.17 — Services are handles

Status: complete
Depends on: R13.16

A program shares its services: a logger and the program write through one
Io, and several containers allocate from one heap. Taken `inout`, a service
is locked while anything derived from it lives, so a second argument, a
query beside an erased view or a region beside its parent is refused, and
the library routes around it with integer addresses and hand-held parent
pointers. A value that is edited stays `inout`; a service becomes a handle,
a small copyable value passed `in` that refers to its state, whose lifetime
is checked once where the handle is made. The allocator and the four I/O
concepts take their handle by value, every provider in `core` and `hosted`
gives one, and the containers take theirs `in`. Process-wide state, the
argument root, the last error and the Linux heap's classes, belongs to the
process, so its handles borrow nothing.

Exit evidence: no `inout` or `ptr` provider parameter left in `core` or
`hosted`; fixtures pinning two lent results at once, a query and a direct
write beside an erased view, a region and its parent used together, and a
handle refused past its state; and the hosted and firmware corpora passing
on every target.

Done: D288 makes a service a handle. The allocator and the four I/O concepts
take theirs by value, every provider in `core` and `hosted` makes one with
`over` from state its caller declares, and region, fault and diag hold a
copy of their parent's. `hosted.host()` and `heap.host()` stay one line; a
handle from `hosted.over` keeps its own last error, which is how
`abi/r440-errno-thread-local` gives each C thread its own until there is
thread-local storage. D289 lets an erased entry take a record `self` by
value, and D290 to D292 correct three borrow checks the conversion met.
Passing records by value pushed a Cortex-M0 image past its flash, so a
caller now snapshots a record only when a later argument could write memory,
and every backend copies aligned records by words.
`runtime/io-handle-lends-two-arguments`, `runtime/io-handle-beside-erased-view`
and `runtime/region-beside-parent` pin the patterns that were refused, and
`negative/handle-outlives-state` and `negative/region-release-live-handle` the
lifetimes still checked. All 42 jobs in
[the complete gate](https://github.com/JanHaan/Landin/actions/runs/38348601801)
passed on `09ca0033`, physical RV64 among them, once Darwin's `stat` device
numbers were read unsigned; [the branch's final gate](https://github.com/JanHaan/Landin/actions/runs/38409022298)
passed on `4fa6f5c9` with RV64 suspended.

### R13.30 — Standard input, files and directories

Status: complete
Depends on: R13.10, R13.11, R13.13, R13.17

The first of four hosted items, R13.30 to R13.33, which share these rules.
Each facility is a narrow concept beside D268's four, with a caller-backed
fake in `core/io`, written once over R13.16's Linux system calls and once
over the C library for Darwin and FreeBSD, and reached through the same
capabilities as now. Each is driven by a complete consumer published in
`examples.md`, decided in `spec.md`'s register, documented in
`docs/library.md` and `core/README.md`, and refused by name on firmware
where it is hosted-only. Together they take R551-34's hosted part, and with
it B5's.

This item lays the ground and adds files and directories. `core/text`
writes `u64` and `usize` decimals and parses them from `[]u8`, replacing the
tree's hand-written copies, and `ENOTDIR` maps to `not_found`. Standard
input joins the process concept, which takes SR-14's by-pointer `out`, `err`
and `argument_count` with it, and reaches a runtime fixture through a
`stdin:` key that every runtime lane honours. A counting consumer reads
standard input. A listing consumer builds a scratch tree, reads its names
as bytes, validates them through `core/text` and prints `u64` sizes and
kinds.

Exit evidence: both consumers running on every hosted target with failure
oracles: a missing path, a file used as a directory, a name that is not
UTF-8 with each system's own outcome, and a directory larger than one read
buffer.

Done: standard input is the process concept's third stream, reached in a
fixture through `stdin:` (D285); `core/text` writes and parses every unsigned
width over bytes (D286); and ENOTDIR is `not_found` (D287). `io.directories`
is a fifth concept whose open directory is a value lending each name until
the next read (D293), over `getdents64` on Linux, with every record held
inside what was filled, and over `readdir` on Darwin and FreeBSD.
`hosted/linux` makes its raw call public and `hosted/linux/numbers` names
every call's number, generated from Linux 7.2's own tables (D294). The word
counter and the directory listing are published in `examples.md` and run by
the outside-user lane. The listing's oracles met each system's own outcome
for a name that is not UTF-8 natively: Darwin refused it with EILSEQ, and
Linux and FreeBSD listed its exact bytes. On the way, `try` of a callee whose
set is still inferred waits for it (D295), unused module data is not emitted
(D296), L0328 names its routes, the Cortex-M0 backend addresses frame homes
from `sp`, which brought three memory-world fixtures inside 32 KiB, and the
FreeBSD lane compares output only where a fixture declares it, as the other
lanes do. The complete gate passed on the commit that closes this item, with
RV64 suspended; [the run before it](https://github.com/JanHaan/Landin/actions/runs/38470178283)
passed every job but FreeBSD's output comparison.

### R13.18 — The POSIX layer and host strings

Status: complete
Depends on: R13.30

The hosted library gets four layers. Each system's own interface stays raw:
`hosted/linux` and `hosted/libc` move to `platform/linux` and
`platform/libc`, and Linux's
epoll, signalfd, pidfd and getrandom stay in `platform/linux`. A new
`platform/posix` gives POSIX's facilities in Landin types, a descriptor as a
handle type, errno as atoms with the number kept, a structured `stat` and
`poll`, written once over Linux's system calls and once over the C library on
Darwin and FreeBSD; it is never available on Windows. The portable concepts
in `core` name no POSIX type, no integer descriptor, mode bit, user or signal
number, and `hosted/io` and `hosted/heap` are rewritten over `platform/posix`,
so a hosted facility is written once and Windows can later implement the
same concepts over its own interface. Each later hosted item adds the POSIX
facilities its consumer needs. A host string is one opaque type whose
representation each target fixes, bytes on POSIX and 16-bit units on
Windows, with checked conversions to `utf8` and to bytes and comparison with
a literal; arguments and paths take it, so a value passed through is never
converted.

Exit evidence: every existing hosted fixture passing on every hosted target
over the new layers, with no `hosted/io` facility written per system;
`platform/posix` fixtures with failure oracles for each facility it gives;
and an argument and a path that are not UTF-8 passed through unchanged and
refused by the checked conversion to `utf8`.

Done: `hosted/linux` and `hosted/libc` are `platform/linux` and
`platform/libc`, and `platform/posix` is written once over each with a
descriptor handle, every system's errno as atoms with its number, a
structured status and `poll` (D297, D298). `hosted/io` and `hosted/heap` have
no code of their own for any system, and one size-class heap serves all three
(D300). Paths, arguments and entry names are host strings, passed through
unconverted (D299). Two language rules came with it: static storage satisfies
a read-only `from` clause, which retired a forged argument table (D301), and
two values of one distinct scalar type compare equal and flag sets combine
(D302). Every backend now gives each routine its own section, which brought a
static arm64 hello from about 200 KB to 15 KB, and L0500 counts only what the
entry reaches (D303). Three checker and lowering defects met on the way are
fixed and pinned, and atom-set validity is tested by ranges. The kqueue module
is R14.30's. The complete gate passed on the commit that closes this item,
with RV64 suspended.

### R13.19 — Formatting, buffered text and byte blocks

Status: complete
Depends on: R13.18

`core/mem` gains `copy`, with `memmove`'s rule for overlap, `fill`, `compare`
and `find` over byte slices with their lengths checked. `core/text` gains a
builder that writes typed pieces into a caller's buffer, bytes and text,
signed and unsigned decimals, hexadecimal, width and padding, failing
`no_space` or growing through an allocator the caller passes, and appends a
byte string; and `text.format` over a format string and an array of
`any text.formattable`, whose count and kinds are checked when it runs,
because nothing is executed at compile time. Parsing is its mirror, signed
values included. `core/io` gains a buffered writer flushed explicitly, with
`defer` its idiom, and a line reader that lends each line until the next
read, as a directory lends its names. Formatting is independent of locale,
and a locale is never global state. The word counter and the directory
listing are rewritten over it.

Exit evidence: both consumers rewritten and running on every hosted target;
fixtures for each piece with failure oracles, a full buffer, a format string
whose count disagrees with its arguments and an overlapping copy among them;
and the builder and the buffered writer running on the Cortex-M0 profiles.

Done: `core/mem` copies, fills, compares and finds over byte slices, overlap
always safe (D304). `core/text` has a builder that writes whole pieces into
the caller's buffer or a growing one (D305), `text.format` with `{}` checked
against its values when it runs (D306), and parsing that mirrors it (D307).
`core/io` has a buffered writer flushed explicitly and a line reader that
lends its lines (D308). An array literal or a fixed array is now lent whole
to a slice parameter, so a format call passes its values directly (D309), and
a value in the `else` of a call returning nothing is refused, which ended an
idiom written 192 times in the corpus (D310). The word counter and the
listing are rewritten over it, and a line numberer is published as the line
reader's consumer. On Cortex-M0 the builder and `format` run in one fixture
of 21 KB and the buffered writer in another; the two broadest fixtures are
recorded as image limits. A checker defect on a generic routine re-failing in
a concept entry's `else` is fixed and pinned. The complete gate passed on the
commit that closes this item, with RV64 suspended.

### R13.31 — The environment and processes

Status: complete
Depends on: R13.19

Under R13.30's rules, written once over `platform/posix`: the environment as
host strings, read from the initial stack on Linux and through the C library
elsewhere, read-only, since changing one's own environment is not safe beside
threads; and processes spawned by explicit path with explicit arguments and
an explicitly built environment, each of their three streams inherited,
discarded or a pipe, waited for, and reported as exited with a code or ended
by a signal. `platform/posix` gains pipes and the waiting it needs. A
consumer runs a shell with an explicit environment, captures what it writes
and reports what the child saw and how it ended.

Exit evidence: the consumer running on every hosted target with failure
oracles: a missing program, a child ended by a signal, and a child's output
larger than a pipe's buffer.

Done: the environment is a read-only concept of its own, whose values are
host strings, reached on every hosted system through the argument
initializer, which now takes `envp` (D311, D312). `io.programs` runs a program
by its path with an explicit environment, each stream inherited, discarded or
piped, reads both outputs as they become ready and reports an exit code or a
signal (D313). `platform/posix` gains pipes, spawning and waiting, and every
descriptor it makes is closed on exec (D314). Both have fakes, and a scripted
child runs on Cortex-M0. A shell runner is published in `examples.md`; its
oracles are a missing program, a signalled child, a mebibyte on each stream,
a leaked descriptor and an environment that is not UTF-8. A payload-free case
of an imported variant could not be constructed; that is fixed and pinned.
The complete gate passed on the commit that closes this item, with RV64
suspended.

### R13.32 — Time and randomness

Status: complete
Depends on: R13.31

Under R13.30's rules: monotonic and wall clocks, and sleeping. On Linux the
clock is read through the vDSO the auxiliary vector names, falling back to
the system call. The system's entropy, getrandom on Linux and arc4random on
Darwin and FreeBSD, is a hosted facility, and `core` gains a deterministic
generator seeded from it or from a fixed seed. Calendars, time zones and
their formatting belong to the locale record in the register. The process
consumer times its child.

Exit evidence: the consumer's timing running on every hosted target, with
monotonic order and a sleep's lower bound as oracles; the entropy facility
answering on every hosted target; and the generator reproducing a fixed
seed's sequence on every target, Cortex-M0 included.

Done: time is a count of nanoseconds in ordered distinct types, and the wall
clock UTC seconds and nanoseconds (D315). A clock, a wall clock and entropy
are concepts of their own with fakes a test controls, and a sleep never
returns early (D316). Linux reads its clock through the vDSO with a checked
parser and a fallback, about four times faster than the system call (D317),
and under `--link=libc` too, since the argument initializer now adopts the
auxiliary vector after `envp` when the tables have the initial stack's
layout. `core/random` is xoshiro256**, reproducing its reference sequence on
every target, Cortex-M0 included (D318). Every distinct scalar type is now
ordered as its base is, amending D302. The shell runner times its child. The
complete gate passed on the commit that closes this item, with RV64
suspended.

### R13.33 — Sockets

Status: complete
Depends on: R13.32

Under R13.30's rules: blocking TCP and UDP sockets over IPv4 and IPv6 that
bind, listen, accept, connect, send and receive, with address values, each
system's address layouts, shutdown and the common options, no delay, address
reuse and timeouts. Unix-domain sockets are `platform/posix`'s. SIGPIPE is
ignored when a POSIX process starts, so a write to a peer that has gone is
an error atom rather than the end of the process, and `posix.spawn` restores
its default in a child, which would otherwise inherit it; until then, writing
to a child that has ended ends the parent. An echo client and server
run over loopback in one process, over TCP and UDP and both address
families. Sockets under an event-driven Io are R14.30's; resolving a name
belongs to the resolver record in the register.

Exit evidence: the echo consumer running on every hosted target with
failure oracles: a refused connection, an address already in use and a write
to a closed peer.

Done: `io.network` gives blocking TCP and UDP over IPv4 and IPv6, its
connections readers and writers, its errors precise atoms and its limits
`timed_out` (D319). An address is a family, sixteen bytes and a port, read and
written as RFC 4291 and RFC 5952 say (D320), and a loopback network in memory
fakes it (D321). SIGPIPE is ignored at start and restored in every child, so a
write to a peer that has gone is `disconnected` (D322), and `platform/posix`
gives sockets in each system's own records, Unix-domain ones among them
(D323). The echo consumer is published. A module value now reads another
module's values as its own (D324), which retired the constants libraries had
wrapped in functions, and an atom widens into a generic routine's atom-set
parameter (D138). Adding a Linux wrapper no longer needs the kernel's source.
The complete gate passed on the commit that closes this item, with RV64
suspended.

### R13.34 — The rest of the file system

Status: complete
Depends on: R13.33

Under R13.30's rules. The portable concepts gain renaming, a metadata record
with size, kind, modification time and a read-only flag, `fsync`,
truncation, temporary files, the current directory, reading and writing at
an offset rather than through a hidden position, and appending as an open
option, and whether a stream is a terminal and its window size.
`platform/posix` gives the rest: mode bits and owners, hard and symbolic
links, file times, advisory locks as each system has them, a terminal's raw
mode, and users and groups, read from `/etc/passwd` and `/etc/group` on a
static Linux program, where accounts kept elsewhere need `--link=libc`. A
consumer copies a tree, keeping what each system keeps.

Exit evidence: the consumer running on every hosted target with failure
oracles: a rename onto an existing name, a symbolic link listed without
being followed, a write refused on a read-only file and an offset past the
end of a file.

Done: `io.file_system` gives renaming, status, synchronizing, truncation,
offset I/O and the working directory read-only, and `io.terminals` whether a
stream is a terminal (D325); temporary files are made exclusively from
entropy the caller passes (D326). `platform/posix` gives links, modes,
owners, times and both kinds of lock (D327), a terminal's raw mode and
pseudo-terminals (D328), and users and groups, read from `/etc/passwd` and
`/etc/group` on a static Linux program and through the C library otherwise,
chosen by the new fact `compiler.c_runtime` (D329). A tree copier is
published. A parser defect refusing a construction fill after a qualified type
is fixed. The complete gate passed on the commit that closes this item, with
RV64 suspended.

### R13.35 — Dynamic loading

Status: complete
Depends on: R13.36

`platform/posix` loads a C library and looks its symbols up into typed
`extern(c)` function values, wherever the system's loader started the
process: on Darwin and FreeBSD always, and on Linux under `--link=libc`. A
static Linux program that asks for it is refused by name before any tool
runs, naming `--link=libc`, as D280 refuses a C import. Code loaded this way
is C, or Landin only through C-ABI entry points. A consumer loads a library
the fixture builds and calls into it.

Exit evidence: the consumer running on Darwin, FreeBSD and Linux under
`--link=libc`, with failure oracles: a missing library, a missing symbol,
and the refusal of a static program.

Done: `platform/posix` loads a C library into an opaque handle with an
explicit scope, finds its symbols and gives the loader's words on request
(D336), and a C function type applied to an address makes the typed function
value, which also retired the vDSO clock's pun through memory (D335). A
static Linux program that loads one is refused by L0500 naming the routines
that ask for the C library. Fixtures may build C shared objects with
`c-shared`. The consumer is a fixture rather than a published example, since
the outside-user lane links statically and assumes no C compiler. The
complete gate passed on the commit that closes this item, with RV64
suspended.

### R13.36 — The recurring parser frictions

Status: complete
Depends on: R13.34

Four refusals were met in nearly every hosted item and routed around each
time, with helper routines the library and its fixtures still carry: a call's
`else` inside an `if` arm taken as the `if`'s (SR-57); a line beginning with
`(` continuing the one before, so a construction or a destructuring is read as
a call (SR-39); an inline atom-set union as a parameter's type (SR-58); and
`lenof` taking only a name, not a field path or a call's result (SR-66,
SR-44). Each gets a decided grammar rule in `spec.md`, which `check.py`'s
derivation and the corpus agree with, a parser that follows it and a refusal
that names the route where a form stays refused; then the workarounds are
removed from the library, the examples and the fixtures.

Exit evidence: fixtures for each form, accepted and refused, the grammar
deriving every positive one, and no helper left in `core`, `hosted` or
`platform` that exists only to avoid one of these refusals.

Done: a call's bound recovery recovers inside an `if` arm (D330); a line that
begins `(` and binds with `:=` destructures, and a continued line is named in
the refusal it causes (D331); an atom union may be written in place as a
declared type (D332); and `lenof` measures paths, slices and a call's result,
a call always evaluated (D333). A statement's branch that ends with a value is
now refused (D334), which the first rule made urgent. Thirty-four
parenthesised recoveries, six helper routines, seven `lenof` helpers with
their seventy-nine calls and twenty locals are gone, and the editor grammar
and the formatter follow every form. `check.py` names the two refused
fixtures its grammar still derives as stated in prose. The complete gate
passed on the commit that closes this item, with RV64 suspended.

### R13.60 — The cheap code-generation and compile-time wins

Status: complete
Depends on: none

The Benchmark Game ports ran at two to sixteen times C's time on Linux
x86-64, and hand-patched assembly put most of the gap in code generation and
the library rather than in the checks [1960] keeps. This takes the parts of
R16.20 those measurements named ahead of R16.10's baselines. On x86-64:
small fixed copies and clears as moves, traps after each routine's body,
`movapd` between registers, results computed in their own register with
immediate operands, float comparisons fused with their branches, division by
a constant as a multiplication, and indexed accesses as scaled operands, with
arm64 using register offsets the same way. In the IR: float and pointer slots
forwarded, a forwarded value surviving writes that cannot reach its slot,
block-local value numbering that reuses an identical earlier check, `and` and
`or` conditions lowered as jumps, and a live interval for every slot, which
the x86-64 and arm64 allocators fill with registers. In the library:
`hosted/heap`'s headers as aligned words and `core/region`'s ledger as a
chain, SR-135, and `core/mem` moving words on hosted targets. Inlining,
vectorization and scalar replacement, SR-154, stay in R16. The ports land
here too: fannkuch-redux, mandelbrot and fasta take their size as an
argument and buffer their output, and reverse-complement and binary-trees
join them, each held to the Benchmark Game's own output.

The compiler itself took longer than gcc, GNAT, rustc and go over every
port, and nearly all of it went to the library rather than the program.
Only the routines a program can reach are lowered, emitted and assembled,
SR-156 and D296; table reads no longer build controlled references and the
checker's container instances are elaborated once, SR-157; and the IR
verifier's duplicate checks and pointer trace, and x86-64's frame test, no
longer repeat work per set, slot or routine.

Exit evidence: every check still trapping at its own operation, with its
line, panic-map entry and unwinding unchanged, and the debugger sessions
unchanged; the five ports timed before and after on Linux x86-64 with
identical output, binary-trees on peak memory as well; the compile-time
scaling bound held; the Cortex-M reference profile still holding the
firmware that uses `core/region` and `core/mem`; and hello-world and the
ports compiled before and after beside gcc, GNAT, rustc, zig and go, with
the GNAT and verifier changes emitting byte-identical assembly.

Done: on Linux x86-64 the five ports take 1.19, 1.13, 2.0, 2.0 and 3.8
times C's time, from 2.7, 5.0, 4.7, 7.9 and 15.9, with identical output, and
binary-trees peaks at 394 megabytes rather than 656; `docs/benchmarks.md`
records each run. The test program, the GDB sessions, object quality and the
scaling bound pass on Linux x86-64. The arm64 and RV64 cross lanes fail only
fixtures that fail identically at `--optimize none` on that host, SR-76, and
the Cortex-M lanes run the new fixtures, `core/mem` keeping its byte loops on
firmware for the 32 KiB flash. A lowering defect the work met, a loop whose
condition leaves on every edge, is fixed with its fixture. Hello-world
compiles in 0.29 seconds rather than 1.16 and the ports in 0.31 to 0.35
rather than 1.19 to 1.25, against 0.12 to 0.18 for gcc `-O3` and 0.22 to
0.30 for go, at a peak of 37 to 44 megabytes rather than 68 to 80. The
complete gate passed on the commit that closes this item, with RV64
suspended.

### R13.70 — The newcomer's path

Status: complete
Depends on: R13.35

The hosted library is complete enough for someone to use, and their first
ten minutes still go wrong. Reproduced with R13.35's compiler: `refine fmt`
refuses to rewrite a writable file for every unprivileged Linux user and says
only that it cannot write, while `--check`'s note sends them back to it; an
index out of bounds ends as "Illegal instruction"; the README's first compile
leaves its assembly beside the executable; `import cor/io` is told to give
`--root`; and `elif`, a reserved word used as a name and a `match` over an
integer each get a refusal that does not name the Landin form. This item
fixes what a newcomer meets, then the contributor and Cortex-M frictions
that R12 would otherwise meet in every item, and ends with the outside
reading the R13 gate requires and no item owned. A second whole reading of
the library after R13.35 found defects, and a library each hosted item had
grown by adding a file to the nearest module: `core/io` has 193 public names
and `platform/posix` 342, and some facilities are written two to four times.
That work comes first, because it renames what the rest teaches and what six
hosted targets and R14's second Io would otherwise build on.

The library's defects, each fixed with a fixture that fails without it:
`io.write` to a Linux socket passes `MSG_NOSIGNAL`, as D322 promises; the
volume fake creates a dangling link's target rather than a second node at
its path, and follows links where a system does, a relative target from its
link's directory; a read or write above `INT_MAX` is bounded on Darwin;
`dlopen` of an empty path is refused rather than giving the main program,
which D336 keeps out; `linux.ppoll`'s limit is writable, as the kernel writes
it; FreeBSD opens its pseudo-terminal controller close-on-exec; the static
and C account routes fail alike, and the C group lookup gets the caller's
whole buffer; the fakes fail as the hosted provider does, for
`remove_directory` on a file, a listener beside an accepted connection and a
line reader over an empty buffer; `vec.list`'s storage cannot be replaced
from outside, and `heap.free`'s trust and its ignored unmap are checked or
stated; `platform/libc`'s `stat` is chosen by name rather than by
elimination; `random.below(0)` is refused as what it is; and `next_u32`'s
reason is xoshiro256**'s own.

The library's shape, decided as R13.13's renames were: each facility once,
with byte equality, hashing and three-way order in `core/cmp`, its `less`,
`equal` and `greater` moved there from `core/mem`, and `[]u8` ordered; one
decimal writer, the builder's, and one home for parsing in `core/text`, whose
legacy byte layer and cursor are retired, with `parse_*` and `core/io`'s
network no longer copying its scanners and hex digits; `text.format` writing
through any byte sink, a buffered writer among them, rather than a builder
and a copy; the containers' slot allocation written once in `core/mem`, and
the arena a provider of its own beside pool, region and fault; one fake of
files and directories, the volume, with the memory world kept as firmware's
own world over it; one way to open and to close a file, `file_system`
refining `files`; and `hosted/io`'s errno mapping, retried open and quiet
close, and `platform/posix`'s close-and-ignore helpers, each written once,
with the declarations and constants D298 and D300 left unused removed,
`platform/libc`'s `malloc` and `free` among them. `core/io` splits along its
seams into `core/time`, `core/net` and fakes under `core/io/fake` named one
way. `core/tree` is named for what it is or leaves `core`. `hosted/io` is
renamed so that no importer needs an alias (SR-181), and its files mirror
`core/io`'s, `file_system`, directories and entropy each in its own.
`platform/posix` keeps each facility's backends in its own file, splits
`posix.ldn` by facility, names its C route for what selects it (SR-183) and
keeps the `/etc/passwd` parsers private; `platform/libc` is one file per
system (SR-184); `vdso` is a submodule of `platform/linux`; and `platform/cpu`
is named for the M profile, as `platform/cortex_m` would be. The closed sets
carried in integers and bools become atom sets or variants: the loopback
socket's role, a scripted program's ending, which stream a child read failed
on, the builder's ownership, a zero-capacity region, a vacant pool slot and
the bare flags of `status_of` and `synchronize`. Principal types, providers'
counters and the fakes' constructors follow one naming rule, a byte is
written as a character rather than a number (SR-182), and SR-14's points are
each changed or retired. The stale documentation it found is corrected:
`last_errno`'s zero; `docs/library.md`'s heap, its `libc.allocation` and its
hand-written descriptor conversion where `hosted.descriptor_of` exists;
D282's header words; dynamic loading's systems in `core/README.md`;
`vdso_image`; and the module headers that describe how things were.

Formatting: `refine fmt` replaces a file without privilege and keeps what it
cannot see, by a replacement decided in `spec.md`'s register, and a refusal
names its cause rather than "cannot write" (SR-17). `--check` reports every
difference, each with the line as the layout wants it, and a mode writes the
formatted source to standard output (SR-69, SR-124). `docs/format.md` shows
a parenthesised continuation (SR-91), the tour's examples are in the one
layout and `check.py` holds them there (SR-137), and the tour states a raw
literal's leading newline (SR-119).

Running a program: a hosted program that traps with no panic handler writes
the trap's kind and source site to standard error before it ends, amending
D232, and firmware keeps its terminal instruction (SR-55). Linux links
through a driver a stock distribution supplies (SR-22), and a static link's
refusal of a C symbol comes before the toolchain's (SR-168). The
intermediate assembly is kept only on request, and an assembly file links
through `refine` as a compiled program does (SR-90, SR-141). `refine` shows
the IR a program lowers to, named in `--help` and `docs/ir.md` (SR-140).

Finding the library: a misspelt library namespace is offered the near name in
the explicit-file mode too (SR-23); a project root holding a reserved
namespace is told about `--library` (SR-62); and a library import found
nowhere names where `refine` looked and `--library`, with `--emit=asm`
refusing rather than leaving a module out (SR-145).

Refusals that name the Landin form: `elif` names `elsif` (SR-152); a reserved
word in a binding's place is named reserved, in one report (SR-144); a
`match` over an integer names `if` and `elsif` (SR-132); a function-typed
module binding is admitted or names the alias it needs (SR-131); and an
assignment after a bare `else` names the recovery's binder (SR-155). SR-13's
decision is taken with them. No note quotes a register label or a grammar
summary as its whole explanation. An untyped integer literal and a fixed
array passed to a generic routine are typed or lent from the parameter, or
refused naming the conversion (SR-109). Ignoring a failure gets a decided
short form, or the tour teaches the block form, and the README's first
program uses what is decided (SR-108). A page maps a C programmer's habits
to their Landin forms and names those with no answer yet (SR-56).

The lanes R12 changes: `nix develop` provides the pinned cross lane, QEMU's
user emulation, the cross drivers with a static `libm` and an aarch64 GDB,
and the lanes' host failures are listed as expected (SR-76). The debugger
workload inventory is checked where a library change is made, naming the
files and the command that regenerates it (SR-113). The memory controls and
the scaling bound give one verdict under load, or refuse a measurement taken
under contention (SR-134, SR-159). The Cortex-M corpus line gives each
section's size against its region, overflowing or not, and a stale image
limit fails (SR-75); missing tools are refused naming the path and `--tools`
(SR-78); a failure names its case and log (SR-93); a profile has one spelling
(SR-103); the inventory's rules are documented and its refusals name the row
(SR-111); a timeout names its limit and the fixture's time (SR-150); and a
firmware image leaves out conformance entries it never calls (SR-61). RV64
returns to the gate on QEMU's user emulation, its hardware jobs staying out
until they are dependable (SR-80), and SR-122 is measured again on the hosted
runners.

A review of `main` after R13.35 found four more defects, each fixed with a
regression fixture: a standard stream whose descriptor is already its
destination losing its close-on-exec clearing in `platform/posix`'s spawn
(SR-210); the compiler's own tool runner losing explicit input and captures
when its caller has closed standard input (SR-211); `map.reserve` keeping
tombstones it then grows for (SR-212); and the volume fake's directory reads
bypassing its failure counter (SR-213).

Exit evidence: the library's defects pinned by fixtures that fail without
their fixes; decisions for every changed interface, the migration table in
`core/README.md`, the reference rebuilt, and every renamed consumer, the
derived programs and the debugger workloads passing on every target; every
record named here meeting its completion, with fixtures pinning each refusal
and each admitted form; `refine fmt` rewriting a file
for an unprivileged user on Linux tmpfs, ZFS and ext4 with its attributes
kept; a trap's report on every hosted target; the README's first program
compiled and run on a stock Ubuntu with only the distribution's compiler;
the RV64 emulated jobs in the gate; and then a reader with no project context
doing a realistic hosted task from the published documentation alone, with
what they met in the register.

### R13.61 — Closing the gap the measurements found

Status: complete
Depends on: R13.60

After R13.60, native arm64 still ran the Benchmark Game ports at 2.4 to 11
times C's time while x86-64 ran them at 1.1 to 3.9, ordinary programs over
`core/vec`, `core/map`, `core/sort`, `text.format` and a lexer at 2.3 to 13.7,
and binary-trees spent nearly all of its gap in calls. Hand-patched code and
library copies, with output unchanged and every check kept, measured each
cause. The arm64 backend takes what R13.60 gave x86-64: floating-point values
in registers, results in their own register with immediate operands, fused
comparisons, division by a constant as a multiplication and small copies as
moves. Both backends give registers to small routines, caller-saved where no
call crosses a value. Immutable module data folds, SR-46; `--specialize auto`
counts no growth for a call it only makes direct; a generic instance is not
address-exposed for being public; a check a dominating comparison or a type's
range proves is removed; a callee reads an aggregate parameter in place when
nothing can change it, under D94's convention unchanged. An allocator may
resize a block, `hosted/heap` with `mremap` on Linux, and the text builder
grows through it. The compiler restricts its own runtime to what it uses, reads
token and node kinds without copying, and builds its emitter's tokens as
spans. A second phase copies small direct calls into their callers at
`speed`, one level, with inlined-routine debugging records and a speed lane
the scaling measure holds (D339); splits slices and small structs into
scalars, SR-154; turns a branch whose arms only compute into a choice
(D338), with fasta's lookup counting as the Benchmark Game's C program does;
starts every x86-64 routine on a 64-byte boundary at `speed`, SR-146; and
makes the debug and release compilers emit the same bytes, SR-179, which a
gate job now holds. Passing slices in registers and frameless leaf routines
would revise D94, D97 and [1550], and stay out.

Exit evidence: every check still trapping at its own operation; the debugger
sessions unchanged, at `speed` too; the five ports and the ordinary workloads
timed before and after on Linux x86-64 and native arm64 with identical output;
compile times before and after beside the other compilers; the scaling bound
held; and the Cortex-M reference profile still holding the firmware.

Done: on Linux x86-64 the five ports take 1.05, 1.07, 1.23, 1.30 and 2.22
times C's time, from 1.20, 1.14, 1.99, 2.10 and 3.87, a geometric mean of
1.32 from 1.86, each over three copies of its executable with output
identical to C's. Native arm64 on an M1 Pro runs them 2.2 to 5.8 times
faster than before at `speed`, at 1.07 to 2.5 times C's time on Darwin and
0.99 to 3.0 on Linux. The ordinary workloads over `core/vec`, `core/map`,
`core/sort`, `text.format`, a lexer and `any` dispatch run 12 to 31 per cent
faster from the first phase, and word count and binary-trees about a third
and vec a fifth faster again from inlining; reverse-complement, which the
second phase first slowed by moving its loop, ends faster than after the
first, 0.99 seconds against 1.03, once placement is fixed. Hello-world compiles in
0.30 seconds rather than 0.34, and the 16,000-declaration families 30 to 40
per cent faster. The test program, the GDB sessions, object quality, the
cross and Cortex-M lanes and both scaling lanes pass on Linux x86-64;
`docs/benchmarks.md` records every run. The complete gate passed on the
commit that closes this item, with RV64 suspended.

Done: `refine fmt` rewrites a file in place without privilege, keeping what it
cannot see, and `--check` gives every line as the layout writes it (D358 to
D360). A hosted trap reports its kind and site (D361); the assembly stays only
on request and links through `refine` (D362); library refusals name
`--library` (D363, D366); Linux links through a stock distribution's driver
(D364); and `--emit=ir` shows the IR (D365). Foreign spellings, keywords as
names, integer matches and a bare `else` name the Landin form (D367 to D370);
a function-typed module binding is admitted (D371); generic arguments are
typed and lent from their parameter (D372); notes say in words what they cite
(D373); and `else none` ignores a failure (D376). The library review's defects
are fixed, and the library is reshaped: `hosted/system`, `core/time`,
`core/net`, `core/io/fake`, `core/arena`, `platform/cortex_m`, `platform/posix`
and `platform/libc` by facility and system, each facility written once
(D340 to D357). A read-only erased view of static storage satisfies a
writable `from` (D375), an erased call no value can reach traps (D377), and
the four defects a review of `main` found are fixed (D378 to D380). The text
cursor, the memory world over the volume and the pool's slot sentinel stay,
for the reasons D355 and D354 record. `nix develop` carries the cross lanes,
RV64 runs in the gate under QEMU, the Cortex-M lanes give each region's size,
and an image keeps only the evidence entries it can call (D374).
`docs/from-c.md` maps C to Landin. A reader with no project context then
built a directory tally from the published documentation alone, and what they
met is in the register. The complete gate passed on the commit that closes
this item, with RV64's hardware jobs suspended.

### R13.71 — What the newcomer's path met

Status: complete
Depends on: R13.70

R13.70's agents and its outside reader recorded what they met as they went,
in rows new to the register and in older rows met again. This item answers
them before the release that follows R13.70 and before R14 builds on the
same tools.

The language, each decided in `spec.md`'s register with fixtures: several
labels on one `match` arm, as the tour already teaches, or the tour
corrected (SR-214); a short way to ignore the failure of a call that returns
a value, or a refusal naming the forms that work (SR-206); byte-packed C
records (SR-216); an offset query and a compile-time assertion over a
declared layout (SR-53); and which public names reach the C namespace, so a
library name cannot collide unseen with a C symbol or a linked object
(SR-26).

Refusals and commands: L0329 names the atom and the `fail` that raises it
(SR-215); a local or parameter that shadows an import or a concept is named
as the cause (SR-64); `check` accepts what `compile` accepts, `--link`,
`--firmware-entry` and `--build-report` among them (SR-70); an option before
its command is named in its refusal with where it goes (SR-170); `refine fmt`
takes a directory (SR-205) and its note marks where a line differs (SR-224);
and the C driver refusal and the installation text name the Nix route and
which commands need no driver (SR-220).

The library: the pool grows a block within its slot (SR-200), a library
failure atom has words for a person (SR-221), and `core/sort` takes a
comparison with a context (SR-222), each with a consumer.

The documentation: the tour's placeholder bodies parse or are marked as
fragments (SR-190); installation is reachable from the front page and says
where an archive unpacks and what `refine version` prints (SR-219); the
reference pages are sized for a reader (SR-223); and `arena` is no longer
coloured as a keyword (SR-208).

The tools a contributor meets: the debugger sessions' frames are checked
where the library changes (SR-189); the suite that checks a recorded report
is named (SR-191); the catalogue's label counts are checked statically
(SR-192); the unfiltered run reports progress per suite (SR-193); every lane
takes one default for merged streams (SR-194); a fixture's report, a server
session and the lowering corpus are re-recorded one at a time and a stale one
is named (SR-197, SR-207, SR-217); the server's analysis sees the library for
rooted fixtures (SR-198); a rooted negative selects its target (SR-199);
`scripts/debug.sh` finds the shell's toolchain and replaces its own output
(SR-201, SR-149); `nix develop` has the pinned tree-sitter CLI and a bash with
completion, and prints its banner on standard error (SR-202, SR-25, SR-218);
the corpus gives per-routine Cortex-M sizes (SR-203) and states its
inventory's trap-report rule (SR-209); a failed build rebuilds only what it
must and a rebuild never pulls `refine` from under a running reader (SR-68,
SR-94); and fixture metadata spells targets as `--target` does (SR-185).
Hosted images narrow what their startup assembly keeps live, so evidence
pruning applies there too (SR-204).

Exit evidence: every record named here meeting its completion, with the
fixtures and decisions it names; and a second outside reader repeating the
directory tally from the published documentation and an archive meeting none
of SR-219, SR-220 or SR-222.

Done: several labels share one `match` arm (D405), a value call's failure is
ignored under a discard with `else none` (D406), C's byte-packed records are
`layout(c, packed)` (D410), `offsetof` and the layout facts measure in
`compiler.assert` (D411, D412), a last `[0]t` field is C's flexible member
(D413, D414), and `public` no longer makes a global symbol: only exports do,
and a collision is named by its module (D415 to D418). Refusals name what
raised them, what hides an import and where an option goes, `check` takes
what `compile` takes and `fmt` takes a directory (D381 to D385). The pool
grows within its slot, `sort.sort_by` takes a context and `core/failure`
gives library atoms words (D386 to D388). Assembly reaches only what it
names, so hosted images prune evidence entries too (D374). The tour's
placeholders are code, installation is reachable from the front page and
the reference pages are a sixth of their size. A contributor's tools record
one artefact at a time, report progress, check the debugger frames and the
catalogue's label counts where they change, refuse a known-bad emulator, and
`nix develop` carries the pinned tree-sitter CLI, a bash with completion and
a build that never pulls `refine` from under a reader. A second reader with
no project context built the directory tally from the published material,
reached installation and sorted with a context; what they met is in the
register. The complete gate passed on the commit that closes this item, with
RV64's hardware jobs suspended.

### R13.72 — What the register holds now

Status: complete
Depends on: R13.71

After R13.71 the register's open rows were mostly friction met while the
library and its tools were built, each waiting for "the next item that
touches" its area. This item takes every one of them that needs neither a
board, a new target, a library facility no program has asked for, nor a
maintainer's release decision, so R14 starts from a register that holds
what waits for a reason.

The language, each decided in `spec.md`'s register with fixtures, either
admitting the form or giving a refusal that names the route that works:
selecting from a call's result (SR-27); a made pointer, a struct literal, a
named array and an erased view as call or generic arguments (SR-37, SR-67,
SR-106, SR-164); positional destructuring of results (SR-42); a guarded
trap (SR-31); fixed selection inside a body and feature facts in module
values, with a fact naming the selected level (SR-38, SR-45, SR-48); a
module constant as an array bound (SR-102); a trapping `match` arm leaving
the match a statement (SR-104); comparing a pointer union with an atom
(SR-105); a payload-free case in module data (SR-116); assignment before
`break` counted (SR-117); destructured bindings addressable, with their
escape refused (SR-123); a qualified module array copied as an unqualified
one is (SR-130); an arm's binding as a `sink` place (SR-138); a concept
entry returning its own pointer argument (SR-175); narrowing in a `_` arm
(SR-230); equality, updating assignment and zero images for distinct types
over atom sets and pointers (SR-107, SR-163); `escaping` outside C-symbol
compatibility (SR-28); `cstring` paths for the raw Linux wrappers (SR-41);
a pointer offset that keeps its base's origin and pointer operands that
keep their permission, or the boundary recorded (SR-29, SR-54); and a
conditional import, or the empty-module shape recorded as the way (SR-40).

Refusals: an unknown applied name gets L0201's near names (SR-20); L0331
names `noreturn` (SR-32); the buffered writer's `format` takes the inline
list `text.format` takes, and L0304 never offers a form that is then refused
(SR-350); no refusal repeats its own span as a secondary
(SR-34); one missing conformance entry is one report (SR-59); L0315 names
the convention that locks (SR-63); L0326 counts an erased view's address
(SR-71); L0342 names a read-only address (SR-74); no fix-it changes a
program's meaning (SR-85); an imported variant's case is offered qualified
(SR-114); L0328 offers `[]` at length zero (SR-115); a module-internal
representation names the concept's public operation (SR-169); the verifier
names the path to an uninitialized read (SR-187); `make_buffer(4, u8)`
and a generic struct value are offered their working forms (SR-238,
SR-239); a `public main` that is not the entry is refused before the link
(SR-243); Cortex-M0's `layout(c)` refusal names its missing C ABI
(SR-252); and `check` gives D280's refusal as `compile` does (SR-229).

The compiler's own visibility: library sources recorded under a logical
prefix (SR-24); each option's effect on generated code in its help and a
specialization report naming what stayed indirect (SR-143); parsing as its
own stage in the stage report (SR-171); generic instances carrying symbols
a profiler shows (SR-142); a documented way to profile `refine` and count
calls (SR-92, SR-172); kept and dropped evidence entries in the IR dump
(SR-241); atom sets described to debuggers as enumerations (SR-16); GDB's
past-`main` setting documented (SR-43); and the shell's linker held to the
pin or the difference recorded (SR-173).

The library and its code: a growable byte container filled at word speed,
measured on reverse-complement (SR-136); no always-true bound on a
`usize`-to-pointer conversion (SR-151); an atom `match` lowered as one test
(SR-231); the vDSO parser's size measured and reduced or stated (SR-128);
glibc's `AT_HWCAP` documented (SR-126); and the binding generator emitting
packed records and flexible members (SR-246).

The documentation's generators: the Linux numbers page as one row per
name (SR-240); a public value on its own line accepted by the site generator
(SR-118); and a continuation layout for `if` expressions with a reference
that reads a wrapped signature (SR-47).

The tools a contributor meets: the fixture format read in one place, with
one base for its paths, a host-excluded fixture saying where it runs, and
adding a fixture or a `core` module naming each step (SR-234, SR-60, SR-72,
SR-176, SR-228, SR-232, SR-233); generated files regenerated by one command
(SR-235); several selectors in one run and an unknown case answered with
the naming rule (SR-158, SR-95); usage without a build and a missing
interpreter naming the shell (SR-139); a build that names what changed
under it, relinks whatever it compiled, has a tree of its own for
experiments, finds its inputs from the project files and does not clean on
a script edit (SR-147, SR-188, SR-186, SR-180, SR-237); each cross lane
selecting its own levels, an RV64 debugger route, the FreeBSD lane's tools
in the shell and a Cortex-M failure naming its fault (SR-77, SR-242,
SR-249, SR-244); misaligned RV64 access shown by a check of the emitted
sequence (SR-245); the corpus held to the formatter (SR-177); the fuzzer's
and mutation suite's dependencies and failures named (SR-73, SR-112); the
syntax walk's contract stating recovery clauses (SR-160); the grammar
corpus derived cold in a small multiple of a warm run (SR-161) and the
roadmap test without the whole site (SR-162); the debugger check on
resolved paths (SR-153); `quality.sh --output` honoured (SR-178); the
scaling families compiling clean (SR-174); the x86 optimization suite
emitting as `refine compile` does (SR-148); the tree-sitter cache and pins
surviving a hand run and a rebase (SR-165, SR-166, SR-248); a closing
commit reusing its candidate's gate (SR-81); and the mirror's contents
described as they are (SR-83).

Exit evidence: every record named here meeting its completion, with the
fixtures and decisions it names.

Done: a parameter whose type names no generic formal is an ordinary
context, so the buffered writer's `format` takes an inline list and erased
views, made pointers and constructions reach generic routines (D419, D420);
distinct types compare, update and zero as their bases do, a pointer union
compares with an atom, `_ (rest):` passes the atoms no arm named, an
assignment before `break` counts, a trapping arm leaves a `match` a
statement, destructured names are places and `ptr (sink l)` consumes a
matched pointer (D427 to D436); module values read compiler facts and size
arrays (D437, D438), the empty-module shape and the pointer and C boundaries
are recorded with their routes (D439 to D442), and `check` and `--emit=asm`
refuse what the link would (D443). Generic instances carry symbols, atom
sets are debugger enumerations, library sources have a logical prefix and
`if` expressions a continuation layout (D421 to D424); a list of bytes is
the growable byte container and the binding generator writes packed and
flexible records (D425, D426). Refusals name their routes and a second
place, the verifier names the path to an uninitialized read, the fixture
format has one reader held to the Ada one, the build relinks what it
compiled, `check.py --generate` regenerates everything, and the tools a
contributor meets take several selectors and name their faults. An atom
`match` tests its subject once but is not yet a table (SR-231). The complete
gate passed on the commit that closes this item, with RV64's hardware jobs
suspended.

### R13.73 — Documentation that teaches

Status: complete
Depends on: R13.72

The tour began as "Learn X in Y minutes" and drifted into a design
document. Its preamble was a version history, 153 of its 173 entries
opened by repeating their own heading, design rationale and decision
records sat in the middle of what a newcomer reads first, and nothing
showed a hello world or what replaces `printf`. `docs/from-c.md` opened
with how its fixture is checked, and the library reference and its
pages read as walls of text. This item makes the published documents
teach, and decides nothing about the language: a rule a rewrite would
drop moves to `spec.md` first.

The tour: it opens with a hello world and a formatted line, and says how
to read it; the version history moves to the handoff. Every entry is a
heading that is a title, one sentence saying what the construct is, its
example, why it is that way, and its edge cases last, pointing to
`spec.md` rather than repeating it. Design history, rejected
alternatives and implementation detail leave the entries for `spec.md`'s
register and the library reference. Sections are ordered so that a
reader can write a function before meeting pointers. Every `[NNNN]` keeps
its number, and the tour stays one page.

`docs/from-c.md` leads with the C habits and their Landin forms, and puts
how its fixture is checked at the end; the gaps are a table. The README's
first program uses `else none`. The library reference reads in order as
text (SR-251), and its sections are paragraphs a reader can scan rather
than one paragraph per module. `examples.md` gains the everyday hosted
tasks — reading standard input, listing a directory, running a command,
printing formatted values — and an example that puts a failure into
words, each run by the outside-user lane (SR-51, SR-250).

Exit: an outside reader with no project context writes a small hosted
program from the tour and the examples alone, and what they met is in the
register; `python3 check.py`, the script tests and the tour's layout case
pass.

Done: the tour is a learning tour again. It opens with a hello world, a
formatted line and a complete program that reads a file, says how to read
it and where the reference part begins, and teaches types before control
flow; its entries have titles, examples that declare what they use and
compile, short fine print and no decision numbers, and the generic types it
teaches build no container it cannot build honestly. `docs/from-c.md` leads
with what to write instead of C, and gained callbacks, the byte calls,
reading a line, `assert`, allocators and `defer`; the README leads with
installing, the first program and next steps; `examples.md` prints what
each program computes, everyday tools first, and reports failures in words;
the library reference reads in order as text, links its calls, shows each
module's own runnable example and holds its code to fixtures; the
prototypes and the specification say who they are for. Four rounds of
outside readers wrote programs from the pages alone, and two rounds of
design review shaped the site: headings above body size, a reading measure,
quiet citations, one captioned code panel, wayfinding on phones and in the
library, print and keyboard use. What they met is SR-285 to SR-308 and
SR-310 in the register.

### R13 gate

- The shared freestanding, target-specific freestanding and hosted roots are
  separate. Every shared module checks on every supported target, each
  target-specific module checks only on its declared targets, firmware
  refuses hosted imports by name, and every facility has a consumer.

- Every shared-root module has R13.10's positive per-target compile/link
  evidence and applicable execution and failure checks. Target-specific
  freestanding and hosted availability checks remain separate.

- The library's concepts, names and shipped evidence follow R13.11's
  conventions, and every later facility is held to them.

- A reader with no project context has done a realistic task from the
  published documentation alone, and what they met is in the register.

## R14 — Concurrency

Beyond blocking, by switching stacks rather than rewriting functions; "The
concurrency execution model" below binds this phase.

### R14.10 — Prototype 5

Status: complete
Depends on: none

A concurrent program written as a specification stress test, as the first four
prototypes were: a small network server with two operations in flight, and a
firmware counterpart that has to answer the same request on a single core.
Its findings are recorded as the first four's were.

Exit evidence: `prototype-5` with its findings, checked by `check.py` like the
other four.

Done: `prototype-5-server.md` is a line-protocol server that admits each
connection to a group of two fibres over stacks cut from its own frame,
with a test client that needs the requests to overlap, and a Cortex-M0
counterpart that takes the same two requests on one serial line with a
taker and an answerer fibre and a round of fixed turns written in the
application. One `app/protocol` module serves both. Switching is
cooperative: a fibre gives the core away only inside a call to the provider
that runs it. An application starts fibres only as a group, which it joins
before going on, and hands each an ordinary routine and a state; the
first draft, which started them as C starts threads, is V15, resolved.
The other fourteen findings, V1-V14, are open, each with a proposed
answer, and each item below names the ones it settles. `check.py` reads the
file as it reads the other four, and the site renders it beside them. It
has no derivation yet, so it has no row in the prototype registers.

### R14.20 — Stackful fibres

Status: complete
Depends on: R14.10

A stack switch on every target, specified with a register decision. The caller
supplies each fibre's writable stack backing, directly from a fixed buffer or
through an explicit allocator capability; creating a fibre does not require
an implicit heap allocation. The caller owns that backing while the fibre can
run or resume and reclaims it only after the fibre has finished and no switch
can reach it. Specify the backing's size, alignment, creation-failure and
release rules with the switch interface. This takes on the stackful-fibre
part of R551-35.

Prototype 5's findings were decided before this item began, and it
implements and pins them: D444, `core/fibre`'s switch, the `scheduler` and
`turns` concepts, `whole`, one round of fixed turns and the group an
application starts fibres as; D445, `escaping into`, with the checker and
the tour's [0780]; D446, cooperative switch points, a provider's fibres as
one D227 context and a switch as a full compiler memory boundary; and D447,
the stack-limit check, the stack-depth report, Cortex-M fibres on the
process stack and the debugger's view. D448's single-core answer is the one
this item specifies. D450 makes the switch two compiler builtins and D451
adds `stack_exhausted` to `core/panic`'s kinds. D471 to D473 move the limit
check from the switch into every routine's prologue in a program that
prepares a stack, with the limit carried in the frames a switch saves. D474
refuses a panic handler deeper than the margin that check leaves.

Exit evidence: fibres switching on every target with debugger backtraces
through a switch, and the single-core freestanding answer specified. On the
retained 32 KiB flash, 16 KiB RAM Cortex-M0 profile with its 4 KiB main-stack
reservation, run a stack-switch consumer using fixed caller-supplied backing.
Report its linked flash size, static RAM with fibre buffers identified, the
main-stack reservation, each fibre's backing size and peak simultaneous
backing, plus the total reserved RAM without double counting and the fit
verdict against that profile. A switch that only fits a larger device profile
does not complete this item; the measurement is for this consumer, not a
general bound on stack depth.

Done: `compiler.stack_prepare` and `compiler.stack_switch` run on every
native target, and `core/fibre` builds a group, `whole`, a round of fixed
turns and the blocking host as a scheduler on them. Every routine of a
program that prepares a stack checks its frame against the running
stack's limit, so an overflow traps `stack_exhausted` at the routine that
overflows, and a program with no prepared stack emits the code it did
before. `refine --stack-report` gives each routine's frame and the deepest
stack it can close, naming what opens it. `escaping into` lets a group
keep state its caller lent, and an `any` made in any position from a
parameterized provider now dispatches. A scripted session through a switch
names `landin.stack_switch` and `landin.stack_start` and checks the frames
on each side with GDB on Linux x86-64, arm64 and RV64 and on Cortex-M0, and
with LLDB on Darwin and FreeBSD. On the retained Cortex-M0 profile two
fibres of `core/fibre`'s round, each on 1,472 bytes of module storage, fit
at every profile: 22,492 bytes of flash at none, 7,168 of 16,384 bytes of
RAM reserved with the 4 KiB main stack, a painted peak of 904 bytes per
fibre, and the Cortex-M lane reports the figures and the verdict (D470).

### R14.25 — Run the firmware counterpart

Status: planned
Depends on: R14.20, R13.20

Derive a complete Cortex-M0 program from prototype 5's firmware counterpart.
It presents the same request for two operations in flight as the hosted server
and produces the single-core answer specified in R14.20. Record a trace that
shows the answer and when each operation starts and finishes.

D448 says what "in flight" means on one core and what the trace shows;
D449 how the tick reaches a fibre without read-modify-write.

Exit evidence: the firmware derivative running in the Cortex-M0 emulator lane
in the gate, with its captured trace checked against a repository-owned oracle
for the specified no-concurrency answer and no two operations in flight. A
missing answer, overlap, trap or timeout fails the run.

### R14.30 — A second Io

Status: complete
Depends on: R14.20, R13.33

An event-driven Io that runs fibres over epoll on Linux and kqueue on
Darwin/FreeBSD, through `platform/kqueue`, the module Darwin and FreeBSD
share (D481), and `platform/linux`'s epoll and signalfd wrappers. Its operations are completion-shaped, submitted and then
answered, so that a completion interface, Windows' or Linux's io_uring, can
later implement the same Io; readiness stays below it, in `platform/posix`'s
`poll` and the systems' own modules. Signals reach it as events, through
signalfd on Linux and kqueue on Darwin and FreeBSD, never as handlers that
run Landin code. Windows is outside this item's scope.

It implements D446's list of the Io's entries that may switch, and D449's
wake with a failure for a waiter whose descriptor is shut or closed, signals
as waitable events and the fake network under a scheduler that takes turns.
It supplies `io.programs` as `hosted/blocking` does, starting a child
through `hosted/system` and waiting on its pipes and its end through the
event mechanism (D479).

Exit evidence: prototype 5's derived server running on the hosted targets over
both implementations of Io, unchanged.

Done: `hosted/system` keeps the services that do not wait, and two
providers wait over it: `hosted/blocking`, which blocks the thread, and
`hosted/events`, which runs fibres on a round whose wait is the system's
event mechanism, epoll and a signalfd on Linux and kqueue on Darwin and
FreeBSD, through `platform/linux`'s new wrappers and `platform/kqueue`
(D476-D481). A wait is submitted on the waiting fibre's own stack and
answered by the loop, so a completion interface can implement the same Io
(D485-D488). Signals are events of `core/io/signal`, which only a provider
of turns supplies (D477, D482); a child's pipes and end wait in the
providers (D479), and a closed or shut descriptor wakes its waiters with a
failure. The fake network takes turns and waits for a fake clock's sleepers
(D483, D493), an `any C` is a provider of C (D492), and lowering keeps only
the evidence entries a program selects (D484). Prototype 5's derived server,
`examples/derived_server`, runs from one source as a process of its own
over both providers on every hosted target: one request at a time and
ended by SIGTERM over `hosted/blocking`, two in flight and stopped cleanly
by its signal waiter over `hosted/events` (D489, D490). Off Linux a trap
report writes on a stack of its own, since lazy binding overran a fibre's
(D491).

### R14.40 — Threads and the atomic wrapper

Status: active
Depends on: R14.20

Hosted threads, and the atomic wrapper type over D227's builtins that answers
Cortex-M0's missing read-modify-write explicitly. This takes on R730-21.
A heap that threads share, and a vDSO cache they can read together, come
with them on every hosted system alike,
since one single-threaded heap serves all three (D300). Under `--link=libc`
the C library owns thread creation and thread-local storage, so a thread there is the C library's; a static Linux program owns
both itself.

It holds D446's rule that threads are not a provider of the fibre
concepts, and gives the wrapper D449's single-writer operation on a core
without read-modify-write.

Exit evidence: consumers of both on every applicable target, with failure
oracles. The hosted thread facility implements D227's creation and join
happens-before edges: executable cases publish ordinary data before starting a
worker and observe its ordinary writes after joining it, on each hosted
target, with no other synchronization supplying either edge.

### R14 gate

- Prototype 5's derived server runs on every hosted target over both Io
  implementations, and its firmware counterpart runs on Cortex-M0 with the
  single-core answer checked against its trace oracle.
- R14.20's retained-profile stack-backing and capacity evidence is recorded.
- On every target covered by R14.20, a scripted debugger session switches
  fibres and checks the expected frames in a backtrace through the switch.

## R15 — Windows (deferred)

Windows is not in the current implementation scope. These identities and
original proposals remain for history and possible reconsideration, not as
current implementation commitments. Only an explicit scope decision can
reactivate them. In particular, they do not block R16 or require a Windows
event-driven backend. R14.30 retains epoll on Linux and kqueue on
Darwin/FreeBSD.

### R15.10 — Windows x86-64

Status: blocked
Blocked because: Windows is outside the approved scope until an explicit decision reopens it.
Depends on: R11.10

The Win64 calling convention, COFF objects, the unwind tables Windows requires
of every function that calls, and a hosted layer over the Windows API. Which
assembler and linker is decided here.

Exit evidence: the corpus on GitHub's Windows runners in the gate.

### R15.20 — Windows debugging

Status: blocked
Blocked because: Windows is outside the approved scope until an explicit decision reopens it.
Depends on: R15.10

CodeView debug information in the objects, and PDB files from the linker
rather than written by the compiler.

Exit evidence: scripted debugger sessions on Windows in the gate.

### R15.30 — Windows arm64

Status: blocked
Blocked because: Windows is outside the approved scope until an explicit decision reopens it.
Depends on: R15.20, R11.20

The same on arm64, which reuses the arm64 backend with Windows' variant of
its calling convention.

Exit evidence: the corpus and debugger sessions on GitHub's arm64 Windows
runners in the gate.

### R15 gate

Inactive while Windows is deferred. If an explicit decision restores this
phase, its original proposed gate is corpus and debugger sessions on both
architectures; future scope and exit evidence must be reviewed at that time.

## R16 — Optimization

Measured first, and then only where the measurement says.

### R16.10 — Measure generated code

Status: planned
Depends on: none

Benchmarks with recorded time and size for every supported target, each CPU
feature level of its family, and all nine independent combinations of
`--optimize=none|size|speed` and `--specialize=off|auto|all`, including none/off
and size/auto. Track the matrix in the recurring gate, with a build report
that counts the same things on every backend. Each baseline identifies its
target, selected `--level`, optimization/specialization pair, workload and
measurement runner. This takes on R730-24. A measured code-quality cost
attributable to assembly's fixed memory effect is recorded against SR-09
before any narrower effect is proposed.

Cover every supported family level, including the default and any later-added
levels. Today these are x86-64 v1 through v4, `armv8-a` and `armv8.1-a`, and
`armv6-m`, `armv7-m` and `armv7e-m` where the target family applies. The
measurement runner must support and execute the selected level; lack of
support cannot silently substitute a lower level or skip a measurement.

Exit evidence: record time and size baselines for the complete
target/level/profile matrix on the same workloads. Compare each combination
against its own baseline and fail the gate if either measure regresses beyond
its stated tolerance. Measure the matrix's recurring cost; no cost saving or
existing coverage of this future matrix is claimed.

### R16.20 — Register allocation

Status: planned
Depends on: R16.10

Further allocation for the arm64 backend's stack homes and the remaining
x86-64 and Cortex-M cases, the bounds check an indexed increment keeps, and
the atomic and barrier lowering, which is baseline. Arm64 already reuses
nonoverlapping scalar value homes at `size` and `speed`, and keeps eligible
integer intermediates in saved registers at `speed`. This takes on R551-12.

Exit evidence: measured improvement for affected target/level/profile
combinations against their matching R16.10 baselines, with unchanged
behavior, ABI and debugger evidence. Every supported combination remains
under the same time and size regression gate, including unaffected levels
and profiles.

### R16 gate

- Every supported target, CPU feature level and all nine optimization/
  specialization combinations are measured on the same workloads against
  their own recorded time and size baselines. Either measure exceeding its
  stated tolerance fails; unsupported runners cannot skip or substitute a
  selected level.

## The concurrency execution model

Carried from the first roadmap, because a settled position written nowhere
reads as an open question and gets reopened.

Concurrency is not a property of a function. It is a capability — an Io the
caller hands down, an ordinary parameter like an allocator, commonly minted at
the entry point [1660]. Code using only that Io blocks or does not according to
the provider it was given. The argument list does not prevent a routine from
minting a separate host root [1680]. No keyword, second calling convention or
colored function type is used to say it. The refusal this replaces is recorded
in `tour.md` under WHAT WAS TRIED AND DROPPED.

- **One Io implementation today, and it blocks.** Signatures and `core` are
  concurrency-capable without any scheduler existing. R14.30 adds the second.
- **Stackless coroutines are a non-goal.** Cutting functions into state
  machines is a compiler project of its own, and it puts the property into
  every function type that reaches one — the coloring the ambient environment
  was removed to avoid. This is a refusal, not a park: no trigger reopens it,
  only a decision to reverse it.
- **Stackful fibres are the route, and the backends keep them reachable on
  purpose.** A backend decision that forecloses switching stacks is a defect
  in that backend rather than a trade-off. The conditions are held for other
  reasons already: call-bearing frames retain a frame pointer, the callee-saved
  discipline is explicit, and no capability rides in a reserved register.
  Call-free Cortex-M leaves may omit the pointer because they cannot switch
  stacks. The case to design against is a single-core freestanding target, where the
  honest answer to a request for concurrency is that there is none.

## Successor families

The first roadmap named six families as destinations for what it did not do,
and this one added Usability. They are kept as the owners of register records, not as roadmaps of their
own; a record that an item here takes on says so, and one that none does
waits for its activation.

- **Scale and self-hosting:** separate compilation and interface files,
  caching, cross-language stage transport and the incremental replacement of
  tested Ada stages.
- **Companion tool and ecosystem:** a build tool, package acquisition, version
  solving, manifests, locks, publishing, naming authority and generator
  orchestration. A build description between Zig's build program and a
  makefile was discussed when this roadmap was written and left out of it.
- **Broader standard library:** library facilities beyond what the prototypes
  needed.
- **Competitive optimization:** optimization beyond correct deterministic
  baseline code.
- **Language evolution:** parked constructs, watches and proposals whose
  triggers have not fired.
- **Release readiness:** distribution, production claims and every release or
  version decision.
- **Usability:** what a person meets using Landin from its documentation
  alone: knowledge a newcomer cannot guess, workarounds, refusals that do
  not say what to do, and documentation that disagrees with the tool.
  `AGENTS.md` makes recording it everyone's job.

## Register

What waits for a trigger. A record keeps the identity it was given — R551 and
R730 for the first roadmap's two debt ledgers, a letter and a number for the
review register it inherited, SR for records added since — because the first
roadmap's text refers to them. Merged records are folded into the record they
joined.

A status is `open`, waiting for its activation; `limit`, a measured boundary
that stands until its activation; `watch`, an observation waiting for
evidence; `scheduled` followed by one or more unfinished items that take on
its parts, separated by commas; or `retired`, with the reason it no longer
applies. Remove a scheduled owner when its part is complete. A record stays
scheduled on its other owners until they finish, then leaves the register.

| Record | Family | What stands | Activation | Completion | Status |
| --- | --- | --- | --- | --- | --- |
| R551-07 | Scale and self-hosting | Final linker placement is not preflighted: Linux RIP-relative reach, Darwin's 2 GiB static-image collision and arm64 branch reach. Merged: R730-05, seventeen shared programs exceed the 32 KiB flash, 16 KiB RAM and 4 KiB stack profile in 72 capacity verdicts. | Before general large-image support, or a workload that needs it. | Bounded reach and layout evidence with the native control and its status-42 oracle retained. R12.10 takes R730-05's larger profiles. | open |
| R551-08 | Scale and self-hosting | Compact source or IR can still ask for enormous assembler repetition; small compiler output does not bound assembler memory or object size. | Before admitting larger images or generation policies. | A bounded emission policy tested on tiny shapes, with the forbidden giant-fixture boundary kept. | scheduled R12.10 |
| R551-09 | Competitive optimization | Guarded cleanups can expand quickly despite correct pop-before-run order. | A measured cleanup workload with unacceptable growth. | Selectors, effects and order preserved, with bounded size compared before and after. | open |
| R551-11 | Competitive optimization | Frame and allocation planning is repeated by preflight, emission and debug output. | Profiling justifies sharing the plans. | One immutable plan owning emission and debug locations, with debugger agreement. | open |
| R551-12 | Competitive optimization | An indexed increment can keep an extra bounds check, and Darwin still has stack homes beyond the scalar value reuse and integer register promotion already implemented. Merged: R730-04, atomic and barrier lowering is baseline, not competitive. | Measured code-quality pressure. | Single evaluation, traps, addresses, ABI and debugger evidence preserved under measured improvement. | scheduled R16.20 |
| R551-15 | Scale and self-hosting | Nix provides a development shell and a flake built by hand, not cached derivations or CI. | An explicit decision to revisit Nix CI. | Builders, SDK identity, debugger permissions and cache provenance accounted for. | limit |
| R551-16 | Scale and self-hosting | Large nested stage procedures, duplicate construction helpers and unused interfaces such as `Needs_Source` remain. | Replacing or splitting the affected stage, or a change it obstructs. | Refactoring behind existing seams with strict warnings, removing only demonstrated dead interfaces. | open |
| R551-19 | Release readiness | No mutation coverage of the driver's options, targets other than the default, several editor documents resolved as one module, or emission, linking and running of the mutants that are accepted. The frontend has source-text crash coverage: R10.50's `compiler/tests/fuzz/fuzz.py` drives the sole direct `.ldn` source of each positive, negative, runtime and ABI fixture directory, plus every reproducer, mutated with a fixed seed, through `refine lsp` with rooted imports and an imported-fixture diagnostic check, bounded per response and in memory. C companions are not executed. | Before robustness or production claims. | Fixed seeds, bounded resources, stage and target reach, crash classes and minimal reproducers, for the driver and the backends as the frontend has them. | open |
| R551-20 | Release readiness | Fake-host failure controls do not establish native device, capture or exhaustion failure paths. | Before claiming those native failure guarantees. | Controlled fault injection with cleanup and diagnostic oracles on each host. | open |
| R551-22 | Release readiness | The code face was removed from all history and the acceptance tags re-issued; only the vendored Nunito Sans remains. Its redistribution, which the pages depend on, is not settled. | Before distribution, or a font policy change. | A distribution decision keeping the private-font boundary. | open |
| R551-25 | Language evolution | Source-debug CFI is not a promise of foreign-exception unwinding. | An explicit proposal for runtime foreign unwinding. | Semantic, ABI and failure decisions, then native evidence. | limit |
| R551-26 | Language evolution | LLDB shows C scalar spellings and manual tag and payload selection, with no Landin expression evaluator. Merged: R730-12, Cortex-M0 debugging is lines and functions only. | A concrete debugger-usability proposal. | Truthful types and locations with native sessions for each new promise. | limit |
| R551-27 | Release readiness | Linux driver overrides follow the GNU contract; Darwin emits thin arm64 Mach-O, not universal binaries; no Clang header parsing. | A requested driver or distribution expansion. | Pinned producer and consumer, packaging and identity evidence. | limit |
| R551-28 | Language evolution | No callback-identity counterexample exists, and static rejection of known slice-range endpoints is not a normative requirement. | A valid counterexample or an explicit semantic proposal. | Present-contract defects go to their implementation owner; semantic changes need specification and tests. | watch |
| R551-32 | Scale and self-hosting | Stable separate compilation and interfaces, package identity in interfaces, cross-language stage transport and incremental self-hosting. | An explicit scope decision; planning R8 considered it and left it outside. | Tested seams and complete interface and package identity with whole-program semantics preserved. | open |
| R551-33 | Companion tool and ecosystem | Package acquisition, version solving, manifests, locks, naming authority, deterministic roots, generators and sandboxing; the binding generator's replacement of its four files is not atomic. Merged: R730-08, the RP2040 fixture is a bounded selection and no general SVD generator exists; R730-11, the firmware linker script is fixed. | Before acquisition, general generation or concurrent build consumers are offered. | Declared inputs and outputs, immutable publication, reproducible roots and single-version conflicts. R12.10 takes the SVD and linker halves. | open |
| R551-34 | Broader standard library | Library facilities beyond the prototypes' slices. Merged: R730-02, a reusable cache-maintenance interface for cached profiles (R12 requires platform providers before admission); R730-09, UART configuration beyond one baud rate; R730-21, the atomic wrapper type. | A concrete program needs an omitted facility. | Capability-passed allocation and I/O, constrained-target costs, complete consumers and failure oracles. R14.40 takes the atomic wrapper. | scheduled R13.20, R14.40 |
| R551-35 | Language evolution | The stackful-fibre exploration. | A program needing two operations in flight. | A stackful-fibre tour amendment and register decision; stackless coroutines stay rejected. | retired: R14.20 specifies the switch (D450), makes fibres a group over a scheduler (D444) and teaches them at [1675]; stackless coroutines stay rejected |
| R551-36 | Release readiness | Licensing and distribution, release and version designation, production and operational claims. | Explicit maintainer decisions. | Separate decisions, each with evidence. | open |
| R730-01 | Release readiness | Only emulators have run firmware; nothing is claimed about physical timing, bus, electrical or interrupt-arrival behaviour. | Before any physical-device or production firmware claim. | A pinned board and smoke procedure checked against a device-specific physical oracle, with shared scenario outcomes compared where their premises hold; emulator lanes stay mandatory. | scheduled R12.20 |
| R730-03 | Release readiness | D227's ordering trials and bounded store-buffer models are evidence, not a formal proof; no wait-free or timing bound is claimed. | Before a claim beyond the bounded models, or any timing bound. | A stated proof or checked model agreeing with the native trials. | open |
| R730-06 | Release readiness | Stack paint and SP observation are measurements, not worst-case bounds; 64 spare flash bytes is a fit, not a budget; reset assumes no NMI or fault in its window. | Before a production budget, worst-case stack or fault-tolerant reset claim. | A workload and interrupt model with a checked bound, and reset-window behaviour with executable evidence. | open |
| R730-07 | Broader standard library | Cortex-M0 C source capabilities, `platform/c` and header generation are disabled; 33 shared programs are general-C restrictions there. | A freestanding program that must call or be called from C. | An ILP32 `platform/c`, Cortex-M0 C signatures, generated bindings from a pinned device C header under a checked Cortex-M0 ABI, and executable firmware fixtures using the generated declarations and adapters with failure oracles; the 33 restrictions re-decided. | scheduled R13.20 |
| R730-13 | Release readiness | Source and debug identity selection is matching, not authentication or protection against concurrent replacement. | Before stronger provenance or attestation claims. | An attestation design with verified restore; the seven negative selections stay. | limit |
| R730-17 | Language evolution | A call returning a plain pointer cannot fill a several-atom pointer union through an atom `else`; D235 keeps it refused. | A program that needs that recovery to widen. | D235 amended with a recovery lowering and evidence on every target. | open |
| R730-20 | Language evolution | D237 leaves u128, i128 and f16 out. | A program that needs 128-bit arithmetic or binary16 values. | D237's recorded plan on every target. | open |
| R730-23 | Release readiness | A linked hosted image is not bit-reproducible: the GNU driver writes a random temporary object name, six bytes. | Before a reproducible-distribution claim. | Byte-identical images on both hosted targets, with the assembly-identity check kept. | open |
| R730-24 | Competitive optimization | Build-report counters are filled differently per backend, so a cross-target comparison from them is unsafe. | Before any cross-target code-quality comparison from the report. | Every declared counter filled on every backend, or the report saying which it does not measure. | scheduled R16.10 |
| B3 | Scale and self-hosting | Separate compilation: whole-program checking is done; stable interfaces are R551-32's. | As R551-32. | As R551-32. | open |
| B4 | Companion tool and ecosystem | Package, build and generators beyond the thin pieces the compiler owns; R551-33's. | As R551-33. | As R551-33. | open |
| B5 | Broader standard library | The standard library beyond the sixteen `core` modules; R551-34's. | As R551-34. | As R551-34. | scheduled R13.20, R14.40 |
| B6 | Companion tool and ecosystem | Package naming authority, keeping the project-first override [1480]. | Before acquisition or a naming authority is offered. | A naming policy that keeps the project-first override. | open |
| D6 | Companion tool and ecosystem | One version of a package name per program [1470]; the compiler's first-root rule is done and arranging roots is the tool's. | Before acquisition or root arrangement is offered. | Roots arranged so one version is reachable, a conflict a hard error. | open |
| C1 | Language evolution | Affine values, which would change [0910]'s non-ownership `sink`. Merged: R730-10, the derived driver's device authority, descriptor linearity and stop are manual obligations. | A peripheral or resource program unpleasant without them. | [0910] amended with a register decision answering R730-10's obligations, on every target. | open |
| C2 | Language evolution | Conformances as named values. | Conformance collisions hurting in real libraries. | A register decision weighed against retained position D2, with library consumers. | open |
| C3 | Language evolution | A checkable host-authority boundary for call trees [1680], including whether root minting should be restricted to the entry module. D258 keeps public constructors: provider arguments support substitution for uses of those providers, but do not prove host exclusion. | A trusted-code case needing static host exclusion or reliable provider substitution without auditing its call tree, or a need to run untrusted code. | [1680] amended with a register decision and executable evidence for the chosen boundary, accounting for constructors, foreign calls and freestanding address literals rather than treating entry-module restriction alone as isolation. | open |
| C4 | Language evolution | Generational observers and inferred uniqueness; no trigger was ever given. | None until later evidence supplies one, recorded first. | That trigger recorded, then a design with its own evidence. | open |
| C5 | Language evolution | Structure-of-arrays collections [0620]. | A simulation program needing one field contiguous. | [0620] enabled by amendment and register decision, with executable evidence. | open |
| E1 | Language evolution | Labels, `break with` and `complete` are implemented and none of the four derived programs uses them. | A proposal to remove or reshape them, with evidence beyond non-use. | A tour amendment and register decision. | watch |
| E3 | Language evolution | Two kinds of generated source exist, SVD modules and C bindings; a third starts the review of retained position D3. Generating the compiler's transcription tables from `spec.md` would be a third. | A third kind of generated source. | That review recorded against D3's rationale. | watch |
| SR-01 | Release readiness | The Cortex-M lane pins `arm-none-eabi-gcc` 14.2.1; the same publisher's `arm-eabi-gcc` 16.1.0 builds a valid image, and moving changes every recorded firmware hash and disassembly. | R12's new cores rebaseline the firmware records anyway. | The toolchain moved with every Cortex-M record rebaselined in one change. | scheduled R12.10 |
| SR-04 | Language evolution | D248 keeps assembly operands to integer registers; a float operand is refused by name as transferred here. | A program that needs a float operand, or a target with float registers: R12.30's M4F is the first. | [1630] and D248 amended with the float register class and its clobber set on each target that has one, with executed fixtures. | scheduled R12.30 |
| SR-03 | Language evolution | A module value cannot hold `addr` of storage: [1940]'s known values are numbers, and a static address is a data relocation no backend emits. L0305 refuses it and its note says why; this record is the construct's only owner. | A program needing a static pointer: a vector table it owns, a table of pointers into module storage, or a statically linked structure. | [1940] amended with a register decision, data relocations emitted on every target, and `negative/r491-construction-static-address` turned into executable fixtures. | open |
| SR-10 | Language evolution | D145 refuses a module static image of `any C`: D147's data-pointer/table-pointer pair needs two relocations, beyond SR-03's single static `addr` value. | A program needs a preinitialized module `any C` value, such as a static dispatch registry; take on SR-03's data-address relocation work too if it is still open. | D145 and [1940] amended with a register decision for static construction; an image containing both the data address and the selected flattened-table address emitted on every target, with executable fixtures for a module binding, an aggregate field and a copied image on 32- and 64-bit targets. | open |
| SR-05 | Broader standard library | `core/text` works on `utf8` as a whole but not from inside it. Traversal yields scalars and hides its byte cursor, and no search returns an offset, so zero-copy ranges around a found character cannot be written; D249 makes an index a decoded `u32`, and turning scalars back into text is a hand-written encoder into a caller buffer. | A consumer that splits, searches or builds `utf8`. | A traversal or search yielding byte offsets beside scalars, a scalar encoder, and a builder over a caller buffer that appends scalars and text and finishes as one `utf8` view without revalidating, each with its consumer. | scheduled R13.20 |
| SR-06 | Language evolution | An XMOS xcore.ai target, XS3: hardware threads, channels and ports timed to the cycle, on which XMOS now recommends C over its own concurrent XC. Its compiler is proprietary, but the public XS3 architecture manual gives the instruction encodings, the XE executable format is specified to the byte, XMOS publishes the source of its BinUtils and XGDB, and AXE, an open XS1 emulator, exists unmaintained. Unsettled: the XTC tools licence, whether the published BinUtils and XGDB work without the proprietary tools, and a load and debug path that avoids the undocumented XTAG protocol. | R14's execution model settled, and an xcore.ai board in hand. | A backend emitting XS3 and packaging XE itself or through the published BinUtils, the corpus on an open emulator lane in the gate, threads and channels mapped through R14's model, and a recorded board run; no timing claim rests on an emulator. | open |
| SR-07 | Language evolution | A Microchip dsPIC33A target: a 32-bit signal controller with a DSP engine and double-precision FPU, sold for the motor and power control TI's C29 serves, where the C29's instruction set is under NDA and its tools forbid reverse engineering. The dsPIC33A Programmer's Reference Manual is public, the XC-DSC assembler, linker and compiler are GPL ports of the GNU tools with published source, and every XC licence is free; no LLVM backend reaches it. Its program and data memories are separate, which no Landin target has had. Unsettled: whether the published source builds a toolchain that runs without MPLAB X, an emulator outside MPLAB X's proprietary simulator, and an open debug path through the on-board debugger or a PICkit. | An open emulator or instruction-set simulator for the dsPIC33A, written from the manual or found, and a Curiosity board in hand. | A backend emitting dsPIC33A for the GNU assembler and linker built from the published source, separate program and data memory decided in `spec.md`'s register, the freestanding corpus on that emulator in the gate, and a recorded board run. | open |
| SR-08 | Scale and self-hosting | D247's 16,384-declaration routine bound limits the measured cost of origin tracking, but the reference pass still stores per-declaration derivation bits with quadratic growth. Branches and loops share unchanged facts; the representation within each fact remains dense. The separate 16,384-field struct bound has a different cause. Measured again in R13.61: `scaling.sh`'s locals family peaks in checking, which grows from 61 to 141 MiB and from 0.10 to 0.28 s of processor time between 8,000 and 16,000 locals, so its peak-memory ratio was 2.45 against the 2.5 bound, its 16,000 point unchanged since R13.60. Met again in R13.70: the locals family's frontend grew 2.52 times from 8,000 to 16,000 and failed the gate's scaling job, the reference pass's joins ORing every derivation byte; a join now reads only the bytes between a fact's lowest and highest local, which took the checking stage at 16,000 locals from 0.27 to 0.20 s, but copying and comparing a fact still costs the routine's size. | A real routine needs more than 16,384 declarations, or measured origin storage for a routine within the bound is unacceptable on a supported host. | Replace the reference pass's dense derivation bits with sparse storage, preserve origin and borrow verdicts across branches and loops, and measure storage and scaling on generated routines at and beyond the current bound. Raise or remove the routine bound only to the extent those measurements support, updating D247 and its size-bound test; leave the struct field bound independently justified. | limit |
| SR-09 | Competitive optimization | D248 fixes every assembly block as a read/write, call and trap boundary; no block can promise a narrower memory effect. | R16.10 or later measurements show a material code-quality cost caused by that fixed effect in a concrete assembly workload. | Record the baseline and the attributable cost, then decide whether a narrower effect is warranted against D248's critical-section rationale. If adopted, amend [1630] and D248, preserve the conservative default, and show IR and backend correctness plus measured improvement on the affected targets; otherwise record why the fixed effect stands. | watch |
| SR-11 | Language evolution | [1570] names direct Fortran interop as a candidate, but no Fortran calling convention is specified or scheduled. The enabled foreign boundary is `extern(c)`. | A concrete program needs to call or expose a Fortran procedure whose required signature cannot use the C boundary. | A decision in `spec.md` and an amendment to [1570] define the supported Fortran ABI and type subset; calls and callbacks run against a pinned Fortran producer on every host claimed, with negative cases for unsupported signatures. | open |
| SR-12 | Language evolution | [1570] names direct Swift interop as a candidate, including its separate error channel, but no Swift calling convention is specified or scheduled. The enabled foreign boundary is `extern(c)`. | A concrete program needs direct Swift calls or callbacks, including error transport, that cannot use the C boundary. | A decision in `spec.md` and an amendment to [1570] define the supported Swift ABI, type subset and error mapping; calls, callbacks and failures run against a pinned Swift producer on every host claimed, with negative cases for unsupported signatures. | open |
| SR-33 | Usability | A runtime fixture cannot report a status from inside a panic handler, so the trap dispatch fixture shows the handler saw the right kind and site only by re-entering it on a match and spinning otherwise, which a missing dispatch would also satisfy as a trap. Met in R14.20: `runtime/stack-exhausted-reaches-the-handler` reports its handler's verdict as `main`'s status by having the handler resume the context `main` saved (D462), which works on firmware too but only on targets whose backend emits the stack builtins, and only from a fibre. | The next panic or trap fixture. | A portable way for a handler to report, on firmware too, used to pin dispatch exactly. | open |
| SR-35 | Usability | The mutation campaign's one-report-on-the-line share is 90.5% against a 90% bar. The largest misses are reports one line from the mistake: a deleted `end` or value reported on the next line, and missing tokens the parser meets on the next line, some genuinely ambiguous. | A frontend change that moves the share, or the next work on the parser's recovery. | The share raised with margin, or the bar's meaning restated for the ambiguous cases. | watch |
| SR-46 | Competitive optimization | An immutable module `bool` is loaded from memory rather than folded, so `return when baseline` kept a whole check routine in a baseline image until the check was split per level. An immutable module `usize` is reloaded the same way at `--optimize speed`: `word: usize = sizeof usize` in `core/mem` is read from memory in every loop, and `3 * word` becomes a run-time `mulq`. | A measured image or hot path holding a foldable module constant. | Immutable scalar module values folded at their uses, with an image comparison. | retired: R13.61 folds a read of an immutable module value, `bool` and `usize` among them, and the arithmetic and checks that become constant |
| SR-51 | Usability | `examples.md` shows every hosted item's consumer, everyday tools first since R13.73, but R13.35's, which loads libraries a fixture builds: the outside-user lane links statically and assumes no C compiler, so it cannot run there honestly. | An outside-user lane that links with `--link=libc` and has a C compiler, or a published example of loading that needs neither. | Each hosted item's consumer published in `examples.md` and run by the outside-user lane. | open |
| SR-79 | Usability | A gate's `darwin-host` build failed at the bind with gnatbind's "error: disk full" writing the binder's generated main on a macOS runner guest with 37 GiB free, after three passes of the same job there. GNAT reports any short write as "disk full", so the message sent the investigation to clean disks that were not full; the cause is unknown, and the root runner service's open-file limit of 256 is unconfirmed. `scripts/build.sh` now reports the free space and open-file limit beside the message. | The next "disk full" from a build, read with the space and limit it reports. | The cause named, and either removed from the runner or reported by the build in its own words. | open |
| SR-82 | Broader standard library | `hosted/linux` gives every Linux system call by number with one raw call that takes and returns integers, and typed wrappers only for the calls the library itself uses; a program calling anything else converts its own pointers, flags and structures, and the checker sees none of them. | A consumer that needs an unwrapped call, or a proposal for a complete Linux binding. | A typed wrapper for each call, generated with the numbers or written, with its flags and structures and their layouts checked per architecture. | open |
| SR-86 | Usability | A second `io.terminate_path` into the same scratch silently re-points a path still in use, because a fresh `[]mut` view of the scratch is not an `inout` use of it, so the checker does not see the first path's borrow end. | The next change to `core/io`'s paths or to the borrow rules for `[]mut` views. | Either the second terminate refused while the first path lives, or a path form that cannot alias. | retired: `io.terminate_path` no longer exists, since R13.18 made paths host strings (D299) |
| SR-96 | Broader standard library | `core` has no math functions: `f32` and `f64` have the language's arithmetic and nothing more. The first `core/math` is written in Landin, so its results are the same on every target, with `sqrt` and `fma` as instructions where IEEE makes them exact and the other functions ported from a permissively licensed implementation, musl's and FreeBSD's msun or CORE-MATH, and tested against MPFR's values; it is known to need tuning for speed and accuracy after that. | The first consumer that needs a math function, or a numeric workload. | `core/math` with its functions' accuracy stated and pinned, and the tuning left measured rather than assumed. | open |
| SR-97 | Broader standard library | Floating-point values are neither written as text nor parsed: R13.19's formatting covers integers. Writing the shortest text that reads back exactly, and parsing correctly rounded, is real work and costs flash on Cortex-M0. The Benchmark Game's n-body and spectral-norm print nine decimal places and k-nucleotide three, which is fixed-precision writing, a different and smaller algorithm than the shortest round trip. | The first consumer that writes or reads a floating-point value, or `core/math`. | Shortest round-trip writing, correctly rounded fixed-precision writing and correctly rounded parsing, with their size on the Cortex-M0 profiles measured. | open |
| SR-98 | Broader standard library | There is no locale or Unicode beyond `utf8`'s validation and traversal. Done properly, a locale is an explicit value named by a BCP 47 identifier, never global state, with the host reporting the user's; its data is generated from a pinned CLDR release into modules a program uses only in part, as ICU4X does; and the work comes in phases: Unicode properties from the character database, case mapping, normalization and segmentation, then numbers and dates by locale, collation, and time zones from the IANA database, read from the host or carried. | The first consumer that formats for a person's locale, or a time zone. | The first phase's data generated from a pinned release with a checked generator, and a consumer formatting in two locales. | open |
| SR-99 | Broader standard library | No library resolves a host name. `getaddrinfo` is a C library service, not a system call: glibc reads `nsswitch.conf`, `hosts` and `resolv.conf` and may load NSS modules, Darwin asks its resolver daemon, and FreeBSD's C library resolves itself. A resolver library uses the system's where it is authoritative, the C library on Darwin and FreeBSD, and on a static Linux program its own, reading `/etc/hosts` and `/etc/resolv.conf` and speaking DNS over UDP and TCP, with configured NSS modules needing `--link=libc`. | The first consumer that connects by name, after R13.33. | The resolver on every hosted target with failure oracles: an unknown name, a name only `/etc/hosts` knows, and a server that does not answer. | open |
| SR-100 | Broader standard library | There is no regular-expression library. It is its own library, outside the hosted layers: linear-time automata without backreferences, so no pattern can make it run away, compiled when the program runs with its allocator passed, and freestanding. | The first consumer that matches a pattern. | The library with its linear time pinned on adversarial patterns, on a hosted target and Cortex-M0. | open |
| SR-101 | Broader standard library | Nothing loads self-contained code into a process: freestanding position-independent C, built `-ffreestanding -nostdlib -fPIC`, or Landin with C-ABI entry points, whose imports the host provides. A loader would have a format-neutral core that maps, relocates, binds each import to a function the host exports, runs initializers and finds exports, with ELF first, then Mach-O, registering a file's signature as Darwin's own loader does, and PE; it works whether or not the host links a C library, and needs no C library in the loaded code. Code that uses a statically embedded C library's process state, musl's thread block among it, is outside it. `refine` would also need to emit a self-contained shared object with C-ABI exports. | A consumer that loads plugins without the system's libraries. | The loader and the driver output on Linux, FreeBSD and Darwin, with failure oracles: an unknown relocation, an import the host does not provide, and an unsigned object on Darwin. | open |
| SR-110 | Usability | A helper returning a memory world over module-level buffers is refused with L0316 (D222), and its note, "pass each alternative as an explicit source", cannot apply to static storage, so a fixture repeats the construction three times instead. | The next change to L0316's note or to static origins. | A note that fits static sources, or the helper admitted. | retired: the note fits static storage after all: a helper taking the module buffers as `[]mut u8` parameters, `-> (host: io.memory from state, output, errors)`, checks clean, and D222 rightly refuses writable module buffers hidden behind `from state` alone |
| SR-120 | Competitive optimization | A static Linux program spawns a child with a `clone` that shares nothing, a `fork` that copies the parent's page tables, because `vfork` or `CLONE_VM` needs a routine on the parent's stack that Landin cannot express; a large parent pays for every spawn. | A consumer spawning from a large process, or a measurement. | A spawn that does not copy the parent, measured against `fork`. | open |
| SR-121 | Broader standard library | Darwin has no `pipe2`, so `posix.pipe` sets close-on-exec with `fcntl` after `pipe`, and a thread spawning in between leaks both ends into its child. Darwin's sockets have the same window since R13.33: `fcntl` follows `socket` and `accept`. | Threads, R14.40. | Pipes and spawning made safe beside threads on Darwin, with a fixture. | retired: Darwin's `spawn` asks for POSIX_SPAWN_CLOEXEC_DEFAULT, so no descriptor it does not give the child reaches a program `platform/posix` starts however and whenever another thread made it, pipes and sockets alike, which `runtime/thread-spawn-leaks-no-descriptor` pins on every hosted target with four pipes made with no close-on-exec flag at all (D503); the window is left only to a C library's own `exec`, which is the C code's |
| SR-122 | Release readiness | Every gate job downloads `actions/checkout` from GitHub, and in three consecutive R13.31 runs GitHub answered some of those downloads with 429 Too Many Requests after three attempts, failing `cortex-m` or a FreeBSD emission job before it ran anything; a failed emission job also skips every FreeBSD execution job, so a whole platform went untested and each run had to be repeated. | The next gate run lost to it, or a change to the runners. | The self-hosted runners serving actions from a local cache, or the workflow retrying a rate-limited download, so a gate verdict no longer depends on GitHub's download limit. | retired: measured again on the GitHub-hosted runners from 2026-10-16T14:57Z to 2026-10-17T20:03Z, 56 runs, 999 job logs and 1,861 action downloads, with no 429 and no retried download; the 429s came from the registered runners, whose jobs shared their hosts' addresses. Reopen on the next gate job lost to a rate-limited download |
| SR-127 | Competitive optimization | The x86-64 backend emits `mfence` before and after every atomic operation whatever its ordering, so a relaxed atomic cost about 50 ns more a clock read than a plain word, and the vDSO cache stays a plain word. | Threads, R14.40, or the optimization phase. | Fences chosen by ordering, measured. | open |
| SR-129 | Broader standard library | No fixture interrupts a sleep with a signal, so the hosted sleep's rule that EINTR means sleeping on for what is left holds only by construction. | Signals as events, R14.30. | A fixture delivering a signal during a sleep. | open |
| SR-133 | Broader standard library | `io.connect` has no limit of its own, since a bounded connect needs a non-blocking one, and an address has no IPv6 zone, so a link-local address cannot be reached. | The event-driven Io, R14.30, or a consumer reaching a link-local peer. | A bounded connect and zoned addresses, with fixtures. | open |
| SR-135 | Competitive optimization | `hosted/heap` reads and writes each block's header a byte at a time, because a header may be misaligned, and an allocation-bound program pays for it: a profile of the Benchmark Game's binary-trees at depth 15 puts `load_word` at 20 per cent and `store_word` at 18, `class_of` at 8, and the program's own routines under 7; depth 21 takes 4 minutes 4 seconds at `--optimize speed`, 655 MB at its peak. A `core/region` over the heap adds a 16-byte ledger record to every allocation, and freeing each node directly instead was 29 per cent faster at depth 16. Hand-measured on 2026-10-15: header words read and written through `ptr usize`, with the header pair placed word-aligned below the block and the `unit - 1` slack dropped when the unit divides 16, took depth 16 from 5.67 to 3.66 seconds and a node's slot from 64 bytes to 32, so depth 21's peak fell from 655 MB to 385 MB, against C's 257; the misalignment the heap's comment gives as the reason is its own placement, not a language constraint. The region ledger maps and unmaps every block over 4 KiB as it doubles, 14,500 of each at depth 16, and chaining fixed 4 KiB ledger blocks took 3.66 seconds to 2.89. | The next `hosted/heap` change, or a measured allocation-bound workload. | Headers read and written as words, with binary-trees measured before and after. | retired: R13.60 reads and writes the headers as aligned words, and binary-trees was measured before and after |
| SR-146 | Competitive optimization | The x86-64 backend aligns no routine entry, so code shrinking anywhere moves the hot routines after it: with `store_word`, `load_word` and `class_of` byte-identical, binary-trees at `--optimize size` ran 4 per cent slower, 5.71 to 5.96 seconds at depth 16, reproducibly, only because earlier copies got shorter. A time baseline therefore moves by a few per cent with unrelated changes. Met again in R13.61, where it cost reverse-complement 22%: larger routines put its hot loop and two callees 4 KB apart, contending for Zen 2's decoded-instruction cache; and copying an unchanged executable moved a timing by up to 50% with where its code landed in physical memory, so one executable's time is no baseline. | R16.10, whose time tolerances meet the same noise. | Routine entries aligned at `speed`, or the baselines' tolerance justified against layout noise measured on the same workloads. | retired: R13.61 starts every routine on a 64-byte boundary at speed and aligns a loop head reached only by a jump to 32 bytes, and reverse-complement runs in 0.78 seconds rather than 1.00; baselines still need several fresh copies of each executable, which R16.10 measures |
| SR-154 | Competitive optimization | Scalar replacement of slices and small structs, written and verified on the local branch `perf3-sroa` (an IR pass before simplification, `DW_OP_piece` locations, a verifier rule and a fixture), saved under a quarter of a per cent of the five Benchmark Game ports' instructions on top of R13.60's allocators and cost about 17 per cent of compile time at `--optimize speed`, so it was left out; a loop narrowing a local slice and updating a local struct saved 14 per cent of its instructions with it. | A measured workload whose hot loop keeps a local slice or small struct, or inlining exposing caller aggregates. | The pass merged with that workload measured before and after, and its verification shared with simplification's. | retired: R13.61 splits slices and small structs inside simplification's own verification, and the lexer runs 18 per cent faster with it |
| SR-156 | Scale and self-hosting | Every routine of every imported module is lowered, simplified, emitted and assembled whether or not the program can call it: lowering prunes unused module data but counts a routine's body as a use "whether or not that routine is itself used". A ten-line hello-world over `core/io` emits 546 routines, 69,178 lines of assembly, among them `network_listen` and the memory world's `scripted_fill`, of which `--gc-sections` keeps 34 in a 9.6 KB executable. Lowering, emission and the assembler take about 0.8 s of its 1.16 s release compile at `--optimize speed`, which is why every Benchmark Game port costs about 1.2 s however small it is, against 0.09 s for C and 0.23 s for Rust. | The next compile-time item, or R16.10's benchmarks. | Routines reachable from `main` (calls, evidence tables, routine values, link symbols, placements and `assembler.block` text) the only ones lowered, with hello-world's compile measured before and after. | retired: R13.60 lowers only the routines a program can reach, and hello-world emits 64 routines rather than 546 and compiles in 0.64 seconds rather than 1.18 |
| SR-157 | Scale and self-hosting | About a fifth of a release compile is GNAT runtime work rather than compiler work: a `perf` profile of hello-world's compile puts 14% in abort deferral and exception-state lookups around controlled container references, 5% in `Ada.Tags` external-tag hashing from the ten generic container instances that `Landin.Stages.Checking.References` and `.Flow` declare inside `Check_Function` and so elaborate on every routine they check, and 12% in `memmove`, a third of it from the IR verifier. | The next compile-time item. | Container instances at library level and element access that elaborates no controlled reference on the hot paths, with the profile measured before and after. | retired: R13.60 reads tables through `Element` and elaborates the checker's container instances once, and hello-world compiles in 0.63 seconds rather than 1.24 with byte-identical assembly |
| SR-167 | Usability | `refine check` refuses `--link`, so `compiler.c_runtime` is false when checking on Linux and a program that asserts it cannot be checked; `compile --dry-run --link=libc` is the route nothing names. | The next driver item or change to `compiler.c_runtime`. | `check` taking `--link`, or its refusal naming the dry run. | retired: R13.71 gave `check` `--link`, so a program asserting `compiler.c_runtime` checks as it compiles |
| SR-179 | Release readiness | The debug and release `refine` built from one tree emit different assembly at `--optimize none` for `cortex-m/cases/utf8-ordinal-out-of-range-traps`, on every target: `subq $720` against `subq $736` on x86-64. Each build is deterministic alone, and the determinism manifests compare debug compilers only, so nothing catches it. Met in R13.61. | Now: the release compiler is what users run. | The two builds emitting identical bytes for the corpus, held by a check. | retired: R13.61 sequences the emissions Ada left unordered in `Lower_Utf8_Index`, and the `build-modes` gate jobs hold the two builds to the same bytes over the corpus |
| SR-195 | Release readiness | The Cortex-M shared-GDB session failed twice in about 2,800 sessions on a loaded host with "Remote replied unexpectedly to 'vMustReplyEmpty': vCont;c;C;s;S" and passed when rerun. Met again in R13.72: one backend-corpus session failed the same way while other streams ran QEMU on the host, and passed when rerun. | Its next failure in a gate run. | The cause named and removed, or the session retried with the reason. | watch |
| SR-196 | Language evolution | Under D145 a closed program refuses an erased call with L0342 when no conformance can answer it, although no such value can exist; the refusal names D145 and no remedy. It kept the arena in `core/mem` in R13.70: as its own module, every program importing `core/text` but no allocator would be refused through the growing builder. | The arena split, or the next change to D145. | D145 amended so an erased call no value can reach is not refused, with the arena moved and fixtures, or the refusal naming its remedy. | retired: D377 amended D145 so an erased call no value can reach traps instead of being refused, and the arena is `core/arena` |
| SR-225 | Usability | Under Ubuntu 24.04's `qemu-user`, 8.2.2, every `linux-rv64` program that sets a signal disposition dies of SIGSEGV before writing anything, because that QEMU writes a 32-byte riscv64 `sigaction` over Linux's 24-byte record; the R13.70 gate reported about 240 runs as "the program returned a status" with empty output, nothing naming the emulator, and the cause was found only in QEMU's source. The gate now runs the pinned QEMU. | The next change to the cross-lane runner or `--runner`. | The harness probing the runner's version, or this signal record, and refusing a known-bad emulator with the reason. | retired: R13.71 probes the runner's emulator before a cross lane and refuses a known-bad one by name, held by `fixture execution/a known-bad runner is refused` |
| SR-226 | Usability | `refine -o x.s main.ldn` with no command is refused with "-o requires its own command", which does not name `compile` as the command it needs. Met in R13.70 checking the Cortex-M probes. | The next command-line item. | The refusal naming `compile`, or `-o` taking it as given. | retired: R13.71 refuses `-o` before its command as "an option of compile; name the command first: refine compile -o …" |
| SR-227 | Usability | `Landin.Driver.Usage` repeats the command catalogue by hand, and the driver and the catalogue check option combinations each with messages of their own, so every command-line contract change edits both and can leave them disagreeing. | The next command-line item. | Usage and option combinations derived from the one catalogue. | open |
| SR-231 | Competitive optimization | An atom `match` re-tests its subject's set at every arm, so `failure.words`'s 32 arms cost about 6.3 KiB of Cortex-M0 code at size/auto, about 200 bytes an arm. R13.72 tests the subject once, through a sealed slot the backends do not revalidate, which took `failure.words` on Cortex-M0 at size/auto from 6,336 to 3,552 bytes; the arms remain a compare-and-jump chain of about 110 bytes each, because a table needs a multiway IR terminator. | The next Cortex-M code-size item. | A multiway IR terminator and an atom `match` lowered through it as a table or jump, with the image measured. | open |
| SR-236 | Release readiness | `nix build .#refine`, the documented default, failed from 2026-10-08 until R13.71 with "build/nix/release/generated is not a valid directory", because nothing in CI builds the flake. | Nix CI, or the next flake change. | The flake's packages built by a job, or by the flake change's own check. | open |
| SR-247 | Usability | In the language server, hover over an `offsetof` expression shows `usize` but hover over its field name shows nothing. | The next server item. | The field's hover and definition through `offsetof`. | open |
| R551-13 | Scale and self-hosting | Workload scheduling and artifact reuse for the exact-revision acceptance. | — | — | retired: the acceptance was removed |
| R551-14 | Scale and self-hosting | Interrupted Darwin acceptance could not resume. | — | — | retired: the acceptance was removed |
| R551-21 | Release readiness | The original R1 to R3 acceptance bundles are unrecoverable. | — | — | retired: nothing accepts revisions, and no claim rests on them |
| R551-23 | Release readiness | Native acceptance evidence had no backup, expiry or attestation. | — | — | retired: nothing produces native evidence now. The Linux and Darwin bundles of the last approval before 0.2.0, `ci/accepted/57d1c76a`, remain on the maintainer's Mac, and on 2026-09-23 their records and source archive matched that tag's hashes; they have no backup, and no claim rests on them. R730-13 stands on its own |
| R551-24 | Release readiness | Two-domain publication was not atomic. | — | — | retired: `pages.yml` is the one publisher |
| R551-06 | Scale and self-hosting | Flow snapshots, declaration-origin matrices, folding and dependency walks and IR scratch arrays have storage and stack costs that grow with input size. | — | — | retired: R8.20 bounded a routine's declarations and a struct's fields (D247, L0325), measured every stage's storage, and made the remaining declaration-origin facts shared between branches; the identified whole-unit IR optimization scratch was subsequently moved off the stack. Automatic per-routine IR-value arrays remain outside L0325's bounds; SR-08 owns the deferred sparse origin representation |
| R551-10 | Competitive optimization | Atom and symbol allocation and imported-module lookup repeat identity scans; simplification keeps size-dependent scratch work. | — | — | retired: R8.20 keyed atom codes, linker spellings, machine-body sharing and imported modules, and simplification forgets only what it stored |
| SR-02 | Scale and self-hosting | The corpus at one worker measured 4,523 s on CI against 3,592 s before the parallelism change; single shared-hardware samples cannot tell variance from a regression. | — | — | retired: three repeated runs on one host put the corpus at one worker at 5,599 to 5,654 seconds before the parallelism change and 5,657 to 5,713 after it, a one per cent cost, and R8.20's tree runs it in 1,400 to 1,436 |
| SR-253 | Usability | `scripts/tests/test_build_inventory.py` cuts `build.sh` apart at fixed lines of its text, so a harmless edit to `build.sh` fails at import with only "substring not found". Met changing the build scripts in R13.72. | The next change to `build.sh`'s structure. | The test reading what it checks through an interface, or failing with what it looked for. | open |
| SR-254 | Usability | `check.py` has no `--help`; its flags, `--generate` among them, are learnt from `main()`. Met in R13.72. | The next change to `check.py`'s command line. | A usage line listing every flag. | open |
| SR-255 | Usability | `check.py` and its controls leave files open, and hundreds of `ResourceWarning` lines bury real failures in `scripts/script_tests.py`'s output. Met in R13.72. | The next change to `check.py`'s file reading. | No resource warnings in a full run. | open |
| SR-256 | Usability | `scripts/script_tests.py` takes only a directory, so one module cannot be run through it. Met in R13.72. | The next change to `script_tests.py`. | Named modules selectable. | open |
| SR-257 | Usability | `scripts/quality.sh` prints its whole 44 MB measurement record to standard output as well as writing it. Met in R13.72. | The next change to `compiler/tests/quality/check.py`. | A summary on standard output and the record in its file. | open |
| SR-258 | Usability | `scripts/scaling.py`'s declarations column counts the platform library's roughly 616 declarations, so the fields family reads 619 at every size, unlike its docstring. Met in R13.72. | The next change to `scripts/scaling.py`. | The column counting the generated program, or labelled for what it counts. | open |
| SR-259 | Usability | The pinned `tree-sitter parse --rebuild` silently keeps the cached parser when no C compiler works, and a bare `tree-sitter` run warns "no parser directories" on every invocation. Met in R13.72. | The next tree-sitter pin change. | A refusal when the parser cannot be rebuilt, and the warning explained or silenced in `highlight/README.md`. | open |
| SR-260 | Usability | Inside `nix develop` every short command is buried under "Git tree is dirty" and, with several builds running, "SQLite eval-cache is busy". Met running R13.72's streams. | The next change to `flake.nix` or `docs/environments.md`. | The shell's output limited to what a command prints, or the messages explained. | open |
| SR-261 | Usability | L0304, like every refusal of its kind, has two fixed notes, the tour paragraph and the standing, so the catalogue cannot carry a route as a note and every route is written into the message. Met writing the generic literal route in R13.72. | The next diagnostics item touching the catalogue's note counts. | A route note available to such refusals, or the message form recorded as the way. | open |
| SR-262 | Usability | L0342's list of concepts uses bare names, `formattable`, not the spelling a program writes, `text.formattable`, because the checker's spelling has no module-qualified concept text. Met in R13.72. | The next change to type spelling. | Concepts spelled as the program would write them. | open |
| SR-263 | Usability | A grammar change cannot pass `highlight/test.sh --integration` in the commit that makes it, because the editors pin the grammar by commit; it needs a second commit, made with `highlight/grammar_pin.py`, and nothing says so before the first fails. Met adding `ptr (sink l)` in R13.72. | The next grammar change. | The two-commit step stated where a grammar change is described, or a pin that needs no second commit. | open |
| SR-264 | Usability | A `match` arm with two statements and no `begin … end` is refused with "a match arm puts `:` after its case" at the second statement's `=`, which does not name `begin … end`. Met writing R13.72's fixtures. | The next parser-diagnostics item. | The refusal naming the block form, with a fixture. | open |
| SR-265 | Usability | `refine fmt` writes `ptr (p):` and `_ (rest):` with a space but `red(shade):` without one. Met in R13.72. | The next formatter item. | One spacing for every arm binding, or the difference stated in `docs/format.md`. | open |
| SR-266 | Usability | An internal compiler defect reported as "failed precondition from landin-syntax.ads:1393" names the specification's line, not the caller, and finding the cause took `gdb` with `catch assert`, which nothing documents. Met in R13.72. | The next driver or diagnostics item. | The report naming the failing caller, or the debugging route documented. | open |
| SR-267 | Language evolution | A library helper's trap reports the helper's site, not its caller's, so a `require(condition)` helper cannot say where the contract failed. Met deciding SR-31 in R13.72. | The first library contract helper. | A caller-site form, such as a `caller` argument to `compiler.unreachable`, decided with fixtures. | open |
| SR-268 | Usability | The Cortex-M lanes' locked tools are Debian binaries, so on NixOS they run only under `steam-run`, with output and `TMPDIR` under `$HOME`; `environments/cortex-m/README.md` and the lanes' refusals say neither. Met in R13.72. Met again in R13.73: `nix develop` provides no `arm-none-eabi-gcc`, so `refine compile --target=cortex-m0` refuses with L0500 in the documented shell. Met again in R14.20, running the stack switch's Cortex-M0 corpus and firmware cases. | The next change to `environments/cortex-m/setup.py` or the shell. | The README and the refusal naming the route. | open |
| SR-269 | Usability | The x86 optimization suite's failures print one sentence, not the routine they judged, and expect exact labels and registers, so moving it onto the pipeline meant compiling each source by hand with `--emit=asm`. Met in R13.72. | The next change to that suite. | A failure showing the assembly it judged. | open |
| SR-270 | Usability | `environments/cortex-m/run.py` stops at its first failing lane, so one transient GDB error skipped firmware, freestanding, devices, driver and evidence, and no selector runs only the rest. Met in R13.72. | The next change to the Cortex-M lane runner. | Every lane run and reported, or a lane selector. | open |
| SR-271 | Usability | `flake.nix` says the shell's `gdb` is for `scripts/debug.sh`, but the pinned GNAT's `gdb`, which has no Python, comes first on `PATH`. Met in R13.72. | The next change to the dev shell or `debug.sh`. | The `gdb` the shell documents first on `PATH`, or the documentation corrected. | open |
| SR-272 | Usability | `scripts/build.sh --help` starts a build instead of printing its usage, unlike `dev-test.sh --help` since R13.72. Met in R13.72. | The next change to the build scripts. | Usage printed without a build. | open |
| SR-273 | Usability | `[]` as an `else` handler's value is refused with L0102 "an expression belongs here", though `x = []` is accepted. Met writing `core-vec-bytes` in R13.72. | The next parser-refusal item. | The empty slice admitted there, or a refusal naming the route. | open |
| SR-274 | Usability | A Cortex-M stack-guard overflow is reported as "gdb-backend failed" with a bare `AssertionError`, where R13.72 names a HardFault's address. Met in R13.72. | The next change to `environments/cortex-m`. | The overflow named with its routine and the stack in use. | open |
| SR-275 | Competitive optimization | A `list` grows by allocate and copy (D356) while the text builder grows by `resize`, so reading 250 MB into a byte list takes 0.40 s against the builder's 0.23 s, and reverse-complement stays on the builder; growing lists through `resize` rewrites the fixtures that pin allocator calls and overflowed a Cortex-M image when tried. | The next `core/mem` change, or R16.10. | Lists grown through `resize` where a provider has it, measured, with the counter fixtures re-decided. | open |
| SR-276 | Usability | `bindings/README.md` says the development shell provides the pinned Clang, but it provides nixpkgs' 19.1.7, not the gate's 19.1.1. Met in R13.72. | The next change to the bindings or the shell. | The README saying which Clang each runs, or the shell carrying the pinned one. | open |
| SR-277 | Usability | The binding generator still types a pointer to an ordinary `layout(c)` record `ptr u8`, while packed and flexible records get typed pointers since R13.72. Met in R13.72. | The next consumer of a generated record pointer. | Typed pointers for every generated record, with the bindings fixtures. | open |
| SR-278 | Usability | `dev-test.sh --record=` takes one fixture a run, each paying the build check and harness start, so re-recording about 85 reports took a long loop. Met in R13.72. | The next change to the recording selectors. | Several records in one run. | open |
| SR-279 | Usability | `f(1)(a: 2)` is L0103 "an expression belongs here" because `f(1)` was read as a type application in a written conversion, which the report does not say; it was found only under a debugger. Met in R13.72. | The next change to written conversions. | The refusal saying what the first application was read as. | open |
| SR-280 | Usability | The stream brief's patch command, `git add -N . && git diff --binary`, silently drops staged changes, so three fixtures one stream removed with `git rm` were missing from its patch and failed the merged tree. Met integrating R13.72. | The next multi-stream item. | `docs/process.md` naming `git diff HEAD --binary`, or a patch check that lists staged changes. | open |
| SR-281 | Usability | A stale `refine` in a sibling checkout is easy to pick up and nothing says a binary predates its checkout: a two-week-old release compiler's reasonless "cannot write" was taken for a current formatter defect. Met in R13.72. | The next item touching `refine version` or the build scripts. | A binary older than its checkout's sources said so, or `refine version` naming the revision it was built from beside the checkout's. | open |
| SR-282 | Usability | No local step holds a change to the build-modes comparison or `scripts/scaling.sh`, and both found defects only after R13.72's streams were merged: an evaluation-order difference between debug and release lowering, and quadratic symbol naming. Met integrating R13.72. | The next change to `docs/process.md`'s checklist. | The checklist naming both, or a wrapper that runs them. | open |
| SR-283 | Release readiness | Ada leaves the order of a call's actuals open, so two `IR.Emit_*` calls as actuals of one call emit in different orders at -O0 and -O2, and only the build-modes comparison notices. Met integrating R13.72. | The next lowering item. | A check refusing side-effecting IR emissions as sibling actuals, or the rule stated in `compiler/ada/README.md`. | open |
| SR-284 | Usability | A documents-only commit that closes an item after its branch's full gate still costs a full run, because the explanatory exception takes its base only from a main run; `docs/process.md` now says to close an item before its gate. A rule letting such a commit take its base from any complete successful push run, branch or main, would be as trustworthy as identical-tree reuse, since the tree key covers the workflows and pins. Met in R13.72. | A maintainer decision on the gate's reuse rules. | The rule adopted in `scripts/gate_inputs.py` and AGENTS.md, or declined with its reason. | open |
| SR-285 | Broader standard library | A `{}` placeholder takes no width, padding or radix, so C's `printf("%5u")` is five builder calls (`docs/from-c.md`'s `printf` entry), where Rust writes `{:5}`. Met in R13.73. | The next change to `core/text`'s formatting. | Rust's format specification studied and the parts that suit a template checked when it runs ported, `{:5}`, `{:<5}`, `{:05}` and `{:x}` among them, or each declined with its reason. | open |
| SR-286 | Usability | A call that can fail, written as a routine's last line, is read as the body's value: the first refusal is L0301, a type mismatch, and L0329's "use `try` or `else`" comes second. Met in R13.73. | The next change to L0329 or to result checking. | L0329 reported first, or L0301 naming the unhandled failure. | open |
| SR-287 | Usability | In `if c then a() else b() end if` the `else` belongs to the `if`, and a call's own `else` inside an arm needs parentheses; the tour needs a paragraph to say so, and nothing warns a reader who meant the call's. Met in R13.73. | The next change to call-site `else` parsing. | A warning or a note when an arm's last call can fail and the `if`'s `else` follows it. | open |
| SR-288 | Usability | A C program that owns `main` must call `_landin_host_initialize_arguments` before `system.new()`, or a use of the arguments traps; the trap does not name the call. Met in R13.73. | The next change to `hosted/system` or its traps. | The trap naming the initializer, with `docs/from-c.md` showing the call. | open |
| SR-289 | Usability | A module value may read a compiler fact (D437) but not a declared option, so `x: bool = compiler.os == linux` is accepted and `x: bool = log_level > 1` is L0201, though both are fixed when compiling. Met in R13.73. | The next configuration item. | Options readable where facts are, or L0201 naming `fixed if` as the route. | open |
| SR-290 | Usability | Printing one formatted line takes three lines of setup first, `system.new()`, `io.buffered_over` over a buffer and `defer io.flush(out) else none`, and an unbuffered `io.write` formats nothing; every example on the examples page repeats them. Met in R13.73. | The next change to `core/io`'s writers. | A formatted write straight to a file through a small buffer of its own, or the three lines kept with the reason recorded. | open |
| SR-291 | Usability | `check.py`'s named-file check reads a file name inside a program listing, so an example that opens a missing settings file named with a `.txt` ending is refused as naming a file not in the repository, and the example had to end its name in `.conf`; this row could not spell the name either. Met in R13.73. Met again in R13.73's third round, in a sample command in `docs/library.md` and in example prose and code comments, each renamed to `.conf` or `.log`. | The next change to `check.py`'s named-file check. | Fenced code exempt from the check. | open |
| SR-292 | Usability | A second statement indented under a `match` arm is refused with L0103 "a match arm puts `:` after its case", pointing at the statement's `=`, and `refine explain L0103` covers other mistakes; nothing says that an arm runs one statement or what wraps several. Met in R13.73's outside reviews. | The next change to match-arm parsing or L0103. | The refusal naming the arm's one statement and the form that holds several. | open |
| SR-293 | Usability | `io.format(out, "{}", [any(addr y)])` with an `f64` is L0318 "this concrete type has no conformance to `formattable`", which does not name `f64`, and its second label points into the library's own `core/io/buffered.ldn`. Met in R13.73's outside reviews. | The next change to L0318. | The refusal naming the concrete type, with the label at the caller's own source. | open |
| SR-294 | Release readiness | The latest release, 0.2.7, ships `refine` without its library, so a newcomer who installs the archive, or `nix profile install` of `#refine-bin` which fetches it, cannot compile hello world: `import core/io` has nowhere to come from. The README now warns above the archive route. Met in R13.73's outside reviews. | The next release. | A released archive holding `lib/landin`, with the README's warning removed. | open |
| SR-295 | Usability | `./scripts/build.sh` builds the debug compiler by default, into `compiler/ada/build/<host tag>/debug/bin/refine`, and a reader building from source to use `refine` finds the release mode only in `scripts/env.sh`'s `LANDIN_BUILD_MODE`. Met in R13.73. | The next change to the build scripts or the README's install route. | The README's source route naming the release build and where `refine` lands, or a `--release` option. | open |
| SR-296 | Usability | Refusal notes cite decision numbers, as L0103's "D77, D405: an arm is its case…", which a reader cannot follow from the message and which the tour no longer uses. Met in R13.73. | The next pass over the diagnostic catalogue. | Notes citing the tour's or spec's paragraph instead, or none. | open |
| SR-297 | Usability | A generic routine nothing calls is not checked for L0315: a live `vec.at` view held across `vec.push` in an uncalled `(provider: type is mem.allocator, …)` routine checked clean until a concrete caller was added, though the tour says a template is checked even if nothing applies it. Met in R13.73. | The next change to generic checking or the borrow check. | The template checked, or the tour's claim narrowed to what is checked. | open |
| SR-298 | Usability | A trap's panic site is resolved to a source line by `scripts/source-location.py`, which exists only in the source repository, so a user of an installed `refine` cannot resolve one. Met in R13.73. | The next change to trap reporting or `refine`'s commands. | A `refine` command that resolves a site, or the report carrying the line. | open |
| SR-299 | Usability | A loop that only repeats cannot say so: `for _ in 0..<3 do` is L0103 "a for loop names its element binding", so a counter nobody reads is named and then thrown away with `_ = attempt`, the ritual the examples just lost for failures. Met in R13.73. | The next change to `for` bindings. | `_` admitted as a `for` binding, or the refusal naming `loop` with a counter as the route. | open |
| SR-300 | Usability | A cosmetic edit to a published example fails `check.py` until the same routine is copied by hand into its hidden memory fixture (`run-shell-memory`, `network-echo-memory`), and the refusal does not say which file to re-sync or how. Met in R13.73. | The next change to the shared-routine check. | The refusal naming the copy and the command that re-syncs it. | open |
| SR-301 | Usability | `any(addr lenof people)` is L0103 "`people` does not belong here" with the help "remove `people`", a repair that changes the program's meaning; the real rule, that `addr` needs a named place, is not said. Met in R13.73's outside reviews. | The next change to L0103's repairs or to `addr`'s operand. | A refusal saying that `addr` takes a named place and to bind the value first, with no repair that drops the operand. | open |
| SR-302 | Usability | `try` inside hosted `main` is L0329, whose note says to add the atom to the routine's `!` set, but `main` may have none (L0502), so the suggested fix is refused next. Met in R13.73's outside reviews, pasting the library's recipes into `main`. | The next change to L0329's note. | In `main`, the note naming `else` or a fallible helper as the route. | open |
| SR-303 | Language evolution | A bound anonymous function cannot supply a concept entry: `i32 is ordered (less: less_i32)` with `less_i32 := (a: i32, b: i32) -> (yes: bool) = a < b end` is L0341, though both are fixed code. The tour now declares a named function there. Met in R13.73's outside reviews. | The next change to conformances. | A module binding of a fixed anonymous function admitted as an entry, or the refusal saying why not. | open |
| SR-304 | Usability | L0202's note for a private type crossing a public signature cites "D150: a private identity may cross", but `spec.md`'s D150 is the module graph's identity order; the note's rule has no decision under that number. Met in R13.73. | The next pass over the diagnostic catalogue, with SR-296. | The note citing the paragraph that holds the rule. | open |
| SR-305 | Usability | A new runtime fixture fails `check.py` until it has a Cortex-M corpus row, and only a traceback points to `scripts/add_fixture.py`, which writes it. Met in R13.73, adding four library fixtures. | The next change to the corpus check or `add_fixture.py`. | The refusal naming the fixture and the `add_fixture.py` command. | open |
| SR-306 | Broader standard library | `failure.words` takes only the library's own atoms, so a `platform/posix` errno has no words and a program that fails through the POSIX layer can only word it in general terms; there is no `strerror`. Met in R13.73's tree-copy example. | The next change to `core/failure` or `platform/posix`. | Words for every errno atom, or a `strerror` beside them. | open |
| SR-307 | Usability | Two string literals side by side in a call are L0103 "a call's arguments are never closed", which hides that Landin joins no literals, so a long `format` template cannot be split across lines. Met in R13.73. | The next change to string literals or L0103. | Adjacent literals joined, or the refusal saying they are not. | open |
| SR-308 | Usability | `check.py` and the test program require exactly one `landin` block per `examples.md` section, so the page cannot show a five-line snippet beside a program. Met in R13.73, showing how to call a routine on a path of your own. | The next change to the examples checks. | Snippets allowed when each is held to its program, or the rule stated in `compiler/tests/README.md`. | open |
| SR-309 | Usability | The Claude session timing review found long local checks managed through repeated sleep/log probes; the process guide did not show how to retain complete output and the command's exit status while using completion notifications. | The next change to the local agent feedback workflow. | A documented logged-command path with completion notifications and resource measurements, preserving the selected checks. | retired: `scripts/run_logged.py` retains the complete log, exit status, elapsed time and CPU/memory measurements; AGENTS.md and `docs/process.md` describe background completion notifications, batched inspections and combined test selectors |
| SR-310 | Usability | `scripts/tests/test_macos_environment.py`'s `test_timeout_stops_a_separate_tool_group` failed once under `scripts/script_tests.py`'s sixteen workers, inside a `check.py` control shard, and passed three times alone and on the whole job's rerun; a timing assertion under load reads as a broken change. Met in R13.73, and again in R14.20, failing a whole `python3 check.py` run on a host other agents loaded and passing on its rerun. | The next change to the macOS environment script or its tests. | The timeout test independent of host load, or its margin stated and widened. | open |
| SR-311 | Usability | Registering a fifth prototype meant finding every place the four are named, and `grep prototype-4` finds only some: the finding letters were written out as `[XYZW]` three times in `check.py` and three in `docs/site/render_html.py`, so the new findings rendered unlinked and ROADMAP.md's citations of them went unchecked, with every check clean; and the site's navigation is a `NAV_GROUPS` list beside each document's own `group=`, which only `site.sh` refuses, after `check.py` has passed. Met in R14.10, which put the letters in `PROTOTYPE_FINDINGS` and one renderer constant that `check.py` holds to it. | The next prototype, or the next change to the renderer's document list. | `NAV_GROUPS` read from the documents' `group=` or checked by `check.py`, and the places a prototype is registered named in one place. | open |
| SR-312 | Usability | A citation of a register record that does not exist passes every check: ROADMAP.md's R13.72 paragraph cites `SR-350`, and the register ends at SR-312 with no such row in its history. `check.py` holds construct and finding citations to a definition and register identities to staying inside ROADMAP.md, but not to existing. Met in R14.10. | The next change to `check_roadmap_citations`. | Every cited register identity defined in the register, and the `SR-350` citation corrected to the row it meant. | open |
| SR-313 | Usability | `scripts/gate_watch.py --commit 581b73f5` printed "no gate run for 581b73f5 yet" for 23 minutes beside a gate run that had passed: `gh run list --commit` matches only a full hash, and the watcher passed the short one on and waited. Met in R14.10. | The next change to the gate watcher. | A short hash expanded, and a name that is no commit refused. | retired: the watcher expands a name with `git rev-parse` and refuses one that is neither a commit here nor a full hash |
| SR-314 | Language evolution | An error set cannot be a generic parameter, so a fibre group (D444) carries every task's failure as `failure.reason`, and a task failing with an atom of the program's own maps it before returning. Met deciding prototype 5's V2. | A second facility that has to carry its caller's error set through a generic: a callback runner, a comparator, a traversal, or a derived program that maps atoms only to get them through a group. | A register decision for error sets as generic parameters, or the mapping recorded as the way with the facilities that met it. | open |
| SR-315 | Language evolution | A fibre group whose backing is the caller's frame must be joined before the frame goes, and only the program's `defer` makes sure of it (D444); a forgotten join runs a fibre on a dead frame. A check that such a group is joined on every path out, as [0910] checks that a sunk place is replaced, was declined until needed, since marking a type as needing it is close to the parked affine values. | A derived program or a fixture that forgets a join, or a second library value whose release is as unsafe to forget. | A register decision for a path check keyed on a property rather than one library type, or the `defer` recorded as the way. | open |
| SR-316 | Usability | A runtime fixture for a feature that lands one backend at a time cannot stay off linux-arm64 honestly: `check.py` and `scripts/add_fixture.py` want a `linux-arm64/parity.json` record naming "the counterpart that runs on arm64 instead", and while arm64 does not emit the feature yet there is none, so a negative fixture pinning arm64's refusal had to be written to stand as the counterpart of four runtime fixtures. Met in R14.20, adding the x86-64 stack switch's fixtures. | The next feature that lands on x86-64 before arm64, or the next change to the parity record. | A disposition for a feature not yet emitted on arm64 that names its refusal and lapses when the backend lands. | open |
| SR-317 | Usability | L0506 is one sentence, the whole contract, for every way a `panic_handler` misses it, so a handler written against the former four kinds was told its shape and not that its kind lacked `stack_exhausted`. R14.20 added that reason; a wrong convention, constraint, site type or error set is still told only the shape. Met in R14.20, moving the contract to D451's five kinds. | The next change to the handler contract or to L0506. | Each refusal naming the part of the signature that differs. | open |
| SR-318 | Usability | `scripts/dev-test.sh` takes one `--fixture` per run while `--suite` and `--case` repeat, and AGENTS.md asks for one invocation with every selector a change reaches; four new runtime fixtures meant four runs or the whole `fixture execution` suite. Met in R14.20, and again in R14.30, where two Linux fixtures on the two cross lanes took four runs and four fixtures on three lanes twelve runs in a shell loop. Met again in R14.40, where seven thread fixtures on three Linux lanes took twenty-one runs. | The next change to the test program's selectors. | `--fixture` repeating as `--suite` and `--case` do. | open |
| SR-320 | Usability | Building a frame list with `escaping into` (D445, D455), every node has to be declared before the list and in the order it is pushed: `push_front`'s head is kept in each new node, so the node pushed earlier must be declared before the one pushed later, and a node declared after the list is L0314, though locals of one block live until the block ends together. The order is right but has to be worked out from the refusal. Met writing `runtime/escaping-into-frame-list` in R14.20. | The next program that builds a frame structure through `escaping into`, or the next change to the outlives rule. | Locals of one block counted as equally long-lived, with the reason it is safe recorded, or the order taught where the tour teaches the form and named in L0314's note. | open |
| SR-321 | Usability | A struct literal passed straight to a parameter of a named struct type is L0304, "a struct literal needs a named type from its destination", though the parameter names the type; `admit(g, (host: host))` had to become a binding `task: state = (host: host)` first. Met writing `runtime/escaping-into-group-state` in R14.20. | The next change to struct-literal typing or to argument checking. | A parameter's type given to a literal argument as a binding's is, or L0304's note naming the binding as the way. | open |
| SR-322 | Usability | A `match` arm whose body is two statements on the lines after `ptr (front):` is refused at the second statement with "a match arm puts `:` after its case", which reads as a mistake in the case; the repair, `begin` ... `end` around the body, is named nowhere in the refusal. Met writing `runtime/escaping-into-frame-list` in R14.20. | The next change to the parser's match-arm recovery. | The refusal naming `begin` ... `end` when an arm's body continues on the next line. | open |
| SR-323 | Usability | `python3 scripts/add_fixture.py` and `python3 check.py --tokens` stopped with "the grammar has problems; fix those first" and named no problem, and `python3 check.py spec.md` reported the grammar clean; the problem, "grammar preamble omits contextual words: into", was found only by calling `read_grammar` from Python. Met adding `escaping into`'s fixtures in R14.20. | The next change to `check.py`'s token or grammar generation. | Both refusals printing the grammar's problems with their lines, and a targeted `spec.md` run reporting them. | open |
| SR-324 | Usability | Whether a backend change's Darwin and FreeBSD arm64 emission still assembles has no local command on a Linux host: the gate's `darwin-*` and `freebsd-*` lanes are the only callers, `compiler/tests/freebsd/check.py` wants a sysroot and a VM, and the route found was reading it to learn it drives Clang with `--target`, then a hand loop of `refine compile --emit=asm` and `clang --target=arm64-apple-macos13 -c` / `--target=aarch64-unknown-freebsd14 -c`, under a nix-wrapped Clang that warns on every call that it is not designed for another target. Met in R14.20, adding the arm64 stack switch. | The next backend change that touches Mach-O or FreeBSD spelling, or the next change to the cross lanes. | One documented command that emits a fixture set for every non-host target and assembles each with the pinned assemblers, without a VM or a Mac. | open |
| SR-325 | Usability | `check.py` refuses a `spec.md` "Pinned by" paragraph that names a retired fixture even in the past tense ("this pins negative/..., which is not a fixture"), so D453's record of the linux-arm64 refusal fixture it once had could say only "a negative fixture", and the history of what pinned a decision is lost from the paragraph that states it. Met in R14.20, retiring that fixture when the arm64 backend emitted the stack builtins. | The next retirement of a fixture a decision cites. | A spelling for a retired pin that the check accepts, or the rule recorded as the way. | open |
| SR-332 | Usability | `environments/cortex-m/firmware.py` has no case selector: its focused command runs every firmware case at the first profile, or every case at all six with `--all-profiles`, so running the new `fibre` case alone at six profiles took a throwaway driver importing `firmware.fibre` and `firmware.build`. Met adding the Cortex-M0 stack switch's interrupt and unwind case in R14.20. | The next change to `firmware.py` or to `run.py`'s lanes. | `--case` on `firmware.py`, repeating as `backend_corpus.py`'s does, with a filtered run marked as one. | open |
| SR-333 | Usability | `backend_corpus.py` accepts an `execute` row in `compiler/tests/cortex-m/corpus.json` for a fixture whose oracle is its output (`run_expect:`) and then fails each profile with "fixture requires hosted input/output", which says neither that the row cannot execute nor what to do: give the fixture a status oracle, or write a `refuse` or `restriction` row; a counterpart cannot help, since the original's metadata is what is read. Found reading `backend.py` before moving `runtime/stack-switch-round-trip` to `execute` in R14.20. | The next change to the corpus inventory or to `backend.fixture`. | The inventory refusing such a row before anything builds, as it refuses one that reads standard input, and naming the two ways out. | open |
| SR-336 | Usability | An `any C` made straight in a call's argument from a pointer to an instance of a parameterized provider, `runner(any(p))` with `(t: type) box(t) is task`, compiles, and the callee's erased call traps `unreachable` at run time: the checker's discovery pass materializes the family's conformance for a binding with a written `any C` type but not for an argument, so D377 decides beforehand that no conformance answers the concept. Binding it first, `work: any task = any(p)`, works, and `core/fibre`'s `admit` does so. Met writing `core/fibre` in R14.20; a patch materializing it for a non-generic callee's `any C` parameter was tried and passed the reproducers, and leaves generic callees, function values, results, fields and array literals as they are. | The next change to erased construction or D377, or the next parameterized provider erased in an argument. | Discovery materializing the conformance wherever the contextual `any C` is known, and D377's trap reported at compile time when a program does make an `any` of the concept. | retired: the checker selected an erased call's dispatch when discovery ended, before an `any` made outside a binding with its type written had materialized the parameterized conformance; the call now takes its dispatch once every body is checked, so D377 is decided over the closed program wherever the `any` is made, pinned by the `runtime/any-parameterized-provider-*` fixtures, and `core/fibre`'s `admit` passes `any(copy)` directly |
| SR-337 | Usability | `fibre.turns_over(any(addr runner), ...)` over a `fibre.whole`, and over the blocking host, is L0318 "this concrete type has no conformance to `turns`": it names neither the type nor that the type provides `turns`' parent `scheduler`, which is the whole reason a group over turns is refused for it (D444). Met writing `negative/fibre-turns-over-scheduler-only` in R14.20. | The next change to L0318 or to concept composition. | L0318 naming the type, and the parent concepts it does conform to when a composed concept is missing. | open |
| SR-338 | Usability | A stack builtin is refused with L0344 on a target that does not emit it wherever it is written, in a routine of an imported module the program never calls as well, so a module that offers a switch makes every program that imports it fail on arm64, RV64 and synthetic-32. `core/fibre` had to put the switch in a submodule of its own so that `hosted/system` could provide `fibre.scheduler` without refusing every hosted program on those targets (D463). Met writing `core/fibre` in R14.20. | The integration of R14.20's backends, or the next library module that calls a target-limited builtin. | Either the refusal limited to a builtin the program reaches, with D453 amended, or the submodule rule written into core/README.md's "Adding a module" for any module that calls one. | open |
| SR-339 | Usability | `x := f() else return` and `f() else return`, written as a newcomer writes them to give up on a failure, are L0102 "`return` begins a statement, and a statement has no value" with the note "a statement stands on its own line"; the forms that do it, `else (problem)` with `_ = problem` and `return` on lines of their own, or `try` in a routine with the failure in its set, are named nowhere in the refusal. Met four times writing R14.20's fibre fixtures. | The next change to `else`'s handler forms or to L0102's notes. | L0102's note naming the block form and `try` when the token after `else` is `return`, `break` or `continue`. | open |
| SR-342 | Usability | The build report's `frame_bytes` reads as a routine's stack and is not one, and means different things by target: on x86-64, arm64 and RV64 it is the frame's extent without the sixteen-byte frame record, the return address or any call's argument area, while on Cortex-M0 it includes the pushed registers. Met in R14.20 building D447's depth report, whose frames had to come from each backend's prologue instead. | The next change to the build report's `routines`. | `frame_bytes` documented as the extent it is, or the report carrying the `Stack_Bytes` the depth report reads. | open |
| SR-343 | Usability | Running one program on Cortex-M0 under QEMU takes a fixture directory under `compiler/tests/fixtures/runtime` and an `execute` row in `compiler/tests/cortex-m/corpus.json`, both removed afterwards: `backend_corpus.py` takes no program path, and a measured value comes back only as the failure "the result is N, expected 0". Met in R14.20 painting a fibre's stack to hold the depth report's bound against it. | The next Cortex-M lane item. | A runner option that executes a named program at the corpus's profiles and prints its status. | open |
| SR-344 | Usability | A fixture can hold only what `refine` prints, never a file an option writes, so an option that writes a report, `--build-report`, `--stage-report` or `--stack-report`, is pinned only by fake-host cases in the test program and never end to end on a real host. Met in R14.20 adding `--stack-report`. | The next fixture-format change. | A fixture key naming a written file and its expected bytes. | open |
| SR-346 | Usability | A runtime fixture that imports nothing has its hosted entry's platform module, `platform/linux`, named in the build report by its absolute library path, while a program that imports it through its root has it named relative to the root; `workload_sources.py --write` recorded `/home/...` paths for the stack switch's debugger workload until it and the test program's inventory case learnt to read an absolute path inside the checkout as a repository one. Met adding `runtime/stack-switch-frames` as a debugger workload in R14.20. | The next change to the build report's source names or to a module's implicit inclusion. | One spelling for a source however the compiler came to include it, or the rule stated in the build report's documentation. | open |
| SR-347 | Usability | The Cortex-M0 image's symbol table gave module storage no size, unlike every other ELF backend's, so `nm -S` could not identify a fibre's backing in static RAM and the extent had to come from the next symbol's address; the backend now types and sizes reserved (zero) storage, and storage with an initial image is still unsized. Met measuring the stack-switch consumer for R14.20. | The next change to the Cortex-M0 backend's data emission. | Every module datum typed and sized, as the other ELF backends do. | open |
| SR-348 | Usability | `compiler/tests/rv64/check.py --kind=debugger` would run its sessions only on physical riscv64 hardware, and with the RISE lanes suspended no command anywhere ran the RV64 GDB sessions, though `compiler/tests/debugging/check.py` runs the arm64 ones under QEMU's stub on any Linux host. Met adding the stack switch's session for R14.20. | — | — | retired: the debugger kind's prepared payload takes `--qemu=PATH` and runs under QEMU's user-mode GDB stub as cross evidence, named in its summary, and the gate's first `rv64-qemu` shard runs it |
| SR-349 | Usability | Nothing in the repository runs an LLDB session on a Linux host: `nix develop` has no LLDB, the Darwin sessions need a Mac and the FreeBSD ones a VM, so a change to an LLDB script or its transcript parser is first run in the gate. The stack switch's LLDB sessions were tried against a Linux x86-64 image with `nix shell nixpkgs#lldb`, found by guessing. Met writing the Darwin and FreeBSD stack switch sessions in R14.20. | The next change to an LLDB session script or to the development shell. | LLDB in the development shell, and a documented command that runs the shared LLDB sessions against a Linux image. | open |
| SR-351 | Usability | Nothing says how deep a fibre's task goes on a target, and the depth differs by a factor of four between targets: `runtime/fibre-same-source-any-provider`'s first task took 4.1 to 4.4 KiB of its stack on RV64 at every profile (4448 bytes at `none`, 4072 at `size`, 4344 at `speed`), against 3.8 KiB on x86-64 at `none` and 1 KiB at `speed`, because RV64 keeps every scalar in a frame home of its own. Its 4 KiB stacks fitted on x86-64 and arm64 and failed on RV64 as a segmentation fault with no output, not `stack_exhausted`: the round's `yield` sweeps through `sweep`, `running` and `entry_record` beside its switch, and on RV64 that chain reaches 1.1 KiB below the switch's frame, more than D465's 1 KiB room, so a software watchpoint saw it overwrite the fibre's own record below its stack before any check (in `runtime/fibre-stack-past-limit-traps` too, which then ends in `bad_conversion` at `size`). Writing the sweep out in `yield`'s body moved the check deeper on RV64, whose larger frame then trapped `runtime/fibre-turns-interleave` and `runtime/fibre-join-first-failure`, so it was not kept. Met fixing the fixture on the RV64 lane in R14.20. Since D471 to D473 the overflow traps `stack_exhausted` at the routine that overflows, on every target, so it no longer writes below the stack; RV64's frame homes remain. Met again in R14.30: two fibres calling the fake network trapped `stack_exhausted` on 5 KiB stacks at `none` on x86-64, needed 7 KiB there and more than 8 KiB on RV64 at every profile, and `--stack-report` gave each task's depth as open (`closed: false`) through the `any` calls to the round, so the size was found by bisecting on each lane. | D447's stack-depth report, or the next change to D465's room or to RV64's frame homes. | The depth report giving each admitted routine's deepest stack per target, so that a stack is sized from a number; the provider's own path to its switch going no deeper than the switch or inside the room on every target; and RV64 reusing scalar homes so that its frames shrink at `size` and `speed` as the other backends' do. | open |
| SR-352 | Usability | The Cortex-M lane's fibre `capacity` control (D470) cannot be run on its own: `environments/cortex-m/evidence.py` has no command line and `run.py` takes no selector, so re-measuring the consumer after changing its backing meant the whole lane or a hand-written script that imports `run.Run` and calls `evidence.fibre_capacity`, found by reading both. Met re-measuring the consumer for D473 in R14.20. | The next change to the Cortex-M lane's drivers. | `run.py` or `evidence.py` taking the control and profile to run, as `freestanding.py --case` does. | open |
| SR-356 | Usability | Adding a construct to `tour.md` or `spec.md` takes four steps nothing names in one place: a row in `compiler/tests/registers.md`'s construct inventory, fixtures whose `constructs:` claim it, the construct in at least one guarantee row of D148's register in `spec.md` (`check.py` says only "implemented construct [NNNN] has no guarantee row"), and a regenerated `constructs.matrix`. `docs/documents.md`'s "Where a new rule goes" names the grammar and the register entry only. Every multiple of ten is also taken up to [2000], so a new construct has to be inserted, as [1795] and [1975] were, which nothing says is the practice. Met writing the tour's [1675] and spec [1995] in R14.20. | The next construct added to either document, or the next change to `docs/documents.md`. | `docs/documents.md` naming every place a new construct is held, and how an id is chosen once the tens are used. | open |
| SR-357 | Usability | A FreeBSD LLDB failure can be seen only in the VM lane: `nix develop` provides no LLDB, the lane's README names no way to ask which symbol LLDB gives an address in an emitted image, and the switch session's refusal ("did not step from landin.stack_switch's first instruction through its return") did not say the frames were right and the routine misnamed; it now names what the debugger called each stop. Reproducing the R14.20 gate's `.Ldebug_end_11_0 + N` frames took `--prepare-only`, an ad hoc `nix shell nixpkgs#lldb` and `image lookup --address` on the prepared image. Met fixing D475 in R14.20. | The next change to the FreeBSD lanes, to `switch_frames.py`'s verdict, or to the flake's debugger tools. | A local, documented `image lookup` step over a prepared payload, with the LLDB it needs in the shell. | open |
| SR-358 | Usability | Running the FreeBSD arm64 lane on a NixOS host takes three things its README does not lead to. The README's command passes `--refine=compiler/ada/build/linux-amd64/release/bin/refine`, but inside `nix develop` the build tag is `nix-x86_64-linux`, and the refusal for the missing path suggests `LANDIN_BUILD_TAG=linux-amd64 ... scripts/build.sh --compiler-only` rather than naming the build that exists. The arm64 guest's firmware is looked for only under `/usr/share`, and the `LANDIN_FREEBSD_EFI` override that `environments/freebsd/vm.py` reads (pointed at `share/qemu/edk2-aarch64-code.fd` of `nix shell nixpkgs#qemu`) is named in no document. `--ssh-port` takes "an existing development VM" without saying how to start one: booting the cached `arm64.raw` behind a qcow2 overlay with the lane's own QEMU arguments, so that the guest could be kept for `image show-unwind` and C comparisons, was read out of `vm.py`. Met investigating the FreeBSD arm64 switch session's final `ret` in R14.20. | The next change to the FreeBSD lanes or to `environments/freebsd/vm.py`. | The README's command naming the shell's build, the firmware override documented, and a `--keep-vm` or boot-only mode that prints the port a later `--ssh-port` run uses. | open |
| SR-359 | Usability | FreeBSD 14.4's base LLDB, 19.1.7, misreads the stack switch's final `ret` on arm64: in frame 0 it emulates the routine's instructions rather than read its CFI, its emulator loses the stack at `mov sp, x10`, and at the `ret` it reads the return address through x29 and skips a frame. A clang-built switch with clang's CFI fails the same way, every other instruction unwinds right, and the CFI there is the standard epilogue's. So the FreeBSD arm64 switch session records that one stop and does not judge it (`UNRELIABLE_RETURN` in `compiler/tests/debugging/switch_frames.py`). Met in R14.20, gate run 40707225594. | FreeBSD's base system shipping another LLDB, or an upstream fix to LLDB's arm64 instruction emulation. | The exemption removed once that LLDB unwinds the `ret` right, or the reason restated for the version that still does not. | watch |
| SR-360 | Usability | A concept's entry cannot be called through a concrete provider type's name: `system.host.make_temporary(services, ...)` is refused with L0338, "a type name does not denote a runtime value", although `provider.make_temporary(...)` is accepted where `provider` is a type parameter. `core/io`'s own `make_temporary` takes a concrete source of names and erases it, so a provider holding an `any io.entropy` already cannot hand it on through that call either; `hosted/blocking` needed a private generic routine whose only line calls the entry. Met supplying `io.file_system` by delegation in R14.30. | The next change to how a concept's entries are called, or to `core/io`'s `make_temporary`. | An entry callable through a concrete type's name, or the helper taking an erased source as it is. | open |
| SR-361 | Usability | Supplying a concept by handing every entry to a field's provider takes one routine per entry, written out with its whole signature, failures and origins: `hosted/blocking` hands thirty-eight entries of nine concepts to the `hosted/system` handle it holds, each a three-line routine that only calls the same entry on `self.services`, and a new entry of any of those concepts must be added there by hand. Met splitting the hosted services in R14.30, and again writing `hosted/events`, whose `delegated.ldn` is a copy of the blocking provider's with each routine renamed. | The next provider built over another, or a change to conformance syntax. | A conformance that names a field whose provider supplies the concept, or the routines kept with the reason recorded. | open |
| SR-362 | Usability | The Cortex-M corpus's refusal reasons are free text written once per fixture, and 69 of them named the hosted module a fixture imported; splitting `hosted/system` meant rewriting them by a script that guessed which ones to change, and nothing checks that a reason names the import the refusal is for, so a stale one stays green. Fixture summaries and comments repeat the module names the same way. Met migrating the hosted fixtures in R14.30. | The next change to the Cortex-M corpus's rows or to `scripts/add_fixture.py`. | A reason the corpus reads from the refusal it records, or a check that each reason names an import the fixture has. | open |
| SR-364 | Usability | R14.30 said the event Io would sit "beside `platform/linux`'s epoll", and there was none: `platform/linux` wrapped no epoll or signalfd call, and only `platform/linux/numbers` named their numbers, so a reader planning the provider was sent to a module that did not have it. Met starting R14.30's platform layer. | Fixed with it: R14.30's text names `platform/linux`'s epoll and signalfd wrappers and `platform/kqueue`, which now exist. | The roadmap naming only what exists, or saying it is to be written. | retired: R14.30 added the wrappers and `platform/kqueue` and its text names them |
| SR-365 | Usability | `scripts/add_fixture.py` gave each new runtime fixture that imports `platform/linux`, `platform/kqueue` or `platform/posix` a Cortex-M row of `execute`, though the Cortex-M0 source check refuses every such import with L0015 before it reads a declaration; the right row, `--refuse=L0015` with a reason, was found by reading the rows of `runtime/posix-poll` and `runtime/linux-system-calls`. Met adding R14.30's platform fixtures. | The next change to `add_fixture.py` or to the Cortex-M corpus check. | A fixture whose imports the freestanding target refuses by namespace given its refusal row, or a refusal that names the option. | open |
| SR-366 | Usability | `compiler/tests/freebsd/check.py` stops the lane at its first failing outcome with a traceback, `ValueError: runtime-posix-non-blocking-size-off-default: guest status 2, expected 42`, so the profiles and fixtures after it have no verdict, and nothing says whether the failure was the only one. Its README also says the shell provides no system emulators, while the amd64 lane runs locally under `nix shell nixpkgs#qemu` with KVM, and the arm64 lane with `LANDIN_FREEBSD_EFI` as SR-358 says. Met running R14.30's kqueue and non-blocking fixtures on a NixOS host. Met again in R14.40, where the amd64 lane stopped at `runtime-thread-creation-and-join-order-writes-size-off-default: guest status 132`, though the guest had run every outcome and only the bundle's status files said the rest had passed. | The next change to the FreeBSD lanes. | Every outcome run and reported, failures listed together without a traceback, and the README naming the local emulator route. | open |
| SR-353 | Usability | `refine check`, and so `refine lsp` in an editor, accepts a program that `refine compile` then refuses with `L0508`: whether a selected panic handler fits a prepared stack's margin is decided from the emitted frames (D474), which a check does not have, and it can differ between optimization profiles of one program. Met implementing D474 in R14.20. | The next change to the depth report, to `refine check`'s request, or to the server's diagnostics. | A check that can say, from the frames a backend would emit, whether the handler fits, or that says it has not decided it; or a handler bound a check can state without emitting. | open |
| SR-368 | Usability | A struct field named `at` after another field, `listener: io.file` and then `at: net.address` on the next line, is refused with `L0102` "an expression belongs here" pointing at the colon: the parser reads `at` as the previous field's [1795] `at` offset clause, across the line end, and nothing in the report says so; the note asks for a literal, a name, a call or a parenthesised expression. Renaming the field was the only way on, found by guessing. Met writing the fake network's fixtures in R14.30, and again writing `hosted/events`' first fixture, `peer` for `at`. | The next change to the parser's struct-field recovery or to contextual words. | An `at` that begins a line taken as the next field's name when a `:` follows it, or the refusal saying it read an offset clause of the field before. | open |
| SR-369 | Usability | An array's length cannot follow the target's word: `[2 * 128 * compiler.word_size]u8` is refused with `L0203` "unavailable tool reference: compiler.word_size", although D437 lets a module value read that fact and `fixed if compiler.word_size == 32` selects on it, and `[2 * 1024 * sizeof usize]u8` with `L0305` "this is not one of the closed fixed-expression forms". A fibre fixture that must fit Cortex-M0's 12 KiB of RAM and give RV64 more than 8 KiB a stack declares its backing twice under a `fixed if`. Met sizing the R14.30 fake network and signals fixtures' stacks. | The next change to fixed expressions or to D437's compiler facts. | A compiler fact, or `sizeof` of a scalar, accepted in an array length, or the `L0203` refusal saying where the fact may be read instead. | open |
| SR-370 | Usability | Nothing says which sources a program is made of, or where its compile time goes among them: `refine check -v` names only the library, `--stage-report` gives each stage's time and the counts of sources, nodes and declarations, and `--build-report` names items by number. Attributing a hello-world's cost to `hosted/blocking`, `core/fibre` or `platform/linux` took a script that walked the `import` lines itself and copies of the library with one file deleted at a time. Met measuring the D476 split's compile-time cost in R14.30. | The next change to `--stage-report`, `--build-report` or `-v`. | A report listing the program's modules and sources, with each module's nodes and its checking and lowering time, or `-v` naming the sources read. | open |
| SR-372 | Usability | `scripts/add_fixture.py negative/NAME` regenerates the coverage, matrices and tokens and then says "now run ... python3 check.py", which fails with "the diagnostic matrix is stale; regenerate it with python3 check.py --generate (or --catalogue)": a new negative fixture adds itself to its code's owners in `compiler/tests/diagnostics.matrix`, which the script does not regenerate. Met adding `negative/hosted-system-runs-no-programs` in R14.30. | The next change to `add_fixture.py`. | The script regenerating every file a new fixture is read into, `--catalogue` among them, or saying which one it left. | open |
| SR-373 | Usability | A provider kept as a concrete value of another module's type cannot have its concept's entries called on it: `self.round.yield()` on a `stacks.round` is refused with `L0202` "`yield` is an entry of a concept this type conforms to, and the type's representation is module-internal", and the refusal does not say that the same call goes through when it is made through evidence. `hosted/events` wraps each of the round's four entries in a routine generic over `fibre.turns` (`turn(self.round)`), as `fibre.yield` does for `yield` alone. Met writing `hosted/events` in R14.30. | The next change to concept-entry calls or to `L0202`'s notes. | Calling a conformance's entry on a value of a public type whose representation is private, or the refusal naming the evidence call that does it. | open |
| SR-374 | Usability | One caller-declared state cannot back two library handles filled through `inout`: `system.over(state.cells)` and then `stacks.round_over(state.round, ...)` is refused with `L0315` "this argument is passed `inout`, so the call may change its storage while `services` still views it", though the two are disjoint fields, and the reverse order meets the same; a handle `from state` holding `system.new()`'s handle is refused with `L0316` "this writable `from` result also carries an independent storage origin". `hosted/events` therefore uses the process's last-error cell, with no `over` for a cell of the caller's own (D485). Met writing `events.new` in R14.30. | The next change to origin tracking of fields or to D222's independent storage. | Disjoint fields of one `inout` state filled by two calls, or the refusal naming the field it saw overlap. | open |
| SR-375 | Usability | On FreeBSD arm64 at `speed`, both with `--specialize=auto` and `all`, a task whose stack is cut from a module-storage backing (`mut backing: [2 * 16384]u8` at module level) and which slept once on `hosted/events`' clock before recursing past its stack ended in SIGSEGV with no output, where every other profile, and Linux arm64 and RV64 under QEMU, printed `trap: stack_exhausted` and stopped on `brk`. The same task over the same provider passed at every profile with the backing a local of the routine making the group, or with `fibre.yield` in place of the sleep; `runtime/fibre-stack-past-limit-traps` passes there. The handler's report goes through FreeBSD's C library `write`, reached through the PLT and the run-time linker's lazy binding, and nothing bounds that below D472's margin, so a handler that writes below the margin under a module backing lands in whatever the image lays out beneath it; this was not confirmed in the guest, which has no debugger the lane can drive from here. `runtime/events-stack-past-limit-traps` keeps its backing local as the existing fixture does. Met running the FreeBSD arm64 lane locally for R14.30's event provider. | The next change to the trap report on FreeBSD, D474's margin or the FreeBSD link. | The report reached without lazy binding (a direct system call, or a link with `-z now`) or the margin counted with it, and a module-storage variant of the fixture trapping `stack_exhausted` at every profile on FreeBSD arm64. | retired: confirmed in the guest, SIGSEGV in the run-time linker's symbol lookup with the stack pointer 848 bytes below the backing, and gone under `LD_BIND_NOW=1`; off Linux a program that prepares a stack now reports on a stack of its own (D491), and `runtime/events-stack-past-limit-traps` keeps its backing in module storage |
| SR-377 | Usability | An `any C` is no provider of `C`, and the refusal does not say what to write instead: prototype 5's sketch passes an `any net.network` to `net.accept`, `io.lines_over` and `io.buffered_over` and an `any time.clock` to a generic `answer`, and each is refused with `L0318` "this concrete type has no conformance to `network`", citing [1290]. The way on is to call the erased entry, `network.accept(listener)`, and for a generic routine to write an adapter that holds the `any` and forwards each entry, as `io.writer_of` does for a world and nothing does for a network; both were found by reading `core/io`. Met deriving prototype 5's server in R14.30. | The next change to erased dispatch, to `L0318`, or to `core/io`'s and `core/net`'s adapters. | `L0318` on an `any` actual naming the erased call and the adapter, or `core/net` lending a reader and writer from an `any net.network` as `io.writer_of` lends one from a world. | retired: an `any C` is a provider of C and of the concepts C refines (D492), so the erased network goes to `io.lines_over`, `io.buffered_over` and `net`'s routines as the sketch wrote it, and the derived session's adapter is gone; an `any` actual of a concept outside that closure is L0318 saying what it provides and to erase the provider as the wanted concept where it is made |
| SR-378 | Usability | `core/io/fake`'s network over turns fails a call `timed_out` after a round in which nothing in the network moved, even while another fibre of the same round is sleeping on a clock that takes turns and will answer when it wakes: a sleep is no move. A server's `accept` and a client's `receive` over it both time out during a 200 millisecond `WAIT`, so the derived server and client retry `timed_out`, which over the hosted providers, with no limit set, never happens. Met writing `runtime/derived-server-fake-turns` in R14.30. | The next change to `core/io/fake`'s network or clock. | A fake clock that takes turns whose sleep the network counts as a move, or the network given the clock it waits beside. | retired: `clock_beside` makes the fake clock beside the network, whose sleep takes the network's turns and moves the clock only after a quiet round, and the network times out no call while a fibre sleeps on it (D493); the derived server and client no longer try a timed-out call again, and `runtime/network-fake-turns-sleeper` pins an accept waiting through two sleeps |
| SR-379 | Usability | A two-process test has no ready parts. Nothing sends a signal to a child: `io.programs` has no entry for it and `platform/posix` no `kill`, so a parent stopping its child writes `linux.system_call(numbers.kill_number, ...)` on Linux and `libc.kill` on Darwin and FreeBSD under `fixed if compiler.os`, with the child's number from `hosted/system`'s `process_of`. A runtime fixture cannot build a second Landin program for the first to start, so the program starts itself again by `posix.program_name()` and chooses its part by its arguments, which the QEMU cross lanes cannot run without a binfmt_misc handler; running it under QEMU with `-0` naming, as its own name, a shell script that runs QEMU on the program again did, and nothing says so. Met writing `runtime/derived-server-two-process` in R14.30. | The next change to `io.programs`, to the fixture format's programs, or to the cross lanes' runner. | A portable way to signal a child, a fixture key naming a second program to build, and a cross runner that runs a program's own children under the same emulator. | open |
| SR-380 | Usability | A failed `scaling` job names its family only in its closing line, and the tail of its log ends in later families' rows: in run 40863273281 the verdict "locals: emission 8000 -> 16000 grew 2.52x" sat below `locals at speed`'s re-measurement marked "within the bound", and read as the script contradicting itself until the whole log was searched for the `locals:` heading. The `locals` family's emission measured 2.52x, 2.52x and 2.53x there and 2.41x on the rerun, against a 2.5x bound, so the job fails now and then on an unchanged compiler. Met pushing a README change to main between R14.20 and R14.30. | The next change to `scripts/scaling.py` or its bound. | The failure repeating the rows it judged under its family's name, and the `locals` family's margin explained or restored. | open |
| SR-390 | Usability | A refused type application leaves its binding with no type, and a generic call over the binding then types its literal argument as `i32`: on Cortex-M0, `mut total: atomic.cell(u64) = zeroed` is L0344 as it should be, and `atomic.exchange(addr total, 18446744073709551615)` below it adds an L0300, "`18446744073709551615` does not fit `i32`", for a value nobody wrote as an `i32`. The same happens on any target after `atomic.cell(bool)`'s L0318. The Cortex-M corpus's refusal of `runtime/atomic-read-modify-write` pins the second report among its codes. Met writing R14.40's atomic fixtures. | The next change to generic argument deduction, or the frontend-review item that re-pins cascades. | One report for the one mistake, and the corpus row re-pinned without its L0300. | open |
| SR-391 | Usability | A program written for every target cannot call `platform/cortex_m` from a `fixed if compiler.arch == cortex_m0` arm: an import cannot stand in an arm, and `platform/cortex_m` asserts its architecture rather than declaring nothing elsewhere, as `platform/linux` does off Linux, so importing it at all refuses the hosted targets. `runtime/atomic-tick-firmware`, prototype 5's tick on every target, writes `dsb sy` and `wfi` in an assembly block of its own rather than calling `cortex_m.wait_for_interrupt`. Met writing R14.40's atomic fixtures. | The next change to `platform/cortex_m`, or R12's boards. | `platform/cortex_m` usable from a shared program's firmware arm, or the refusal saying which way to write it. | open |
| SR-392 | Usability | On a fresh clone that had never been built, `./scripts/dev-test.sh` began with "landin: the last build did not finish (it was interrupted); rebuilding from clean, keeping bin/", which reads as a fault in a build nobody started. Met on a Mac clone running R14.40's Darwin fixtures. | The next change to `scripts/build.sh`'s attempt state. | A first build saying that it is one, or nothing. | open |
| SR-393 | Usability | `scripts/add_fixture.py CLASS/NAME --refuse=CODES` writes the codes into the Cortex-M corpus row as given, in order and with repeats, as a negative fixture's `codes:` is written, but the corpus compares the sorted set of distinct codes, so a row written from the compiler's ordered report, `L0344,L0344,...,L0300,...`, fails with "source restriction diagnostics changed" and nothing says the row wants `["L0300", "L0344"]`. Met adding R14.40's atomic fixtures. | The next change to `scripts/add_fixture.py` or the corpus's refusal check. | The script writing the set the corpus compares, or the refusal naming the row it expected. | open |
| SR-400 | Usability | A label in a naked routine's body is refused with L0330, "ordinary assembly is straight-line and defines no label", which calls the naked body ordinary; a hosted naked body may branch (D279) but no rule says it may not label, so a forward branch can only be computed. Met writing `platform/linux`'s `clone` trampoline in R14.40, whose text became branch-free, with conditional moves and on RV64 a mask, to do without one. | The next change to assembly's text rules. | The refusal naming a naked body as one, and either numeric local labels admitted in a naked body or the rule written where [1990] says what a naked body holds. | open |
| SR-401 | Usability | A bodyless `extern(c) link(symbol: "S")` import beside a public naked routine named `S`, which D415 makes a global symbol under its own spelling, is admitted with no L0347: the collision check compares explicit and C link names, and a public machine-convention routine's spelling is neither, so the pair reached the IR unchecked. D516 admits the pair when the naked routine names its symbol explicitly. Met trying ways to call `clone`'s naked text in R14.40. | The next change to link-symbol checking. | A public naked routine's own spelling held to the same collision rule as an explicit link name. | open |
| SR-402 | Usability | A fixture `compiler/tests/cross-lanes.json` lists for an emulator fails when it is run alone with `./scripts/dev-test.sh --fixture=...` on that lane, as it would with no row, and the transcript does not mention the row: the rows are read only by the corpus case of `fixture execution`. Met adding `runtime/thread-start-refused`'s row for QEMU's abort on a refused thread in R14.40, whose effect could be seen only through the whole corpus. | The next change to the cross lanes or to the test program's selectors. | A selected fixture with a row reported as the corpus reports it, an expected host failure, or the row named beside the failure. | open |
| R730-22 | Companion tool and ecosystem | No job ran the structural editor grammar's integration pass. | — | — | retired: R8.30's `editor-grammar` gate job runs it on each full gate run, subject to the R8 gate's explanatory-only reuse exception, with the release CLI `environments/pins.sh` pins by sha256, and fails if regenerating the parser changes the committed one |
| R730-25 | Release readiness | `end-to-end/refine-identity`'s macOS arm64 evidence was a run, not a record the coverage readers read. | — | — | retired: R8.30 runs end-to-end fixtures in Darwin's diagnostics runner, which the gate runs, places their Darwin claims from it, and has `check.py` refuse any fixture whose named product target no record places |

## Retained positions

Six positions an outside review challenged and the project kept. Reopen one
only with new evidence that answers its rationale, and record the reopening.
These D labels are the review's, not `spec.md`'s decisions.

| Position | What was kept, and why |
| --- | --- |
| D1 | Integer indexing of UTF-8 text by codepoint ordinal, linear, for ergonomics [0610]; reopen only with program or measurement evidence. |
| D2 | No weak conformances and no orphan rule: a collision is an error, answered with `distinct` or an explicit function [1280], because a weak conformance lets an application silently change a generic library's behaviour; reopen on ecosystem-scale evidence. |
| D3 | No compile-time execution and no macros; generated source comes from programs the build runs [1540]. A third kind of generated source starts its review (E3). |
| D4 | `escaping` and `from` are written, not inferred, to keep checking local and because an allocator is a counterexample to inferred `from` [0790] [0900]. |
| D5 | Landin's own backends emitting assembly; not LLVM, a dependency larger than the language, and not C, which loses the calling convention, the traps and the debug information [1550]. |
| D6 | One version of a package name per program: 32 KB of flash, nominal types and one conformance register [1470]. |
