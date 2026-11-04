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

Execution order: R8, R9, R10, R11, R13.10, R13.11, R13.12, R13.13, R13.14, R13.15, R13.16, R13.17, R13.30, R13.18, R13.19, R13.31, R13.32, R13.60, R13.33, R13.34, R13.36, R13.61, R13.35, R13.70, R13.71, R13.72, R13.73, R14.10, R14.20, R14.30, R14.40, R13.74, R13.75, R12, R13.20, R14.25, R15, R16

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
shorthand, and float operands came with R12.30 (D630). The gate ran every job green at
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
ESP32-S and ESP32-C series, on the boards of the maintainer's rig. QEMU
emulates their cores and few of the chips, so emulator lanes carry each
core's instructions, exceptions and ABI, and the boards carry every claim
about a chip's peripherals, memory map and boot.

The compiler knows architectures and boot image kinds and names no chip. A
chip is a description in Landin source: its memory regions, vector slots,
boot image kind and core options, beside the register modules `refine`
generates from its SVD, which a developer reads, checks and navigates with
the editor tooling like any other source. Learning a chip whose
architecture and boot kind `refine` already supports changes no compiler
source. No feature of the compiler needs Python, and a new runtime
dependency is agreed with the maintainer before it is added. Vendor inputs
are pinned by URL and hash and fetched, not vendored. The linker script and
the sections are the developer's as well as the compiler's: a derived
script is an output a developer can read and replace, and a declaration can
be placed in a region its description names.

An item may describe a noncoherent cached memory profile without admitting
it for firmware. Before the first R12 item claims support for such a profile,
it must provide platform-specific DMA cache maintenance and evidence for
cache levels, aliases, cache-line ownership and device visibility points.
Require target execution of transmit and receive consumers and bounded
failure oracles for stale reads and lost dirty bytes when maintenance is
omitted. Cacheless profiles need no such provider. A cached profile without
this evidence remains unsupported through the R12 gate; R12.10, R12.11,
R12.30, R12.40 and R12.50 each apply this rule to any profile they first
admit.

### R12.10 — Describe devices

Status: complete
Depends on: R11.10, R13.35, R13.70

A device description in Landin source selects the memory profile, linker
configuration, firmware vector mapping and boot image format per device,
instead of the fixed constrained profile. The compiler holds the
architectures and a closed set of boot image kinds: a plain vector table at
the boot address, RP2040's checked second stage, RP2350's image block and
Espressif's application image. The constrained profile becomes a
description, retained as the reference. The selected device's interrupt
numbers must map to absolute vector slots (external IRQ0 is slot 16), with
its reserved slots kept zero and its implemented slots available to typed
handlers. When device selection lands, [1990]/D229's fixed vector slot
exclusions must become profile-specific; the current constrained profile
remains a reference.

The compiler derives the linker script from the description's regions and
the regions it places each section in, and writes it as an output. A
developer may supply a replacement script. The linked image is then checked
against a written contract, the vector image at the boot address, the
startup symbols, the stack and the initialized-data images, rather than the
compiler parsing the script. A declaration can be placed in a named region
of the selected description, where [1990] refuses section addresses and
linker scripts today.

This schedules the linker half of R551-33, R730-05's larger profiles,
R551-08's bounded emission policy and the Cortex-M toolchain move SR-01.
The emission policy must be in force before admitting images larger than
32 KiB; the retained constrained profile remains available while that
policy is established.

Exit evidence: descriptions of RP2040 and the constrained reference select
their profiles by device identity. Fixture checks compare each selected
memory region, vector mapping and boot image format fact with an
independently recorded expectation for that device; a wrong or absent fact
fails the checks. The firmware ELF alone does not establish this selection.
A developer-supplied script that meets the contract links, one that breaks
each clause of it is refused naming that clause, and a declaration placed
in a named region lies in that region in the linked map. Every capacity
verdict is rerun against each selected profile with the 32 KiB reference
retained.

The Cortex-M gate runs with SR-01's migrated `arm-eabi-gcc` toolchain,
pinned beside the host toolchain in `environments/pins.sh`,
`compiler/ada/TOOLCHAIN.md` and `flake.nix`. Every affected Cortex-M record,
including firmware hashes and disassemblies, is regenerated and reviewed in
the same toolchain change.

Check the RP2040 interrupt-to-vector mapping against the linked firmware
image: `USBCTRL_IRQ` is IRQ5, so a typed handler at absolute slot 21 must
compile in the RP2040 profile and occupy that vector word; R12.20 executes
it when IRQ5 is delivered on the board. Verify the constrained reference
profile still refuses slot 21 and emits zero there.

Small source/IR shapes must demonstrate that compact inputs cannot cause
unbounded assembler repetition or object growth under the emission policy,
with the forbidden giant-fixture boundary retained. Check this bound before
enabling a larger profile; this schedules the policy and its evidence without
choosing a new numeric compiler limit here.

Done: a firmware program selects its device by importing its description,
a module of `compiler` and `linker` directives under
`devices/descriptions/<chip>/`; with none it keeps the reference profile,
now the library's `platform/cortex_m/reference`, and its assembly is
byte-identical to before (D542, D543). A description's core builds at its
own level or a lower one of its family. The selected profile decides which
vector slots a handler may take and which are zero, in the checker, the IR
verifier and the backend (D544); the linker script is derived from its
regions and placements, the plain table and RP2040's second stage are boot
kinds with RP2350's and Espressif's reserved (D545), `--linker-script` is
held to a written contract that names the clause it breaks (D546), and
`link(region:)` places a declaration (D547). RP2040's regions, vector map
and boot kind are checked against recorded expectations, a handler at slot
21 occupies its word there and the reference still refuses it; its second
stage is 256 zero bytes until R12.20. Every static image is held before
emission to the selected profile's flash and RAM or to its hosted target's
reach, and repeated runs are written as `.zero`, `.fill` and short plain
values, so assembler memory stays near the object's size on every target
(D536, D537). The Cortex-M lane links with GNAT's arm-elf GCC 16.1.0, pinned
beside the host toolchain, and refine looks for `arm-eabi-gcc` and then
`arm-none-eabi-gcc` (D532); every Cortex-M record was rerun on it beside
main's on the old toolchain. Capacity verdicts against each selected
profile are measured from image sizes and frames, since the corpus links
against the reference map (SR-489).

### R12.11 — Learn a device from its SVD

Status: complete
Depends on: R12.10

`refine` generates Landin from a CMSIS-SVD file: the register modules, and
the interrupt and vector part of the device description, beside which a
developer writes its memory and boot part. The importer is part of
`refine`, written in Ada with no new dependency, and replaces the Python
fixture generator. Its inputs, and every vendor header and document
used to check its output, are pinned by URL and hash and fetched rather
than vendored; the RP2040 inputs leave the tree too. The second family is
the STM32H753 on the rig's NUCLEO-H753ZI; R12.30, R12.40 and R12.50 learn
their chips the same way. This schedules the SVD half of R551-33.

Exit evidence: the RP2040 fixture regenerated byte for byte by `refine`; the
STM32H753 generated from pinned inputs, with every selected register and
field's address, layout, reset and encoding checked against ST's CMSIS
device header or reviewed literals independent of the generator and its SVD
input; its read and write access policies checked against separately
reviewed expectations; and a generated-module consumer checked against an
independent control. No emulator models the chip, so that control compares
the addresses, widths and values of the consumer's linked accesses with
reviewed expectations. Each distinct SVD form used by the selected
registers, including peripheral derivation, device-level property
inheritance and alternate registers, is exercised by these checks;
unsupported forms have negative refusal controls.

The H753 description selects its profile as R12.10's do, with its regions,
vector mapping and plain-table boot format checked against independently
recorded expectations, and every capacity verdict rerun against it. Its
profile is cacheless: compiler-owned startup leaves the M7's caches disabled,
as reset leaves them, and a cached profile may be described but is not
admitted.

Done: `refine svd` reads a device's SVD with its own strict XML reader and a
JSON selection policy, and writes the register modules and the description's
`interrupts.ldn`, replacing them whole or not at all (D555-D558); the Python
generator is gone. RP2040's fixture is regenerated byte for byte, and every
vendor input is pinned in `devices/inputs.json` by URL and SHA-256 and
fetched, RM0433 supplied by hand, with only the licence notices kept in the
tree (D559). The STM32H753 is learnt from ST's SVD in Arm's STM32H7xx_DFP
for prototype 1's UART and DMA, its selected registers held to ST's CMSIS
header and to RM0433 Rev 9 by section and page, with reviewed corrections to
two fields, a reset value and the vector table (D560); a consumer's device
accesses are read from its linked image (D561); and its description is
cacheless, with DMA buffers kept out of the TCMs (D562).

### R12.12 — What the register owes now

Status: complete
Depends on: R12.11

A survey of the register before R12.20 found rows on the first board's
path, and rows whose activation an earlier item met without taking them:
R12.10 and R12.11 changed the flake, the Cortex-M lane's runners and corpus,
the command catalogue, the grammar and the Cortex-M0 data emission, and
added diagnostic codes, and R14.20 and R14.30 delivered what four rows
waited for (SR-499). This item takes them, with the recurring friction of
the test program's selectors and the stream patches, and decides:

- An import whose first matching directory holds no source, while a later
  root holds a module of the same path, is refused naming that root; first-
  root precedence stands, and an empty module with no rival stays legal
  (SR-487).
- A target-limited builtin is refused only where the program reaches it,
  amending D453, so a module that offers one needs no submodule of its own
  (SR-338).
- The gate builds the flake on every run that does not reuse a pass: Nix
  CI limited to that, the explicit
  decision R551-15 waits for (SR-236).
- A documents-only commit after a complete successful push run of its
  branch reuses that run under the explanatory rule, as a main run is
  reused now (SR-284).
- A reference manual its publisher serves only to a browser stays supplied
  by hand, pinned by URL and SHA-256 and verified by
  `scripts/fetch_inputs.py`, with how a reviewer obtains it written beside
  the pin (SR-497).

The rows on R12.20's path: the Cortex-M corpus linked with each selected
profile's derived script (SR-489), `platform/cortex_m` usable from a shared
program's firmware arm (SR-391), the NixOS route to the lane's tools
(SR-268), and the lane runners: a named program run with its status, every
lane reported, case and control selectors, and a stack-guard overflow named
(SR-343, SR-270, SR-332, SR-352, SR-274). The overdue rows: SR-129, SR-133,
SR-227, SR-236, SR-260, SR-263, SR-271, SR-276, SR-333, SR-347, SR-349,
SR-351, SR-362, SR-388 and SR-488. The recurring friction: SR-318, SR-428
and SR-280, and SR-499's step naming the rows an item's changes activate.
The shell and checklist work also meets SR-282, SR-356 and SR-357.
Its own changes then met the activations of SR-278, SR-283, SR-305, SR-306,
SR-353, SR-365, SR-366, SR-372, SR-393, SR-402, SR-511 and SR-517, which
it takes too.

Exit evidence: each row's completion as the register states it, with the
fixtures and controls it names; the gate green on the completing commit;
and what the work met in the register.

Done: an import whose first directory holds no source while a later root
holds the module is L0532, naming both (D563); a target-limited builtin is
refused only where lowering keeps the call (D564); the command catalogue
says what each option needs and writes the driver's usage (D565), and a
diagnostic code is one row of one table. The stack report closes a call
through `any`, a generic's table or a function value over every routine it
can reach (D570), a round's yield goes at most 688 bytes past its switch on
every target (D571), `refine check` and the server decide a handler's margin
from the frames a build would emit (D572), RV64 reuses dead scalar homes at
`size` and `speed`, and every Cortex-M0 datum is typed and sized.
`platform/cortex_m` declares its operations only on M-profile, so a shared
program calls them from a firmware arm (D575); the Cortex-M corpus links
each program with its profile's derived script, RP2040's and the
STM32H753's verdicts linked rather than measured, and its lanes run one
program, case, lane or control, report every failure, name a stack-guard
overflow and write a new fixture's row from its compilation.
`connect_within` bounds a connect (D580), an IPv6 address keeps its zone
(D581), `posix.words` words every errno (D582), and a signal during a sleep
is pinned on every hosted target. The gate builds the flake on every run
that reuses no pass (D585), an explanatory close may reuse a branch's full
run (D586), the shell carries LLDB, `scripts/activations.py` names the rows
an item's changes activate, the FreeBSD lane reports every outcome, and the
test program's `--fixture` and `--record` repeat. Darwin parity's 3,916
outcomes and the host suite passed on a Mac before the gate. What it met is
SR-510, SR-515 to SR-517, SR-525 to SR-527, SR-530, SR-540, SR-550 and
SR-551.

### R12.20 — The first board

Status: complete
Depends on: R12.10, R12.12

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

Done: RP2040's description holds its second stage, a port of pico-sdk's
generic 03h stage marked `link(boot_stage)`, which refine places at the
start of flash, pads and seals with the boot ROM's CRC-32 in the object it
assembles (D587, D588), and `--emit=linker-script` writes a profile's
script and limits without a program (D589). The prototype-1 application
runs on a Pico H at the RP2040's own addresses, clocks, resets and pads,
keeping the synthetic driver's receive contract over the chip's own DMA
protocol, a live count and an abort for stop, with the UART's own overrun
reported (D593, D594); its echo and indicator are a module both lanes run.
`environments/boards/rp2040/board.py` flashes the image through a probehive
SWD slot, reads the second stage back, cycles the Pico's power and checks
the UART trace against an oracle written from what the host sent and the
datasheet (D595); IRQ5 is set pending in the NVIC and runs slot 21's
handler in exception 21 (D596). The recorded run is
`environments/boards/rp2040/record.json`: a power-on boot, CHIP_RESET
HAD_POR alone, with no probe attached; VTOR 0x1000_0100, written only by the
ROM-loaded stage, whose CRC is e5e96a65; the shared `1A0` echoed with GPIO3
set and cleared as the emulator lane's application does, read back by its pad
and on a wire by the probe; a ring overrun and
a FIFO overflow each reported and restarted; an exhausted epoch restarted
with nothing lost; 11,202 bytes echoed in order; and the counters read over
SWD equal to the trace's. It left SR-556, SR-569 to SR-571 and SR-573.

### R12.30 — Thumb-2, Cortex-M33 and M7

Status: complete
Depends on: R12.20, R12.11

The ARMv7-M and ARMv8-M instruction sets and the M7's hardware floating
point, for RP2350 and the NUCLEO-H753ZI, with QEMU's `mps2-an505` M33 and
`mps2-an500` M7 machines as the emulator lanes for the cores. RP2350 is
learnt through R12.11's importer, with its image block as the boot format.
`armv7-m` and `armv7e-m` exist as D255 levels with hardware division only;
this adds `armv8-m.main`, Thumb-2 selection beyond division, and the M7's
FPv5-D16 single- and double-precision registers, which change the C ABI and
so are a description rather than a level. The H753 profile stays cacheless
under R12's rule. This item also extends assembly operands to
float registers on the M7 and the hosted targets that have them, including
the register class and clobber set in [1630] and D248.

Exit evidence: the Cortex-M corpus on the emulator lanes in the gate, and a
recorded run on each board. On the M7 board, nonconstant source f32 and f64
arithmetic and comparison fixtures must execute with results checked
against their oracles; linked disassembly must show compiler-generated
hardware float operations rather than software arithmetic helpers. Direct
target-description and C ABI-planner checks must establish the M7's VFP
argument and result registers, call-preserved registers and stack fallback
against AAPCS32's VFP variant, and check the linked image's float ABI
attributes. Executable C
source interoperation remains in R13.20. [1630] and D248 must also be amended for float
operands, with executed float-operand fixtures on every target with float
registers.

The recurring emulator gate must also execute a compiler-generated,
non-division Thumb-2 operation at `armv8-m.main` and check its result. Linked
disassembly must locate the selected instruction in the fixture's compiled
function. The same source at default `armv6-m` must retain its baseline
lowering without that instruction. This evidence supplements the M7 float,
ABI and assembly-operand requirements above.

Done: `armv8-m.main` is D255's fourth M-profile level, without the optional
DSP extension, beside the `cortex-m33` core, which executes it, `armv7-m` and
`armv6-m`. At every Thumb-2 level a 32-bit product is `smull` or `umull` and
a 64-bit one `umull` with `mla` (D605), and at `armv8-m.main` an acquiring
load or releasing store is `lda` or `stl` (D606); the Cortex-M corpus finds
each in its fixture's linked function, and the same source's `bl
__aeabi_lmul` and `ldr` with `dmb` at `armv6-m` and `armv7-m`. QEMU's
`mps2-an505` and `mps2-an500` run the whole runtime corpus beside the M0's,
each through a lane description in Landin source (D607, D619), as the gate's
`cortex-m-corpus` job. The M7's FPv5-D16 is a description's
`compiler.float_unit`, which `compiler.feature.fp` and `fp_dp` read (D615): a
build with it uses AAPCS32's VFP variant for C and for Landin, its planner
held to GCC's hard-float build (D616); its float arithmetic, comparisons and
conversions are VFP instructions and call no helper (D617); reset enables CP10
and CP11, handlers take the extended frame (D618) and a fibre's context keeps
d8-d15 and FPSCR (D620). The linked image reads `Tag_ABI_VFP_args: VFP
registers`, and a soft-float object is refused at its link. The STM32H753's
description has the unit, and its consumer's device accesses are the board's
to check (D621). Assembly operands take f32 and f64 in the class `float` on
x86-64, arm64, RV64 and the M7, a block declaring each callee-saved float
register it names, and a square root runs on each (D630). RP2350 is learnt
from pico-sdk's SVD (D635, D636), and `rp2350-image-block` is built: one
IMAGE_DEF linked to itself after the vector table, read back from the object
and held to the first 4 KiB (D637, D638). A reviewed correction may add a
field the SVD lacks, as the H753's DMA needs TRBUFF (D652), and a
vector-table description may hold a stage that runs before reset, where the
H753's configures its supply before RAM is written (D653). The board tools
share `environments/boards/common.py`, and the shared command loop names no
device (D645, D646).

The recorded runs are `environments/boards/rp2350/record.json`, a Pico 2 on
its Cortex-M33 at `armv8-m.main` from power-on, CHIP_RESET HAD_POR alone and
VTOR 0x1000_0000, its image refused into USB BOOTSEL when the block's end
marker is corrupted, the shared `1A0` echoed with GPIO3 set and cleared, IRQ14
in exception 30, an overrun and the epochs with the UART's 32 bytes kept,
11,202 bytes echoed in order and the counters read over SWD equal to the
trace's (D654, D655); and `environments/boards/stm32h753/record.json`, a
NUCLEO-H753ZI at `armv7e-m` with its float unit from power-on, through the
supply stage with ACTVOSRDY set, CPACR granting CP10 and CP11 and CCR's caches
off, the shared scenario on LD1, USART3's handler in exception 55, an overrun
and the epochs with the receiver holding 17 bytes, 52 f32 and 52 f64 operand
pairs whose sums, differences, products, quotients, comparisons and square
roots, compiled to VFP instructions, match the host's IEEE arithmetic, and the
counters read over SWD equal to the trace's (D647-D651). SR-510's activation
stands, since the item changed the fibre stack's margin and not its
documentation. It left SR-574, SR-575, SR-577, SR-578, SR-580 to SR-586,
SR-590 to SR-596, SR-600, SR-602, SR-603, SR-605 to SR-608, SR-610, SR-613
and SR-614.

### R12.40 — RISC-V microcontrollers

Status: complete
Depends on: R11.40, R12.11, R12.30

RP2350's Hazard3 cores and ESP32-C5 use `rv32imac`; ESP32-C3 uses `rv32imc`
without A. The ESP targets also need their application image format, and
their chips are learnt through R12.11's importer. Espressif's QEMU emulates
the C3; it has no machine for the C5 and none emulates Hazard3, so QEMU's
`sifive_e` carries the `rv32imac` core. The C3 default level and assembler
limit must omit A. Under D227, support aligned
one-, two- and four-byte atomic loads/stores and thread fences, and statically
refuse read-modify-write atomics and eight-byte operations with L0344. There
is no implicit library or interrupt-masking fallback.

Exit evidence: the freestanding corpus on an emulator lane in the gate, and a
recorded run on each board.

C3 emulator and board cases execute its admitted atomic operations. The C3
lane checks the `rv32imc` assembler setting and absence of A-extension
instructions in linked firmware, and requires refusal of exchange, add,
compare-exchange and eight-byte atomics. The Hazard3 and C5 boards and the
`rv32imac` emulator lane execute an A-extension read-modify-write operation.

Done: `rv32` is a firmware target with the ilp32 layout and two D255
levels, `rv32imc`, the default, and `rv32imac` (D660); a program that
imports no description is given `platform/riscv/reference`, QEMU's
`sifive_e` map with the Cortex-M reference's capacities (D661), and a
description names one of four cores, `sifive-e31`, `esp-rv32imc`,
`esp-rv32imac-clic` and `hazard3`, each with its interrupt model and slots
(D662). Its code is RV64's emitter at XLEN 32: eight-byte integers in
register pairs, soft float and 64-bit division through libgcc, word frames,
Table A.6's atomics, the ilp32 planner held to riscv64-elf-gcc, and RV32
assembly operands with a verifier refusal of an invalid register
(D670-D679), linked by GNAT's riscv64-elf GCC or a distribution's
riscv64-unknown-elf (D660). Its text is 1.02 to 1.04 times Cortex-M0's
Thumb for the same fixtures (D676-D678), and the epilogue, which read its
frame record below a released stack pointer at both XLENs until the
Hazard3's first DMA interrupt landed between the two, reads nothing below
it (D679). A level's `a` decides the one checking rule a level may: a
read-modify-write atomic is refused with L0344 at the caller's use at
`rv32imc` and admitted at `rv32imac`, and an eight-byte one is refused at
both (D690, D691). An image begins with an entry word and a trap table
dispatching by mcause, vectored on the E31 and the C3, through one CLIC
entry on the C5 and through meinext on the Hazard3 (D680-D687), records an
unhandled trap in five cells (D656), and places RAM code where it can run
(D657, D688, L0578). `esp-app-image` is built, a RAM-only image at the
ROM's offset with no second stage, written as `OUT.bin` and read back
(D683-D685, L0575-L0577), and `rp2350-image-block` carries RISC-V's
IMAGE_DEF (D682). The ESP32-C3 and ESP32-C5 are learnt from Espressif's
SVDs, with their watchdogs stopped in a stage before reset, and the
RP2350's Hazard3 cores from pico-sdk's (D700-D708). Espressif's QEMU,
pinned in the Cortex-M lock, runs the whole corpus at `rv32imc` on its
`esp32c3` machine, whose CPU is held to lack A, and at `rv32imac` on
`sifive_e` with the reference, as the gate's `cortex-m-rv32` job, and boots
the C3's `OUT.bin` through the chip's own ROM (D695-D698); the host
determinism manifest and the build-modes comparison hold `rv32`'s bytes
(D658), and the recorded lowering lowers a fixture at the target it names
(D659).

The recorded runs are `environments/boards/rp2350_hazard3/record.json`, a
Pico 2 on its Hazard3 cores at `rv32imac` from power-on, CHIP_RESET
HAD_POR alone and mtvec vectored at 0x1000_0200, the shared `1A0` echoed
with GPIO3 set and cleared, IRQ14 forced through meifa into slot 30's
handler, the overrun and the epochs with two DMA completions taken through
meinext, 11,202 bytes echoed in order, `amoadd.w` numbering every frame
and the counters read over SWD equal to the trace's (D710-D713);
`environments/boards/esp32c3/record.json`, an ESP32-C3 at `rv32imc` from
power-on, its ROM's log on UART0 loading each segment of the `OUT.bin`
read apart from refine and entering at its entry, the image holding no A
instruction, a broken checksum refused by the ROM and our SHA-256 the one
it computed, the receive and timer interrupts on lines the program routes
through the interrupt matrix, its admitted atomics checked against the
oracle, the overrun and the threshold window, and the counters, atomic
cells and trap record read over JTAG equal to the trace's; and
`environments/boards/esp32c5/record.json`, the same on an ESP32-C5 at
`rv32imac` through its CLIC, its power-on read over JTAG and its ROM's log
taken after a chip-enable reset, with an AMO and two compare-exchanges
checked (D720-D727). The board tools share a rig lock and pace every
action that drops a device from the hub, and refuse to switch a port
unless the probe's Arty, moved off the hub's cascade, is still off it
(D725). The `check.py` rows SR-254, SR-255, SR-291, SR-323, SR-460 and
SR-530 keep their activations, since the item changed only `check.py`'s
pin and target checks; SR-515's, SR-552's, SR-555's, SR-580's and
SR-680's, which it reached, are restated with the others it reached. It
left SR-618 to SR-622, SR-625, SR-635 to SR-637, SR-645 to SR-651,
SR-655, SR-660, SR-671 to SR-673, SR-680, SR-681, SR-684, SR-685 and
SR-690 to SR-694.

### R12.45 — Board runs from RAM

Status: complete
Depends on: R12.40

Done: all six board ports default to SRAM development runs under a defined
warm reinitialization contract, without flash programming or a ROM reset.
`--firmware-layout=ram` derives SRAM placement, validates allocated sections
and startup ranges, keeps BSS clearing and omits in-place copies (D900).
`environments/boards/run.py` builds on epycmicro and transfers checksummed
images and matching tools to rigpi, where the locked, timed physical
oracle runs (D901, D902). Explicit boot mode checks ROM packaging and cold
startup, then restores and verifies a USB-silent fixed image. Pico 2 setup,
architecture changes and boot checks stay off the cascade; manual UF2 and
Pico-only cold cycles never switch the Arty or attach in BOOTSEL.

All six ports passed cold-boot and repeated RAM oracles, with separate
records that match all twelve current offline builds in strict mode.
Pico 2 Arm RAM runs took 6.362 and 6.348 seconds; Hazard3 took 15.897 and
15.898 seconds from the verified cold fixed image and then the running
application. Hazard3 uses core 0 program-buffer transfers, retained hart 1
debug halt, resume flushing and a TIMER0 pause policy that permits its
alarm to run (SR-754, SR-755). Six independent readbacks per run confirmed
the retained halt; RAM runs wrote no flash, reset no chip through the ROM
and logged no kernel USB lines. Both Pico 2 boot checks passed exact
power-on and fixed-restoration oracles; their 907.098 and 739.301 seconds
include the operator's manual steps. Detailed timings and identities are
retained in the tool records and the central boards guide.

The complete integrated Linux suite passed 1,116 cases and 251,104 checks.
All 286 board controls pass on Linux; native Darwin passes 284 with only
two live Linux process-discovery checks skipped. The same focused native
Mac compiler cases, native/Pi helper builds, fifteen Rust controls, six
real RAM-image validations, modes/manifest comparisons, scaling,
highlighter integration and document checks pass. The activation sweep
uses the starting commit `eef9d3db5`. Settled SR-680, SR-684, SR-691,
SR-706, SR-735, SR-737, SR-738, SR-739 and SR-741 through SR-756. SR-736 remains open because the Pi's
Arty and cascade share VL805. The LiteX-only companion shell is published
on probehive's `landin-ram-gpio` branch at `4f69b8269a664cf1e1c47b2b40365b482e9f30ec`
(SR-737). Promotion requires the candidate's complete multi-host gate.

The activation sweep also reached SR-266, SR-289, SR-296, SR-298 and
SR-605: caller-aware internal-error reporting, language option values,
diagnostic citation policy, trap-site resolution and RP2350 image hashes
retain their activations. The Hazard3 debug wedge met SR-685's trigger;
full architectural register capture remains deferred because debug access
itself stalled, and recovery would replace the state being diagnosed.
This item retains debug prestate, loader errors and USB deltas, and prevents
ESP failures before a successful load from presenting stale application trap cells
(SR-748). SR-552 and SR-555 retain theirs: no script-test
host-only dependency or locked lane tool changed. SR-699's activation is
the Cortex-M runner's arguments, not the new board runner. SR-724 remains
for the next change to gate job identities, matrix legs or the reuse list;
this item adds a step to the existing Cortex-M programs leg.
It also builds both RAM helpers in the existing flake job; job identities
and reuse rules are unchanged.

### R12.50 — Xtensa, ESP32 and ESP32-S3

Status: complete
Depends on: R12.11

Done: added the `xtensa` family, default `xtensa-esp32` LX6 and selectable
`xtensa-esp32s3` LX7, with one windowed ILP32 layout (D903) and compiler-owned
window overflow/underflow, interrupt, trap and stack-switch startup. CLI and
server level selection, feature queries and L0009 refusals cover both levels;
one unchanged source takes distinct `salt` feature branches. Pinned vendor
assemblers accept available instructions and reject absent instructions in
source blocks and generated code, including the default selection. Actual
ESP32 objects run on S3 only after configuration, linked-instruction and
helper compatibility checks; this supplies no general LX7-superset claim.
Both strict configurations, independent C peers and helper-state audits pass.
The compact frame plan retains ordinary checked frames, an independent opaque
assembly bank and a measured prepared-stack handler reserve (D472, D474).

Both exact CPUs pass the complete unchanged freestanding inventory on pinned
Espressif QEMU's explicitly virtual 64 MiB SIM profile: 3,303 cases per CPU, comprising
3,066 executions, 168 expected source refusals, 65 target restrictions and
four witnessed selected-image limits for the unchanged two-GiB fixture.
Separate chip controls retain the physical SRAM bounds. Both imported boards
pass recorded RAM runs and separate packaging/cold-start checks, with verified
fixed USB-silent images restored. ESP32 records USB cycling followed by
CHIP_PU reset and unmeasured rail discharge; S3 separately observes power-on
before UART. The common rig lock, USB stop rule and Hazard3 contract remain.
No external memory, DMA or physical timing guarantee is claimed. The two new
complete emulator lanes and required-job reuse inventory move together.

Focused Linux and native Mac compiler checks, script controls, independent
assembler/C ABI controls, all sixteen offline board images, highlighter and
flake checks pass. Debug/release emission has no disagreements across 24,548
requests; the all-target manifest covers 52,272 entries. The full fixture-execution suite agrees at one and eight workers: all
14 aggregate cases pass, with 16,024 checks and retained verdict/diagnostic
diffs empty after progress-time normalization. Scaling passes alone on its
host with the default parameters and worker settings.
The candidate must pass its complete remote gate before main promotion,
which needs separate authorization and the unchanged tested tree.

Settled SR-614 (including its merged SR-671) and SR-672 through the manual-text and policy-drafting recipes;
SR-660 through emulator pointers; SR-709 through the public fake-filesystem
contract; SR-719 through the configuration-atom catalogue; SR-723 through
runtime link policy in mode comparisons; SR-724 through expanded required-job
inventory checks; SR-725 through target debug-mode queries; and the carried
SR-757 through RAM-default help. New findings SR-758 through SR-767 are also
settled: grouped interrupt corrections, dimension documentation, installer
preflight, distinct command logs, scoped boot reads, complete UART boot traces,
owned emulator cancellation, explicit classic cold reset, external URL
recognition and measured remote-protocol latency. SR-770 and SR-771 are
settled through deterministic retained comparison evidence and canonical
reader-lock fixtures with an inherited-marker alias control. SR-757 keeps
its original identity. New SR-768 remains open: contended wall-clock timeouts stay failures,
with scheduling guidance and controlled replay evidence, pending a general
guest/transport budget policy. New SR-769 remains open for architecture-specific result/diagnostic labels
in the shared ESP scenario; existing Xtensa records are
documented as INTERRUPT pending bits, with the correct per-line masks. New
SR-772 remains open for selected-target corpus restriction explanations;
shared witnesses stay valid, but inherited Cortex-M wording does not name
Xtensa's separate controls. New SR-773 remains open for a first-failure log
command that works while the overall gate is still active.
New SR-774 is settled through explicit stock C compiler, library and header
packages without unused target C++ recommendations. A signed-index resolver
comparison preserves the C dependencies, stock identity and PATH guards,
and the existing twenty-minute budget; actual runner timing remains a gate
verdict rather than a claim of that simulation.

Activation review against `5d1bed296d7779a718d000baa687535a7d13d62d` includes
all unmatched rows. SR-555 retains the existing locked runtime/FHS route;
restate its trigger for a QEMU/GDB version or packaging change. SR-650 remains
for RV32 watchdog-stage validation, SR-605 for RP2350 boot-kind/hash work,
and SR-552 for script tests requiring development-shell-only tools; these
new standard-Python controls and Xtensa stages do not implement those changes.
SR-736 remains for rig failure isolation: Arty and the cascade still share a
controller. R551-07 remains for general large-image placement, SR-649 for a
physical ESP image beyond internal SRAM, and SR-637 for RV32 scratch homes;
virtual corpus RAM and Xtensa frame changes do not settle them.

SR-317 remains for handler-signature and L0506 diagnostics: the resource
margin changed without improving its convention, constraint, site-type or
error-set explanations. SR-510 remains for discovery of the fibre task-sizing
row: compact frames change costs without naming the library's private first
frame or adding per-task rows. R551-12 retains R16.20's indexed-check, Darwin
home and atomic/barrier work despite the measured Xtensa frame improvement.

Other unmatched triggers remain attached to their described behavior:
SR-266 internal-defect caller reporting; SR-289 module-value options;
SR-296 diagnostic-note citations; SR-298 installed panic-site resolution;
SR-379 hosted cross-runner children; SR-451 C-layout cascades; SR-722 generator
failure reporting; SR-721 shared subprocess hang guards; SR-685 wedged
RISC-V register capture; and SR-636 RV32 float operands or an F level.
SR-740 retains the proposed local-path notation trigger. SR-291 is restated
for named-file handling of fenced examples, SR-254 for the checker's command
line and SR-530 for citation checking: external URL recognition changes none
of those interfaces or policies.

SR-734 remains for the fixture failure's re-recording hint: the lane-description
message now names Xtensa's corpus, while that separate hint is unchanged.
SR-281 retains stale-binary detection: the comparison wrapper builds once and
records provenance without comparing an installed binary to its checkout.
SR-324 retains a common non-host assembler command: adding configured Xtensa
lanes does not change Mach-O/FreeBSD spelling or introduce that command.

### R12.60 — Boards in the gate

Status: planned
Depends on: R12.20, R12.30, R12.40, R12.45, R12.50

A self-hosted runner with the boards attached, run for `main` and by hand and
never for a pull request from a fork. This extends R12.20's first-board
readiness evidence to recurring smoke runs on every supported board.

Exit evidence: every board this phase supports runs its smoke procedure
against a device-specific physical oracle in the gate, beside the emulator
lanes it does not replace.

### R12 gate

- RP2040, RP2350, an STM32 board, ESP32, ESP32-S3 and ESP32-C run
  compiler-owned firmware on hardware, each against an oracle valid for that
  device, and their cores in emulation where QEMU has them, each against an
  oracle valid for that emulator model. The synthetic driver remains an
  emulator lane.

- Every device this phase supports is selected by a description in Landin
  source, and no compiler source names a chip.

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
(D419); no refusal repeats its own span as a secondary
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

### R13.74 — What a first stream meets

Status: complete
Depends on: R13.73

A newcomer trial of the 0.2.8 archive, guessing from C the way a streamer
reviews a language, had hello world compiled in a third of a second and
then needed five attempts to call raylib, could not print a number in one
line and found no way to run what it built (SR-420 to SR-427). This item
fixes what it met, and decides:

- Under `--link=libc`, `linker.library("NAME")` is passed to the C driver as
  `-lNAME` on every hosted target, so the driver resolves it as it would for
  C, shared library or archive. This amends D202's archive-only resolution;
  the default static link still refuses the directive (D280) (SR-423).
- `linker.directory("DIR")`, a tool directive resolved against the
  declaring file's directory, and a repeatable `-L DIR` on `compile` and
  `run` name where libraries are searched. A library the link cannot find
  is refused with the directories searched (SR-422).
- `refine run FILE [-- ARGS]` compiles to a temporary executable, runs it
  with the arguments, exits with its status and removes it. Bare
  `refine FILE` says that it only checked (SR-424).
- One call writes a template and its values straight to a file, with no
  buffered writer or flush, and the tour shows it before its first loop. An
  unknown `core/io` member spelt as another language's print, `print`,
  `println` or `printf`, is told that call (SR-426). Floating-point text
  stays SR-97's.

Without a decision: L0012 once per identifier, naming `link(symbol: ...)`
when the declaration follows `extern(c)` (SR-420); L0346 naming the record
that is not `layout(c)` (SR-421); `refine explain` resolving `[NNNN]` and
`Dnnn` to their titles and where to read them (SR-427); the released
compiler without its debug information, and the archive's size beside the
install route (SR-425); and `docs/from-c.md`'s C entry calling a mixed-case
C library linked from a directory beside the source.

Exit evidence: a runtime fixture that calls an archive built beside it
through mixed-case link names, passes a `layout(c)` record by value and
calls `sqrtf` and `pow` from libm under `--link=libc`, linked through both
`linker.directory` and `-L`; a negative fixture for each refusal above;
`refine run` cases in the test program; and the trial repeated on a release
archive with raylib 5.5, what it meets in the register.

Done: under `--link=libc` a library is the C driver's `-lNAME` on every
hosted target, so libm links as C links it (D523), `linker.directory` beside
the source and `-L` on the command line say where libraries are, each also
the executable's runtime search path (D524), and a library the link cannot
find is L0509 naming every directory searched, the SDK's on Darwin (D525).
`refine run` compiles to a private temporary directory, runs the program
with its arguments and exits with its status, and bare `refine FILE` says
it only checked (D526). `io.write_format` writes a template and its values
in one call, which the tour shows before its first loop and L0201 offers
for another language's print (D527). L0012 is one report per word, naming
`link(symbol: ...)` for a C name (D528), L0346 names the record that is not
`layout(c)` (D529), `refine explain` answers a construct or a decision
(D530), and the released compiler's debug information ships beside the
archive (D531). `runtime/c-library-directories` calls two archives built
beside it through mixed-case link names, one found by `linker.directory`
and one by `-L`, passes a `layout(c)` record by value and calls `sqrtf` and
`pow`. The trial, repeated on a release-shaped archive outside the
checkout, followed each refusal to a raylib 5.5 program that links against
raylib's shared library and starts; a window was not drawn, since the
headless host has no GLX and the same C program stops there alike. What it
met is SR-461 to SR-463.

### R13.75 — Refusals that say what to do

Status: complete
Depends on: R13.74

The register's largest group of findings was refusals that name a symptom
rather than the mistake, or name the mistake and not what to write: a
second statement under a match arm, another language's unnamed result, an
exit written as an `else` value, a failure in the hosted `main`, a type
spelt as the checker holds it rather than as the program wrote it. This item
takes the three groups the November triage rated first, parser refusals,
refusals around failures and types named in refusals, with the driver's
messages beside them. Each refusal points at the cause and says what to
write, in the code whose meaning fits; no new form is admitted, so no
accepted program behaves differently.

Exit evidence: a negative fixture for each refusal pinning its text, and a
`fixes` case for each repair that writes one.

Done: a second statement under a match arm names `begin ... end` (D860), a
type alone after `->` names `-> (result: i32)` and the function still closes
at its own `end`, as named returns without parentheses do (D861), a quoted
import path is told to lose its quotes (D862), `addr` of a measure is the
address of a value to bind first (D863) and no repair moves `lenof` (D864),
a stray `when` names the four exits (D865), and a `_` arm on a variant part
is one L0333 naming the cases left, [1210] saying where `_` stands (D866).
An exit written as an `else` value is told to stand in `else begin ... end`,
with a fix that writes it (D870); a failing call ending a body is refused for
its failure alone (D871); a failure in the hosted `main` names `else` and a
fallible helper, not an error set `main` cannot have (D872); an assignment
after `defer` or `undo` is named as one (D873); and an atom `else` filling a
several-atom pointer union names the one-atom union to recover into (D874).
Refusals spell types and concepts as the program writes them (D880), a
missing composed conformance names the parents the type has (D881), a memory
builtin given an atomic cell names the cell's operations (D882), a source
with no entry was checked as a module (D883), and a missing option value
names its values while `-g` is answered with `--debug=full` (D884). It
retires SR-264, SR-462, SR-673, SR-301, SR-440, SR-471, SR-553, SR-339,
SR-286, SR-302, SR-527, SR-696, SR-293, SR-337, SR-690, SR-262, SR-470 and
SR-651.

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

Status: complete
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

Done: `hosted/thread` starts threads as a group its caller joins, over a
backing the caller lends, with the first failure kept: `clone` and a wait
on the word the kernel clears in a static Linux program, `pthread_create`
on a stack area and `pthread_join` under `--link=libc`, on Darwin and on
FreeBSD (D494, D495, D516-D520). A thread begins with the asynchronous
signals blocked and a fault's own left open (D521), and runs on a
prepared stack whose limit is its own: `link(thread)` places per-thread
module storage, ELF local-exec on Linux and FreeBSD and Darwin's
thread-local variables, and the stack-limit cell is the thread's, a
pthread key's slot read inline on Darwin (D496, D497, D504-D508). One
report stack serves every thread behind a latch (D498), and a
`system.new()` handle records into the calling thread's last error
(D503, D509). `core/atomic` wraps one unsigned scalar with acquiring
loads, releasing stores, acq_rel read-modify-writes, a relaxed family
and `sole_add`, the single writer's update, and Cortex-M0 refuses its
read-modify-writes where they are used, naming `sole_add` and the
critical section (D500, D510, D511). A lock waits on its word through
the futex, `_umtx_op` or `os_sync_wait_on_address`, the heap is behind
it once a thread has started, and the vDSO cache is a relaxed word
(D501, D502, D512-D514). Every backend fences an atomic only as its
ordering asks, so a relaxed load on x86-64 is a plain move (D499, D522).
Executable cases publish ordinary data before a worker starts and read
its ordinary writes after the join on every hosted target and under
`--link=libc`, with no other synchronization.

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
measurement runner. A measured code-quality cost
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

A record that leaves the table is still cited by the item that closed it,
so its identity is listed below, and a citation of a record that never
existed can be told from one of a record that left. Remove a settled row
and add its identity to the following departure list in the same edit.
SR-210 to SR-213 are
the four defects a review of `main` after R13.35 numbered and fixed at
once; they were never rows.

Records that have left the register: SR-13, SR-14, SR-15, SR-16, SR-17,
SR-20, SR-22, SR-23, SR-24, SR-25, SR-26, SR-27, SR-28, SR-29, SR-31, SR-32,
SR-34, SR-37, SR-38, SR-39, SR-40, SR-41, SR-42, SR-43, SR-44, SR-45, SR-47,
SR-48, SR-53, SR-54, SR-55, SR-56, SR-57, SR-58, SR-59, SR-60, SR-61, SR-62,
SR-63, SR-64, SR-66, SR-67, SR-68, SR-69, SR-70, SR-71, SR-72, SR-73, SR-74,
SR-75, SR-76, SR-77, SR-78, SR-80, SR-81, SR-83, SR-85, SR-90, SR-91, SR-92,
SR-93, SR-94, SR-95, SR-102, SR-103, SR-104, SR-105, SR-106, SR-107, SR-108,
SR-109, SR-111, SR-112, SR-113, SR-114, SR-115, SR-116, SR-117, SR-118,
SR-119, SR-123, SR-124, SR-126, SR-128, SR-129, SR-130, SR-131, SR-132,
SR-133, SR-134, SR-136, SR-137, SR-138, SR-139, SR-140, SR-141, SR-142,
SR-143, SR-144, SR-145, SR-147, SR-148, SR-149, SR-150, SR-151, SR-152,
SR-153, SR-155, SR-158, SR-159, SR-160, SR-161, SR-162, SR-163, SR-164,
SR-165, SR-166, SR-168, SR-169, SR-170, SR-171, SR-172, SR-173, SR-174,
SR-175, SR-176, SR-177, SR-178, SR-180, SR-181, SR-182, SR-183, SR-184,
SR-185, SR-186, SR-187, SR-188, SR-189, SR-190, SR-191, SR-192, SR-193,
SR-194, SR-197, SR-198, SR-199, SR-200, SR-201, SR-202, SR-203, SR-204,
SR-205, SR-206, SR-207, SR-208, SR-209, SR-210, SR-211, SR-212, SR-213,
SR-214, SR-215, SR-216, SR-217, SR-218, SR-219, SR-220, SR-221, SR-222,
SR-223, SR-224, SR-227, SR-228, SR-229, SR-230, SR-232, SR-233, SR-234,
SR-235, SR-236, SR-237, SR-238, SR-239, SR-240, SR-241, SR-242, SR-243,
SR-244, SR-245, SR-246, SR-248, SR-249, SR-250, SR-251, SR-252, SR-260,
SR-263, SR-268, SR-270, SR-271, SR-274, SR-276, SR-278, SR-280, SR-282,
SR-283, SR-284, SR-305, SR-306, SR-318, SR-332, SR-333, SR-338, SR-343,
SR-347, SR-349, SR-351, SR-352, SR-353, SR-356, SR-357, SR-362, SR-365,
SR-366, SR-372, SR-388, SR-391, SR-393, SR-402, SR-428, SR-487, SR-488,
SR-489, SR-499, SR-511, SR-517, SR-680, SR-684, SR-691, SR-706, SR-735,
SR-737, SR-738, SR-739, SR-741, SR-742, SR-743, SR-744, SR-745, SR-746,
SR-747, SR-748, SR-749, SR-750, SR-751, SR-752, SR-753, SR-754, SR-755,
SR-756, SR-614, SR-660, SR-671, SR-672, SR-709, SR-719, SR-723, SR-724,
SR-725, SR-757, SR-758, SR-759, SR-760, SR-761, SR-762, SR-763, SR-764,
SR-765, SR-766, SR-767, SR-770, SR-771, SR-774.

| Record | Family | What stands | Activation | Completion | Status |
| --- | --- | --- | --- | --- | --- |
| R551-07 | Scale and self-hosting | Final linker placement is not preflighted: Linux RIP-relative reach, Darwin's 2 GiB static-image collision and arm64 branch reach. Merged: R730-05, thirty-six shared programs exceed the 32 KiB flash, 16 KiB RAM and 4 KiB stack profile in 148 capacity verdicts, 118 map overflows, 26 frames over the stack and 4 images over the budget, recounted when the descriptions arrived; linked again with each device's derived script and held to its build report's limits, 34 of them in 8 programs still exceed RP2040's profile, 26 frames over its 4 KiB stack, 4 RAM overflows and the 4 images over the budget, the same 34 in 8 RP2350's, 26 frames over its 4 KiB stack, the 4 RAM overflows of one program's 530,012 bytes against its 512 KiB and the 4 images over the budget, and 30 in 7 the STM32H753's, 22 frames over its 16 KiB stack and the same 8, the counts the earlier measurement from image sizes and frames gave. | Before general large-image support, or a workload that needs it. | Bounded reach and layout evidence with the native control and its status-42 oracle retained. R12.10 gave the per-device profiles (D543) and held every image to its target's reach (D537); placement is still not preflighted. | open |
| SR-580 | Language evolution | Atomic exchange, add and compare-exchange are refused on `cortex-m0` at every level: Cortex-M0's admission (D510, D690) holds no level's read-modify-write, so a Thumb-2 core's LDREX and STREX, and Armv8-M's LDAEX and STLEX, go unused, and `core/atomic`'s `exchangeable` has no conformance there. The level-dependent admission itself exists since R12.40 (D690, RV32's `a`); what is missing is the lowering. Met deciding R12.30's selection, which left it out of scope. | A program that needs a read-modify-write on a Thumb-2 core. | The exclusive loops lowered at `armv7-m`, `armv7e-m` and `armv8-m.main` by each ordering's published mapping, Cortex-M0's admission and `core/atomic`'s condition opened at those levels, and executed fixtures on the AN385 and the AN505. | open |
| SR-581 | Competitive optimization | The Cortex-M backend allocates only r0 to r7 at every level, so at the Thumb-2 levels, whose 32-bit encodings reach the high registers as they reach the low ones, r8, r10 and r12 still hold no value and every value moves through the low registers and frame homes. Left out of R12.30's Thumb-2 selection. | R16.20's register allocation, or a measured Thumb-2 code-size or speed need. | High registers allocated at the Thumb-2 levels with `armv6-m` byte for byte unchanged, and the corpus, the frame stepping and the source-debugging lanes still passing at each level. | open |
| SR-582 | Competitive optimization | A conditional transfer inverts its condition over an absolute jump at every level, and a comparison with zero is a `cmp` and a branch: Thumb-2's IT blocks and CBZ and CBNZ go unused. Left out of R12.30's Thumb-2 selection. | A measured Thumb-2 code-size need, or R16.20. | IT, CBZ and CBNZ selected at the Thumb-2 levels where their reach allows, with branch-reach controls at each level and `armv6-m` unchanged. | open |
| SR-583 | Competitive optimization | A packed field is extracted and inserted with shifts and masks at every level; Thumb-2's UBFX, SBFX and BFI go unused. Left out of R12.30's Thumb-2 selection. | A measured cost of packed register access on a Thumb-2 board. | Bitfield instructions selected at the Thumb-2 levels, with the packed peripheral traces unchanged at each level. | open |
| SR-584 | Competitive optimization | A constant MOVS cannot make comes from a literal island at every level; Thumb-2's MOVW and MOVT go unused, so a Thumb-2 image still carries the islands and the branches over them. Left out of R12.30's Thumb-2 selection. | A measured Thumb-2 code-size need, or R16.20. | MOVW and MOVT selected at the Thumb-2 levels, the literal-reach controls kept for `armv6-m`, which keeps its lowering. | open |
| SR-585 | Language evolution | D255 has no Armv8-M level with the optional DSP extension, so a Cortex-M33 that has it, as RP2350's do, builds at `armv8-m.main` and `compiler.feature.dsp` is false there, and a `cortex-m33` description admits no `armv7e-m` build either, since its DSP instructions are optional. Left out of R12.30. | A program that selects declarations by `compiler.feature.dsp` on an Armv8-M core, or a DSP instruction the backend would select. | A level in D255's table, `armv8-m.main+dsp` in GCC's spelling, holding `dsp`, admitted for a core whose description says it has the extension, with its tool arguments and an executed fixture on the AN505. | open |
| SR-586 | Usability | The Cortex-M emitter's local labels, `L3_1` and `Lcm_step_17`, are symbols in the object and the linked image, so `objdump -d` lists a routine as fragments, each label a heading of its own, and a reader looking for `main`'s instructions under `<main>:` finds only its prologue. Met when the corpus's selection check first read every routine as empty past its first label, and took each routine's extent from `nm -S` instead. | The next change to the Cortex-M emitter's labels. | Labels the listing does not split a routine at, or the lane guide saying where a routine's instructions are found. | open |
| R551-08 | Scale and self-hosting | Compact source or IR can still ask for enormous assembler repetition; small compiler output does not bound assembler memory or object size. | Before admitting larger images or generation policies. | A bounded emission policy tested on tiny shapes, with the forbidden giant-fixture boundary kept. | retired: R12.10 writes repeated runs without expansion (D536) and bounds every image before emission on every target, tested on small shapes with the giant fixture still refused (D537) |
| R551-09 | Competitive optimization | Guarded cleanups can expand quickly despite correct pop-before-run order. | A measured cleanup workload with unacceptable growth. | Selectors, effects and order preserved, with bounded size compared before and after. | open |
| R551-11 | Competitive optimization | Frame and allocation planning is repeated by preflight, emission and debug output. | Profiling justifies sharing the plans. | One immutable plan owning emission and debug locations, with debugger agreement. | retired: preflight answers from a bound on the reference frame and plans a frame only past it, and emission plans each routine once with debug output reading that plan, on every backend (D790); arm64's allocation fell from 15.5 to 6 per cent of a 16,000-declaration compile with `--debug=full`, with byte-identical assembly on all eight targets, nine profiles and both debug modes |
| R551-12 | Competitive optimization | An indexed increment can keep an extra bounds check, and Darwin still has stack homes beyond the scalar value reuse and integer register promotion already implemented. Merged: R730-04, atomic and barrier lowering is baseline, not competitive. | Measured code-quality pressure. | Single evaluation, traps, addresses, ABI and debugger evidence preserved under measured improvement. | scheduled R16.20 |
| R551-15 | Scale and self-hosting | Nix provides a development shell and a flake, and the gate's `flake` job builds the flake on every run that does not reuse a pass (D585). Nothing else is Nix CI: no derivation is cached, and the only other job that uses the flake, `rv64-qemu`, takes its emulator from it. | An explicit decision to extend Nix CI beyond building the flake. | Builders, SDK identity, debugger permissions and cache provenance accounted for. | limit |
| R551-16 | Scale and self-hosting | Stage and backend procedures nest tens of thousands of lines in one closure: the checker's `Run` 41,842, lowering's `Run` 21,022, the parser's `Parse` 12,036, the four backends' `Emit` at 6,700 to 9,200 and the verifier's `Check` 8,728. The four backends repeat their static-data emission body for body (`Folded` 497 lines, `Evaluate` 479, `Whole_Clear_Extent`, `Element_Shape_Of`, `Place_Fields`, `Emit_Children`, `Run` and `Packed`, and a dozen smaller), as do `Validate_Linkage`, `Allocate_Symbols`, `Call_Plan` and `Signature_Plan`; the driver repeats `Text_At` and `Number` in its image block, ESP image and boot stage, and the checker and its flow pass `Declaration_At`, `Tree_For` and `Written`. `Add_Module`'s `Root_Index` is stored and never read; the Arm32 ABI's `Error_Register`, `Frame_Record_Bytes`, `Call_Stack_Alignment`, `Minimum_SP_Alignment` and `Thumb_Address_Bit` and ELF's `Data_Section` and `Zero_Section` are declared while the backends spell the same values as literals. The interfaces nothing called, `Needs_Source` among them, the unused variadic-descriptor chain and the stages' duplicated construction helpers are gone, and lowering's three largest statement arms are named procedures. | Replacing or splitting the affected stage, or a change it obstructs. | Refactoring behind existing seams with strict warnings: the backends' static-data emission shared once, closures turned into parameters where a split needs it, and every listed declaration used or removed. | open |
| R551-19 | Release readiness | No mutation coverage of the driver's options, targets other than the default, several editor documents resolved as one module, or emission, linking and running of the mutants that are accepted. The frontend has source-text crash coverage: R10.50's `compiler/tests/fuzz/fuzz.py` drives the sole direct `.ldn` source of each positive, negative, runtime and ABI fixture directory, plus every reproducer, mutated with a fixed seed, through `refine lsp` with rooted imports and an imported-fixture diagnostic check, bounded per response and in memory. C companions are not executed. | Before robustness or production claims. | Fixed seeds, bounded resources, stage and target reach, crash classes and minimal reproducers, for the driver and the backends as the frontend has them. | open |
| R551-20 | Release readiness | Fake-host failure controls do not establish native device, capture or exhaustion failure paths. | Before claiming those native failure guarantees. | Controlled fault injection with cleanup and diagnostic oracles on each host. | open |
| R551-22 | Release readiness | The code face was removed from all history and the acceptance tags re-issued; only the vendored Nunito Sans remains. Its redistribution, which the pages depend on, is not settled. | Before distribution, or a font policy change. | A distribution decision keeping the private-font boundary. | retired: settled; Nunito Sans is under the SIL Open Font License 1.1, which permits vendoring, serving and redistributing it with its notice, kept as `assets/fonts/nunito-sans/OFL.txt` and named among `LICENSE`'s third-party notices, while MonoLisa stays in the private `landin-fonts` checkout and the publishing workflow refuses without it |
| R551-25 | Language evolution | Source-debug CFI is not a promise of foreign-exception unwinding. | An explicit proposal for runtime foreign unwinding. | Semantic, ABI and failure decisions, then native evidence. | limit |
| R551-26 | Language evolution | LLDB shows C scalar spellings and manual tag and payload selection, with no Landin expression evaluator. Merged: R730-12, Cortex-M0 debugging is lines and functions only. | A concrete debugger-usability proposal. | Truthful types and locations with native sessions for each new promise. | limit |
| R551-27 | Release readiness | Linux driver overrides follow the GNU contract; Darwin emits thin arm64 Mach-O, not universal binaries; no Clang header parsing. | A requested driver or distribution expansion. | Pinned producer and consumer, packaging and identity evidence. | limit |
| R551-28 | Language evolution | No callback-identity counterexample exists, and static rejection of known slice-range endpoints is not a normative requirement. | A valid counterexample or an explicit semantic proposal. | Present-contract defects go to their implementation owner; semantic changes need specification and tests. | watch |
| R551-32 | Scale and self-hosting | The whole program is compiled together on every build, the library included, and nothing is kept between builds: no stable separate compilation, interfaces or package identity in them. The scaling bound holds frontend and emission to 2.5 times per doubling. Merged: B3, whole-program checking done and stable interfaces left here. Self-hosting, split from this record, is SR-697. Kept outside the current roadmap and proposed for the next in discussion #2 (<https://github.com/JanHaan/Landin/discussions/2#discussioncomment-19369243>). | The next roadmap taking it, or a measured compile cost the scaling bound or private caches cannot answer. | Tested seams and complete interface and package identity with whole-program semantics preserved. | limit |
| R551-33 | Companion tool and ecosystem | Package acquisition, version solving, manifests, locks, naming authority, deterministic roots, generators and sandboxing; the binding generator's replacement of its four files is not atomic. Merged: B6, a naming authority keeping the project-first override [1480]; R730-08, a general SVD generator, and R730-11, a fixed firmware linker script, which R12.11's `refine svd` and R12.10's derived and developer scripts settled. | Before acquisition, general generation or concurrent build consumers are offered. | Declared inputs and outputs, immutable publication, reproducible roots, single-version conflicts and a naming policy that keeps the project-first override [1480]. R12.10 gave the derived and the developer's linker script (D545, D546) and R12.11 the general SVD importer (D555-D558). | open |
| R551-34 | Broader standard library | Library facilities beyond the prototypes' slices. Merged: R730-02, a reusable cache-maintenance interface for cached profiles (R12 requires platform providers before admission); R730-09, UART configuration beyond one baud rate; R730-21, the atomic wrapper type, which R14.40's `core/atomic` gave (D500). | A concrete program needs an omitted facility. | Capability-passed allocation and I/O, constrained-target costs, complete consumers and failure oracles. R14.40 gave the atomic wrapper, `core/atomic` (D500). | scheduled R13.20 |
| R551-35 | Language evolution | The stackful-fibre exploration. | A program needing two operations in flight. | A stackful-fibre tour amendment and register decision; stackless coroutines stay rejected. | retired: R14.20 specifies the switch (D450), makes fibres a group over a scheduler (D444) and teaches them at [1675]; stackless coroutines stay rejected |
| R551-36 | Release readiness | No production or operational claim is made, and no versioning scheme is: each release and its version designation is a maintainer decision of its own, and Landin does not assume SemVer. Licensing is decided, `MIT OR Apache-2.0` with compiled programs and linked `core/*` under no condition of `refine`'s, and so is distribution, through `release.yml`'s tagged assets. | A proposed production or operational claim, or a versioning scheme. | Each claim or scheme a separate decision with its evidence. | limit |
| R730-01 | Release readiness | Only emulators have run firmware; nothing is claimed about physical timing, bus, electrical or interrupt-arrival behaviour. | Before any physical-device or production firmware claim. | A pinned board and smoke procedure checked against a device-specific physical oracle, with shared scenario outcomes compared where their premises hold; emulator lanes stay mandatory. | retired: R12.20 ran the first pinned board against its physical oracle, with the shared scenario compared and the emulator lanes kept (D595); recurring board runs are R12.60's |
| R730-03 | Release readiness | D227's ordering trials and bounded store-buffer models are evidence, not a formal proof; no wait-free or timing bound is claimed. | Before a claim beyond the bounded models, or any timing bound. | A stated proof or checked model agreeing with the native trials. | open |
| R730-06 | Release readiness | Stack paint and SP observation are measurements, not worst-case bounds; 64 spare flash bytes is a fit, not a budget; reset assumes no NMI or fault in its window. | Before a production budget, worst-case stack or fault-tolerant reset claim. | A workload and interrupt model with a checked bound, and reset-window behaviour with executable evidence. | open |
| R730-07 | Broader standard library | Cortex-M0 C source capabilities, `platform/c` and header generation are disabled; 65 restrictions in `compiler/tests/cortex-m/corpus.json` stand there, 53 of them shared ABI fixtures that need the general C surface. | A freestanding program that must call or be called from C. | An ILP32 `platform/c`, Cortex-M0 C signatures, generated bindings from a pinned device C header under a checked Cortex-M0 ABI, and executable firmware fixtures using the generated declarations and adapters with failure oracles; those restrictions re-decided. R12.30 gave the AAPCS32 VFP variant's planner beside the base one, checked against GCC's hard-float build (D616). | scheduled R13.20 |
| R730-13 | Release readiness | Source and debug identity selection is matching, not authentication or protection against concurrent replacement. | Before stronger provenance or attestation claims. | An attestation design with verified restore; the seven negative selections stay. | limit |
| R730-17 | Language evolution | A call returning a plain pointer cannot fill a several-atom pointer union through an atom `else`; D235 keeps it refused. | A program that needs that recovery to widen. | D235 amended with a recovery lowering and evidence on every target. | open |
| R730-20 | Language evolution | D237 leaves u128, i128 and f16 out. | A program that needs 128-bit arithmetic or binary16 values. | D237's recorded plan on every target. | open |
| R730-23 | Release readiness | A linked hosted image is not bit-reproducible: the GNU driver writes a random temporary object name, six bytes. | Before a reproducible-distribution claim. | Byte-identical images on both hosted targets, with the assembly-identity check kept. | retired: every hosted ELF target's assembly names its file symbol `landin` (D810), so GNU ld names none after the driver's temporary object; `test_determinism.py` requires identical images from two directories on Linux x86-64, Linux arm64 and Darwin, and keeps the assembly-identity check |
| R730-24 | Competitive optimization | Build-report counters are filled differently per backend, so a cross-target comparison from them is unsafe. | Before any cross-target code-quality comparison from the report. | Every declared counter filled on every backend, or the report saying which it does not measure. | retired: every backend fills every counter with one meaning, sites counted over the final text (D791) |
| B4 | Companion tool and ecosystem | Package, build and generators beyond the thin pieces the compiler owns; R551-33's. | As R551-33. | As R551-33. | open |
| B5 | Broader standard library | The standard library beyond the `core` modules `core/README.md` lists; R551-34's. | As R551-34. | As R551-34. | scheduled R13.20 |
| D6 | Companion tool and ecosystem | One version of a package name per program [1470]; the compiler's first-root rule is done and arranging roots is the tool's. | Before acquisition or root arrangement is offered. | Roots arranged so one version is reachable, a conflict a hard error. | open |
| C1 | Language evolution | Affine values, which would change [0910]'s non-ownership `sink`. Merged: R730-10, the derived driver's device authority, descriptor linearity and stop are manual obligations. | A peripheral or resource program unpleasant without them. | [0910] amended with a register decision answering R730-10's obligations, on every target. | open |
| C2 | Language evolution | Conformances as named values. | Conformance collisions hurting in real libraries. | A register decision weighed against retained position D2, with library consumers. | open |
| C3 | Language evolution | A checkable host-authority boundary for call trees [1680], including whether root minting should be restricted to the entry module. D258 keeps public constructors: provider arguments support substitution for uses of those providers, but do not prove host exclusion. | A trusted-code case needing static host exclusion or reliable provider substitution without auditing its call tree, or a need to run untrusted code. | [1680] amended with a register decision and executable evidence for the chosen boundary, accounting for constructors, foreign calls and freestanding address literals rather than treating entry-module restriction alone as isolation. | open |
| C4 | Language evolution | Generational observers and inferred uniqueness; no trigger was ever given. | None until later evidence supplies one, recorded first. | That trigger recorded, then a design with its own evidence. | open |
| C5 | Language evolution | Structure-of-arrays collections [0620]. | A simulation program needing one field contiguous. | [0620] enabled by amendment and register decision, with executable evidence. | open |
| E1 | Language evolution | Labels, `break with` and `complete` are implemented and none of the four derived programs uses them. | A proposal to remove or reshape them, with evidence beyond non-use. | A tour amendment and register decision. | watch |
| E3 | Language evolution | Three kinds of generated source exist: SVD modules, C bindings, and `platform/linux/numbers`, which `scripts/linux_syscalls.py` generates from Linux's system-call tables. A third kind starts the review of retained position D3, and that review is not recorded. Generating the compiler's transcription tables from `spec.md` would be a fourth. | Now: the third kind exists. | That review recorded against D3's rationale. | open |
| SR-01 | Release readiness | The Cortex-M lane pins `arm-none-eabi-gcc` 14.2.1; the same publisher's `arm-eabi-gcc` 16.1.0 builds a valid image, and moving changes every recorded firmware hash and disassembly. | R12's new cores rebaseline the firmware records anyway. | The toolchain moved with every Cortex-M record rebaselined in one change. | retired: R12.10 moved the lane to GNAT's arm-elf GCC 16.1.0 and rebaselined every Cortex-M record in one change (D532) |
| SR-03 | Language evolution | A module value cannot hold `addr` of storage: [1940]'s known values are numbers, and a static address is a data relocation no backend emits. L0305 refuses it and its note says why; this record is the construct's only owner. | A program needing a static pointer: a vector table it owns, a table of pointers into module storage, or a statically linked structure. | [1940] amended with a register decision, data relocations emitted on every target, and `negative/r491-construction-static-address` turned into executable fixtures. | open |
| SR-625 | Usability | Adding the `rv32` target meant finding every hand-written list of what a target is: the `compiler.arch` atoms are spelled out as string alternatives five times in `landin-stages-configuration.adb` and once in `landin-stages-resolution.adb`, the `compiler.c_*` fact names four times across `landin-stages-configuration.adb` and `landin-configuration.adb`, the driver keeps its own target-spelling list and identity text beside `Landin.Targets.Selection`, and two discussion templates list the targets again, which `check.py` compared only when a name had a hyphen, so `rv32` was first read as prose; only the compiler's missing-case errors and `check.py`'s template comparison named any that was missed, and the rest were found by search. Met adding RV32 for R12.40. The first fixture to name `targets: rv32`, the atomics' refusals, met four more: the fixture harness's `Is_Named_Target` and the fixture suite's `Facts_Named`, `check.py`'s own set of known targets, and the target applicability register in `compiler/tests/registers.md`, from which `check.py` takes the targets a fixture may name; `check.py` named the last two, and only by calling the fixture's target unknown. A runtime fixture written for `rv32` met a sixth: `scripts/add_fixture.py` refused `targets: rv32` as an unknown target, so `runtime/library-platform-riscv` names `cortex-m0` and reaches the RV32 lanes through the Cortex-M inventory; the list was `compiler/tests/fixture_meta.py`'s `TARGETS` and `FAMILIES`, which also failed the gate's scripts job on the first `rv32` fixture, and the close added `rv32` there. | The next target or fixed fact, R12.50's Xtensa first. | One table of architectures and their atoms, and one of fixed facts, in the compiler, each list derived from it and the driver's spellings read from `Landin.Targets.Selection`. | retired: one table of architecture atoms (`Landin.Targets.Atom`) and one of fixed facts (`Landin.Configuration.Fact_Name`), every Ada list derived from them, the driver's spellings and identity and the harness's targets and levels read from `Landin.Targets.Selection`, and `fixture_meta.TARGETS` and `check.py`'s known targets parsed from its `Described_Name`, with `FAMILIES` held to `Landin.Targets.Levels` |
| SR-626 | Usability | `environments/cortex-m`'s harness read every `devices` record of `descriptions.json` as an Arm device it builds and links, in `backend.py`, `backend_corpus.py`, `descriptions.py` and `test.py`, so recording the RV32 reference there, where its lane reads it, would have failed every Cortex-M lane; nothing in the file or its README said a record is one target's, and two readers now pass over a record that names another `target`. Met recording the RV32 reference for R12.40. | R12.40's RV32 lane. | The record's `target` documented in the README beside the lanes, and every reader selecting by it rather than by omission. | retired: every record in `descriptions.json` names its `target`, each reader selects by it and refuses a record that names none, and the README beside the lanes says so |
| SR-10 | Language evolution | D145 refuses a module static image of `any C`: D147's data-pointer/table-pointer pair needs two relocations, beyond SR-03's single static `addr` value. | A program needs a preinitialized module `any C` value, such as a static dispatch registry; take on SR-03's data-address relocation work too if it is still open. | D145 and [1940] amended with a register decision for static construction; an image containing both the data address and the selected flattened-table address emitted on every target, with executable fixtures for a module binding, an aggregate field and a copied image on 32- and 64-bit targets. | open |
| SR-05 | Broader standard library | `core/text` works on `utf8` as a whole but not from inside it. Traversal yields scalars and hides its byte cursor, and no search returns an offset, so zero-copy ranges around a found character cannot be written; D249 makes an index a decoded `u32`, and turning scalars back into text is a hand-written encoder into a caller buffer. `core/text`'s builder now appends into a caller buffer, but it finishes as bytes rather than a `utf8` view and appends no scalar. | A consumer that splits, searches or builds `utf8`. | A traversal or search yielding byte offsets beside scalars, a scalar encoder, and a builder over a caller buffer that appends scalars and text and finishes as one `utf8` view without revalidating, each with its consumer. | scheduled R13.20 |
| SR-06 | Language evolution | An XMOS xcore.ai target, XS3: hardware threads, channels and ports timed to the cycle, on which XMOS now recommends C over its own concurrent XC. Its compiler is proprietary, but the public XS3 architecture manual gives the instruction encodings, the XE executable format is specified to the byte, XMOS publishes the source of its BinUtils and XGDB, and AXE, an open XS1 emulator, exists unmaintained. Unsettled: the XTC tools licence, whether the published BinUtils and XGDB work without the proprietary tools, and a load and debug path that avoids the undocumented XTAG protocol. | R14's execution model settled, and an xcore.ai board in hand. | A backend emitting XS3 and packaging XE itself or through the published BinUtils, the corpus on an open emulator lane in the gate, threads and channels mapped through R14's model, and a recorded board run; no timing claim rests on an emulator. | open |
| SR-07 | Language evolution | A Microchip dsPIC33A target: a 32-bit signal controller with a DSP engine and double-precision FPU, sold for the motor and power control TI's C29 serves, where the C29's instruction set is under NDA and its tools forbid reverse engineering. The dsPIC33A Programmer's Reference Manual is public, the XC-DSC assembler, linker and compiler are GPL ports of the GNU tools with published source, and every XC licence is free; no LLVM backend reaches it. Its program and data memories are separate, which no Landin target has had. Unsettled: whether the published source builds a toolchain that runs without MPLAB X, an emulator outside MPLAB X's proprietary simulator, and an open debug path through the on-board debugger or a PICkit. | An open emulator or instruction-set simulator for the dsPIC33A, written from the manual or found, and a Curiosity board in hand. | A backend emitting dsPIC33A for the GNU assembler and linker built from the published source, separate program and data memory decided in `spec.md`'s register, the freestanding corpus on that emulator in the gate, and a recorded board run. | open |
| SR-08 | Scale and self-hosting | D247's 16,384-declaration routine bound limits the measured cost of origin tracking, but the reference pass still stores per-declaration derivation bits with quadratic growth. Branches and loops share unchanged facts; the representation within each fact remains dense. The separate 16,384-field struct bound has a different cause. Measured again in R13.61: `scaling.sh`'s locals family peaks in checking, which grows from 61 to 141 MiB and from 0.10 to 0.28 s of processor time between 8,000 and 16,000 locals, so its peak-memory ratio was 2.45 against the 2.5 bound, its 16,000 point unchanged since R13.60. Met again in R13.70: the locals family's frontend grew 2.52 times from 8,000 to 16,000 and failed the gate's scaling job, the reference pass's joins ORing every derivation byte; a join now reads only the bytes between a fact's lowest and highest local, which took the checking stage at 16,000 locals from 0.27 to 0.20 s, but copying and comparing a fact still costs the routine's size. | A real routine needs more than 16,384 declarations, or measured origin storage for a routine within the bound is unacceptable on a supported host. | Replace the reference pass's dense derivation bits with sparse storage, preserve origin and borrow verdicts across branches and loops, and measure storage and scaling on generated routines at and beyond the current bound. Raise or remove the routine bound only to the extent those measurements support, updating D247 and its size-bound test; leave the struct field bound independently justified. | limit |
| SR-09 | Competitive optimization | D248 fixes every assembly block as a read/write, call and trap boundary; no block can promise a narrower memory effect. | R16.10 or later measurements show a material code-quality cost caused by that fixed effect in a concrete assembly workload. | Record the baseline and the attributable cost, then decide whether a narrower effect is warranted against D248's critical-section rationale. If adopted, amend [1630] and D248, preserve the conservative default, and show IR and backend correctness plus measured improvement on the affected targets; otherwise record why the fixed effect stands. | watch |
| SR-11 | Language evolution | No Fortran calling convention is specified or scheduled. R13.73's trim of the tour took direct Fortran interop out of [1570]'s candidates, so this record is the idea's only owner. The enabled foreign boundary is `extern(c)`. | A concrete program needs to call or expose a Fortran procedure whose required signature cannot use the C boundary. | A decision in `spec.md` and an amendment to [1570] define the supported Fortran ABI and type subset; calls and callbacks run against a pinned Fortran producer on every host claimed, with negative cases for unsupported signatures. | open |
| SR-12 | Language evolution | No Swift calling convention is specified or scheduled. R13.73's trim of the tour took direct Swift interop, with its separate error channel, out of [1570]'s candidates, so this record is the idea's only owner. The enabled foreign boundary is `extern(c)`. | A concrete program needs direct Swift calls or callbacks, including error transport, that cannot use the C boundary. | A decision in `spec.md` and an amendment to [1570] define the supported Swift ABI, type subset and error mapping; calls, callbacks and failures run against a pinned Swift producer on every host claimed, with negative cases for unsupported signatures. | open |
| SR-33 | Usability | A runtime fixture cannot report a status from inside a panic handler, so the trap dispatch fixture shows the handler saw the right kind and site only by re-entering it on a match and spinning otherwise, which a missing dispatch would also satisfy as a trap. Met in R14.20: `runtime/stack-exhausted-reaches-the-handler` reports its handler's verdict as `main`'s status by having the handler resume the context `main` saved (D462), which works on firmware too but only on targets whose backend emits the stack builtins, and only from a fibre. R12.30's `runtime/checked-products-of-arguments` reports its first overflow the same way, at `armv7-m` and `armv8-m.main` too. | The next trap fixture that cannot resume `main` through D462, or a portable way for a handler to report. | A portable way for a handler to report, on firmware too, used to pin dispatch exactly. | open |
| SR-35 | Usability | The mutation campaign's one-report-on-the-line share is 90.5% against a 90% bar. The largest misses are reports one line from the mistake: a deleted `end` or value reported on the next line, and missing tokens the parser meets on the next line, some genuinely ambiguous. | A frontend change that moves the share, or the next work on the parser's recovery. | The share raised with margin, or the bar's meaning restated for the ambiguous cases. | watch |
| SR-46 | Competitive optimization | An immutable module `bool` is loaded from memory rather than folded, so `return when baseline` kept a whole check routine in a baseline image until the check was split per level. An immutable module `usize` is reloaded the same way at `--optimize speed`: `word: usize = sizeof usize` in `core/mem` is read from memory in every loop, and `3 * word` becomes a run-time `mulq`. | A measured image or hot path holding a foldable module constant. | Immutable scalar module values folded at their uses, with an image comparison. | retired: R13.61 folds a read of an immutable module value, `bool` and `usize` among them, and the arithmetic and checks that become constant |
| SR-51 | Usability | `examples.md` shows every hosted item's consumer, everyday tools first since R13.73, but R13.35's, which loads libraries a fixture builds: the outside-user lane links statically and assumes no C compiler, so it cannot run there honestly. | An outside-user lane that links with `--link=libc` and has a C compiler, or a published example of loading that needs neither. The stock outside-user lane has had both since R13.74 (D523, D524). | Each hosted item's consumer published in `examples.md` and run by the outside-user lane. | open |
| SR-79 | Usability | A gate's `darwin-host` build failed at the bind with gnatbind's "error: disk full" writing the binder's generated main on a macOS runner guest with 37 GiB free, after three passes of the same job there. GNAT reports any short write as "disk full", so the message sent the investigation to clean disks that were not full; the cause is unknown, and the root runner service's open-file limit of 256 is unconfirmed. `scripts/build.sh` now reports the free space and open-file limit beside the message. | The next "disk full" from a build, read with the space and limit it reports. | The cause named, and either removed from the runner or reported by the build in its own words. | retired: met only on a registered macOS runner, and those are retired; `scripts/build.sh` still prints the free space and open-file limit beside GNAT's "disk full", so a recurrence on a hosted runner is read with them. |
| SR-82 | Broader standard library | `platform/linux` gives every Linux system call by number with one raw call that takes and returns integers, and typed wrappers only for the calls the library itself uses; a program calling anything else converts its own pointers, flags and structures, and the checker sees none of them. | A consumer that needs an unwrapped call, or a proposal for a complete Linux binding. | A typed wrapper for each call, generated with the numbers or written, with its flags and structures and their layouts checked per architecture. | open |
| SR-86 | Usability | A second `io.terminate_path` into the same scratch silently re-points a path still in use, because a fresh `[]mut` view of the scratch is not an `inout` use of it, so the checker does not see the first path's borrow end. | The next change to `core/io`'s paths or to the borrow rules for `[]mut` views. | Either the second terminate refused while the first path lives, or a path form that cannot alias. | retired: `io.terminate_path` no longer exists, since R13.18 made paths host strings (D299) |
| SR-96 | Broader standard library | `core` has no math functions: `f32` and `f64` have the language's arithmetic and nothing more. The first `core/math` is written in Landin, so its results are the same on every target, with `sqrt` and `fma` as instructions where IEEE makes them exact and the other functions ported from a permissively licensed implementation, musl's and FreeBSD's msun or CORE-MATH, and tested against MPFR's values; it is known to need tuning for speed and accuracy after that. | The first consumer that needs a math function, or a numeric workload. | `core/math` with its functions' accuracy stated and pinned, and the tuning left measured rather than assumed. | open |
| SR-590 | Usability | A program that imports no description cannot be built against one unchanged without knowing two things nothing says: an extra source file holding `import descriptions/NAME` joins the entry module when it is named beside the program's own files, and a rooted program must then be named by its directory's `.ldn` files, since `--root=DIR DIR other.ldn` is L0002, "a rooted request names one entry-module directory, or the entry module's source files", which does not say the files form is the way to add one. Met building R12.30's mps2-an500 corpus lane, whose `lane_inputs` in `environments/cortex-m/backend.py` does both. | The next change to how a request names a description it does not import, or to L0002's text. | A documented way to build an existing program against a description, or L0002 naming the files form when a file is given beside a directory. | open |
| SR-591 | Release readiness | refine's soft-float Cortex-M assembly declares no `Tag_ABI_FP_number_model`, and the linker compares `Tag_ABI_VFP_args` only between objects that both declare one, so a soft-float refine object links silently into a hard-float image and its floats go to the wrong registers, while a soft-float GCC object is refused. R12.30's hard-float output declares IEEE 754 and VFP arguments; the soft-float output was kept byte-identical. | The next change to the Cortex-M assembly header, or a mixed-object consumer. | Soft-float objects declaring their number model and base arguments, with a refused mixed link in both directions. | retired: soft-float Arm assembly declares the IEEE number model and base arguments, as GCC's soft-float object does (D780); `firmware.py`'s float-unit case refuses each mixed pair in both orders |
| SR-592 | Release readiness | `runtime/r420-list-real-exhaustion`, `runtime/r420-map-arena` and `runtime/r420-pool-provider` are sized for 64-bit pointers, `sizeof padded_slot == 24` and arenas exhausted at 64-bit extents, so on Cortex-M they fail their oracles; the constrained reference's map never held them, so no Cortex-M lane ran them until R12.30's mps2-an500 lane, where they carry a lane restriction that the lane still requires to fail. | The next change to these three fixtures, or an M7 or RV32 counterpart of them. | 32-bit counterparts in `compiler/tests/cortex-m/cases` with their own expected values, executed on the M7 lane, and the restrictions removed. | retired: 32-bit counterparts of the three fixtures execute on the M7 lane at every profile and the lane restrictions are removed; on the reference, the M33 and both RV32 lanes their images remain limits |
| SR-593 | Language evolution | Only `fpv5-d16` is a float unit refine builds. The Cortex-M33 of RP2350 and mps2-an505, and single-precision Cortex-M4 and M7 parts, have `fpv5-sp-d16` or `fpv4-sp-d16`: hard float with f32 in the VFP bank and f64 still in software helpers under the VFP variant, which needs the helpers' base-PCS transport beside banked f32 and a level per unit. | A consumer on RP2350 or another single-precision part that wants hardware f32. | Those units as description facts with their cores and levels, f64 helpers called across the VFP variant, and execution on an emulator lane with each. | open |
| SR-594 | Language evolution | A float unit always selects hard float. `softfp`, the unit's instructions with the base PCS's core-register transport, which links with soft-float objects, is not offered. | A consumer that must link soft-float objects on a part with a unit. | A decision whether to offer it, and if so the transport and its contract rows. | open |
| SR-595 | Release readiness | No debugger session runs on mps2-an500: the GDB lanes and source debugging stay on the micro:bit and the AN385, so a debugger's view of VFP registers, of the d8-d15 a switch or a framed routine saves and of an extended exception frame is checked only by the corpus's sentinels and the firmware lane's `float-unit` case, not by unwinding. | The next change to the Cortex-M debugger lanes, or a float consumer debugged on a board. | GDB sessions on the M7 lane that read banked arguments, saved d8-d15 through the CFI and unwind across an extended frame. | open |
| SR-596 | Competitive optimization | With a float unit every f32 and f64 operation loads its operands from their homes and stores its result through r6, two to five instructions each beside the one VFP instruction, and a comparison branches where an IT block would do; no float stays in a register between operations. Nothing is measured. | A float-heavy Cortex-M workload or benchmark. | A measured float selection that keeps values in VFP registers across operations, or the cost recorded as acceptable. | open |
| SR-97 | Broader standard library | Floating-point values are neither written as text nor parsed: R13.19's formatting covers integers. Writing the shortest text that reads back exactly, and parsing correctly rounded, is real work and costs flash on Cortex-M0. The Benchmark Game's n-body and spectral-norm print nine decimal places and k-nucleotide three, which is fixed-precision writing, a different and smaller algorithm than the shortest round trip. | The first consumer that writes or reads a floating-point value, or `core/math`. | Shortest round-trip writing, correctly rounded fixed-precision writing and correctly rounded parsing, with their size on the Cortex-M0 profiles measured. | open |
| SR-98 | Broader standard library | There is no locale or Unicode beyond `utf8`'s validation and traversal. Done properly, a locale is an explicit value named by a BCP 47 identifier, never global state, with the host reporting the user's; its data is generated from a pinned CLDR release into modules a program uses only in part, as ICU4X does; and the work comes in phases: Unicode properties from the character database, case mapping, normalization and segmentation, then numbers and dates by locale, collation, and time zones from the IANA database, read from the host or carried. | The first consumer that formats for a person's locale, or a time zone. | The first phase's data generated from a pinned release with a checked generator, and a consumer formatting in two locales. | open |
| SR-99 | Broader standard library | No library resolves a host name. `getaddrinfo` is a C library service, not a system call: glibc reads `nsswitch.conf`, `hosts` and `resolv.conf` and may load NSS modules, Darwin asks its resolver daemon, and FreeBSD's C library resolves itself. A resolver library uses the system's where it is authoritative, the C library on Darwin and FreeBSD, and on a static Linux program its own, reading `/etc/hosts` and `/etc/resolv.conf` and speaking DNS over UDP and TCP, with configured NSS modules needing `--link=libc`. | The first consumer that connects by name, after R13.33. | The resolver on every hosted target with failure oracles: an unknown name, a name only `/etc/hosts` knows, and a server that does not answer. | open |
| SR-100 | Broader standard library | There is no regular-expression library. It is its own library, outside the hosted layers: linear-time automata without backreferences, so no pattern can make it run away, compiled when the program runs with its allocator passed, and freestanding. | The first consumer that matches a pattern. | The library with its linear time pinned on adversarial patterns, on a hosted target and Cortex-M0. | open |
| SR-101 | Broader standard library | Nothing loads self-contained code into a process: freestanding position-independent C, built `-ffreestanding -nostdlib -fPIC`, or Landin with C-ABI entry points, whose imports the host provides. A loader would have a format-neutral core that maps, relocates, binds each import to a function the host exports, runs initializers and finds exports, with ELF first, then Mach-O, registering a file's signature as Darwin's own loader does, and PE; it works whether or not the host links a C library, and needs no C library in the loaded code. Code that uses a statically embedded C library's process state, musl's thread block among it, is outside it. `refine` would also need to emit a self-contained shared object with C-ABI exports. | A consumer that loads plugins without the system's libraries. | The loader and the driver output on Linux, FreeBSD and Darwin, with failure oracles: an unknown relocation, an import the host does not provide, and an unsigned object on Darwin. | open |
| SR-110 | Usability | A helper returning a memory world over module-level buffers is refused with L0316 (D222), and its note, "pass each alternative as an explicit source", cannot apply to static storage, so a fixture repeats the construction three times instead. | The next change to L0316's note or to static origins. | A note that fits static sources, or the helper admitted. | retired: the note fits static storage after all: a helper taking the module buffers as `[]mut u8` parameters, `-> (host: io.memory from state, output, errors)`, checks clean, and D222 rightly refuses writable module buffers hidden behind `from state` alone |
| SR-120 | Competitive optimization | A static Linux program spawns a child with a `clone` that shares nothing, a `fork` that copies the parent's page tables, so a large parent pays for every spawn. A spawn with `CLONE_VM` and a stack of the child's own is expressible since R14.40's naked `clone` for threads (D516), and is not built. | A consumer spawning from a large process, or a measurement. | A spawn that does not copy the parent, measured against `fork`. | open |
| SR-121 | Broader standard library | Darwin has no `pipe2`, so `posix.pipe` sets close-on-exec with `fcntl` after `pipe`, and a thread spawning in between leaks both ends into its child. Darwin's sockets have the same window since R13.33: `fcntl` follows `socket` and `accept`. | Threads, R14.40. | Pipes and spawning made safe beside threads on Darwin, with a fixture. | retired: Darwin's `spawn` asks for POSIX_SPAWN_CLOEXEC_DEFAULT, so no descriptor it does not give the child reaches a program `platform/posix` starts however and whenever another thread made it, pipes and sockets alike, which `runtime/thread-spawn-leaks-no-descriptor` pins on every hosted target with four pipes made with no close-on-exec flag at all (D503); the window is left only to a C library's own `exec`, which is the C code's |
| SR-122 | Release readiness | Every gate job downloads `actions/checkout` from GitHub, and in three consecutive R13.31 runs GitHub answered some of those downloads with 429 Too Many Requests after three attempts, failing `cortex-m` or a FreeBSD emission job before it ran anything; a failed emission job also skips every FreeBSD execution job, so a whole platform went untested and each run had to be repeated. | The next gate run lost to it, or a change to the runners. | The self-hosted runners serving actions from a local cache, or the workflow retrying a rate-limited download, so a gate verdict no longer depends on GitHub's download limit. | retired: measured again on the GitHub-hosted runners from 2026-10-16T14:57Z to 2026-10-17T20:03Z, 56 runs, 999 job logs and 1,861 action downloads, with no 429 and no retried download; the 429s came from the registered runners, whose jobs shared their hosts' addresses. Reopen on the next gate job lost to a rate-limited download |
| SR-127 | Competitive optimization | The x86-64 backend emits `mfence` before and after every atomic operation whatever its ordering, so a relaxed atomic cost about 50 ns more a clock read than a plain word, and the vDSO cache stays a plain word. | Threads, R14.40, or the optimization phase. | Fences chosen by ordering, measured. | retired: R14.40 lowers every atomic by its ordering on each backend (D499, D522), and a relaxed load on x86-64 is one `mov`, 0.9 ns a read in a loop against 49.5 before and 0.6 for a plain word; the vDSO cache's relaxed word is D502's |
| SR-135 | Competitive optimization | `hosted/heap` reads and writes each block's header a byte at a time, because a header may be misaligned, and an allocation-bound program pays for it: a profile of the Benchmark Game's binary-trees at depth 15 puts `load_word` at 20 per cent and `store_word` at 18, `class_of` at 8, and the program's own routines under 7; depth 21 takes 4 minutes 4 seconds at `--optimize speed`, 655 MB at its peak. A `core/region` over the heap adds a 16-byte ledger record to every allocation, and freeing each node directly instead was 29 per cent faster at depth 16. Hand-measured on 2026-10-15: header words read and written through `ptr usize`, with the header pair placed word-aligned below the block and the `unit - 1` slack dropped when the unit divides 16, took depth 16 from 5.67 to 3.66 seconds and a node's slot from 64 bytes to 32, so depth 21's peak fell from 655 MB to 385 MB, against C's 257; the misalignment the heap's comment gives as the reason is its own placement, not a language constraint. The region ledger maps and unmaps every block over 4 KiB as it doubles, 14,500 of each at depth 16, and chaining fixed 4 KiB ledger blocks took 3.66 seconds to 2.89. | The next `hosted/heap` change, or a measured allocation-bound workload. | Headers read and written as words, with binary-trees measured before and after. | retired: R13.60 reads and writes the headers as aligned words, and binary-trees was measured before and after |
| SR-146 | Competitive optimization | The x86-64 backend aligns no routine entry, so code shrinking anywhere moves the hot routines after it: with `store_word`, `load_word` and `class_of` byte-identical, binary-trees at `--optimize size` ran 4 per cent slower, 5.71 to 5.96 seconds at depth 16, reproducibly, only because earlier copies got shorter. A time baseline therefore moves by a few per cent with unrelated changes. Met again in R13.61, where it cost reverse-complement 22%: larger routines put its hot loop and two callees 4 KB apart, contending for Zen 2's decoded-instruction cache; and copying an unchanged executable moved a timing by up to 50% with where its code landed in physical memory, so one executable's time is no baseline. | R16.10, whose time tolerances meet the same noise. | Routine entries aligned at `speed`, or the baselines' tolerance justified against layout noise measured on the same workloads. | retired: R13.61 starts every routine on a 64-byte boundary at speed and aligns a loop head reached only by a jump to 32 bytes, and reverse-complement runs in 0.78 seconds rather than 1.00; baselines still need several fresh copies of each executable, which R16.10 measures |
| SR-154 | Competitive optimization | Scalar replacement of slices and small structs, written and verified on the local branch `perf3-sroa` (an IR pass before simplification, `DW_OP_piece` locations, a verifier rule and a fixture), saved under a quarter of a per cent of the five Benchmark Game ports' instructions on top of R13.60's allocators and cost about 17 per cent of compile time at `--optimize speed`, so it was left out; a loop narrowing a local slice and updating a local struct saved 14 per cent of its instructions with it. | A measured workload whose hot loop keeps a local slice or small struct, or inlining exposing caller aggregates. | The pass merged with that workload measured before and after, and its verification shared with simplification's. | retired: R13.61 splits slices and small structs inside simplification's own verification, and the lexer runs 18 per cent faster with it |
| SR-635 | Usability | `u64(1.0e18)` is 999,999,984,306,749,440, not 10^18: a float literal with no context is an f32 ([0210], D162), so a conversion's operand is rounded to 24 bits before it is converted, and nothing says so; writing `big: f64 = 1.0e18` first gives the exact value. Met writing R12.40's RV32 conversion checks, whose expected values were off by the rounding. | The next item that touches literal typing or conversion diagnostics. | A note, or a refusal naming `f64(...)`, when a float literal's conversion to an integer would differ at f64, or the default documented where conversions are taught. | retired: L0350 refuses an untyped float literal's integer conversion that its f32 rounding changes (D760), and the tour's [0310] says the literal is f32 |
| SR-636 | Usability | On `--target=rv32` a float assembly operand is refused as "a float assembly operand needs a float register, and the constrained reference profile has none", Cortex-M's wording, which suggests that another profile would have one; no RV32 level has a float register at all (D660). Met checking R12.40's RV32 assembly text. | The next item that touches assembly operand diagnostics or an RV32 level with F. | The refusal saying that rv32 has no float registers at any level, and what to write instead. | open |
| SR-637 | Competitive optimization | RV32's frames reserve a home for every fixed scratch register a routine might save, 44 bytes, although D678 prunes the saves a routine's text never names after its frame is laid out, so a frame is up to 44 bytes larger than its saves need; with eight-byte homes and sixteen-byte rounding RV32's frames are 1.1 to 1.35 times Cortex-M0's, and seven corpus programs overrun the reference's 4 KiB stack. | A firmware program whose stack the reservation decides, or R12's lanes asking for a smaller stack. | The frame laid out after the text that decides its saves, or the saves predicted before it. | open |
| SR-156 | Scale and self-hosting | Every routine of every imported module is lowered, simplified, emitted and assembled whether or not the program can call it: lowering prunes unused module data but counts a routine's body as a use "whether or not that routine is itself used". A ten-line hello-world over `core/io` emits 546 routines, 69,178 lines of assembly, among them `network_listen` and the memory world's `scripted_fill`, of which `--gc-sections` keeps 34 in a 9.6 KB executable. Lowering, emission and the assembler take about 0.8 s of its 1.16 s release compile at `--optimize speed`, which is why every Benchmark Game port costs about 1.2 s however small it is, against 0.09 s for C and 0.23 s for Rust. | The next compile-time item, or R16.10's benchmarks. | Routines reachable from `main` (calls, evidence tables, routine values, link symbols, placements and `assembler.block` text) the only ones lowered, with hello-world's compile measured before and after. | retired: R13.60 lowers only the routines a program can reach, and hello-world emits 64 routines rather than 546 and compiles in 0.64 seconds rather than 1.18 |
| SR-157 | Scale and self-hosting | About a fifth of a release compile is GNAT runtime work rather than compiler work: a `perf` profile of hello-world's compile puts 14% in abort deferral and exception-state lookups around controlled container references, 5% in `Ada.Tags` external-tag hashing from the ten generic container instances that `Landin.Stages.Checking.References` and `.Flow` declare inside `Check_Function` and so elaborate on every routine they check, and 12% in `memmove`, a third of it from the IR verifier. | The next compile-time item. | Container instances at library level and element access that elaborates no controlled reference on the hot paths, with the profile measured before and after. | retired: R13.60 reads tables through `Element` and elaborates the checker's container instances once, and hello-world compiles in 0.63 seconds rather than 1.24 with byte-identical assembly |
| SR-167 | Usability | `refine check` refuses `--link`, so `compiler.c_runtime` is false when checking on Linux and a program that asserts it cannot be checked; `compile --dry-run --link=libc` is the route nothing names. | The next driver item or change to `compiler.c_runtime`. | `check` taking `--link`, or its refusal naming the dry run. | retired: R13.71 gave `check` `--link`, so a program asserting `compiler.c_runtime` checks as it compiles |
| SR-179 | Release readiness | The debug and release `refine` built from one tree emit different assembly at `--optimize none` for `cortex-m/cases/utf8-ordinal-out-of-range-traps`, on every target: `subq $720` against `subq $736` on x86-64. Each build is deterministic alone, and the determinism manifests compare debug compilers only, so nothing catches it. Met in R13.61. | Now: the release compiler is what users run. | The two builds emitting identical bytes for the corpus, held by a check. | retired: R13.61 sequences the emissions Ada left unordered in `Lower_Utf8_Index`, and the `build-modes` gate jobs hold the two builds to the same bytes over the corpus |
| SR-195 | Release readiness | The Cortex-M shared-GDB session failed twice in about 2,800 sessions on a loaded host with "Remote replied unexpectedly to 'vMustReplyEmpty': vCont;c;C;s;S" and passed when rerun. Met again in R13.72: one backend-corpus session failed the same way while other streams ran QEMU on the host, and passed when rerun. | Its next failure in a gate run. | The cause named and removed, or the session retried with the reason. | watch |
| SR-196 | Language evolution | Under D145 a closed program refuses an erased call with L0342 when no conformance can answer it, although no such value can exist; the refusal names D145 and no remedy. It kept the arena in `core/mem` in R13.70: as its own module, every program importing `core/text` but no allocator would be refused through the growing builder. | The arena split, or the next change to D145. | D145 amended so an erased call no value can reach is not refused, with the arena moved and fixtures, or the refusal naming its remedy. | retired: D377 amended D145 so an erased call no value can reach traps instead of being refused, and the arena is `core/arena` |
| SR-225 | Usability | Under Ubuntu 24.04's `qemu-user`, 8.2.2, every `linux-rv64` program that sets a signal disposition dies of SIGSEGV before writing anything, because that QEMU writes a 32-byte riscv64 `sigaction` over Linux's 24-byte record; the R13.70 gate reported about 240 runs as "the program returned a status" with empty output, nothing naming the emulator, and the cause was found only in QEMU's source. The gate now runs the pinned QEMU. | The next change to the cross-lane runner or `--runner`. | The harness probing the runner's version, or this signal record, and refusing a known-bad emulator with the reason. | retired: R13.71 probes the runner's emulator before a cross lane and refuses a known-bad one by name, held by `fixture execution/a known-bad runner is refused` |
| SR-226 | Usability | `refine -o x.s main.ldn` with no command is refused with "-o requires its own command", which does not name `compile` as the command it needs. Met in R13.70 checking the Cortex-M probes. | The next command-line item. | The refusal naming `compile`, or `-o` taking it as given. | retired: R13.71 refuses `-o` before its command as "an option of compile; name the command first: refine compile -o …" |
| SR-600 | Usability | `refine --target=cortex-m0` refuses `assembler.block("vsqrt.f64 {r}, {x}", in x: f64 at float = x, out r: f64 at float)` as L0330 "assembly requires enabled M0 instructions; ordinary blocks require straight-line control flow": it names neither the instruction it refused nor the level or float unit that has one, and it cites a straight-line rule a block with no branch did not break. R12.30 now reports a float operand's L0304 in its place on a profile with no float registers, which the text's refusal hid, but a VFP instruction among integer operands still meets this line. Met writing `runtime/assembly-float-square-root`'s Cortex-M arm in R12.30. | The next change to the `armv6-m` admission. | The refusal naming the mnemonic and, where one exists, the level or float unit that admits it. | open |
| SR-602 | Usability | `./scripts/dev-test.sh --suite='fixture execution'`, which an item's brief named beside its new fixtures, executes every runtime fixture at every profile, and at the default single test worker it was still running after the 30 minutes an agent's background command is given, and was stopped, where at `LANDIN_TEST_JOBS=8` it took 15; `--help` lists the suite with no word of what it runs or of `LANDIN_TEST_JOBS`, which only `docs/process.md`'s examples, setting it to 1, and AGENTS.md's gate table, setting it to 8, mention. Met running R12.30's float-operand fixtures. The same holds of `--suite=parser`, which a stream brief requires in every run, and `--suite=memory`: in R12.40's first filtered target run they took 290 s and 281 s of its 636 s, every other selected suite together under a minute, and `--help` says neither. | The next change to `scripts/dev-test.sh`'s help or to the fixture execution suite. | The help saying what the suite runs and naming `LANDIN_TEST_JOBS`, or the suite taking the wider worker count by default under `parallel-equivalence.sh`'s guarantee. | retired: `dev-test.sh --help` says what `fixture execution`, `parser` and `memory` run and cost, and that `LANDIN_TEST_JOBS` splits only `fixture execution`'s corpus cases |
| SR-603 | Usability | `QEMU_CPU= ./scripts/dev-test.sh --target=linux-arm64 --runner=qemu-aarch64 ...`, with the variable set but empty, fails every fixture as "qemu-aarch64 is refused before any program runs under it (qemu-aarch64 version 11.1.0): it could not run the runner probe ... qemu-aarch64: -cpu option cannot be empty; run the lane under the pinned QEMU, which nix develop provides", though the QEMU was the pinned one and the fault was the empty variable, which the advice never names. Met running R12.30's float-operand fixtures on the arm64 cross lane from a loop that set `QEMU_CPU` for RV64 alone. | The next change to the cross lanes' runner probe. | The refusal naming `QEMU_CPU` when QEMU's own message is about `-cpu`, or the lane refusing an empty `QEMU_CPU` by name before it probes. | retired: the runner probe's refusal names `QEMU_CPU` when QEMU's own message is about `-cpu` |
| SR-231 | Competitive optimization | An atom `match` re-tests its subject's set at every arm, so `failure.words`'s 32 arms cost about 6.3 KiB of Cortex-M0 code at size/auto, about 200 bytes an arm. R13.72 tests the subject once, through a sealed slot the backends do not revalidate, which took `failure.words` on Cortex-M0 at size/auto from 6,336 to 3,552 bytes; the arms remain a compare-and-jump chain of about 110 bytes each, because a table needs a multiway IR terminator. | The next Cortex-M code-size item. | A multiway IR terminator and an atom `match` lowered through it as a table or jump, with the image measured. | open |
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
| SR-254 | Usability | `check.py` has no `--help`; its flags, `--generate` among them, are learnt from `main()`. Met in R13.72. Since then an unknown flag is refused with a usage line naming every flag, but `--help` itself is refused as unknown, with status 2. | The next change to `check.py`'s command line. | `--help` accepted as a request for that usage. | open |
| SR-255 | Usability | `check.py` and its controls leave files open, and hundreds of `ResourceWarning` lines bury real failures in `scripts/script_tests.py`'s output. Met in R13.72. | The next change to `check.py`'s file reading. | No resource warnings in a full run. | retired: `check.py` closes every file it opens, and `scripts/script_tests.py` fails a module that prints a ResourceWarning |
| SR-256 | Usability | `scripts/script_tests.py` takes only a directory, so one module cannot be run through it. Met in R13.72. | The next change to `script_tests.py`. | Named modules selectable. | open |
| SR-257 | Usability | `scripts/quality.sh` prints its whole 44 MB measurement record to standard output as well as writing it. Met in R13.72. | The next change to `compiler/tests/quality/check.py`. | A summary on standard output and the record in its file. | open |
| SR-258 | Usability | `scripts/scaling.py`'s declarations column counts the platform library's roughly 616 declarations, so the fields family reads the same at every size, 619 when met and 789 now, unlike its docstring. Met in R13.72. | The next change to `scripts/scaling.py`. | The column counting the generated program, or labelled for what it counts. | retired: the column counts the generated program's own declarations, the empty program's count taken off |
| SR-259 | Usability | The pinned `tree-sitter parse --rebuild` silently keeps the cached parser when no C compiler works, and a bare `tree-sitter` run warns "no parser directories" on every invocation. Met in R13.72. `highlight/tree-sitter/README.md` now explains both and gives a fresh-cache recipe; the pinned CLI still refuses nothing. | The next tree-sitter pin change. | A refusal when the parser cannot be rebuilt, and the warning explained or silenced in `highlight/README.md`. | retired: the suite compiles into an empty cache, passes no `--rebuild` and refuses when no library results; both READMEs say what the pinned CLI's `--rebuild` and warning do |
| SR-261 | Usability | L0304, like every refusal of its kind, has two fixed notes, the tour paragraph and the standing, so the catalogue cannot carry a route as a note and every route is written into the message. Met writing the generic literal route in R13.72. | The next diagnostics item touching the catalogue's note counts. | A route note available to such refusals, or the message form recorded as the way. | retired: L0304 carries its route as a third note (D761); the generic-literal, match-alias and construction-statement routes moved out of their messages |
| SR-262 | Usability | L0342's list of concepts uses bare names, `formattable`, not the spelling a program writes, `text.formattable`, because the checker's spelling has no module-qualified concept text. Met in R13.72. | The next change to type spelling. | Concepts spelled as the program would write them. | retired: R13.75: concepts are spelt as the program writes them (D880) |
| SR-264 | Usability | A `match` arm with two statements and no `begin … end` is refused with "a match arm puts `:` after its case" at the second statement's `=`, which does not name `begin … end`. Met writing R13.72's fixtures. Merged: SR-292, the same refusal met in R13.73's outside reviews, where `refine explain L0103` covers other mistakes and nothing says an arm runs one statement; SR-322, met at `ptr (front):` writing `runtime/escaping-into-frame-list` in R14.20. | The next parser-diagnostics item. | The refusal naming the block form, with a fixture. | retired: R13.75: a second statement under an arm is one L0103 naming the bare block, labelled at the arm's case, and the next arm still parses (D860) |
| SR-265 | Usability | `refine fmt` writes `ptr (p):` and `_ (rest):` with a space but `red(shade):` without one. Met in R13.72. `docs/format.md` states the difference between `ptr (p):` and `some(value):`, but not `_ (rest):`. | The next formatter item. | One spacing for every arm binding, or the difference stated in `docs/format.md`. | retired: `docs/format.md` states `_ (rest):`'s spacing and why, and its example holds the formatter to it |
| SR-266 | Usability | An internal compiler defect reported as "failed precondition from landin-syntax.ads:1393" names the specification's line, not the caller, and finding the cause took `gdb` with `catch assert`, which nothing documents. Met in R13.72. | The next driver or diagnostics item. | The report naming the failing caller, or the debugging route documented. | open |
| SR-267 | Language evolution | A library helper's trap reports the helper's site, not its caller's, so a `require(condition)` helper cannot say where the contract failed. Met deciding SR-31 in R13.72. | The first library contract helper. | A caller-site form, such as a `caller` argument to `compiler.unreachable`, decided with fixtures. | open |
| SR-269 | Usability | The x86 optimization suite's failures print one sentence, not the routine they judged, and expect exact labels and registers, so moving it onto the pipeline meant compiling each source by hand with `--emit=asm`. Met in R13.72. | The next change to that suite. | A failure showing the assembly it judged. | open |
| SR-272 | Usability | `scripts/build.sh --help` starts a build instead of printing its usage, unlike `dev-test.sh --help` since R13.72. Met in R13.72. It is worse than a missing usage line: the option reaches the staleness check first, so checking SR-295 with `./scripts/build.sh --help` rebuilt from clean and deleted the debug build's objects. | The next change to the build scripts. | Usage printed without a build. | retired: `build.sh` and `dev-build.sh` print their usage on `--help`, and refuse an argument they do not take with it, before any build step |
| SR-273 | Usability | `[]` as an `else` handler's value is refused with L0102 "an expression belongs here", though `x = []` is accepted. Met writing `core-vec-bytes` in R13.72. `else []` is admitted now on the call's line and as a handler block's value, except on a line after one that ends in a name, where the `[` is read as an index and refused with L0102, which does not say so. | The next parser-refusal item. | The empty slice admitted there, or a refusal naming the route. | open |
| SR-275 | Competitive optimization | A `list` grows by allocate and copy (D356) while the text builder grows by `resize`, so reading 250 MB into a byte list takes 0.40 s against the builder's 0.23 s, and reverse-complement stays on the builder; growing lists through `resize` rewrites the fixtures that pin allocator calls and overflowed a Cortex-M image when tried. | The next `core/mem` change, or R16.10. | Lists grown through `resize` where a provider has it, measured, with the counter fixtures re-decided. | open |
| SR-277 | Usability | The binding generator still types a pointer to an ordinary `layout(c)` record `ptr u8`, while packed and flexible records get typed pointers since R13.72. Met in R13.72. | The next consumer of a generated record pointer. | Typed pointers for every generated record, with the bindings fixtures. | open |
| SR-279 | Usability | `f(1)(a: 2)` is L0103 "an expression belongs here" because `f(1)` was read as a type application in a written conversion, which the report does not say; it was found only under a debugger. Met in R13.72. | The next change to written conversions. | The refusal saying what the first application was read as. | retired: the refusal is "an applied type is not called to make a value", with a label on the applied type, pinned by `negative/an-applied-type-is-not-called`. |
| SR-281 | Usability | A stale `refine` in a sibling checkout is easy to pick up and nothing says a binary predates its checkout: a two-week-old release compiler's reasonless "cannot write" was taken for a current formatter defect. Met in R13.72. `refine version` names the revision a binary was built from; nothing compares it with the checkout's. Met again in the November register sweep: the main checkout's stale release `refine` refused an empty program with L0347 at `platform/linux/threads.ldn`, which does not suggest the binary is stale. | The next item touching `refine version` or the build scripts. | A binary older than its checkout's sources said so, or `refine version` naming the revision it was built from beside the checkout's. | open |
| SR-530 | Usability | `check.py` refuses every token shaped like a roadmap identity outside `ROADMAP.md`, so the invented register of a test of a register reader, `scripts/tests/test_activations.py`'s, was refused row by row: `SR-10`, `SR-11` and an invented item in a status, none of them a record or item of either roadmap, were each "cited outside ROADMAP.md, which is the only place a roadmap identity belongs", and the spellings the check lets through, a one-digit `SR-0` and a letter-and-digit `Q9`, were found by trial. Met writing the closing step's control in R12.12. | The next change to `check.py`'s citation check, or the next test that needs an invented register. | The refusal saying it refuses the form rather than a record, and naming the spellings a test may use. | open |
| SR-285 | Broader standard library | A `{}` placeholder takes no width, padding or radix, so C's `printf("%5u")` is five builder calls (`docs/from-c.md`'s `printf` entry), where Rust writes `{:5}`. Met in R13.73. | The next change to `core/text`'s formatting. | Rust's format specification studied and the parts that suit a template checked when it runs ported, `{:5}`, `{:<5}`, `{:05}` and `{:x}` among them, or each declined with its reason. | open |
| SR-286 | Usability | A call that can fail, written as a routine's last line, is read as the body's value: the first refusal is L0301, a type mismatch, and L0329's "use `try` or `else`" comes second. Met in R13.73. | The next change to L0329 or to result checking. | L0329 reported first, or L0301 naming the unhandled failure. | retired: R13.75: such a call is one L0329 saying the body reads it as its value, and L0301 waits for the failure to be handled (D871) |
| SR-287 | Usability | In `if c then a() else b() end if` the `else` belongs to the `if`, and a call's own `else` inside an arm needs parentheses; the tour needs a paragraph to say so, and nothing warns a reader who meant the call's. Met in R13.73. | The next change to call-site `else` parsing. | A warning or a note when an arm's last call can fail and the `if`'s `else` follows it. | retired: L0329 says that the `else` after the call divides the `if` around it and names the parenthesised form, pinned by `negative/recovery-value-in-an-if-arm-divides-the-if`; the change predates the row. |
| SR-288 | Usability | A C program that owns `main` must call `_landin_host_initialize_arguments` before `system.new()`, or a use of the arguments traps; the trap does not name the call. Met in R13.73. | The next change to `hosted/system` or its traps. | The trap naming the initializer, with `docs/from-c.md` showing the call. | open |
| SR-289 | Usability | A module value may read a compiler fact (D437) but not a declared option, so `x: bool = compiler.os == linux` is accepted and `x: bool = log_level > 1` is L0201, though both are fixed when compiling. Met in R13.73. | The next configuration item. | Options readable where facts are, or L0201 naming `fixed if` as the route. | open |
| SR-290 | Usability | Printing one formatted line takes three lines of setup first, `system.new()`, `io.buffered_over` over a buffer and `defer io.flush(out) else none`, and an unbuffered `io.write` formats nothing; every example on the examples page repeats them. Met in R13.73. | The next change to `core/io`'s writers. | A formatted write straight to a file through a small buffer of its own, or the three lines kept with the reason recorded. | retired: D527's `io.write_format` writes a template and its values to a file in one call, through a store of its own. |
| SR-645 | Usability | An RV32 ordinary block that stores zero, `sw zero, 4(t0)`, is L0330, "the text names `zero`, a register no ordinary block may write", though the text only reads it; storing zero takes a scratch register loaded with `li t1, 0`. The rule is RV64's, which never names x0 to x4, and its note speaks of stack, frame and link registers. Met writing an RV32 timer-interrupt probe for R12.40. | The next change to the RISC-V block rules. | x0 admitted as a source operand, or the refusal saying that reading it is refused too and what to write. | open |
| SR-646 | Language evolution | An RV32 handler runs with mstatus.MIE clear until its `mret` (D680), so no interrupt preempts another at any priority: a long handler delays every other, and the CLIC's levels and Hazard3's meicontext priorities go unused. The NVIC nests by priority on Cortex-M. Left out of R12.40. | A board program whose interrupt latency needs preemption. | Nesting by the core's priority mechanism, with the saved context and the stack it needs stated. | open |
| SR-647 | Language evolution | The ESP32-C5's CLIC runs in its non-vectored mode (D680): every interrupt enters the common entry, which reads mcause, and `mtvt` is never set, so an interrupt a program configures with `shv` set enters an address table that does not exist. Selective hardware vectoring, as ESP-IDF uses it, is not built. Left out of R12.40. | A C5 program that needs the lower latency of hardware vectoring. | mtvt pointing at a table of handler addresses, written beside the table of jumps, and the interrupts' `shv` the program's. | retired: the C5 port vectors its timer through mtvt's table of stubs by `shv`, with UART0 on the common entry (D830); its board run passed with CLICINT18's SHV set and CLICINT17's clear in its boot frame, and the C5's record was re-recorded from it |
| SR-648 | Release readiness | The RV32 entry word and every table slot is one `j`, which reaches 1 MiB either way, so a naked handler or a stub placed farther from the table than that, an RP2350 Hazard3 handler in `.ramtext` at 0x2000_0000 with the table in flash at 0x1000_0000 among them, fails to link with the linker's "relocation truncated to fit". Met reading R12.40's slot layout. | The first RV32 profile whose handlers lie beyond 1 MiB of its table. | A slot that reaches anywhere, an `auipc` and `jr` pair through a stub kept in range, or a refusal naming the distance. | open |
| SR-649 | Language evolution | An `esp-app-image` is RAM-only (D683): the ROM loads every segment into SRAM, so an image is bounded by the SRAM the description gives code and data, and flash execute-in-place, which needs the ROM's or a second stage's cache and MMU set-up, is not built. Left out of R12.40, as Jan decided. | An ESP program larger than its SRAM. | Flash-mapped text and rodata, the cache and MMU set up before reset, and the image's flash segments placed where the ROM maps them. | open |
| SR-650 | Release readiness | `descriptions.json` records the device accesses each ESP description's watchdog stage makes, as it does for the STM32H753's supply stage, but no lane follows an RV32 stage: `devices/thumb.py` evaluates Thumb alone, so the descriptions lane checks only that the entry word reaches the stage. Met adding the RV32 descriptions to the lane for R12.40. | The next change to an RV32 ESP watchdog stage's code, or to the RV32 description-stage validation lane. | A RISC-V evaluator beside `devices/thumb.py`, following the stage from the entry word to reset with no RAM and no stack. | open |
| SR-651 | Usability | `refine compile --debug` is refused as "--debug needs a value", which does not say the values are `none`, `full` and `lines`; `-g`, which a C programmer tries first, is "unknown option: -g". Met building RV32 firmware with debug lines for R12.40. `--debug FILE` is now answered with the values; a bare `--debug` or `--debug=` still is not. | The next change to the driver's option messages. | The refusal listing the values, and `-g` answered with the option that gives debug information. | retired: R13.75: a missing value names the values, and `-g` is answered with the option it means rather than accepted (D884) |
| SR-291 | Usability | `check.py`'s named-file check reads a file name inside a program listing, so an example that opens a missing settings file named with a `.txt` ending is refused as naming a file not in the repository, and the example had to end its name in `.conf`; this row could not spell the name either. Met in R13.73. Met again in R13.73's third round, in a sample command in `docs/library.md` and in example prose and code comments, each renamed to `.conf` or `.log`. | The next change to `check.py`'s named-file check. | Fenced code exempt from the check. | open |
| SR-293 | Usability | `io.format(out, "{}", [any(addr y)])` with an `f64` is L0318 "this concrete type has no conformance to `formattable`", which does not name `f64`, and its second label points into the library's own `core/io/buffered.ldn`. Met in R13.73's outside reviews. | The next change to L0318. | The refusal naming the concrete type, with the label at the caller's own source. | retired: R13.75: L0318 names the type and the concept as the program writes them, `f64` and `text.formattable`, with its primary label at the caller's erasure (D880) |
| SR-294 | Release readiness | The latest release, 0.2.7, ships `refine` without its library, so a newcomer who installs the archive, or `nix profile install` of `#refine-bin` which fetches it, cannot compile hello world: `import core/io` has nowhere to come from. The README now warns above the archive route. Met in R13.73's outside reviews. | The next release. | A released archive holding `lib/landin`, with the README's warning removed. | retired: v0.2.8's archive holds `lib/landin`, and the README confines its warning to 0.2.7 and earlier; what still keeps a newcomer from building the first program from a release is SR-695's. |
| SR-295 | Usability | `./scripts/build.sh` builds the debug compiler by default, into `compiler/ada/build/<host tag>/debug/bin/refine`, and a reader building from source to use `refine` finds the release mode only in `scripts/env.sh`'s `LANDIN_BUILD_MODE`. Met in R13.73. | The next change to the build scripts or the README's install route. | The README's source route naming the release build and where `refine` lands, or a `--release` option. | retired: the README's source route names the debug build's path and `LANDIN_BUILD_MODE=release`; that `build.sh --help` builds is SR-272's. |
| SR-296 | Usability | Refusal notes cite decision numbers, as L0103's "D77, D405: an arm is its case…", which a reader cannot follow from the message and which the tour no longer uses. Met in R13.73. `refine explain` resolves a decision number since R13.74 (D530), so a reader can follow one; whether a note should cite a paragraph instead stands. | The next pass over the diagnostic catalogue. | Notes citing the tour's or spec's paragraph instead, or none. | open |
| SR-297 | Usability | A generic routine nothing calls is not checked for L0315: a live `vec.at` view held across `vec.push` in an uncalled `(provider: type is mem.allocator, …)` routine checked clean until a concrete caller was added, though the tour says a template is checked even if nothing applies it. Met in R13.73. | The next change to generic checking or the borrow check. | The template checked, or the tour's claim narrowed to what is checked. | retired: the tour narrowed: a generic routine's body is checked for each instance a call makes (D771, [1290]); checking templates symbolically is declined until a program needs a template refused uncalled |
| SR-298 | Usability | A trap's panic site is resolved to a source line by `scripts/source-location.py`, which exists only in the source repository, so a user of an installed `refine` cannot resolve one. Met in R13.73. A hosted trap with no handler now prints its own line; a `panic_handler`'s site and a firmware trap still need the script. | The next change to hosted trap reporting or to `refine`'s commands. | A `refine` command that resolves a site, or the report carrying the line. | open |
| SR-299 | Usability | A loop that only repeats cannot say so: `for _ in 0..<3 do` is L0103 "a for loop names its element binding", so a counter nobody reads is named and then thrown away with `_ = attempt`, the ritual the examples just lost for failures. Met in R13.73. | The next change to `for` bindings. | `_` admitted as a `for` binding, or the refusal naming `loop` with a counter as the route. | open |
| SR-300 | Usability | A cosmetic edit to a published example fails `check.py` until the same routine is copied by hand into its hidden memory fixture (`run-shell-memory`, `network-echo-memory`), and the refusal, which now names the copy and the published file, offers no command that re-syncs it. Met in R13.73. | The next change to the shared-routine check. | The refusal naming the copy and the command that re-syncs it. | open |
| SR-301 | Usability | `any(addr lenof people)` is L0103 "`people` does not belong here" with the help "remove `people`", a repair that changes the program's meaning; the real rule, that `addr` needs a named place, is not said. Met in R13.73's outside reviews. | The next change to L0103's repairs or to `addr`'s operand. | A refusal saying that `addr` takes a named place and to bind the value first, with no repair that drops the operand. | retired: R13.75: `addr` of a measure is refused as a value's address, saying to bind it first, with no repair dropping the operand (D863) |
| SR-302 | Usability | `try` inside hosted `main` is L0329, whose note says to add the atom to the routine's `!` set, but `main` may have none (L0502), so the suggested fix is refused next. Met in R13.73's outside reviews, pasting the library's recipes into `main`. Merged: SR-463, the same note met writing `try io.write_format(...)` inside `main`, following L0329's earlier text, "write `try` to propagate or `else` to handle". | The next change to L0329's note. | In `main`, the note naming `else` or a fallible helper as the route. | retired: R13.75: in hosted `main` both L0329 notes name `else` and a fallible helper, never `main`'s `!` set (D872) |
| SR-303 | Language evolution | A bound anonymous function cannot supply a concept entry: `i32 is ordered (less: less_i32)` with `less_i32 := (a: i32, b: i32) -> (yes: bool) = a < b end` is L0341, though both are fixed code. The tour now declares a named function there. Met in R13.73's outside reviews. | The next change to conformances. | A module binding of a fixed anonymous function admitted as an entry, or the refusal saying why not. | open |
| SR-304 | Usability | L0202's note for a private type crossing a public signature cites "D150: a private identity may cross", but `spec.md`'s D150 is the module graph's identity order; the note's rule has no decision under that number. Met in R13.73. | The next pass over the diagnostic catalogue, with SR-296. | The note citing the paragraph that holds the rule. | retired: D150's body holds the rule, that public declarations may mention private identities, and D151 cites it so; only D150's title, the identity order, does not suggest it, and `refine explain D150` shows that title. |
| SR-307 | Usability | Two string literals side by side in a call are L0103 "a call's arguments are never closed", which hides that Landin joins no literals, so a long `format` template cannot be split across lines. Met in R13.73. | The next change to string literals or L0103. | Adjacent literals joined, or the refusal saying they are not. | open |
| SR-308 | Usability | `check.py` and the test program require exactly one `landin` block per `examples.md` section, so the page cannot show a five-line snippet beside a program. Met in R13.73, showing how to call a routine on a path of your own. | The next change to the examples checks. | Snippets allowed when each is held to its program, or the rule stated in `compiler/tests/README.md`. | open |
| SR-309 | Usability | The Claude session timing review found long local checks managed through repeated sleep/log probes; the process guide did not show how to retain complete output and the command's exit status while using completion notifications. | The next change to the local agent feedback workflow. | A documented logged-command path with completion notifications and resource measurements, preserving the selected checks. | retired: `scripts/run_logged.py` retains the complete log, exit status, elapsed time and CPU/memory measurements; AGENTS.md and `docs/process.md` describe background completion notifications, batched inspections and combined test selectors |
| SR-310 | Usability | Script tests fail under host load and pass alone, so a timing assertion reads as a broken change: `scripts/tests/test_macos_environment.py`'s `test_timeout_stops_a_separate_tool_group` failed under `scripts/script_tests.py`'s sixteen workers in R13.73 and R14.20 and twice more in the November register sweep; in that sweep `test_build_inventory.py`'s `ConfiguredBuild` failed with `TimeoutExpired` on its five-second `build.sh` timeout at a load near 50, `test_board_common.py`'s `test_a_tty_console_keeps_every_byte_each_way` got `b'S'` for `b'S1'` from one `os.read` of a pty, and `test_run_logged.py` failed once, each passing alone. | The next change to any of those tests. | Each test independent of host load: reads until the bytes or a deadline, timeouts with margins stated and wide enough for the load `script_tests.py` itself puts on a host. | retired: each test named here, `test_fuzz_close.py` and five more modules read until their bytes or a stated deadline, with hang guards of 120 to 300 s; `scripts/script_tests.py` passed run twice at once beside a busy loop on every core, at a load of 65 to 99 |
| SR-311 | Usability | Registering a fifth prototype meant finding every place the four are named, and `grep prototype-4` finds only some: the finding letters were written out as `[XYZW]` three times in `check.py` and three in `docs/site/render_html.py`, so the new findings rendered unlinked and ROADMAP.md's citations of them went unchecked, with every check clean; and the site's navigation is a `NAV_GROUPS` list beside each document's own `group=`, which only `site.sh` refuses, after `check.py` has passed. Met in R14.10, which put the letters in `PROTOTYPE_FINDINGS` and one renderer constant that `check.py` holds to it. The finding letters were settled then; each document's `group=` in the renderer is still read nowhere, and already disagrees with `NAV_GROUPS`. | The next prototype, or the next change to the renderer's document list. | `NAV_GROUPS` read from the documents' `group=` or checked by `check.py`, and the places a prototype is registered named in one place. | retired: `NAV_GROUPS` is the one place a page's group is written, and `check.py` holds it, every prototype's page and `pages.yml`'s paths to the documents; `PROTOTYPE_FINDINGS` is where a prototype is registered and names the places outside it |
| SR-312 | Usability | A citation of a register record that does not exist passes every check: ROADMAP.md's R13.72 paragraph cites `SR-350`, and no such row ever existed; the register now runs past it, so the citation could come to point at an unrelated row. `check.py` holds construct and finding citations to a definition and register identities to staying inside ROADMAP.md, but not to existing. Met in R14.10. | The next change to `check_roadmap_citations`. | Every cited register identity defined in the register, and the `SR-350` citation corrected to the row it meant. | retired: `check.py` holds every cited register record to a row, a `Merged:` name or the list of records that have left the register, and the R13.72 paragraph cites D419, what it meant, since no SR-350 ever existed |
| SR-313 | Usability | `scripts/gate_watch.py --commit 581b73f5` printed "no gate run for 581b73f5 yet" for 23 minutes beside a gate run that had passed: `gh run list --commit` matches only a full hash, and the watcher passed the short one on and waited. Met in R14.10. | The next change to the gate watcher. | A short hash expanded, and a name that is no commit refused. | retired: the watcher expands a name with `git rev-parse` and refuses one that is neither a commit here nor a full hash |
| SR-314 | Language evolution | An error set cannot be a generic parameter, so a fibre group (D444) carries every task's failure as `failure.reason`, and a task failing with an atom of the program's own maps it before returning. Met deciding prototype 5's V2. | A second facility that has to carry its caller's error set through a generic: a callback runner, a comparator, a traversal, or a derived program that maps atoms only to get them through a group. | A register decision for error sets as generic parameters, or the mapping recorded as the way with the facilities that met it. | open |
| SR-315 | Language evolution | A fibre group whose backing is the caller's frame must be joined before the frame goes, and only the program's `defer` makes sure of it (D444); a forgotten join runs a fibre on a dead frame. A check that such a group is joined on every path out, as [0910] checks that a sunk place is replaced, was declined until needed, since marking a type as needing it is close to the parked affine values. | A derived program or a fixture that forgets a join, or a second library value whose release is as unsafe to forget. | A register decision for a path check keyed on a property rather than one library type, or the `defer` recorded as the way. | retired: the `defer` recorded as the way (D773); a path check keyed on a library type or a declared property declined as the parked affine values |
| SR-316 | Usability | A runtime fixture for a feature that lands one backend at a time cannot stay off linux-arm64 honestly: `check.py` and `scripts/add_fixture.py` want a `linux-arm64/parity.json` record naming "the counterpart that runs on arm64 instead", and while arm64 does not emit the feature yet there is none, so a negative fixture pinning arm64's refusal had to be written to stand as the counterpart of four runtime fixtures. Met in R14.20, adding the x86-64 stack switch's fixtures. | The next feature that lands on x86-64 before arm64, or the next change to the parity record. | A disposition for a feature not yet emitted on arm64 that names its refusal and lapses when the backend lands. | open |
| SR-317 | Usability | L0506 is one sentence, the whole contract, for every way a `panic_handler` misses it, so a handler written against the former four kinds was told its shape and not that its kind lacked `stack_exhausted`. R14.20 added that reason; a wrong convention, constraint, site type or error set is still told only the shape. Met in R14.20, moving the contract to D451's five kinds. | The next change to the handler contract or to L0506. | Each refusal naming the part of the signature that differs. | open |
| SR-320 | Usability | Building a frame list with `escaping into` (D445, D455), every node has to be declared before the list and in the order it is pushed: `push_front`'s head is kept in each new node, so the node pushed earlier must be declared before the one pushed later, and a node declared after the list is L0314, though locals of one block live until the block ends together. The order is right but has to be worked out from the refusal. Met writing `runtime/escaping-into-frame-list` in R14.20. | The next program that builds a frame structure through `escaping into`, or the next change to the outlives rule. | Locals of one block counted as equally long-lived, with the reason it is safe recorded, or the order taught where the tour teaches the form and named in L0314's note. | open |
| SR-321 | Usability | A struct literal passed straight to a parameter of a named struct type is L0304, "a struct literal needs a named type from its destination", though the parameter names the type; `admit(g, (host: host))` had to become a binding `task: state = (host: host)` first. Met writing `runtime/escaping-into-group-state` in R14.20. Only a literal holding a reference is refused: a struct literal of scalar fields takes the parameter's type. | The next change to struct-literal typing or to argument checking. | A parameter's type given to a literal argument as a binding's is, or L0304's note naming the binding as the way. | open |
| SR-323 | Usability | `python3 scripts/add_fixture.py` and `python3 check.py --tokens` stopped with "the grammar has problems; fix those first" and named no problem, and `python3 check.py spec.md` reported the grammar clean; the problem, "grammar preamble omits contextual words: into", was found only by calling `read_grammar` from Python. Met adding `escaping into`'s fixtures in R14.20. | The next change to `check.py`'s token or grammar generation. | Both refusals printing the grammar's problems with their lines, and a targeted `spec.md` run reporting them. | retired: a run over `spec.md` alone and the token generator, which `add_fixture.py` runs, both print the grammar's problems with their lines |
| SR-324 | Usability | Whether a backend change's Darwin and FreeBSD arm64 emission still assembles has no local command on a Linux host: the gate's `darwin-*` and `freebsd-*` lanes are the only callers, `compiler/tests/freebsd/check.py` wants a sysroot and a VM, and the route found was reading it to learn it drives Clang with `--target`, then a hand loop of `refine compile --emit=asm` and `clang --target=arm64-apple-macos13 -c` / `--target=aarch64-unknown-freebsd14 -c`, under a nix-wrapped Clang that warns on every call that it is not designed for another target. Met in R14.20, adding the arm64 stack switch. | The next backend change that touches Mach-O or FreeBSD spelling, or the next change to the cross lanes. | One documented command that emits a fixture set for every non-host target and assembles each with the pinned assemblers, without a VM or a Mac. | open |
| SR-325 | Usability | `check.py` refuses a `spec.md` "Pinned by" paragraph that names a retired fixture even in the past tense ("this pins negative/..., which is not a fixture"), so D453's record of the linux-arm64 refusal fixture it once had could say only "a negative fixture", and the history of what pinned a decision is lost from the paragraph that states it. Met in R14.20, retiring that fixture when the arm64 backend emitted the stack builtins. | The next retirement of a fixture a decision cites. | A spelling for a retired pin that the check accepts, or the rule recorded as the way. | open |
| SR-336 | Usability | An `any C` made straight in a call's argument from a pointer to an instance of a parameterized provider, `runner(any(p))` with `(t: type) box(t) is task`, compiles, and the callee's erased call traps `unreachable` at run time: the checker's discovery pass materializes the family's conformance for a binding with a written `any C` type but not for an argument, so D377 decides beforehand that no conformance answers the concept. Binding it first, `work: any task = any(p)`, works, and `core/fibre`'s `admit` does so. Met writing `core/fibre` in R14.20; a patch materializing it for a non-generic callee's `any C` parameter was tried and passed the reproducers, and leaves generic callees, function values, results, fields and array literals as they are. | The next change to erased construction or D377, or the next parameterized provider erased in an argument. | Discovery materializing the conformance wherever the contextual `any C` is known, and D377's trap reported at compile time when a program does make an `any` of the concept. | retired: the checker selected an erased call's dispatch when discovery ended, before an `any` made outside a binding with its type written had materialized the parameterized conformance; the call now takes its dispatch once every body is checked, so D377 is decided over the closed program wherever the `any` is made, pinned by the `runtime/any-parameterized-provider-*` fixtures, and `core/fibre`'s `admit` passes `any(copy)` directly |
| SR-337 | Usability | `fibre.turns_over(any(addr runner), ...)` over a `fibre.whole`, and over the blocking host, is L0318 "this concrete type has no conformance to `turns`": it names neither the type nor that the type provides `turns`' parent `scheduler`, which is the whole reason a group over turns is refused for it (D444). Met writing `negative/fibre-turns-over-scheduler-only` in R14.20. | The next change to L0318 or to concept composition. | L0318 naming the type, and the parent concepts it does conform to when a composed concept is missing. | retired: R13.75: L0318 names the type and, for a composed concept, the parents it does conform to (D880, D881) |
| SR-339 | Usability | `x := f() else return` and `f() else return`, written as a newcomer writes them to give up on a failure, are L0102 "`return` begins a statement, and a statement has no value" with the note "a statement stands on its own line"; the forms that do it, `else (problem)` with `_ = problem` and `return` on lines of their own, or `try` in a routine with the failure in its set, are named nowhere in the refusal. Met four times writing R14.20's fibre fixtures. | The next change to `else`'s handler forms or to L0102's notes. | L0102's note naming the block form and `try` when the token after `else` is `return`, `break` or `continue`. | retired: R13.75: an exit after a call's `else` is L0102 naming `else begin ... end`, with the note naming the bound block and `try` and a fix that writes the block (D870) |
| SR-342 | Usability | The build report's `frame_bytes` reads as a routine's stack and is not one, and means different things by target: on x86-64, arm64 and RV64 it is the frame's extent without the sixteen-byte frame record, the return address or any call's argument area, while on Cortex-M0 it includes the pushed registers. Met in R14.20 building D447's depth report, whose frames had to come from each backend's prologue instead. | The next change to the build report's `routines`. | `frame_bytes` documented as the extent it is, or the report carrying the `Stack_Bytes` the depth report reads. | retired: the build report carries `stack_bytes`, the depth report's frame, and `frame_bytes` is what the prologue reserves on every target, documented with it (D791) |
| SR-605 | Release readiness | An `rp2350-image-block` image carries one IMAGE_DEF block with no HASH_DEF item, so RP2350's boot ROM boots it without checking a byte of the image: a partly written or corrupted flash image whose first 4 KiB survive is entered as if whole, and a board with secure boot enabled refuses it. pico-sdk's default build does the same, and adds an end block only to close its block loop. Met making the boot kind in R12.30. | A board run that needs to detect a damaged image, a secure-boot RP2350, or the next change to the boot kind after R12.40's RISC-V form. | A HASH_DEF item and HASH_VALUE over the image's load map, computed after the link and checked by the descriptions lane, with a board run booting it and refusing a corrupted one. | open |
| SR-681 | Usability | probe-rs enumerates every USB probe before it opens the one `--probe` names, a CMSIS-DAP TCP probe included, so a USB device the host cannot enumerate delays every command, `read` of one word, by 85 s, with no message at the default log level; it showed only as a gap before `list_wlink_devices` at `RUST_LOG=probe_rs=debug`. Met in R12.40's Hazard3 board run, with a halted BOOTSEL Pico 2 on the bus (SR-680). | The next change to the probe-rs fork's CMSIS-DAP TCP and UDP transports. | A probe selector naming a network transport opening it without listing USB probes. | open |
| SR-682 | Usability | Polling `uhubctl -l HUB` after a port's cycle fails now and then with "There were permission problems while accessing USB", the race `common.power_cycle` describes for a second call, since the cycle re-enumerates the hub's inner hubs before udev regroups their nodes. The Arm Pico 2's tool polls for BOOTSEL with a listing that fails the run on it; R12.40's Hazard3 tool met it on its first block control and now retries its poll. | The next change to `environments/boards/rp2350/board.py` or to `common.py`'s hub functions. | A shared poll in `common.py` that retries a listing refused this way until its deadline. | retired: `common.listing` retries a listing refused this way, or taken while the cascade hides the hub, until its deadline, and the Arm Pico 2's BOOTSEL poll and the Hazard3 and ESP tools take their listings through it |
| SR-683 | Release readiness | On the rig the probe's Arty hangs from the same hub tree as the boards' power: a Pico 2 that fell back to BOOTSEL and was then halted by a probe-rs attach (SR-680) left port 7-2.3.3.2 failing enumeration, and the kernel's recoveries and three guarded `uhubctl -a cycle`s of port 2 each coincided to the second with a disconnect of the whole tree from 7-2 down, the Arty's FTDI on the guarded port 4 and the ESP boards' hub included; once more, at 15:27:19, the tree went while a Hazard3 tool only listed the hub, with no kernel error on any port before it. The guard keeps the Arty's port from being switched, not its upstream hubs from being reset, and probehive kept its bitstream only as far as `ping` shows. The Hazard3 tool now refuses a BOOTSEL attach, cycles only after a quiet minute in the kernel log and stops unless the Arty and `ping` are back (D712); the BOOTSEL negative control does not run on this hub. Met in R12.40's Hazard3 board run. | Before the next board run that cycles a port on the probe's own hub, or the next BOOTSEL negative control. | The cause of each tree reset found in the kernel and uhubctl logs, and either the probe moved off a switched hub, the boards powered otherwise, or every board tool holding the same guards. | retired: the maintainer moved the Arty off the RSH-A16 cascade to a host port of its own, and every board tool now refuses a cycle unless the Arty's FTDI, found by its serial, is present and off the cascade it switches (D725) |
| SR-685 | Usability | Reading a wedged RISC-V core's state needs probe-rs's interactive `debug` console: with its commands given as `-c` and its input not a terminal, it runs them and then panics with "No such device or address" at `cmd/debug.rs:444`, so a script has to give it a pty through `script -qc`; its `info reg` names mepc, mcause and mstatus but not mtval, and a board tool has no way to record a failed run's pc and cause. Met finding R12.40's Hazard3 wedge, an interrupt that corrupted a frame. | The next board run that fails on a wedged core, or the next change to the Hazard3 board tool's failure record; the ESP tools record D656's trap cells in a failed run's result since R12.40. | A failed board run reading the halted core's pc, mepc, mcause and mtval into its result, through `probe-rs gdb` and the pinned GDB rather than the console. | open |
| SR-606 | Usability | `devices/inputs.json` has two ways to fetch an input, by script and `"fetch": "by hand"`, and `scripts/fetch_inputs.py`, `devices/README.md` and D559 all say by hand is for an input "its publisher will not serve to a script". The RP2350 datasheet is served to a script, but its URL serves whatever release is current, so pinning it by script would break the gate's fetch the day a new release appears; it had to be marked by hand, which the documentation says is for something else, to keep every job from fetching it. Met pinning the datasheet the RP2350 policy cites in R12.30; RM0433's URL has the same property. `devices/README.md` now gives both reasons; `scripts/fetch_inputs.py`'s refusal and D559 still give the first alone. | The next input pinned that a job need not fetch, or the next change to `scripts/fetch_inputs.py`. | A pin that says the input names a document reviewed rather than one a job reads, or the by-hand text stating both reasons. | open |
| SR-607 | Usability | The cores a description may name are `Landin.Targets.Firmware`'s, and `refine svd` kept its own list of the SVD `cpu/name`s it reads, with `devices/test.py`'s `render_d542` a third: the core `cortex-m33` was added to the first alone, so the RP2350's SVD would have been refused as L0528, "the SVD's cpu is CM33, which is none of CM0, CM0PLUS, CM3, CM4 and CM7", for a core the compiler builds, and nothing points from the core list to the other two. Met reading the importer before learning the RP2350 in R12.30. | R12.50's Xtensa core, or the next core a description may name after R12.40's four RISC-V ones. | One table of cores and their SVD names that the importer reads, or a targets case that holds the importer's names to the core list. | retired: `Landin.Targets.Firmware.Svd_Name` is the one table of cores and their SVD names, which `refine svd` reads, and `devices/test.py`'s `CORES` is held to it by an offline test |
| SR-608 | Usability | A boot kind's layout is restated by the Cortex-M corpus harness: `environments/cortex-m/backend.py`'s `BOOT_PREFIX` and `BOOT_SUFFIX` and `probes/backend-start.S` give the bytes each kind puts before and after the vector table, which refine's build report and the derived script already say, so a new boot kind would first fail the corpus with "the harness supplies no BOOT boot prefix", and its suffix the derived script's size assertion, until both are edited by someone who has read the harness. Met adding `rp2350-image-block` to the corpus's capacity verdicts in R12.30. | The next boot kind, `esp-app-image`, or the next change to the corpus harness's start. | The harness reading the prefix and suffix from the derived profile's report, so a boot kind is known in one place. | retired: R12.40's build report gives each boot kind's `boot_prefix` and `boot_suffix`, which the corpus harness reads from the derived profile and `descriptions.json` records apart from the compiler, so a boot kind is known in one place |
| SR-344 | Usability | A fixture can hold only what `refine` prints, never a file an option writes, so an option that writes a report, `--build-report`, `--stage-report` or `--stack-report`, is pinned only by fake-host cases in the test program and never end to end on a real host. Met in R14.20 adding `--stack-report`. | The next fixture-format change. | A fixture key naming a written file and its expected bytes. | open |
| SR-346 | Usability | A runtime fixture that imports nothing has its hosted entry's platform module, `platform/linux`, named in the build report by its absolute library path, while a program that imports it through its root has it named relative to the root; `workload_sources.py --write` recorded `/home/...` paths for the stack switch's debugger workload until it and the test program's inventory case learnt to read an absolute path inside the checkout as a repository one. Met adding `runtime/stack-switch-frames` as a debugger workload in R14.20. | The next change to the build report's source names or to a module's implicit inclusion. | One spelling for a source however the compiler came to include it, or the rule stated in the build report's documentation. | retired: an added module is spelt through the root that names the library, as its import is (D732); `workload_sources.py` and the inventory case lost their absolute-path branches |
| SR-348 | Usability | `compiler/tests/rv64/check.py --kind=debugger` would run its sessions only on physical riscv64 hardware, and with the RISE lanes suspended no command anywhere ran the RV64 GDB sessions, though `compiler/tests/debugging/check.py` runs the arm64 ones under QEMU's stub on any Linux host. Met adding the stack switch's session for R14.20. | — | — | retired: the debugger kind's prepared payload takes `--qemu=PATH` and runs under QEMU's user-mode GDB stub as cross evidence, named in its summary, and the gate's first `rv64-qemu` shard runs it |
| SR-358 | Usability | Running the FreeBSD arm64 lane on a NixOS host takes three things its README does not lead to. The README's command passes `--refine=compiler/ada/build/linux-amd64/release/bin/refine`, but inside `nix develop` the build tag is `nix-x86_64-linux`, and the refusal for the missing path suggests `LANDIN_BUILD_TAG=linux-amd64 ... scripts/build.sh --compiler-only` rather than naming the build that exists. The arm64 guest's firmware is looked for only under `/usr/share`, and the `LANDIN_FREEBSD_EFI` override that `environments/freebsd/vm.py` reads (pointed at `share/qemu/edk2-aarch64-code.fd` of `nix shell nixpkgs#qemu`) is named in no document. `--ssh-port` takes "an existing development VM" without saying how to start one: booting the cached `arm64.raw` behind a qcow2 overlay with the lane's own QEMU arguments, so that the guest could be kept for `image show-unwind` and C comparisons, was read out of `vm.py`. Met investigating the FreeBSD arm64 switch session's final `ret` in R14.20. The README now gives the shell's build tag and `LANDIN_FREEBSD_EFI`; the missing-`refine` refusal still names the tag asked for, and nothing starts and keeps a VM. | The next change to the FreeBSD lanes or to `environments/freebsd/vm.py`. | The README's command naming the shell's build, the firmware override documented, and a `--keep-vm` or boot-only mode that prints the port a later `--ssh-port` run uses. | open |
| SR-359 | Usability | FreeBSD 14.4's base LLDB, 19.1.7, misreads the stack switch's final `ret` on arm64: in frame 0 it emulates the routine's instructions rather than read its CFI, its emulator loses the stack at `mov sp, x10`, and at the `ret` it reads the return address through x29 and skips a frame. A clang-built switch with clang's CFI fails the same way, every other instruction unwinds right, and the CFI there is the standard epilogue's. So the FreeBSD arm64 switch session records that one stop and does not judge it (`UNRELIABLE_RETURN` in `compiler/tests/debugging/switch_frames.py`). Met in R14.20, gate run 40707225594. | FreeBSD's base system shipping another LLDB, or an upstream fix to LLDB's arm64 instruction emulation. | The exemption removed once that LLDB unwinds the `ret` right, or the reason restated for the version that still does not. | watch |
| SR-360 | Usability | A concept's entry cannot be called through a concrete provider type's name: `system.host.make_temporary(services, ...)` is refused with L0338, "a type name does not denote a runtime value", although `provider.make_temporary(...)` is accepted where `provider` is a type parameter. `core/io`'s own `make_temporary` takes a concrete source of names and erases it, so a provider holding an `any io.entropy` already cannot hand it on through that call either; `hosted/blocking` needed a private generic routine whose only line calls the entry. Met supplying `io.file_system` by delegation in R14.30. | The next change to how a concept's entries are called, or to `core/io`'s `make_temporary`. | An entry callable through a concrete type's name, or the helper taking an erased source as it is. | open |
| SR-361 | Usability | Supplying a concept by handing every entry to a field's provider takes one routine per entry, written out with its whole signature, failures and origins: `hosted/blocking` hands thirty-eight entries of nine concepts to the `hosted/system` handle it holds, each a three-line routine that only calls the same entry on `self.services`, and a new entry of any of those concepts must be added there by hand. Met splitting the hosted services in R14.30, and again writing `hosted/events`, whose `delegated.ldn` is a copy of the blocking provider's with each routine renamed. | The next provider built over another, or a change to conformance syntax. | A conformance that names a field whose provider supplies the concept, or the routines kept with the reason recorded. | open |
| SR-364 | Usability | R14.30 said the event Io would sit "beside `platform/linux`'s epoll", and there was none: `platform/linux` wrapped no epoll or signalfd call, and only `platform/linux/numbers` named their numbers, so a reader planning the provider was sent to a module that did not have it. Met starting R14.30's platform layer. | Fixed with it: R14.30's text names `platform/linux`'s epoll and signalfd wrappers and `platform/kqueue`, which now exist. | The roadmap naming only what exists, or saying it is to be written. | retired: R14.30 added the wrappers and `platform/kqueue` and its text names them |
| SR-368 | Usability | A struct field named `at` after another field, `listener: io.file` and then `at: net.address` on the next line, is refused with `L0102` "an expression belongs here" pointing at the colon: the parser reads `at` as the previous field's [1795] `at` offset clause, across the line end, and nothing in the report says so; the note asks for a literal, a name, a call or a parenthesised expression. Renaming the field was the only way on, found by guessing. Met writing the fake network's fixtures in R14.30, and again writing `hosted/events`' first fixture, `peer` for `at`. | The next change to the parser's struct-field recovery or to contextual words. | An `at` that begins a line taken as the next field's name when a `:` follows it, or the refusal saying it read an offset clause of the field before. | retired: an `at` that a `:` or `,` follows is the next field's name, in the parser and the structural grammar; pinned by `positive/field-named-at` |
| SR-369 | Usability | An array's length cannot follow the target's word: `[2 * 128 * compiler.word_size]u8` is refused with `L0203` "unavailable tool reference: compiler.word_size", although D437 lets a module value read that fact and `fixed if compiler.word_size == 32` selects on it, and `[2 * 1024 * sizeof usize]u8` with `L0305` "this is not one of the closed fixed-expression forms". A fibre fixture that must fit Cortex-M0's 12 KiB of RAM and give RV64 more than 8 KiB a stack declares its backing twice under a `fixed if`. Met sizing the R14.30 fake network and signals fixtures' stacks. R12.30 added `compiler.feature.fp` and `compiler.feature.fp_dp` (D615) and left what an array length may read unchanged. A fact reaches an array length through an immutable module value since R13.72 (D438); written inside the brackets it is still L0203, and `sizeof usize` is L0305, reported twice at one column. | The next change to fixed expressions, or the next compiler fact a program must read in an array length. | A compiler fact, or `sizeof` of a scalar, accepted in an array length, or the `L0203` refusal saying where the fact may be read instead. | open |
| SR-370 | Usability | Nothing says which sources a program is made of, or where its compile time goes among them: `refine check -v` names only the library, `--stage-report` gives each stage's time and the counts of sources, nodes and declarations, and `--build-report` names items by number. Attributing a hello-world's cost to `hosted/blocking`, `core/fibre` or `platform/linux` took a script that walked the `import` lines itself and copies of the library with one file deleted at a time. Met measuring the D476 split's compile-time cost in R14.30. R12.30 added the firmware report's `float_unit` and `image_block` without a module listing. `--build-report` lists each source's path, hex-encoded, but attributes no nodes or time to one. | The next change to `--stage-report` or `-v`, or to how the build report names a program's modules. | A report listing the program's modules and sources, with each module's nodes and its checking and lowering time, or `-v` naming the sources read. | open |
| SR-373 | Usability | A provider kept as a concrete value of another module's type cannot have its concept's entries called on it: `self.round.yield()` on a `stacks.round` is refused with `L0202` "`yield` is an entry of a concept this type conforms to, and the type's representation is module-internal", and the refusal does not say that the same call goes through when it is made through evidence. `hosted/events` wraps each of the round's four entries in a routine generic over `fibre.turns` (`turn(self.round)`), as `fibre.yield` does for `yield` alone. Met writing `hosted/events` in R14.30. `yield`'s refusal now names `fibre.yield`; `start`, `finished` and `wait` are refused with no route. | The next change to concept-entry calls or to `L0202`'s notes. | Calling a conformance's entry on a value of a public type whose representation is private, or the refusal naming the evidence call that does it. | open |
| SR-374 | Usability | One caller-declared state cannot back two library handles filled through `inout`: `system.over(state.cells)` and then `stacks.round_over(state.round, ...)` is refused with `L0315` "this argument is passed `inout`, so the call may change its storage while `services` still views it", though the two are disjoint fields, and the reverse order meets the same; a handle `from state` holding `system.new()`'s handle is refused with `L0316` "this writable `from` result also carries an independent storage origin". `hosted/events` therefore uses the process's last-error cell, with no `over` for a cell of the caller's own (D485). Met writing `events.new` in R14.30. | The next change to origin tracking of fields or to D222's independent storage. | Disjoint fields of one `inout` state filled by two calls, or the refusal naming the field it saw overlap. | open |
| SR-375 | Usability | On FreeBSD arm64 at `speed`, both with `--specialize=auto` and `all`, a task whose stack is cut from a module-storage backing (`mut backing: [2 * 16384]u8` at module level) and which slept once on `hosted/events`' clock before recursing past its stack ended in SIGSEGV with no output, where every other profile, and Linux arm64 and RV64 under QEMU, printed `trap: stack_exhausted` and stopped on `brk`. The same task over the same provider passed at every profile with the backing a local of the routine making the group, or with `fibre.yield` in place of the sleep; `runtime/fibre-stack-past-limit-traps` passes there. The handler's report goes through FreeBSD's C library `write`, reached through the PLT and the run-time linker's lazy binding, and nothing bounds that below D472's margin, so a handler that writes below the margin under a module backing lands in whatever the image lays out beneath it; this was not confirmed in the guest, which has no debugger the lane can drive from here. `runtime/events-stack-past-limit-traps` keeps its backing local as the existing fixture does. Met running the FreeBSD arm64 lane locally for R14.30's event provider. | The next change to the trap report on FreeBSD, D474's margin or the FreeBSD link. | The report reached without lazy binding (a direct system call, or a link with `-z now`) or the margin counted with it, and a module-storage variant of the fixture trapping `stack_exhausted` at every profile on FreeBSD arm64. | retired: confirmed in the guest, SIGSEGV in the run-time linker's symbol lookup with the stack pointer 848 bytes below the backing, and gone under `LD_BIND_NOW=1`; off Linux a program that prepares a stack now reports on a stack of its own (D491), and `runtime/events-stack-past-limit-traps` keeps its backing in module storage |
| SR-377 | Usability | An `any C` is no provider of `C`, and the refusal does not say what to write instead: prototype 5's sketch passes an `any net.network` to `net.accept`, `io.lines_over` and `io.buffered_over` and an `any time.clock` to a generic `answer`, and each is refused with `L0318` "this concrete type has no conformance to `network`", citing [1290]. The way on is to call the erased entry, `network.accept(listener)`, and for a generic routine to write an adapter that holds the `any` and forwards each entry, as `io.writer_of` does for a world and nothing does for a network; both were found by reading `core/io`. Met deriving prototype 5's server in R14.30. | The next change to erased dispatch, to `L0318`, or to `core/io`'s and `core/net`'s adapters. | `L0318` on an `any` actual naming the erased call and the adapter, or `core/net` lending a reader and writer from an `any net.network` as `io.writer_of` lends one from a world. | retired: an `any C` is a provider of C and of the concepts C refines (D492), so the erased network goes to `io.lines_over`, `io.buffered_over` and `net`'s routines as the sketch wrote it, and the derived session's adapter is gone; an `any` actual of a concept outside that closure is L0318 saying what it provides and to erase the provider as the wanted concept where it is made |
| SR-378 | Usability | `core/io/fake`'s network over turns fails a call `timed_out` after a round in which nothing in the network moved, even while another fibre of the same round is sleeping on a clock that takes turns and will answer when it wakes: a sleep is no move. A server's `accept` and a client's `receive` over it both time out during a 200 millisecond `WAIT`, so the derived server and client retry `timed_out`, which over the hosted providers, with no limit set, never happens. Met writing `runtime/derived-server-fake-turns` in R14.30. | The next change to `core/io/fake`'s network or clock. | A fake clock that takes turns whose sleep the network counts as a move, or the network given the clock it waits beside. | retired: `clock_beside` makes the fake clock beside the network, whose sleep takes the network's turns and moves the clock only after a quiet round, and the network times out no call while a fibre sleeps on it (D493); the derived server and client no longer try a timed-out call again, and `runtime/network-fake-turns-sleeper` pins an accept waiting through two sleeps |
| SR-379 | Usability | A two-process test has no ready parts. Nothing sends a signal to a child: `io.programs` has no entry for it and `platform/posix` no `kill`, so a parent stopping its child writes `linux.system_call(numbers.kill_number, ...)` on Linux and `libc.kill` on Darwin and FreeBSD under `fixed if compiler.os`, with the child's number from `hosted/system`'s `process_of`. A runtime fixture cannot build a second Landin program for the first to start, so the program starts itself again by `posix.program_name()` and chooses its part by its arguments, which the QEMU cross lanes cannot run without a binfmt_misc handler; running it under QEMU with `-0` naming, as its own name, a shell script that runs QEMU on the program again did, and nothing says so. Met writing `runtime/derived-server-two-process` in R14.30. | The next change to `io.programs`, to the fixture format's programs, or to the cross lanes' runner. | A portable way to signal a child, a fixture key naming a second program to build, and a cross runner that runs a program's own children under the same emulator. | open |
| SR-380 | Usability | A failed `scaling` job names its family only in its closing line, and the tail of its log ends in later families' rows: in run 40863273281 the verdict "locals: emission 8000 -> 16000 grew 2.52x" sat below `locals at speed`'s re-measurement marked "within the bound", and read as the script contradicting itself until the whole log was searched for the `locals:` heading. The `locals` family's emission measured 2.52x, 2.52x and 2.53x there and 2.41x on the rerun, against a 2.5x bound, so the job fails now and then on an unchanged compiler. Met pushing a README change to main between R14.20 and R14.30. | The next change to `scripts/scaling.py` or its bound. | The failure repeating the rows it judged under its family's name, and the `locals` family's margin explained or restored. | open |
| SR-390 | Usability | A refused type application leaves its binding with no type, and a generic call over the binding then types its literal argument as `i32`: on Cortex-M0, `mut total: atomic.cell(u64) = zeroed` is L0344 as it should be, and `atomic.exchange(addr total, 18446744073709551615)` below it adds an L0300, "`18446744073709551615` does not fit `i32`", for a value nobody wrote as an `i32`. The same happens on any target after `atomic.cell(bool)`'s L0318. The Cortex-M corpus's refusal of `runtime/atomic-read-modify-write` pins the second report among its codes. Met writing R14.40's atomic fixtures. | The next change to generic argument deduction, or the frontend-review item that re-pins cascades. | One report for the one mistake, and the corpus row re-pinned without its L0300. | open |
| SR-655 | Usability | `refine --target=rv32 --level=rv32imac DIR` succeeds with "checked DIR and wrote nothing; run it with `refine run DIR`, or build it with `refine compile DIR -o NAME`": the hint drops the `--target`, `--level` and `--root` the check was given, so the commands it offers check another build, on `rv32` a hosted one; `cortex-m0`'s positive fixtures record the same hint. Met recording `positive/atomic-read-modify-write-rv32imac` for R12.40's atomics. | The next change to the driver's closing line. | The hint repeats the selection the check was given, and offers only what the target can do. | retired: the closing line repeats the selection and offers `run` only for a hosted target, `compile` with `--firmware-entry` for firmware (D731) |
| SR-392 | Usability | On a fresh clone that had never been built, `./scripts/dev-test.sh` began with "landin: the last build did not finish (it was interrupted); rebuilding from clean, keeping bin/", which reads as a fault in a build nobody started. Met on a Mac clone running R14.40's Darwin fixtures. | The next change to `scripts/build.sh`'s attempt state. | A first build saying that it is one, or nothing. | open |
| SR-410 | Usability | Adding a row to `compiler/tests/cross-lanes.json` for a new fixture fails `scripts/tests/test_check_controls.py`'s `CrossLanes` control with "runtime/NAME names no fixture", though the fixture exists: the control checks the record in a copied tree whose files are a hand-kept list, and nothing says the list is what to extend. Met adding the QEMU row for `runtime/atomic-orderings-between-processes` in R14.40. | The next change to the cross-lanes record or its control. | The control copying every fixture the record names, or its failure naming the list. | retired: the control reads the fixtures it copies from the record itself, so a new row needs no second list; met again when R14.40's integration added the thread rows |
| SR-411 | Usability | On a Mac, `./scripts/dev-test.sh --fixture=runtime/r630-memory-scalars` refuses every `armv8.1-a` variant as "UNVERIFIED, not run: the darwin-arm64 lane has no /proc/cpuinfo to confirm a level with", though `compiler/tests/darwin/check.py`, which the gate's `darwin-parity` job runs, confirms the same level through `sysctl hw.optional.arm.FEAT_LSE`; the refusal names neither that route nor the sysctl, so a level fixture's focused Darwin check looks like a failure. Past that refusal the image check assumed `readelf`, which a Mac has not: it held every non-Linux-arm64 level to an x86 ISA note. Met checking R14.40's orderings on Apple silicon. | The next change to the test program's level confirmation or to the Darwin lanes. | The test program confirming a Darwin level through the same sysctl, or its refusal naming `compiler/tests/darwin/check.py --case`. | retired: R14.40's test program asks a Mac's `hw.optional.arm` sysctls, `FEAT_LSE`, `FEAT_CRC32` and `FEAT_RDM`, runs the level they confirm, and holds a Darwin arm64 image to its level with `objdump` as it does Linux arm64's |
| SR-412 | Release readiness | QEMU on an x86-64 host does not keep an arm64 `stlr` before a later `ldar`, which ARMv8 orders (the RCsc rule seq_cst's mapping relies on): QEMU 11.1's TCG ops, from `qemu-aarch64 -one-insn-per-tb -d op`, are `mb rel:all` then `qemu_st_i64` for `stlr x9, [x10]`, and `qemu_ld_i64` then `mb acq:all` for `ldar x9, [x10]`, so nothing lies between the store and the later load, and the x86-64 store buffer lets `runtime/atomic-store-buffering-between-processes` read both old values at `--optimize speed` in every local run, under user emulation and under the FreeBSD arm64 lane's system emulation alike, while the same rounds with a `dmb ish` between pass. Any program built by GCC or LLVM has the same `stlr`/`ldar`. Met in R14.40. | A QEMU release ordering them, or an arm64 lane that is not emulated on x86-64 for FreeBSD. | The fixture targeting FreeBSD arm64 again and its `cross-lanes.json` row removed, with the emulator's ops shown to order the pair. | watch |
| SR-381 | Release readiness | GDB cannot read a `link(thread)` instance in a static Linux program: under `--link=libc` `print counter` gives the selected thread's value, and statically linked it says "Cannot find thread-local storage ... Unable to fetch TLS block address", because GDB resolves `DW_OP_form_tls_address` through the C library's thread descriptors, which a block platform/linux lays has none of (D508). On arm64 ELF the datum has no location at all, since GNU as spells no DTP-relative word. Met checking D508 by hand on x86-64 during R14.40. | A debugger session that prints a thread's instance, or a static program's thread storage a debugger needs. | A scripted session printing a thread's instance on every hosted target, the static Linux block carrying what the debugger reads, and arm64 ELF described. | open |
| SR-382 | Usability | A routine returning either a module binding's address or a pointer its argument carries, `failure_cell: (self: host) -> (place: ptr mut i32 from self)` matching `calling_thread: place = addr thread_errno` and `ptr (own): place = own`, is refused with `L0316` "this writable `from` result also carries an independent storage origin", and the refusal does not say that module storage needs no `from` or what to write instead; `hosted/system` keeps and reads each cell inside the `match` instead. Selecting from the helper's result, `failure_cell(self).val = 0`, is refused with `L0103` "a call's result is not selected from", which does say what to do. Met writing D509's cells in R14.40. | The next change to D290's `from` rules or to `L0316`'s note. | `L0316` naming the alternative that is independent and saying how a result that may be module storage is written. | open |
| SR-383 | Language evolution | Nothing refuses keeping a thread's `link(thread)` address where another thread reads it after the first ends; D505 tracks the address as module storage's, and a store into a module pointer union, the one place module storage can hold it, is admitted. | A program that keeps a thread's instance's address in shared storage, or a defect traced to one. | D375's external alternative carrying "thread storage", and a store of it into a module binding without `link(thread)` refused. | retired: a store of a thread's instance's address into a module binding without `link(thread)` is L0314 (D772, `negative/thread-storage-address-kept-in-module`); call results and escaping arguments stay the program's |
| SR-384 | Release readiness | On Darwin a thread's first access to a `link(thread)` datum enters dyld's `tlv_get_addr` slow path, which saves every register and allocates the thread's block, on whatever stack the access runs on; on a prepared stack that depth is in no check and no depth report, as the C library's `write` was before D491. Every later access takes the fast path, which uses no stack. Found while emitting D496's accessor in R14.40; not measured. | A Darwin thread that first touches thread storage on a prepared stack, or the threads item's Darwin start. | The first access made before a prepared stack runs, or the slow path's depth measured and counted as D468's foreign opening. | retired: the threads `hosted/thread` starts write a `link(thread)` byte on their start area before the prepared stack runs, so dyld makes their storage on the C library's 16 KiB area (D517); a C thread calling into Landin makes it wherever its first access runs, as it calls any C function there, and the slow path's depth stays unmeasured |
| SR-385 | Competitive optimization | x86-64 reaches a `link(thread)` instance in two instructions, `movq %fs:0, %rcx` and a `@tpoff(%rcx)` operand, where one `%fs:x@tpoff` operand would do, because the backend's move helper reads an operand that begins with `%` as a register; D497's check uses the one-instruction form. | The optimization phase, or a measured hot loop over thread storage. | The single `%fs`-relative operand in every access, with the helper telling a segment-prefixed operand from a register. | open |
| SR-386 | Usability | `./scripts/dev-test.sh --fixture=abi/r440-errno-thread-local` on a Mac fails to link with "ld: unknown options: --wrap=open": the fixture's `c-args: -pthread -Wl,--wrap=open` are GNU ld's, and only `compiler/tests/darwin/check.py`'s parity run rewrites `-Wl,--wrap=NAME` to Apple's `-Wl,-alias,___wrap_NAME,_NAME`, so the gate's `darwin-parity` passes while the test program's own ABI execution on Darwin refuses the fixture, and nothing says which of the two is the fixture's Darwin verdict. The harness is unchanged by R14.40; met running R14.40's Darwin fixtures on the Mac. | The next change to the ABI fixture execution's C link or to Darwin parity. | One translation of a fixture's linker arguments for Darwin, shared by the test program and the parity run, or a fixture key that says which runner gives the Darwin verdict. | retired: `compiler/tests/c-args.targets` spells `-Wl,--wrap=NAME` as Apple's `-Wl,-alias,___wrap_NAME,_NAME`, and the test program and every Python lane read it; `fixture-meta.cases`' `c-args@TARGET` holds both readers to it |
| SR-387 | Competitive optimization | `hosted/heap` with no thread started still costs about 10 ns more an allocation and free of 24 bytes than the heap before its lock, 37.7 against 27.5 ns a pair at `--optimize speed` on Linux x86-64 (100 against 76 at `size`), though the flag it reads is one relaxed load that D499 lowers to a plain move; nothing has yet shown where the rest goes, whether the call into `hosted/thread/lock` or the cell's concept dispatch. D514 records the figures. | The optimization phase, or a measured allocation-heavy program. | The flag-clear path within a load and a branch of the old heap, measured. | open |
| SR-510 | Usability | A fibre's task has no row of its own in `--stack-report`: what a stack must hold below its first frame is the row of `core.fibre.stacks.first_frame`, a private routine of the library, and nothing in the report, `docs/library.md` or `--help` says that is the row to read; the depth there is the bound over every task the program can start, the deepest provider of each concept counted, not the task one group admits. Met sizing `runtime/fibre-same-source-any-provider`'s stacks from the report in R12.12. | The next change to `core/fibre`'s documentation or to the stack report's rows. | The row a fibre's stack is sized from named where a provider and an application are told how to size a stack, or a row per admitted task. | open |
| SR-401 | Usability | A bodyless `extern(c) link(symbol: "S")` import beside a public naked routine named `S`, which D415 makes a global symbol under its own spelling, is admitted with no L0347: the collision check compares explicit and C link names, and a public machine-convention routine's spelling is neither, so the pair reached the IR unchecked. D516 admits the pair when the naked routine names its symbol explicitly. Met trying ways to call `clone`'s naked text in R14.40. The pair checks clean and then fails at the link with an undefined reference to `spin_text`, since the naked routine is emitted as `main.spin_text`. | The next change to how naked or machine-convention routines' symbols are checked for collisions. | A public naked routine's own spelling held to the same collision rule as an explicit link name. | retired: a public machine-convention routine's own spelling is held to [1610]'s collision rule (D770, `negative/naked-routine-own-symbol-collides`); D516's pair still needs the routine's written link name |
| SR-403 | Usability | A shell's own descriptors look like a child's inherited ones, and the one place that says so is a comment in `runtime/run-no-descriptor-leak`'s source. Darwin's /bin/sh, bash 3.2.57, keeps a descriptor of its own at the lowest free number from 10 up while it works: a probe that tried `(true >&"$fd") 2>/dev/null` for each number from 3 found 10 open in every child, and so did its replacement, which tried only the numbers its parent named with `(exec 2>/dev/null; exec 1>&"$fd")`, into a pipe and into a file alike, with nothing inherited; dash, Linux's sh, finds nothing. Nothing in `docs/process.md` or the fixture README says how a fixture asks a child which descriptors it holds. Met when `runtime/thread-spawn-leaks-no-descriptor` failed only on Darwin, twice, in R14.40; it now starts itself again and asks `poll` about the numbers its parent names, as `runtime/run-no-descriptor-leak` does. | The next fixture that asks a child process what it holds. | A shared, documented way to ask, in the fixture README, beside the warning that a shell cannot be the check. | open |
| SR-525 | Usability | `record.name = name`, a whole `[16]u8` parameter assigned to a record's `[16]u8` field, is L0334 "this selects a whole array field, and this position does not take one", pointing at the field, while the same assignment from a local array, `copy: [16]u8 = name` and then `record.name = copy`, and a record literal `(name: name, ...)` are both accepted; the note, "an array is copied, passed, returned, discarded or computed with whole", says the assignment is one the language has. The refusal blames the destination for what the source being a parameter decides. Met writing `platform/posix`'s interface lookup for zoned addresses in R12.12. | The next change to the checker's whole-array rules. | A whole array parameter assignable to an array field as a local is, or a refusal that names the parameter and says to copy it into a local first. | open |
| SR-526 | Usability | Nothing turns a Landin `extern(c)` function into the `u64` that `platform/libc`'s `signal_action.handler` keeps, so `runtime/sleep-signal-sleeps-on` installs its handler by storing the function in a binding and reading the binding's word through a `ptr u64`; neither `docs/from-c.md` nor `platform/libc` says how a handler is given to `sigaction`. Met writing that fixture in R12.12. | The next change to `platform/libc`'s signal declarations, or a consumer that installs a handler. | `signal_action`'s handler typed as a C function value, or a documented conversion from one to its code address. | open |
| SR-527 | Usability | `defer finished = true` is L0103 "`defer` registers a call, not a constructed value", with the note "write the call that runs when its block is left": an assignment is called a constructed value, and the way to defer one, a routine of its own that makes it, is not said. Met writing `runtime/events-connect-within` in R12.12. | The next change to `defer`'s refusals. | An assignment after `defer` named as one, with the note showing it moved into a routine the `defer` calls. | retired: R13.75: an assignment after `defer` or `undo` is named as one, the note moving it into a routine the cleanup calls (D873) |
| SR-420 | Usability | `extern(c) InitWindow: (...) -> none`, raylib's own name, is L0012 "identifiers use lower-case letters" once per capital letter, 58 errors for eight declarations, and neither the note nor `refine explain L0012` says that a C name Landin cannot spell is `extern(c) link(symbol: "InitWindow") init_window: ...`; `docs/from-c.md`'s "Calling C, and linking it" calls `atoi`, which needs no link name. Met calling raylib from the 0.2.8 archive, guessing from C, in a newcomer trial on 2026-10-29. | The next change to L0012 or to `docs/from-c.md`'s C entry. | One refusal per identifier, naming `link(symbol: ...)` when the declaration follows `extern(c)`, and the C entry showing a mixed-case C name. | retired: R13.74 reports a word with a capital once, and an `extern(c)` name's note shows `link(symbol: "InitWindow") init_window` (D528); `docs/from-c.md`'s C entry calls raylib's mixed-case names, `negative/c-name-with-capitals` pins the note |
| SR-421 | Usability | A C function taking raylib's `Color` by value, declared as a plain `struct`, is L0346 "C cannot take this parameter" with [1580]'s whole C-signature rule as its note, eleven clauses, `layout(c) structs` among them, rather than saying that `color` is not `layout(c)`. Met in the same trial. | The next change to L0346. | The refusal naming the record and the `layout(c)` repair. | retired: R13.74's L0346 says "C cannot take `tint`: `color` is not `layout(c)`" with the repair (D529), pinned by `negative/c-record-not-layout-c` |
| SR-422 | Usability | Nothing says where `linker.library("raylib")` looks: `-L` is "unknown option: -L", `refine compile --help` names no search directory, and an archive in the project's own `raylib/lib` was found only through GCC's `LIBRARY_PATH`, which no document mentions. Met in the same trial. | The next change to [1590] or to `compile`'s link options. | A documented way to name an archive's directory, and a missing archive's refusal naming it. | retired: R13.74 adds `linker.directory` beside the source and `-L` on `check`, `compile` and `run`, each also the runtime search path (D524), and a library the link cannot find is L0509 naming every directory searched (D525) |
| SR-423 | Usability | `linker.library("m")` passes `-l:libm.a`, so under `--link=libc` glibc's static `libm` goes into a dynamically linked executable, and raylib 5.5's `libraylib.a` then fails with "undefined reference to `_dl_x86_cpu_features`" from libm's ifunc members; the same C program fails alike with `-l:libm.a` and links with `-lm`. Only a `--toolchain` wrapper appending `-lm` linked it. [1590]'s own example is `linker.library("m")`, and `runtime/r430-static-library` calls only `fegetround`, which avoids those members. Reproduced with glibc 2.42 on NixOS; Debian and Ubuntu not tried. Met in the same trial. | Now: [1590]'s own example. | The C runtime's own libraries linked as the driver links them, or a shared-library form, with a fixture calling `sqrtf` and `pow` under `--link=libc`. | retired: under `--link=libc` a library is the C driver's `-lNAME` on every hosted target (D523); `runtime/c-library-directories` calls `sqrtf` and `pow` from libm beside two archives built beside it |
| SR-424 | Usability | `refine main.ldn` exits 0 silently having only checked, so a newcomer looks for an executable that was never written, and `refine run main.ldn` answers "`refine run` is not a command: name the source to check it, as `refine FILE`", steering to checking rather than running. There is no compile-and-run, which `hare run`, `nim c -r`, `crystal run`, `rdmd` and `c3c compile-run` each offer. Met in the same trial. | The next driver item. | The bare form saying it checked, and either a compile-and-run command or the refusal naming `refine compile main.ldn -o prog`. | retired: R13.74 adds `refine run FILE [-- ARGS]` and has bare `refine FILE` say it checked and wrote nothing (D526) |
| SR-425 | Release readiness | The 0.2.8 archive's `bin/refine` is 100 MB, not stripped and carrying its debug information; stripped it is 27.6 MB. Met unpacking the archive in the same trial. | The next release. | The released compiler stripped, or its debug information shipped apart, with the archive's size stated beside the install route. | retired: R13.74's `scripts/package.sh --debug` publishes the debug information beside the archive, which on Linux x86-64 drops from 34 MB to about 10 MB, and the README says so (D531) |
| SR-426 | Usability | `io.println(x)` is L0201 "module `io` has no member `println`", naming nothing to use instead, and the shortest way the documents give to print an integer is `docs/from-c.md`'s `printf` entry: a buffered writer over a storage array, a deferred flush and `[any(addr name), any(addr count)]`. A float cannot be printed at all (SR-97). Met printing a number in the same trial. | The next change to L0201 or to `core/io`'s writing. | L0201 naming the module's nearest members, and one line that prints an integer shown before the tour's first loop. | retired: `io.write_format` writes a template and its values in one call, the tour prints with it before its first loop, and `print`, `println`, `printf` and `puts` asked of `core/io` are told it (D527) |
| SR-427 | Usability | Diagnostic notes cite paragraphs and decisions, `[1760]`, `[1580]` and `D275`, which `refine explain` refuses ("no catalogue row holds the code: D275"), so a reader at a terminal cannot follow a note's citation without the site. Met in the same trial. | The next change to `refine explain` or to diagnostic notes. | `refine explain` resolving a citation, or a note carrying where to read it. | retired: `refine explain` answers `[1590]`, `1590`, `D275` and `d275` with the title, place and page, and `--full` with the text (D530) |
| SR-429 | Usability | `refine run` removes its private directory when the program ends, is refused or is killed, and ignores the terminal's interrupt and quit while it runs, but a `SIGTERM` or `SIGHUP` to refine itself, as a closed terminal or `kill` sends, ends refine at once and leaves `refine-run-*` under `TMPDIR`. Met stopping a spinning program's run with `pkill`. Met again integrating R12.12: a stream's `refine run` of a program that spun ended without its child, which then ran for thirteen and a half hours at a full core, parented to the session manager, until a load check before `scaling.sh` found it. | The next change to `refine run`. | refine forwarding termination to the program and removing the directory, or the leftover named where it is. | retired: `refine run` passes SIGTERM and SIGHUP on to the program and removes its directory (D730) |
| SR-440 | Usability | A `_` arm on a variant part, `_: fail no_space` after `drains(onto): ...`, is refused as L0333 "this case does not belong to the variant part matched here", beside an L0312 for each case it was to cover, although [1210] says the subject may be "a variant part" and that "`_` is an arm of its own and covers whatever is left". D77 declined a wildcard on a variant part, which neither the tour nor the refusal says; naming the remaining cases in one arm (D405) is the way on, found by reading `spec.md`. Met writing `core/text`'s draining builder in R13.74. | The next change to [1210] or to `match` on a variant part. | [1210] saying where `_` stands, and its refusal on a variant part saying that a wildcard is not taken there and to list the cases instead; or a `_` arm admitted. | retired: R13.75: [1210] says where `_` stands, and on a variant part it is one L0333 naming the cases to list, with no L0312 per case (D866) |
| SR-441 | Usability | Following L0201's note for `io.println(answer)` in a program that imports only `core/io`, `io.write_format(host, io.out(host), "{}\n", [any(addr x)])`, still leaves a newcomer to find where `host` comes from: the note named the call and not `hosted/blocking`'s `blocking.new()`. Met repeating the print trial outside the checkout in R13.74. | Now: the note. | The note naming where a hosted program's `host` comes from. | retired: R13.74's note says where `host` comes from |
| SR-450 | Usability | `refine explain [1760]`, the citation as a note writes it, never reaches `refine` under zsh, macOS's default shell: zsh reads `[1760]` as a pattern and answers "no matches found: [1760]"; bash passes it on only while no one-character file named `1`, `7`, `6` or `0` is in the directory. Met trying the new citation forms from a terminal outside the checkout. | The change that makes `refine explain` answer citations. | The bare `1760` accepted beside `[1760]`, and the explanation page saying which to write in zsh. | retired: `refine explain 1760` answers as `[1760]` does, and `docs/diagnostics.md` says to write it so in zsh |
| SR-451 | Usability | A `layout(c)` record holding a plain struct is refused at its field, and every C signature taking that record is refused again with L0346's general note, all eleven clauses of [1580], though its only fault is the field already reported. Met declaring raylib's `Camera2D` over a plain `Vector2` while trying the record's refusal outside the checkout. | The next change to L0346 or to C layout validation. | A signature over a record already refused for its layout says nothing more, or names that record. | open |
| SR-460 | Usability | `python3 check.py docs/from-c.md`, the narrowest scope a reader is told to use, reports "'at' is a keyword and cannot be a name" at line 1223, a parameter the test program compiles, while the full `python3 check.py` reports the same file clean: the single-file and full runs read the document under different word lists. Met checking `docs/from-c.md` alone while integrating R13.74. | The next change to `check.py`'s per-file checks. | One verdict for a document whichever scope checks it. | retired: a file named alone gets the per-file rules the full run gives it, and any other is left to the full run with a line saying so |
| SR-461 | Usability | The call L0201's note offers for `io.println(x)`, `io.write_format(host, io.out(host), "{}\n", [any(addr x)])`, pasted as it is, is L0329 "this failing call is neither tried nor recovered with `else`": the note leaves out the `else none` that hello world's own `io.write` line carries. Met repeating the newcomer trial on a release-shaped archive outside the checkout. | Now. | The note's call compiling as written in `main`. | retired: R13.74's note carries `else none` |
| SR-462 | Usability | `add: (a: i32, b: i32) -> i32 =`, a C programmer's unnamed result, is first L0104 "this function is never closed" at the `->`, although `end add` closes it, and only second L0103 "returns are named, or `none`", which is the mistake and its repair. Met in the same trial. | The next change to the parser's recovery of a signature. | One report, the named-results one. | retired: R13.75: one L0103 naming the named form, for a bare type and for named returns without parentheses, the function closed by its own `end` (D861) |
| SR-470 | Usability | `refine FILE` on a source with no `main`, a library module or a file still being written, answers "checked FILE and wrote nothing; run it with `refine run FILE`, or build it with `refine compile FILE -o NAME`", and both commands it names then refuse the same file as L0502 "a hosted program needs public main". Met checking the reduced reproducer of the gate's fuzzer hit while integrating R13.74. | The next change to the driver's closing line. | The closing line offering `run` and `compile` only for a program that has a `main`, and saying for one without that it was checked as a module. | retired: R13.75: the closing line offers `run` and `compile` only for a program with an entry, and says a module was checked otherwise (D883) |
| SR-471 | Usability | `count = lenof line +`, an expression cut off after its operator, is L0102 "`line` and `+` are written the wrong way round" with the note "written as `count = lenof + line` the line parses", and that line is L0201 "`lenof` is not declared"; `y = x +` gets the right "a value belongs after `+`". The repair search treats `lenof`'s operand as a name it may move. Met writing the reproducer of the same fuzzer hit. | The next change to the parser's operator repairs. | A trailing operator after a `lenof` or `sizeof` operand answered as one after any other value. | retired: R13.75: no repair moves `lenof` or its operand, and a trailing operator after a measure is answered as after any value (D864) |
| SR-472 | Usability | `compiler/tests/fuzz/fuzz.py --batch`, the command-line oracle, runs `refine FILE` with no import root, so a mutant of a fixture that imports outside the library, such as `runtime/derived-server-two-process`'s `examples/derived_server/app`, is refused as L0006 and neither `--batch` nor `--batch --reduce` can reproduce or reduce a defect it shows on the command line; the server oracle's own reduction keeps that import, so its result cannot be a reproducer the server suite serves without a root. Met reducing the gate's fuzzer hit at seed 501824, which took a reducer of its own. | The next change to `fuzz.py`. | `--batch` passing the checkout as `--root`, as the server oracle's initialization does. | open |
| SR-473 | Language evolution | Renesas's FPB-RA8E1, on the maintainer's rig: a Cortex-M85, Armv8.1-M with the MVE (Helium) vector extension, and with the PACBTI pointer authentication and branch target extension unconfirmed until its ID_ISAR5 is read; Renesas's FSP headers give the RA8E1 no double-precision FPU. No level, register class or emulator lane covers Armv8.1-M or MVE. | A program that wants MVE or the M85. | The M85 learnt through R12.11's importer, an Armv8.1-M level with its MVE registers in [1630]'s classes and the C ABI, PACBTI decided from the read ID_ISAR5, the corpus on QEMU's `mps3-an547` M55 core lane, and a recorded board run. | open |
| SR-690 | Usability | `compiler.atomic_store(addr word_cell, word, compiler.seq_cst)` on a `mut word_cell: atomic.cell(u32)` is refused with L0344, "memory access needs an unsigned scalar pointer without a subtype", whose note cites [1620]/D227 and names neither `core/atomic`'s own `atomic.store` and `atomic.load` for a cell nor a plain `u32` for the builtin; the fix was found by reading `core/atomic`'s source. Met writing the ESP32-C3 board port's atomics for R12.40. | The next change to L0344's texts or to `core/atomic`. | When the pointer is to an `atomic.cell`, the refusal names the cell's operations, or the builtins accept a cell. | retired: R13.75: L0344 names the pointer and, for an atomic cell, the cell's own operations (D882) |
| SR-692 | Usability | On the maintainer's rig every hub of the cascade under 7-2 re-enumerates, the Arty's FTDI and every board's USB device with it, whenever any port of it is switched or any device on it disconnects: an ESP32-C3's `probe-rs download` ended at 15:33:47.22 on 2026-11-02 with the chip's reset, whose USB-Serial-JTAG then dropped, and at 15:33:47.66 `usb 7-2: USB disconnect` took the whole tree until 15:33:50, so the run's next `uhubctl -l 7-2.3.4`, at 15:33:48, found no hub; a guarded cycle of the ESP32-C5's port at 15:32:31 did the same, and two streams' runs disturbed each other until every run took one host-wide lock. Paced two minutes apart after a quiet minute, an ESP32-C5 download at 20:57:5x set off a storm, 20:57:57 to 20:58:02, of whole-tree disconnects in which the kernel itself power-cycled `7-2-port4`, `7-2.4-port4` and `7-2.3.3-port4`, the Arty's; an image the ROM refuses leaves an ESP chip resetting every few seconds, each reset dropping its USB-Serial-JTAG, until a good one is written back; and uhubctl, between two switches, finds no hub while the cascade re-enumerates, for up to most of a minute. Since then every board run holds `common.rig_lock`, the Arty is off the cascade (D725) and the RP and ESP boards' READMEs say every switch re-enumerates it; the RP and STM32H753 tools do not wait for the hub after a download, and `environments/boards/stm32h753/README.md` does not name the cascade. Met running the ESP boards for R12.40. | The rig's next hub, or a board run the cascade's re-enumeration disturbs. | Every board run under `common.rig_lock`, every tool waiting with `common.wait_for_hub` after a download or a switch, as the ESP tools now do, and a hub topology whose switching does not reset its parent, or the cascade documented in each board's README. | retired: every board run holds `common.rig_lock` and every tool waits for the hub after a download or a switch (D832); on the cascade's present port a switch drops only its own device, measured on 2026-11-03, so the fixed spacing is gone (D725 amended); every board's README describes the cascade |
| SR-693 | Language evolution | The ESP32-C3 board port runs at the chip's reset clock, 20 MHz from the crystal, because nothing in the RAM-only image brings up its PLL, and at that clock its interrupt-driven receive and echo keep pace with 115200 baud only when the host waits for each 64-byte piece's echo (D727); a C3 program that wants its 80 or 160 MHz has no library or description support for the PLL and the analog registers it is configured through. Met recording the C3's board run for R12.40. | A program that needs the C3's or C5's full CPU clock. | The PLL bring-up as a description stage or a `platform` routine, cited from the TRMs, and the board's stream at the line's rate. | open |
| SR-694 | Language evolution | One trap on the ESP32-C3, 2026-11-02 about 22:10, that no handler took and nothing explains: the RV32 unhandled entry's record (D656) held cause 0x2 (illegal instruction), pc 0x00000002, value 0x0, sp 0x3fcc7d10, count 1; ra was not recorded. pc 2 is a jump to address 0 or 2, which the RX FIFO drain fixed by D726 alone does not account for: the image's function values were intact in memory afterwards (`port` at 0x40385e20 held indicate 0x403802d0 and transmit 0x4038034c through both buses). It ran a diagnostic build of the C3 board port before D726, built at r1240-s8 982fea271's parent with counters added in the main loop, OUT.bin SHA-256 ca64ec01d5a9f53dfdf61655478fc967d7f229cd55053cc6a1f67e9cc4e84b60, ELF 7defda26a4c538254417de3e6e461c83b386bc6949049d61c32f19d29ca00b51, at the C3's 20 MHz reset clock: after a paced download and power cycle, a recovery from line noise on UART0 (recoveries 1), two bytes handled, the last of them 0, no command dispatched, and then the trap; the main loop's counters stopped there and the timer interrupts with them. The recorded runs of both ESP boards since, with D726, read a trap count of 0. Met debugging the ESP boards' threshold step for R12.40. | A second trap of the kind on any RV32 board or lane. | The trap's instruction found from its record and the image, and its cause fixed where it lies. | watch |
| SR-474 | Language evolution | Espressif's ESP32-P4, on the maintainer's rig as chip revision v1.3 on board Rev.D: RV32 with F, whose ESP-IDF builds use `rv32imafc_zicsr_zifencei` below revision v3 and add Zc* and B from it, with the hard-float `ilp32f` ABI. No RV32 level has F, no register class holds its float registers, and Espressif's QEMU has no P4 machine. | A program that wants RV32 float hardware. | The P4 learnt through R12.11's importer, an F level with the `ilp32f` ABI in the C ABI planner and float operands in [1630], revision-dependent extensions as levels rather than one assumed chip, an `rv32imafc` emulator lane for the core, and a recorded board run. | open |
| SR-475 | Release readiness | The C binding generator, a feature a developer uses, was a Python script under `bindings/`, so binding a C header needed Python; no feature of the compiler may. | The next change to the binding surface, and before R13.20's executable C interoperation. | The generator ported into `refine` in Ada with no new dependency, still asking the pinned Clang for its AST rather than parsing C, its four outputs and their checks unchanged, and the Python generator removed. | retired: `refine bindings` is the generator (D820, D821), in Ada with no new dependency, still asking the pinned Clang for its JSON AST; its four outputs matched the Python generator's byte for byte for all 220 generations its tests make and for the r440 fixture on all three targets, save the first line naming `refine bindings`; the tests and the gate's `bindings` job run refine, and the Python generator is removed |
| SR-481 | Usability | A `refine` copied out of its build tree finds no library, and a static Linux program is then L0500 "no library holding platform/linux was found" with the note "name the library with --library=PATH", while `refine --help` says `--library=DIR`, "find core, hosted and platform under DIR": the note does not say that the directory wanted is the one holding `core`, `hosted` and `platform`, the checkout's root, rather than a library file. Met emitting the corpus with a saved copy of the compiler to compare its assembly before and after a backend change. | The next change to D363's refusal or to how `refine` finds its library. | The note naming `--library=DIR` and the directory it wants, as the help does. | open |
| SR-540 | Usability | A fixture's `root` names one import root, so a fixture that needs two, such as `negative/empty-first-directory-hides-a-later-root`'s first and later roots, writes both and its entry module in `args` as paths from `compiler/ada`, `--root=../tests/fixtures/negative/NAME/first`, which only `negative/module-not-found`'s metadata shows and which repeats the fixture's own name three times. Met writing D563's fixture in R12.12. | The next change to the fixture metadata's keys or to `scripts/add_fixture.py`. | `root` taking several directories in order, relative to the fixture, or the `args` form for several roots stated where `root` is described. | open |
| SR-573 | Usability | L0517's natural example, `link(region: "NOWHERE") table: u32 = 1` at `--target=cortex-m0`, is refused with it by `refine` beside its library, and the test program compiles an example on a file system holding the example alone, where no library holds the constrained reference, so the program is refused as L0518 and the section shows no example; a region placement cannot stand in a description's own module, so no one-file example raises it. L0518, L0519 and L0538 need a library without the reference, a linker script or the assembler's object, and show none either, and so does L0555, R12.30's image-block refusal, which needs the assembler's object. Met giving the Cortex-M codes their examples in R12.20. | The next diagnostic section whose code needs the library, or the next change to how the test program compiles the examples. | The examples compiled beside the repository's own library, or an example form that holds a second file, stated where the page describes its examples. | open |
| SR-497 | Usability | ST's RM0433, the STM32H753's reference manual, cannot be fetched by a script: www.st.com resets the HTTP/2 stream and times out over HTTP/1.1. It is pinned in `devices/inputs.json` by URL and SHA-256 as Rev 9, which the STM32H753's reviewed literals cite by section and page, but marked `"fetch": "by hand"`, so a person must download it in a browser and put it in the cache before `scripts/fetch_inputs.py --all` can verify it, and no job can. Met learning the STM32H753 under R12.11; the maintainer supplied the copy. | R12.20's board run, or the next item that checks a chip against a manual its publisher serves only to a browser. | A source that serves the pinned manual to a script, or the maintainer's decision that hand-supplied manuals stay, recorded with how a reviewer obtains one. | retired: R12.12 keeps a manual its publisher serves only to a browser supplied by hand, pinned by URL and SHA-256, with how a reviewer obtains it beside the pin |
| SR-670 | Usability | `environments/cortex-m/descriptions.json`'s `devices` is where a description's facts are recorded apart from the compiler, and its readers are Cortex-M's: `descriptions.py` and `backend.py` skip every record naming another target (D661), so the ESP32-C3's, the ESP32-C5's and RP2350's Hazard3 records, each naming `rv32`, are recorded and nothing compares a linked image with them; and the Hazard3 record holds no table address, boot prefix or suffix, since RP2350's RISC-V image puts its code before its trap table and block, a layout the boot kind decides and `backend_corpus.py`'s fixed `boot_prefix` does not describe. Met recording R12.40's three RISC-V descriptions. | R12.40's RV32 descriptions lane. | A lane that selects each RISC-V description by its identity and compares its linked image with its record, the Hazard3 record completed with the layout the boot kind gives. | retired: R12.40's descriptions lane links every RV32 description with the RV32 toolchain, selects each by its record's `target` and identity, and holds the linked image, its slots and the Hazard3's completed layout and block to the record |
| SR-673 | Usability | `import "esp32c5/clic"`, a module path in quotes as a text literal, is refused with L0100 "a name belongs here" at the quote, whose note cites [1760]'s rule for names and says nothing of an import taking a bare path, `import esp32c5/clic`. Met checking the generated ESP modules with `refine check` in R12.40. | The next change to the parser's import refusals. | The refusal at an import saying that a module path is written without quotes. | retired: R13.75: the refusal at a quoted import path says the path is written without quotes (D862) |
| SR-515 | Usability | `environments/cortex-m/gdb_server.py` promises that a session cannot see the one before it and discards breakpoints between sessions, but a breakpoint a script makes with `internal=True` survives `delete`, so the corpus's first stack-guard watchpoint, made internal, fired in the paint loop of the next program on the same worker, at an armv7-m profile, and failed it as a stack overrun. Met adding the guard in R12.12, which now makes an ordinary watchpoint. | The next change to how `gdb_server.py` ends a session's breakpoints and watchpoints. | The server removing every breakpoint and watchpoint a session made, internal ones included, or its contract saying a session may make none. | retired: `gdb_server.py` deletes every breakpoint and watchpoint a session made, internal ones included; `test.py`'s fake-GDB control and the shared-debugger control hold the next session to seeing none |
| SR-550 | Usability | A rooted negative fixture runs on the real host with its recorded `args`, so one the compiler unexpectedly accepts writes its output where the test program runs: `negative/stack-handler-opens-its-graph`, whose `args` say `--emit=asm` without `-o`, left `compiler/ada/a.s` in the checkout when a change to the stack report made it compile, beside the parser suite's verdict that its codes were missing. Met integrating R12.12. | The next change to the parser suite's pinned-codes case or to how a rooted fixture is run. | Such a run writing into a directory of its own, or its output named beside the failure. | retired: rooted negatives are compiled through an overlay that refuses writes; the failure shows the report naming the refused output |
| SR-551 | Usability | A scripted server session that needs a directory with nothing in it passes where it was written and fails in every clone: `handler-margin` opened `file:///workspace/app/main.ldn` with only an empty `workspace/app` beside its transcript, which git does not keep, so the merged tree's server answered L0007 "entry module is not a directory". The native runner also rewrote only `file:///workspace`, so a session naming a library file, as the fake host's `/opt/landin/lib/landin`, could pass only in-process. Met integrating R12.12; the session now carries its source in `workspace/` and the native runner maps the library prefix. | The next change to the session harness or `native_session.py`. | The harness refusing a session whose document's directory it does not hold, naming the file to add. | open |
| SR-552 | Usability | `python3 scripts/script_tests.py`, run inside `nix develop` as AGENTS.md says, passes a test that leans on a tool only the shell carries, and the gate's `scripts`, `release` and `arm64-release` jobs, which run outside it, are the first to fail: `test_the_linux_runner_refuses_before_building` expected the "not empty" refusal and the runners, with no `lldb` on `PATH`, met "no lldb on PATH" first. Met in R12.12's first gate run. | The next change to `scripts/script_tests.py`, or a script test that needs a tool only the dev shell carries. | A local way to run the script tests as the gate's jobs do, outside the shell, or each job's tools named and checked before its tests. | open |
| SR-553 | Usability | `code = outcome when outcome > 30` is L0110 "this begins no statement" at `when`, whose note lists the statements; nothing says that `when` qualifies only `return`, `break` and `continue`, or that an assignment wants an `if`. Met making a fixture's status say which case failed in R12.12. | The next change to L0110's notes or to `when`. | The refusal naming the three statements `when` qualifies and `if` as the form for the rest. | retired: R13.75: the refusal names the four exits [0970] gives `when`, and `if` for the rest (D865) |
| SR-554 | Usability | `compiler/tests/freebsd/check.py --case runtime/network-connect-within`, the name every other runner takes, and `--case runtime-network-connect-within`, the outcome's spelling in the lane's own transcript, are both "unknown exact case"; the lane wants the fixture directory's bare name, `network-connect-within`, which the refusal does not say and `--help` calls an "exact fixture name". Met rechecking three fixtures in the FreeBSD VM during R12.12's gate. | The next change to the FreeBSD lanes' selection. | The lane taking `CLASS/NAME` as the other runners do, or the refusal listing the names it knows. | open |
| SR-555 | Usability | The Cortex-M lanes' QEMU 10.0.13 and GDB 16.3 with Python are Debian binaries locked in `environments/cortex-m/tools.lock.json`, and since the RV32 lanes so is Espressif's QEMU 9.2.2 release binary with the 36 Debian libraries it loads, so on NixOS every lane, three programs in all, runs only under `steam-run`, with `TMPDIR` and its output under `$HOME`, the route `environments/cortex-m/README.md` gives, and setup only with `dpkg` and `xz` added to that shell. A flake package building QEMU's ARM system emulator, Espressif's QEMU and GDB from upstream at the locked versions would let `nix develop` run every lane as the gate does; R12.12 declined it as a second source of the same pins beside the lock, and builds no cache holds. | The next version or packaging change to the locked QEMU/GDB runtimes, or a maintainer decision that the flake carries them. | The lanes' QEMUs and GDB built by the flake at the lock's versions, every lane run from `nix develop` without `steam-run`, and the gate's lanes on the same build or its lock checked against it. | open |
| SR-661 | Usability | `environments/cortex-m/README.md`'s "On NixOS" gave the `steam-run` route for `run.py` only; `setup.py` under the same route fails, because NixOS puts neither `dpkg-deb` nor, since the RV32 lanes' `tar.xz` archive, `xz` on the path that `steam-run` inherits, and finding that took trial. Met installing the RV32 lanes' tool root. | This change. | The README giving setup's own route on NixOS. | retired: the README gives setup's route, with `dpkg` and `xz` in the shell |
| SR-662 | Usability | A tool root installed before the lock changed refused every lane with "tool lock mismatch", and one whose files differed from its record with "installed tools changed", neither saying which area differed or that a fresh root is the remedy, since setup refuses an existing one. Met moving to the RV32 lanes' lock with an older root. | This change. | Both refusals naming what differs and the fresh `--tools` root. | retired: both name the root, the differing areas and `setup.py` |
| SR-569 | Usability | `refine --target=cortex-m0 FILE` closes "checked FILE and wrote nothing; run it with `refine run FILE`, or build it with `refine compile FILE -o program`": both commands drop the target it was given, so the first refuses a firmware source as L0502 "a hosted program needs public main", and with `--target=cortex-m0` put back `refine run` is L0002, since nothing runs a Cortex-M program on the host; a firmware build needs `--firmware-entry`, which the line does not name. Met recording `positive/assembly-comments-naked`'s expectation in R12.20; SR-470 is the same line on a source with no `main`. | The next change to the driver's closing line. | The closing line keeping the target it was given, and offering a firmware target `refine compile --target=... --firmware-entry=NAME --emit=exe` rather than `run`. | retired: the closing line keeps the target and offers a firmware target `compile` with `--firmware-entry` (D731) |
| SR-571 | Usability | `python3 scripts/add_fixture.py positive/NAME` says it made the fixture "known everywhere a fixture has to be known" and ends "now run ./scripts/dev-test.sh --fixture=positive/NAME and python3 check.py", both of which pass, but a positive fixture is also recorded in `compiler/tests/lowering.ir`, so the next `--suite=lowering` fails "the recorded corpus is current" until `--record=lowering` writes it, a step neither the script nor its closing line names. The same fixture's multi-line raw literal broke `compiler/tests/lexical.tokens`, which the script regenerates and only `--suite=lexer` reads: the token dump wrote the literal's lines as they were, and its reader took each as a token, so `lexer/agrees with the corpus` raised CONSTRAINT_ERROR in every job of the branch's first gate while the selections the script and the briefs named all passed; the dump now writes a line break inside a token as `\n`. Met adding `positive/assembly-comments-naked` in R12.20. Met again in R12.30: a stream that edited `runtime/assembly-keeps-call-preserved-floats` ran every suite its brief named, and only the integrated tree's `--suite=formatting` found the edit unformatted, in `the corpus is formatted`; nothing an edit of a fixture is pointed to says the corpus is held to `refine fmt`. | The next change to `scripts/add_fixture.py`. | The script recording the lowering corpus for a positive fixture, or its closing line naming `./scripts/dev-test.sh --record=lowering`, and the fixture format's documentation naming `refine fmt` and `--suite=formatting`. | retired: `add_fixture.py` lays out a positive, runtime or ABI fixture's sources with `refine fmt` and ends naming, per class, `--record=lowering`, `--record=CLASS/NAME` for an unwritten report, one run of the fixture and the corpus cases that read it, the highlighters' integration pass and `check.py` |
| SR-556 | Competitive optimization | RP2040's description boots through a port of pico-sdk's generic second stage, which reads the flash with the serial 03h command at a quarter of the system clock, so every cache miss in flash costs one serial read; pico-sdk's default for the Pico, `boot2_w25q080.S`, reads four bits a clock, and it also writes the flash's non-volatile QE bit when that is clear, a path the Pico H's W25Q16JV, shipped with QE set, would never run. Chosen for the first board because every instruction of the generic stage runs on it and it fits any RP2040 board's flash. | A program whose speed in flash matters on an RP2040 board, or a board whose flash the generic stage cannot read. | A quad-read second stage for that flash in its description, every path of it executed on the board. | open |
| SR-610 | Usability | `link(section: ".ramtext.handle")` on a generic routine, `handle: (port: type is device, bytes: []u8, p: port)`, is refused as L0347, "invalid or conflicting Cortex-M0 placement", whose note lists the section spellings, alignments and vectors [1640] admits, every one of which the declaration met; nothing in the refusal or in L0347's explanation says that a generic routine cannot be placed, or what to write instead. Met making the shared command loop device-neutral in R12.30, which took function values instead (D645). | The next change to a generic routine's placement, or to L0347's text for it. | The refusal naming the type parameter as what keeps the routine from being placed and offering a nongeneric routine that calls it, or placement of a generic routine's instances defined. | open |
| SR-613 | Usability | The STM32H753's SVD describes none of the Cortex-M7's System Control Space, so the board application reaches VTOR, CPACR, CCR, the NVIC's enables and SysTick through a module of its own, `scs`, of volatile accesses at addresses read out of the Armv7-M Architecture Reference Manual; the RP2040's SVD gave its `ppb` module, and `platform/cortex_m` offers barriers and the interrupt mask but no System Control Space register, though every M-profile board has them at the same addresses. Met writing the STM32H753 board application in R12.30. | The next board whose SVD lacks the core's registers, or the next change to `platform/cortex_m`. | The architecture's System Control Space as a library module or a generated one of its own, which the STM32H753 board imports instead. | open |
| SR-615 | Usability | D265 says RV64's instruction selection "uses target XLEN and independent extension sets so a future RV32 emitter can share it", and `landin-backend-riscv_instructions` takes a width of 32 or 64, but every call in `landin-backend-riscv.adb` passes a literal 64, and its frames (`sd`, `ld`, CFI at −8 and −16), its 64-bit products and quotients, its float instructions and its atomics, which use AMOs and LR/SC whatever the level holds, are written for RV64 alone, so the decision promises a reuse a reader planning RV32 finds only by reading the emitter. Met planning R12.40. | R12.40's RV32 emitter. | The emitter parametric in XLEN as D265 says, or D265's note corrected to what is shared. | retired: D671 makes `Landin.Backend.RiscV` ask the target its XLEN, and RV32 is that emitter at 32, with eight-byte values in pairs, libgcc's soft float and division, word frames with CFI at −4 and −8, and A's instructions only where the level holds A; D265's note says so |
| SR-616 | Usability | Once an RP2350's boot ROM has switched its cores to RISC-V for an IMAGE_DEF that asks for it, probe-rs's `RP235x` target, which flashed the image, fails every later read and write with "Target device responded with a FAULT response", which says nothing of the architecture, and only `--chip RP235x_riscv` reaches the chip's memory; `probe-rs reset` with `RP235x` hangs. Met booting a Hazard3 image on the Pico 2 for R12.40. | R12.40's Hazard3 board tool. | The board tool choosing the target by the image's architecture and its README saying which reaches the chip after each boot. | retired: R12.40's Hazard3 tool flashes and reads through the target that reaches the architecture running, `RP235x` in BOOTSEL or before the switch and `RP235x_riscv` after it, and its README says which reaches the chip after each boot (D712) |
| SR-617 | Usability | `probe-rs reset` on an ESP32-C3 resets the chip's USB-Serial-JTAG with it, "A USB error occurred", so a console opened on the board's own CDC port before the reset receives nothing of what the ROM prints at boot, and the ROM's account of the image it loaded is lost. Met checking a RAM-only image on the C3 for R12.40. | R12.40's ESP board tools. | The board's oracle reading the ROM's boot log from UART0, wired to the rig, and the README saying why the CDC port cannot carry it. | retired: R12.40's ESP32-C3 board tool reads the ROM's boot log from UART0, wired to probehive's slot 2, and its README says why the USB-Serial-JTAG cannot carry it |
| SR-618 | Usability | GDB's `break _landin_firmware_unhandled` and `hbreak _landin_firmware_unhandled` on an RV32 image do not stop at the entry: the compiler-owned routine has CFI but no line information, so GDB places the breakpoint past a prologue it guesses, which on the ESP32-C3's image was 0x40380288, inside `start`, beyond the entry at 0x40380224, and a session waiting for a trap never stopped; only `hbreak *_landin_firmware_unhandled` does. The Cortex-M lanes use the plain form. Met writing D656's emulator check for R12.40. | The next change to the RV32 firmware's debug information, or the next board tool that breaks at a compiler-owned entry. | The compiler-owned RV32 entries given line information, or a prologue end, that GDB stops at, or `docs/targets.md` saying to break at the address. | open |
| SR-619 | Usability | An ordinary `assembler.block("csrrw zero, cycle, zero")` on `rv32` is L0330, "the text names `zero`, a register no ordinary block may write", though x0 is the hardwired zero, which no write changes, and the pseudo-instruction `csrw cycle, {value}` that assembles to the same `csrrw x0` is admitted. Met writing a program that executes an illegal instruction for D656's check in R12.40. | The next change to the RISC-V assembly checks. | `zero` admitted as a destination, or L0330's note saying the pseudo-instruction form. | open |
| SR-620 | Usability | A target added to the compiler is not in `scripts/emit_manifest.py`'s `TARGETS` or `MODE_TARGETS` until someone adds it, and a positive fixture only one target compiles makes `emit` fail on every other target: on R12.40's integration branch three rv32-only fixtures, from three streams, failed the host manifest for all seven targets, and nothing short of the gate's `determinism` job says so, since `docs/process.md`'s close runs only `modes` and no stream runs `emit`. Met adding rv32 to both lists for R12.40 (D658). | The next item that adds a target or a fixture class one target alone compiles. | The manifest's targets held to the compiler's own list by a check, and a fixture whose `args` name a target refused elsewhere without hand-listing every pair, or `docs/process.md` naming `emit` beside `modes`. | retired: a fixture of one target is compiled for it alone (D740), `check.py` holds the manifest's target lists to the compiler's selection table, and `docs/process.md`'s close names `emit` beside `modes` |
| SR-621 | Usability | `cortex-m-programs` failed in the `descriptions` lane with "gdb-trap-record failed" and a log saying only "Selected architecture riscv:rv32 is not compatible with reported target architecture arm" and "Architecture of file not recognized", while the same lane passed when run alone: `Run.debug` serves every session on a worker thread from one GDB (`gdb_server.py`), whose reset between sessions kept the description the last target reported and the architecture the last script set, so the ESP32-C3 trap record failed whenever an Arm lane had debugged on its thread first. Nothing in `environments/cortex-m/README.md` says lanes share a GDB, a lane run alone cannot meet another's state, and the failure names neither the earlier session nor the server. The reset now also unsets `tdesc filename` and sets the architecture back to `auto`. Met fixing R12.40's first gate run. | The next change to `gdb_server.py` or the next lane that debugs a second architecture. | A control that serves an Arm session and then an RV32 one through one real GDB, and the README saying sessions share a GDB per worker. | retired: `rv32_controls.py`'s shared-debugger control serves an Arm session, an RV32 one and an Arm one again through one GDB and fails without the reset's description and architecture lines; `environments/cortex-m/README.md` says sessions share a GDB per worker |
| SR-622 | Usability | `darwin-parity`'s "Source verdicts" step failed with only `ValueError: end-to-end/refine-identity: exact diagnostic differs`: `compiler/tests/darwin/diagnostics.py` holds the fixture to the same `expected.txt` the test program does, which the message does not say, and it shows neither difference nor the `--record=` that rewrites it, which the test program's own failure names. Met fixing R12.40's first gate run. | The next change to `compiler/tests/darwin/diagnostics.py`. | The message naming the expectation file, the first differing line and the re-recording command. | open |
| SR-714 | Usability | The root agent guide was 45,986 bytes, while Codex's default project-document budget is 32 KiB. Its injected copy in the 2026-11-03 process review ended mid-word in Sources of truth, before the architecture, design constraints and specification-editing rules, with no warning in the conversation. | The next change to agent guidance or its delivery. | Essential instructions delivered in full, with detailed references loaded for their task and a check against future truncation. | retired: the root guide is below 24 KiB, `check.py` enforces that UTF-8 byte budget and the shared Claude alias, and linked references carry conditional detail; custom host/ancestor guidance remains subject to the guide's delivery check |
| SR-715 | Usability | Host-local Claude guidance still said the gate was Linux-only, prescribed an old build tag and told Mac agents never to end a turn with background work, while the current process and hubbish describe different behavior; the project's `landin-native-hosts` skill link also points to a missing directory. Met comparing live instructions and transcripts during the 2026-11-03 process review. | The next update to local agent guidance or skill deployment. | Local notes checked against the current tools, obsolete operational claims removed, and skill discovery verified per provider and host. | retired: the local environment, Mac and index notes are corrected, the dangling native-hosts alias is removed with its target retained in a backup, and the portable `landin-change` skill is discovered by Codex with its Claude project alias verified against the same source |
| SR-716 | Usability | The local feedback recipe prescribed a 540-second blocking wait inside a 600-second tool call without accounting for Codex's yielded process sessions or shorter tool limits. Met reading the recipe alongside the active Codex tool interfaces in the 2026-11-03 process review. | The next change to the local feedback recipe. | Waiting through the harness's process continuation, or a logged wait shorter than its tool limit, with completion and scope inspected before reporting. | retired: the recipe and root guide name native continuation and bounded waits, including `--timeout 45` for a 60-second tool limit |
| SR-717 | Usability | The agent guide's gate table described the Cortex-M matrix as two parts, while `gate.yml` already ran `programs`, `corpus` and `rv32`; the RV32 controls and corpora were absent from the explanation. Met checking the moved reference against the workflow during the 2026-11-03 process review. | The next change to the gate reference. | The reference naming every current matrix part. | retired: the gate reference in `docs/process.md` names all three parts and their scope |
| SR-718 | Usability | Parallel-session briefs repeatedly supplied checkout isolation, identity allocation, publication and hardware restrictions, but the maintained process did not explain that a new Paseo chat shares its caller's checkout, that worktrees share Git refs, or how independent sessions hand off a candidate and the rig. Met comparing Landin's RV32 briefs with Paseo's defaults and the board tools during the 2026-11-03 process review. | The next change to parallel-agent guidance. | A shared recipe naming writer isolation, integration and publication ownership, exact-tree CI evidence, peer handoffs and the rig's common exclusion boundary. | retired: `docs/process.md` defines those handoffs and ownership rules, with concise entrypoints in the root guide and `landin-change` skill |
| SR-500 | Usability | On a nix host an agent reaches `python3` and the pinned toolchain only through `nix develop -c`, which evaluates the flake before every command, about two seconds each over some eleven thousand calls from 9 to 30 October; 229 commands run without it failed with "python3: command not found". The shell's two `landin:` banner lines came with every call, and the `grep -v '^landin:'` written to drop them also dropped the build's own "rebuilding from clean" and build-lock messages. Met reviewing that period's agent sessions. | The next change to the flake's development shell or to the local feedback recipe. | The shell's environment available to an agent without an evaluation per command, and nothing to filter from its output. | retired: `scripts/agent_env.sh` writes the shell's environment once per flake and pins, for a harness to source before each command, and the banner goes only to a terminal |
| SR-501 | Usability | A subagent cannot wait for a background run's completion notification, since it ends with its turn, and the recipe's "use the tool's blocking wait" ends after ten minutes, so the October streams waited in about 990 `sleep` loops over logs. 39 of the 85 loops waiting for `pgrep -f` to find nothing never ended, because the pattern matched the polling shell's own command line. Met reviewing that period's agent sessions. | The next change to `scripts/run_logged.py` or to the local feedback recipe. | A blocking wait that outlasts any run by being repeated, named by the recipe. | retired: `run_logged.py --wait` blocks for up to 540 seconds and exits 124 to be called again, or 125 when the run died without a result, and AGENTS.md and the recipe name it and rule out `pgrep -f` |
| SR-502 | Usability | `docs/process.md` recommended `dev-build.sh -j2`, and briefs to parallel streams named `-j4`, `-j8` and `taskset`, on a 32-core host where the project's own `-j0` builds the whole compiler in 72 seconds against 190 at `-j4`. Met reviewing the October agent sessions. | The next change to the local feedback recipe. | The recipe leaving the worker count to the project. | retired: the recipe and AGENTS.md leave the worker count and CPU placement at their defaults |
| SR-503 | Usability | `scripts/gate_watch.py` returns at a run's first failed job, so a second lane that failed in the same run went unseen: in R14.40 the watcher reported `scripts`, the fix was pushed, and the next run failed on `editor-grammar`, which had failed beside it. | The next change to `scripts/gate_watch.py`. | A way to hear every failed job of a run before the fixing push. | retired: `gate_watch.py --all` follows the run to its end and names every failed job |
| SR-574 | Usability | The Cortex-M lane's `qemu-system-arm` cannot be run by hand to try a machine: under `steam-run` it stops with "libcapstone.so.5: cannot open shared object file", because the Debian closure's libraries are found only through `LD_LIBRARY_PATH=TOOLS/root/usr/lib/x86_64-linux-gnu`, which `run.py` and `setup.py` set for their own processes and `environments/cortex-m/README.md` does not name. Met trying `mps2-an505` and `mps2-an500` in R12.30's planning. | The next change to `environments/cortex-m/setup.py` or the README's NixOS route. | The README naming the variable beside its `steam-run` route, or the tools root carrying a launcher that sets it. | retired: the README's NixOS route names both directories for a QEMU or GDB run by hand, the lanes' own `pulseaudio` one among them, which Espressif's QEMU needs as well |
| SR-575 | Usability | QEMU's `mps2-an500`, the M7 lane, reads zero and ignores writes over unmapped space past its two 4 MiB RAMs, at 0x1000_0000 among them, rather than raising a bus fault, so a program that strays there executes zeros until the lane's timeout instead of trapping where it went wrong; `mps2-an505` faults at the same kind of address. Met probing the two machines in R12.30's planning. | A lane failure on `mps2-an500` that ends in a timeout. | The lane naming the last PC it saw, or a guard that makes a stray fetch fault, said in `environments/cortex-m/README.md`. | watch |
| SR-577 | Competitive optimization | On a Cortex-M profile with a float unit, a framed routine that holds any assembly block saves and restores all of d8 to d15, 64 bytes of stack and sixteen transfers, although a block must now declare each callee-saved float register it names (D630), so the declared set is known. Kept conservative when float operands came after the frame's save in R12.30. | A measured cost of the save in a routine with an assembly block on the M7, or the next change to the Cortex-M frame's float save. | The routine saving only the d registers its blocks declare and its own code uses. | open |
| SR-578 | Usability | `. "$(./scripts/agent_env.sh)"`, the natural way to take the file the script prints, fails with bash's ": No such file or directory" in a shell that already has `python3` and `gprbuild`, as every Claude Code session started through the SessionStart hook does: there the script prints nothing, by design, and sourcing an empty path names no file, so the command fails before its own work starts and the message does not say the environment is already present. Met starting a build in R12.30's gate split, whose stream brief named that idiom. | The next change to `scripts/agent_env.sh` or to the local feedback recipe. | An idiom that holds in both shells, the script printing a path that is always safe to source, an empty file when nothing differs, or the recipe naming the guarded form. | retired: `agent_env.sh` prints `/dev/null` when it has nothing to add, so the natural sourcing form holds in either shell |
| R730-22 | Companion tool and ecosystem | No job ran the structural editor grammar's integration pass. | — | — | retired: R8.30's `editor-grammar` gate job runs it on each full gate run, subject to the R8 gate's explanatory-only reuse exception, with the release CLI `environments/pins.sh` pins by sha256, and fails if regenerating the parser changes the committed one |
| R730-25 | Release readiness | `end-to-end/refine-identity`'s macOS arm64 evidence was a run, not a record the coverage readers read. | — | — | retired: R8.30 runs end-to-end fixtures in Darwin's diagnostics runner, which the gate runs, places their Darwin claims from it, and has `check.py` refuse any fixture whose named product target no record places |
| SR-695 | Usability | The README's install route points at the latest release, v0.2.8, whose archive holds `lib/landin`, but its first program imports `hosted/blocking` and is started with `refine run`, neither of which 0.2.8 has: following the README with the archive gives L0006 "module not found: hosted/blocking" and "`refine run` is not a command", and the README does not say which release its examples need. Met checking SR-294 against the 0.2.8 archive. | Now, or the next release. | The README's install route and first program agree with the archive it points to: a release that holds them, or the README naming the release its examples need and how to build main instead. | retired: the README's release route says no release yet builds the first program and sends a newcomer to nix or the source build until one does |
| SR-696 | Usability | R730-17's refusal, a call returning a plain pointer filling a several-atom pointer union through an atom `else`, is a generic L0301 naming the required pointer type and shape; it names neither D235 nor what to write instead. Met checking R730-17 against main. | The next change to D235's recovery or to L0301's notes. | The refusal saying that this recovery does not widen a plain pointer, and naming the form that does. | retired: R13.75: the refusal spells the union and names the one-atom union that widens into it (D874) |
| SR-697 | Scale and self-hosting | `refine` is written in Ada 2022 and building it from source needs the pinned GNAT toolchain; its stages sit behind tested seams so a Landin stage could replace one at a time, but no cross-language stage transport exists and self-hosting is not scheduled. Split from R551-32. Kept outside the current roadmap and proposed for the next in discussion #2 (<https://github.com/JanHaan/Landin/discussions/2#discussioncomment-19369244>). | The next roadmap taking it. | An explicit scope decision, then stages replaced behind the existing seams with their tests unchanged. | open |
| SR-698 | Usability | `scripts/emit_manifest.py` makes an output-identity proof slow and hard to set up: `emit` runs a fixed four workers, so one manifest of every target took 31 to 40 minutes on a 32-core host and a before-and-after proof over an hour; it compiles only the positive corpus, so proving a refactor left the runtime corpus alone needed a script of its own; it has no profile or fixture selector; its `debug` key is `--build-mode=debug` and no manifest covers `--debug=full` or `--debug=lines`; and a baseline `refine` copied out of its build tree refuses every static link with L0500, which the manifest reports only as thousands of "unexpected emission result 'refused:1'" lines without the diagnostic. Met by five streams of the November register sweep proving refactors emitted the same bytes. | The next change to `emit_manifest.py` or to `docs/process.md`'s local feedback recipe. | A worker count defaulting to the host's cores, a corpus, profile and fixture selector, debug-information entries, an unexpected refusal printing its first diagnostic, and the recipe saying how to keep a baseline compiler. | retired: `emit` takes corpus, fixture, profile, mode and job selectors and runs every core by default, adds same-checkout debug-information entries kept out of the cross-host comparison, prints an unexpected refusal's first diagnostic, and `docs/process.md` says how to keep a baseline compiler (D841) |
| SR-699 | Usability | `environments/cortex-m/run.py --lane rv32-controls` refuses to start without `--refine`, though the README says that lane needs no compiler and `run.py` checks for one only when a lane needs it. Met running that lane alone to check a debugger-server change. | The next change to `run.py`'s arguments. | `--refine` required only when a selected lane needs it, or the README saying every run needs one. | open |
| SR-700 | Usability | A generic routine nothing calls is not refused for a `try` that also has `else` (L0329): it checked clean until a caller was added, though L0329 does not depend on the type parameters. Met checking an uncalled template for SR-297. | The next change to what an uncalled generic template is checked for. | Every check that does not depend on the actuals run on the template, or D771's list of what is checked before a call kept exact. | open |
| SR-701 | Usability | D505's "another of the thread's instances" reads as if a thread's instance's address could be kept in thread storage, but thread storage holds no pointer or pointer union (L0328), only an integer; [1996] was corrected in the November register sweep, D505 was not. Met writing SR-383's fixture. | The next edit to D505 or to thread storage. | D505 saying the address is kept in thread storage only as an integer. | retired: D505 says a thread's instance keeps the address only as an integer (L0328) |
| SR-702 | Usability | The gate's `darwin-host` and `darwin-host-release` run the test program only as `--host --target=linux-x86-64`, so its ABI fixture execution on `darwin-arm64` never runs in CI; that is how SR-386's refusal of `abi/r440-errno-thread-local` stood while `darwin-parity` passed. Met retiring SR-386. | The next change to the Darwin host jobs or to ABI fixture execution. | The test program's `darwin-arm64` ABI fixtures run in a gate job, or the README saying `darwin-parity` alone gives their Darwin verdict. | open |
| SR-703 | Release readiness | A `--debug=full` Darwin image is likely not reproducible: `-save-temps=obj` keeps the object beside the output, and ld64's debug map records that object's path and modification time. Reasoned while retiring R730-23, not measured; Linux debug images are identical in one directory. | Before a reproducible-distribution claim covers debug builds. | Two `--debug=full` Darwin links in one directory measured, and made identical through the adapter or the residue declared in `docs/targets.md`. | open |
| SR-704 | Usability | `scripts/add_fixture.py positive/NAME` ends by naming `dev-test.sh --fixture=...` and `check.py`, but a new positive fixture also needs `--record=lowering`, or the lowering suite's "recorded corpus is current" case fails; only `compiler/tests/README.md` says so. Met adding `positive/field-named-at`. | The next change to `add_fixture.py` or the fixture format. | `add_fixture.py` naming `--record=lowering`, and any other recording a fixture class needs, among what is left to do. | retired: `add_fixture.py` names `--record=lowering` for a positive fixture among every step it leaves, as SR-571's retirement says |
| SR-705 | Usability | `Landin.Diagnostics.Checking.Report` silently discards a note given with a code whose notes come from the catalogue, as L0304's do: two raise sites in the checker, the substituted array element and a nested struct value, pass notes that never reach a report, and nothing refuses them. Met moving L0304's routes into a route note. | The next diagnostics item touching L0304. | A note given to a fixed-note code refused when the diagnostic is built, and the two sites' notes dropped or made routes. | retired: a note given to L0304 is a compiler defect when the diagnostic is built (D856); the `offsetof` refusals' notes are routes, and the array element's note, which restated its message, is dropped |
| SR-707 | Usability | The build report's routine row and the depth report's both have `frame_bytes`, with different meanings: the depth report's is the build report's `stack_bytes`. Met in SR-342. | The next change to the depth report's format. | One name per quantity across both reports, or each format's documentation naming the other's field. | open |
| SR-708 | Usability | `check.py --matrix` does not regenerate `compiler/tests/diagnostics.matrix`; only `--catalogue` does, though the usage line says `--catalogue`, `--coverage` and `--matrix` regenerate theirs. Met adding L0579 to L0582: after `--matrix` the new codes still showed no test owner. | The next change to `check.py`'s generators. | Each generated file named by the option that regenerates it, in the usage line and in the stale-file message. | retired: `check.py`'s usage names every generated file beside the flag that writes it, every stale-file message takes its flag from the same table, which a test holds to what each generator writes, and `check.py --help` prints it |
| SR-710 | Usability | `option linux: bool = true` is accepted while `option big` is refused as L0390 "this option name is compiler-owned" (D202): the refusal covers the architecture, byte-order and build-mode atoms but not D264's `linux`, `darwin`, `freebsd` and `freestanding`, and an option of that name is then read in place of the atom, so `compiler.os == linux` compares a bool with a system. Met making the atom lists one table for SR-625, which kept the old set to change no behaviour. | The next change to configuration atoms or options. | Every configuration atom refused as an option name, with a decision and a negative fixture. | retired: every configuration atom is refused as an option's name from the one table, and the note lists them (D855); `negative/option-takes-no-atom-name` |
| SR-711 | Usability | `refine --target=linux-x86` answers "did you mean linux-rv64?" rather than `linux-x86-64`. Met recording the driver's refusals for SR-625. | The next change to target selection or the suggestions. | A prefix of a described name ranked first, with a driver case. | retired: at one distance and depth the candidate whose head is nearest the misspelling ranks first, and a system named alone is offered its targets (D857) |
| SR-712 | Usability | The fixture execution suite names no lane for a runtime fixture naming `rv32`, saying "rv32 is a layout model the targets suite measures", which is `synthetic-32`'s description; RV32 runs through the Cortex-M inventory. Met reading the harness's per-target lists for SR-625. | The first runtime fixture naming `targets: rv32`, or R12.50. | The suite naming which lane runs an RV32 fixture, or refusing `rv32` in a runtime fixture's `targets:` with that lane named. | retired: the harness's note names the firmware corpus's RV32 lanes, and `check.py` holds a runtime fixture naming `rv32` to a corpus row they execute (D842) |
| SR-713 | Usability | Python lists that pick a subset of targets are held to the compiler's list by nothing, so a renamed or new target passes them silently: `check.py`'s `PRODUCT_TARGETS` and `TARGET_SCOPES`, which leave out `rv32`, `scripts/driver_manifest.py`'s and `compiler/tests/test_determinism.py`'s `TARGETS`, and `scripts/image_bounds.py`'s table. Met searching for SR-625's lists. | R12.50's Xtensa target. | Each such list checked to be a subset of `fixture_meta.described_targets()`, and the construct inventory saying whether `rv32` is a product target. | retired: `check.py` holds every subset target list to the compiler's described targets with a backend, and the construct inventory says `rv32` is no product target and why, while a fixture naming `rv32` is held to a run (D840) |
| SR-720 | Usability | The formatting test's exemptions for fixtures whose layout is their evidence are a list of names inside the Ada test, with no key in `fixture.meta`; `add_fixture.py` mirrors the list to know which fixtures not to reformat, and a newcomer who wants such a fixture learns this only from the test's failure. Met extending `add_fixture.py` for SR-571. | The next fixture exempted from the layout. | The exemption declared in the fixture's metadata and read by both. | open |
| SR-721 | Usability | Nothing stops a new script test from guarding a subprocess with a thin timeout: SR-310's list named four load-sensitive tests and six more were found, `test_fuzz_close.py` among them, because the fuzz driver's one-second bound also covered the stub server's start. Met proving SR-310. | The next new script test with a subprocess timeout. | A shared, stated hang guard in `scripts/tests`, or a check refusing a timeout below it. | open |
| SR-722 | Usability | `check.py`'s catalogue and coverage generators stop with "the explanations could not be generated; run check.py" or "the coverage registers could not be read" and name no cause, as `--tokens` did before SR-323. Met reading the generators for SR-708. | The next change to the catalogue or coverage generation. | Each generator's refusal printing the problems that stopped it. | open |
| SR-726 | Usability | `return a + b` as the body of a function with a named result is L0110 "this statement prefix cannot have a final value", whose note neither says that `return` carries no value nor to assign the named result first, as L0107 says elsewhere. Met reproducing SR-462's C-style function. | The next change to L0107 or to value prefixes. | The refusal saying `return` carries no value and to assign the named result. | open |
| SR-727 | Usability | A variant case whose payload is written as a call, `full(n: i32)` among a variant part's cases, is L0103 "a variant part ends with `end` and its name" at the `(`, which does not say a payload is written `full: (n: i32)`. Met writing a reproducer for SR-264. | The next change to the parser's variant-part refusals. | The refusal at `(` after a case name naming the `case: (fields)` form. | open |
| SR-728 | Usability | `mut done = false` in a body is L0103 "`mut` does not belong here", whose note and fix, removing `mut`, turn a declaration into an assignment to an undeclared name; the form is `mut done := false`. Met writing the SR-527 reproduction. | The next change to the line repair or to `mut`'s refusals. | `mut name = value` named as a declaration that needs `:=`, with that fix. | open |
| SR-729 | Usability | `low, high := pair(2)` is L0010 "an inferred binding names one binding; shared names write their type", which does not name the destructuring `(low, high) := pair(2)` that was meant. Met writing D871's fixture. | The next change to L0010 or to destructuring. | A run of names before `:=` with a call on the right naming the parenthesised destructuring. | open |
| SR-730 | Usability | After a diagnostic's text changes, nothing short of the complete `fixture execution` suite says which existing negative fixtures' `expected.txt` it changes, and `--record` needs their names; R13.75 found them with a script of its own running every negative's `args`. | The next change to `dev-test.sh`'s selectors. | A selector for the negative fixtures whose expected reports carry a given code. | open |
| SR-731 | Usability | `compiler.atomic_load(addr s, compiler.relaxed)` on a range-subtype binding is two reports, L0344 "memory access needs a pointer" and L0304 "the address of a range subtype place cannot be taken"; the first is a cascade, and wrong, since `addr s` is written as a pointer. Met checking how L0344 spells a subtype pointer for SR-690. | The next change to L0344 or to L0304's recovery. | One report, L0304, for the one mistake. | open |
| SR-732 | Usability | The language server's hover spells types for no source, so a value of a library type shows `whole` rather than `fibre.whole`, and a private type its private name, `blocking_value` for `blocking.host`; refusals spell both as the program writes them since D880, so the two disagree. Met reading the server's type text for SR-293. | The next change to hover. | Hover spelling through `Landin.Checking.Spelling` for the hovered source, with its server sessions re-recorded. | open |
| SR-733 | Usability | A refusal spells a non-generic alias of a structural type by its structure: an alias `maybe` of the union of `absent` and `ptr u32` is spelt as that union in L0344, not as the `maybe` the program wrote, because the checker's descriptor keeps no alias. Met re-recording `negative/r630-optional`. | The next change to type spelling or to alias identity. | A written alias recovered where the refused node names one. | watch |
| SR-734 | Usability | A recorded fixture's failure says "./scripts/test.sh --record=CLASS/NAME re-records it", which runs a full build, while `scripts/dev-test.sh --record=` is the fast route the local recipe names. Met re-recording R13.75's fixtures. | The next change to the fixture harness's messages. | The hint naming `scripts/dev-test.sh --record=`. | open |
| SR-736 | Usability | The rig's USB host failed three ways in a day. On the front-panel port the cascade's top hub dropped every 30-50 s with no device or kernel error before it, and autosuspend, turned off everywhere, was not the cause; on the ASMedia xHCI at PCI c2:00.0 a Pico 2 halted in BOOTSEL failing enumeration hard-locked a CPU in `xhci_handle_command_timeout` and the controller died, taking the Arty's USB, which shared it, with the cascade; and with the cascade on the onboard connector's second port, a Pico 2 left in BOOTSEL dropped the whole cascade 75 times in ten minutes until it was unplugged. A switch of one port drops only its own device where the host is sound. Met in the November board round. | The next rig change or board run. | The cascade and the Arty on separate controllers, no BOOTSEL on the bus (SR-680), and a run that meets a controller death stopping with recovery left to the maintainer. | open |
| SR-740 | Usability | Writing R12.45's command proposals before implementation, `check.py` reported the explicitly provisional script paths as missing repository references. Its named-file check has no documented notation for proposed paths; finding that meant reading `check_named_files`, and the proposal had to use command placeholders. | The next change to the named-file check or its documentation. | A documented way to name a proposed path without claiming that it exists, held by a check control. | open |
| SR-768 | Usability | The complete Xtensa corpus times out its exhaustive memory-alignment fixture while modes, manifests and a flake build saturate the host. Both the previously passing image and the new image complete with status 42, no trap and an intact guard under controlled replay, but need 21 to 45 wall seconds despite 12 to 18 CPU seconds; the runner applies a 20-second wall guard. Met closing R12.50 with default workers. | The next change to the Xtensa oracle's guest time budget. | A stated transport and guest budget policy, with finite heavy-fixture and nonterminating-guest controls under documented scheduling assumptions; a contended timeout cannot become a source exemption. | open |
| SR-769 | Usability | Reviewing the new Xtensa physical records, the shared ESP scenario names its interrupt snapshots `receive_mcause` and `timer_mcause`, and its refusal says mcause. These ports actually report the Xtensa INTERRUPT pending bits and use chip-specific masks for lines 1 and 23; the inherited RISC-V labels make the evidence look like another register was checked. | The next change to shared ESP scenario diagnostics or record field names. | Architecture-specific register labels in results and refusals, with controls for both architectures and an explicit interpretation of older records. | open |
| SR-772 | Usability | Reading the complete Xtensa corpus's C ABI restrictions, its retained reason says Cortex-M0 disables the general C surface and points to Cortex transport controls. The Xtensa result inherits the shared inventory's text without naming the selected configuration or its separate independent C peers, so discovering why this target is restricted requires reading the runner. Met auditing R12.50's final evidence. | The next change to shared freestanding corpus restriction reporting. | Retain the shared restriction witness while rendering an explanation for the selected target and pointing to that target's actual independent controls. | open |
| SR-773 | Usability | Following a candidate gate's first failed job, the watcher suggests `gh run view --job ... --log-failed`, but that command refuses while the overall run is still active and says logs are available only when it completes. The completed job's REST log endpoint already works, so getting the early diagnostic requires a different command discovered outside the watcher. Met following the first R12.50 gate. | The next change to gate-watcher diagnostics or failed-job log guidance. | An actionable completed-job log command while its run remains active, with controls retaining the run and job identities. | open |
| SR-775 | Usability | The stock-user gate can spend its whole twenty-minute budget downloading distribution packages before any compiler check runs. After unused C++ recommendations were removed, the Azure Ubuntu mirror still took eighteen minutes to deliver the 57.5 MB GCC archive; the next C library download was cancelled by the job limit. Recovering requires inspecting the download timestamps and rerunning on a fresh hosted runner, rather than following a diagnostic from the job. Met following R12.50's corrected candidate gate. | The next change to stock-user package acquisition or its mirror policy. | A bounded package-download attempt with a stated official-mirror fallback, retained diagnostics and fatal failure after exhaustion, preserving the distribution-toolchain identity and compiler checks. | open |
| SR-776 | Usability | A gate watcher started as a failed job was being rerun printed the old aggregate failure, then the successful replacement and `run ...: success`, but exited one and still listed `gate` as failed. It retains failures observed earlier in the watch even after its complete latest-attempt listing replaces them with success, so the caller must separately verify that listing to distinguish stale watcher state from a failed gate. Met following R12.50's same-tree stock-job retry. | The next change to gate-watcher verdicts or rerun handling. | The final exit status and failure summary derived from the complete latest-attempt listing, retaining historical observations separately, with a failed-then-successful retry control. | open |


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
