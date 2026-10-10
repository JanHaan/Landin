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

Execution order: R8, R9, R10, R11, R13.10, R13.11, R13.12, R13.13, R13.30, R12, R13.20, R14, R15, R16

The library availability split and hosted facilities precede microcontrollers.
R12.10 depends on R13.30 to hold the first boundary. The freestanding
facilities retain R12.30's prerequisite and also depend on R12.60 to hold
the boundary after the whole microcontroller phase. R12 stays in scope, and
its gates and R13's gate retain their requirements, and no identity is renumbered. Each new R12 target repeats
the shared-library consumer matrix established by R13.10.

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
Depends on: R11.10, R13.30

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

Status: active
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

### R13.13 — Review the library

Status: planned
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

### R13.30 — The hosted library

Status: planned
Depends on: R13.10, R13.11

Files and directories, processes, the environment, time and sockets, each
driven by a complete consumer, with the operating system reached through the
same capabilities as now. This takes R551-34's hosted part, and with it B5's.

Exit evidence: each consumer running on every hosted target with failure
oracles.

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

## R14 — Concurrency

Beyond blocking, by switching stacks rather than rewriting functions; "The
concurrency execution model" below binds this phase.

### R14.10 — Prototype 5

Status: planned
Depends on: none

A concurrent program written as a specification stress test, as the first four
prototypes were: a small network server with two operations in flight, and a
firmware counterpart that has to answer the same request on a single core.
Its findings are recorded as the first four's were.

Exit evidence: `prototype-5` with its findings, checked by `check.py` like the
other four.

### R14.20 — Stackful fibres

Status: planned
Depends on: R14.10

A stack switch on every target, specified with a register decision. The caller
supplies each fibre's writable stack backing, directly from a fixed buffer or
through an explicit allocator capability; creating a fibre does not require
an implicit heap allocation. The caller owns that backing while the fibre can
run or resume and reclaims it only after the fibre has finished and no switch
can reach it. Specify the backing's size, alignment, creation-failure and
release rules with the switch interface. This takes on the stackful-fibre
part of R551-35.

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

### R14.25 — Run the firmware counterpart

Status: planned
Depends on: R14.20, R13.20

Derive a complete Cortex-M0 program from prototype 5's firmware counterpart.
It presents the same request for two operations in flight as the hosted server
and produces the single-core answer specified in R14.20. Record a trace that
shows the answer and when each operation starts and finishes.

Exit evidence: the firmware derivative running in the Cortex-M0 emulator lane
in the gate, with its captured trace checked against a repository-owned oracle
for the specified no-concurrency answer and no two operations in flight. A
missing answer, overlap, trap or timeout fails the run.

### R14.30 — A second Io

Status: planned
Depends on: R14.20, R13.30

An event-driven Io that runs fibres over epoll on Linux and kqueue on
Darwin/FreeBSD. Windows is outside this item's scope.

Exit evidence: prototype 5's derived server running on the hosted targets over
both implementations of Io, unchanged.

### R14.40 — Threads and the atomic wrapper

Status: planned
Depends on: R14.20

Hosted threads, and the atomic wrapper type over D227's builtins that answers
Cortex-M0's missing read-modify-write explicitly. This takes on R730-21.

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

The first roadmap named six families as destinations for what it did not do.
They are kept as the owners of register records, not as roadmaps of their
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
| R551-34 | Broader standard library | Library facilities beyond the prototypes' slices. Merged: R730-02, a reusable cache-maintenance interface for cached profiles (R12 requires platform providers before admission); R730-09, UART configuration beyond one baud rate; R730-21, the atomic wrapper type. | A concrete program needs an omitted facility. | Capability-passed allocation and I/O, constrained-target costs, complete consumers and failure oracles. R14.40 takes the atomic wrapper. | scheduled R13.20, R13.30, R14.40 |
| R551-35 | Language evolution | The stackful-fibre exploration. | A program needing two operations in flight. | A stackful-fibre tour amendment and register decision; stackless coroutines stay rejected. | scheduled R14.20 |
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
| B5 | Broader standard library | The standard library beyond the sixteen `core` modules; R551-34's. | As R551-34. | As R551-34. | scheduled R13.20, R13.30, R14.40 |
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
| SR-08 | Scale and self-hosting | D247's 16,384-declaration routine bound limits the measured cost of origin tracking, but the reference pass still stores per-declaration derivation bits with quadratic growth. Branches and loops share unchanged facts; the representation within each fact remains dense. The separate 16,384-field struct bound has a different cause. | A real routine needs more than 16,384 declarations, or measured origin storage for a routine within the bound is unacceptable on a supported host. | Replace the reference pass's dense derivation bits with sparse storage, preserve origin and borrow verdicts across branches and loops, and measure storage and scaling on generated routines at and beyond the current bound. Raise or remove the routine bound only to the extent those measurements support, updating D247 and its size-bound test; leave the struct field bound independently justified. | limit |
| SR-09 | Competitive optimization | D248 fixes every assembly block as a read/write, call and trap boundary; no block can promise a narrower memory effect. | R16.10 or later measurements show a material code-quality cost caused by that fixed effect in a concrete assembly workload. | Record the baseline and the attributable cost, then decide whether a narrower effect is warranted against D248's critical-section rationale. If adopted, amend [1630] and D248, preserve the conservative default, and show IR and backend correctness plus measured improvement on the affected targets; otherwise record why the fixed effect stands. | watch |
| SR-11 | Language evolution | [1570] names direct Fortran interop as a candidate, but no Fortran calling convention is specified or scheduled. The enabled foreign boundary is `extern(c)`. | A concrete program needs to call or expose a Fortran procedure whose required signature cannot use the C boundary. | A decision in `spec.md` and an amendment to [1570] define the supported Fortran ABI and type subset; calls and callbacks run against a pinned Fortran producer on every host claimed, with negative cases for unsupported signatures. | open |
| SR-12 | Language evolution | [1570] names direct Swift interop as a candidate, including its separate error channel, but no Swift calling convention is specified or scheduled. The enabled foreign boundary is `extern(c)`. | A concrete program needs direct Swift calls or callbacks, including error transport, that cannot use the C boundary. | A decision in `spec.md` and an amendment to [1570] define the supported Swift ABI, type subset and error mapping; calls, callbacks and failures run against a pinned Swift producer on every host claimed, with negative cases for unsupported signatures. | open |
| SR-13 | Release readiness | A spelling from another language gets the generic report of what the parser stopped on rather than the Landin form: no single-token repair mends it, and R11.26 deliberately added no table of foreign spellings. R11.26's audit of agent sessions counted eight: `fn` for a function twice, `as` for a conversion once, `++` for concatenation once, `*u8` for a pointer once, and `[]u8(s)` as a slice conversion three times. That is the historical refusal inventory: D266 subsequently admits the written-type application `[]u8(s)`, so it is no longer a foreign spelling to diagnose. | Session audits show such spellings among the refusals people and agents actually make, recorded with their counts. | A decision in `spec.md`'s register: either a general mechanism that names the Landin construct a foreign form stands for, with negative fixtures pinning one report each, or the generic report kept, with the reason. | watch |
| SR-14 | Broader standard library | R13.13's review left interface points no consumer has yet asked for: the map is a public composition with a seven-part invariant and a cursor whose start and end are sentinel slot numbers; a tree node cannot be asked for its leaf count, kind or children; a spill list has no `clear`, `last` or `reserve`; `io.out`, `err` and `argument_count` take the provider by value while `argument_at` takes a pointer; `host()` constructs where D269 says `new`; the memory file's two flags encode three states; a saved PRIMASK is a bare `u32`; `pool.over` reports misconfiguration as `out_of_memory`; `text.nowhere` cannot be told from offset zero; a bounded diagnostic entry lends its message only byte by byte; an arena has no reset; `grow_storage` trusts three separately passed extents; the fault injector and the region refuse in-place growth, so a container tested through them never takes that path; byte slices have no shipped order. | A consumer that needs one of them, or the next whole reading of the library. | Each changed with the fixtures that pin it, or retired with the reason it stands. | open |
| SR-15 | Broader standard library | `core/text` formats and parses decimals only as `u32`, and parses only `utf8`: a directory listing's sizes are `u64` over bytes, and six programs in the tree hand-roll their own. The process concept has no standard input, and `ENOTDIR` reports `io_failed` rather than `not_found`. | R13.30's file and directory consumer. | `u64` and `usize` decimal writing and `[]u8` parsing in `core/text`, used by `core/diag` and the derived programs; standard input; the errno mapping, each with a consumer on every hosted target. | scheduled R13.30 |
| SR-16 | Release readiness | A debugger shows an atom as its carrier number, which differs between programs, so the derived parser's token kind stays a `u8` that the debugger sessions read as 1 and 6. | A debugger session that has to show an atom-set value. | DWARF describing an atom set as an enumeration on every debugger target, then the token kind an atom set with its sessions reading names. | open |
| SR-17 | Release readiness | `refine fmt` cannot replace a file for an unprivileged Linux user: before replacing it, it proves the `trusted.*` attribute namespace is visible by setting one on the temporary file, which only a privileged process may, and refuses with L0005 otherwise. `--check` works. | A user formatting on Linux without privileges. | A visibility proof that needs no privilege, or a replacement that copies every attribute it cannot see, held by a native case run unprivileged. | open |
| R551-13 | Scale and self-hosting | Workload scheduling and artifact reuse for the exact-revision acceptance. | — | — | retired: the acceptance was removed |
| R551-14 | Scale and self-hosting | Interrupted Darwin acceptance could not resume. | — | — | retired: the acceptance was removed |
| R551-21 | Release readiness | The original R1 to R3 acceptance bundles are unrecoverable. | — | — | retired: nothing accepts revisions, and no claim rests on them |
| R551-23 | Release readiness | Native acceptance evidence had no backup, expiry or attestation. | — | — | retired: nothing produces native evidence now. The Linux and Darwin bundles of the last approval before 0.2.0, `ci/accepted/57d1c76a`, remain on the maintainer's Mac, and on 2026-09-23 their records and source archive matched that tag's hashes; they have no backup, and no claim rests on them. R730-13 stands on its own |
| R551-24 | Release readiness | Two-domain publication was not atomic. | — | — | retired: `pages.yml` is the one publisher |
| R551-06 | Scale and self-hosting | Flow snapshots, declaration-origin matrices, folding and dependency walks and IR scratch arrays have storage and stack costs that grow with input size. | — | — | retired: R8.20 bounded a routine's declarations and a struct's fields (D247, L0325), measured every stage's storage, and made the remaining declaration-origin facts shared between branches; the identified whole-unit IR optimization scratch was subsequently moved off the stack. Automatic per-routine IR-value arrays remain outside L0325's bounds; SR-08 owns the deferred sparse origin representation |
| R551-10 | Competitive optimization | Atom and symbol allocation and imported-module lookup repeat identity scans; simplification keeps size-dependent scratch work. | — | — | retired: R8.20 keyed atom codes, linker spellings, machine-body sharing and imported modules, and simplification forgets only what it stored |
| SR-02 | Scale and self-hosting | The corpus at one worker measured 4,523 s on CI against 3,592 s before the parallelism change; single shared-hardware samples cannot tell variance from a regression. | — | — | retired: three repeated runs on one host put the corpus at one worker at 5,599 to 5,654 seconds before the parallelism change and 5,657 to 5,713 after it, a one per cent cost, and R8.20's tree runs it in 1,400 to 1,436 |
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
