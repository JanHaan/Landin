# AGENTS.md

Guidance for coding agents working in this repository. `CLAUDE.md` is a
symlink to this file, so Claude Code and any harness that reads `AGENTS.md`
see the same text; edit this one.

Read [the current development loop](docs/process.md#the-loop-that-runs-now)
for implementation work, and its closing checklist before declaring an
item complete. Load subsystem references for the task at hand; the gate
matrix and historical process are reference material, not startup reading.
Host-local notes and skills can supply paths and access details, but check
their operational claims against the current checkout and tools. A request
to evaluate or review should produce a reviewable result; publication and
promotion follow the user's authorized scope.

`check.py` limits this file to 24 KiB of UTF-8, leaving room below Codex's
32 KiB default combined instruction budget, and verifies the shared Claude
alias. Move detail to its maintained reference when the guide grows. Local
or ancestor instructions can consume that remaining room; verify the
loaded guidance when changing a host's agent configuration.

For implementing or preparing a candidate, the
[landin-change skill](.agents/skills/landin-change/SKILL.md) connects the
current recipes. Its source is shared with Claude Code through a project
skill alias. The rules here also apply when no skill is selected.

## Repository state

Landin is a language specification with a working Ada bootstrap compiler.
[What refine does today](docs/capabilities.md) is the maintained inventory
of language, library, targets, execution and debugging coverage, and the
[README's current compiler capabilities](README.md#current-compiler-capabilities)
summarise it. Update the inventory when a capability changes, editing the
entry it changes rather than appending to it, and the summary when the
change is one a newcomer would notice; this file describes the repository
and the commands used to work on it.

Under `compiler/ada/` are the Ada 2022 GPRbuild projects, the `refine`
executable, source and diagnostic foundations, host adapters, target facts,
stage seams, the scanner, parser, syntax table, name resolver, type checker,
verified IR, the native backends, the toolchain adapter and the
repository-owned test harness; shared fixtures live under `compiler/tests/`.
The five prototype files remain specification stress tests written as code
sketches; they contain omissions such as `...` and are not standalone
programs.

## Commands

Use the pinned environment for compiler work; the
[local feedback recipe](docs/process.md#local-agent-feedback) also shows how
to source it in a harness whose commands start fresh shells. The common
commands are:

```sh
nix develop
python3 check.py
./scripts/dev-build.sh
./scripts/dev-test.sh --help
./scripts/dev-test.sh --case='harness/filters select exact cases'
python3 scripts/gate_watch.py --all
```

Choose the exact suites, cases and fixtures for the change, combining the
selectors in one invocation. A filtered run is visibly `FILTERED` and is
not complete-suite evidence. The [command reference](docs/process.md#command-reference)
holds clean builds, generation, release/scaling, cross-target and Mac
examples, site rendering and flake builds. Toolchain pins and the warning
policy are in `compiler/ada/TOOLCHAIN.md`.

## Agent feedback without unnecessary round trips

Batch independent searches and file reads in one tool response, inspect every
result, then choose the next step. Keep edits, dependent operations and checks
over shared mutable build outputs ordered. A shell command that gathers several
independent facts avoids a model round trip per fact.

Use one `dev-test.sh` invocation with all affected exact `--suite`, `--case`
and `--fixture` selectors, and one with every `--record=` a change needs,
rather than a shell loop invoking it once per selector. It already
checks the build; run `dev-build.sh` separately when compilation feedback is
needed. Enter `nix develop` once around related commands, or source the file
`scripts/agent_env.sh` names, the same environment at no cost per command
([the local feedback recipe](docs/process.md#local-agent-feedback) says how a
harness takes it). Keep the existing host, worker, target and verification
requirements.

Run a long local command through `scripts/run_logged.py` inside that
environment with the harness's background facility, and do independent work
until its completion notification. In Codex, keep a yielded command's
session id and resume it with the native process continuation tool until it
completes, keeping the turn open while the result is needed. Without either,
use `python3 scripts/run_logged.py --wait DIR` with a wait shorter than the
calling tool's timeout, repeated on exit 124; the recipe gives the default
540-second wait and shorter limits. Never wait in a `sleep` loop, nor on
`pgrep -f`, whose pattern matches the waiting shell's own command line, so
the wait never ends. Then inspect `result.json` and the retained log, and
report the command's scope and status, `FILTERED` or `HOST-ONLY` included;
an exit-zero summary alone is not full-suite evidence. Never pipe a check
through a filter that hides its failure status. See [the local feedback recipe](docs/process.md#local-agent-feedback).

Once a push is authorized, push the candidate as soon as it builds and the
checks for what it touches pass. Run further local lanes beside its gate,
not before the push: the lanes that fail a gate are mostly ones no local
host has, so an hour on the local matrix first only delays hearing from
them. A change to
the grammar, the highlighters or a fixture also runs
`./highlight/test.sh --integration`, about a minute, before the push.

A question to the user holds up only the work its answer decides. Complete
an authorized promotion whose gate passed, start what the answer cannot
change, and say which answer you would take by default. A stated default is
not approval for an action that needs the user's answer.

A brief to a subagent or a parallel stream carries these rules itself:
streams not told them polled their logs and ran complete suites. The brief
names the exact selectors for what the stream changes, leaves the complete
suite to the integrated tree or the gate, names the harness's completion
method with `run_logged.py --wait` as fallback, and leaves the build's
worker count and CPU placement at their defaults, with no `-j` or
`taskset`: a full build at `-j4` took 2.5 times as long as the default.

For parallel sessions, follow the
[ownership and integration rules](docs/process.md#parallel-sessions-and-shared-resources).
Each writer gets its own worktree and branch from an explicit base; a new
chat in Paseo, the tool that runs agents on the project's networked hosts, does not
isolate a checkout. Name the integrator and who may push, rebase or promote.
Coordinate overlaps and shared resources with their owner before using them.
Hardware work on the rig, the host wired to the development boards, uses
the board tools and its common lock; another board, or another slot of its
shared probe, still shares the USB hubs' switched power, so power
operations are never independent. Existing authorization carries into the brief;
silence or an idle agent is not permission to take its resources.

Reduce repeated orchestration, not reasoning effort, model capability, required
checks or review depth. Keep relevant design context; return concise results
and log paths instead of repeatedly pasting complete transcripts.

## The mechanical gate

An authorized promotion to main needs the candidate's complete multi-host
software gate passed, a `scope=boards` dispatch passed on the identical
tree unless the edit is declared `Gate: explanatory`, and main's own push
gate followed to its end; the promoted tree must be the one tested. A
changed merge tree needs new evidence. Filtered local checks are
development feedback; they do not replace the gate.

Read [the gate reference](docs/process.md#the-mechanical-gate) when changing
CI, checking reuse, following a candidate or promoting it. It owns the job
matrix, identical-tree and explanatory reuse conditions, runner scope,
retained artifacts and historical timings. The workflows are executable
truth; keep that reference current when they change. Document and script
checks always run, including when a verified full pass is reused.

Before closing an implementation item, follow
[closing an item](docs/process.md#closing-an-item): run activations against
the item's starting commit, read unmatched rows, and run the build-modes
comparison and scaling check when lowering or emission changed. After any
documentation edit run the full `python3 check.py` and review the prose
against what it describes. A change to the harness or fixtures that Darwin
runs also receives focused native Mac checks when a Mac is available; the
full Darwin lanes belong to the candidate's gate.

## Friction is a finding

Landin is meant to be used by people who have not read its source, and
everyone working here works inside the checkout with the roots, toolchain
and conventions already in hand, which is exactly where usability problems
go unseen. So whoever works on the repository, a person or an agent, records
a finding whenever they meet one of these:

- something a newcomer could not guess: a flag, an environment variable, a
  path or an order of steps the documentation does not lead to;
- a workaround: routing around a tool or the compiler instead of using it;
- a refusal that does not say what to do, or says something misleading;
- having to read the source to learn how to use something;
- documentation that disagrees with what the tool does.

A finding is a row in `ROADMAP.md`'s register under the Usability family,
never a separate list: the symptom as it was met, what the person was doing,
and an activation, usually the next item that touches the area. Merge it
into an existing row when one already says the same. An agent names every
row it adds in its report, so the finding reaches a maintainer as it is
made rather than when the register is next read.

## Sources of truth

Use the repository documents in this order:

1. `spec.md` is the normative specification; where it and `tour.md` could be read differently, it decides. It holds the grammar of the enabled kernel, [1740]-[1830], which covers what the compiler accepts today and shrinks as the language grows; the rules the tour left unsaid, [1840] onward, which are permanent; and its decision register, by subject: every rule that was a decision rather than a transcription, with the alternative and the fixture that pins it.
2. `tour.md` explains the language, [0010]-[1730]. It teaches by example, which is why it omits what a reader supplies for themselves — every implementation item so far has found more of what it left unsaid, and the answer is to write the rule into `spec.md` rather than to attribute one to a paragraph that does not state it. Its four-digit construct IDs (`[NNNN]`) are stable citation anchors, spaced in increments of ten so new constructs can be inserted without renumbering existing decisions, and no ID is defined in both documents. Both documents are arranged by subject and their numbers therefore do not ascend down the page; that is the numbering working, not drift to be tidied up. `docs/documents.md` says where a new rule goes.
3. `ROADMAP.md` is the sole authority for open work: the current roadmap's phases, with their items, dependencies and gates; its register of work that waits for a trigger; and the positions an outside review challenged and the project kept. The first roadmap is closed and its text is in the history. Do not create a parallel TODO list in the specification, the tour, the prototypes, or issue files. The evidence registers, which record what the compiler's evidence is rather than what is left to do, are in `compiler/tests/registers.md`.
4. `prototype-{1..5}-*.md` are specification tests, not illustrative samples. Each deliberately stressed the design, and its ending findings record both obsolete wording and the resulting resolution.
5. `handoff.md` summarizes the inherited design principles and decisions that should not be reversed without new evidence.
6. `check.py` enforces cheap textual invariants across the specification, roadmap, prototypes, and the other live documents — including that the container recipe, `compiler/ada/TOOLCHAIN.md` and `flake.nix` pin the same toolchain, the flake by reading `environments/pins.sh` rather than naming a version of its own. Extend it when a new mechanically checkable invariant is introduced or when it misses a textual defect.

The [document ownership and checks](docs/documents.md#mechanical-document-checks)
reference explains the grammar/fixture agreement, transcription tables,
Markdown invariants, generated pages, assets, fonts and highlighters. Read
the affected part when editing those sources.

## Prototype coverage

The prototypes jointly define the implementation pressure on the specification:

- Prototype 1 covers freestanding hardware: generated SVD modules, packed registers, volatile access, DMA, interrupts, and vector placement.
- Prototype 2 covers a recovering parser and distinguishes foreseeable syntax diagnostics from failures such as allocation failure.
- Prototype 3 develops the conceptual `core/mem`, `core/vec`, `core/small`, `core/map`, `core/tree` and `core/sort` layers and stresses generics, allocators, evidence tables, origins, and raw storage.
- Prototype 4 builds on prototypes 2 and 3, adds hosted I/O, and exercises heterogeneous runtime dispatch through `any C`.
- Prototype 5 builds on prototypes 1 and 4: a server with two requests in flight and a Cortex-M0 counterpart answering them on one core. It stresses fibres over caller-supplied stacks, started only as a group the caller joins, concurrency as a provider's answer rather than a function's, switch points, origins across a switch, interrupts waking fibres without read-modify-write atomics, and stopping without cancellation. The concurrency phase implemented its findings, decided as D444-D449.

Repeated module names describe shared future subsystems, not separately checked source dependencies. Prototypes 1 and 4 cover the freestanding and hosted authority roots respectively, and prototype 5 both at once; capabilities below those roots are passed as ordinary arguments.

## Implementation architecture

The bootstrap compiler implements the enabled pre-v1 Landin slice in Ada 2022. It uses pinned GNAT/GPRbuild, minimal dependencies, no SPARK, and a repository-owned compiler test harness. The README describes its current capabilities; the ROADMAP records outstanding driver and backend mutation evidence and maintainer decisions for production claims. Its direct executable is `refine`, and Landin source files use the `.ldn` suffix. `compiler/ada/README.md` records the current package layout and what each package may and may not own; `compiler/ada/TOOLCHAIN.md` records the pinned versions and the warning policy; `compiler/tests/README.md` records the fixture format.

Two rules already hold in the chassis and must keep holding. Every host effect the compiler needs goes through a `Landin.Platform` interface, so every driver and stage case runs against a fake filesystem; the cases that exercise the native adapter, run the recorded fixtures, or read the real fixture tree are the deliberate exceptions, and each one names the real host in its own comment. Nothing outside `Landin.Targets` may ask the host how wide a pointer is: a 32-bit target description stays 32-bit on a 64-bit host, and layout arithmetic counts target bytes in `Landin.Targets.Byte_Count` rather than in the host compiler's `Natural`.

The compiler checks whole programs and may use private caches. Its verified target-neutral IR is allowed to evolve from implementation evidence rather than being frozen as one flat or serialized form. Landin retains its own native backends, which emit assembly for platform assembler/linker tooling. The first targets came in the order Linux x86-64, native macOS arm64, then emulator-first Cortex-M; [what refine does today](docs/capabilities.md) lists the current ones. C and LLVM remain rejected backend alternatives.

[`docs/ir.md`](docs/ir.md) explains the IR and its rationale for readers new to
the project. Keep it current when the representation, verification boundary
or optimization pipeline changes. It is derived from implementation and
tests, never an authority for semantics, implementation decisions or work.
Seven more are derived the same way:

| document | what it holds |
|---|---|
| `docs/targets.md` | the C and link-name package boundaries |
| `docs/diagnostics.md` | every diagnostic code: the text `refine explain` prints, built in by `python3 check.py --catalogue` |
| `docs/format.md` | every rule of `refine fmt`'s one layout, held to it by the test program |
| `docs/server.md` | what `refine lsp` answers, held to it by the sessions under `compiler/tests/server/` |
| `examples.md` | the complete programs the runtime suite executes |
| `docs/benchmarks.md` | what five of them cost against other languages |
| `docs/from-c.md` | the Landin form of each C habit, its examples a fixture the test program compiles |

All eight are derived; none decides anything.

Compiler stages are Ada packages behind tested seams so a future self-hosting roadmap may replace them incrementally. The current roadmap neither schedules self-hosting nor freezes a serialized cross-language stage protocol.

The standard library uses `core/*` for shared modules, `hosted/*` for hosted
services and `platform/*` for modules with a declared target scope. Target
availability follows the import namespace even when a project root supplies
the source. These namespace names are not lexical keywords.
`landin/compiler`, `landin/assembler`, and `landin/linker` are reserved
toolchain modules. Package acquisition and arrangement of package roots belong
to a separate companion tool rather than the compiler, and a program may
contain only one version of a package name.

Implementation proceeds without waiting for every unresolved foundation.
`ROADMAP.md` assigns each question to the first vertical slice that needs it.
The first roadmap is complete: no work item remains. It built the bootstrap
chassis, the executable language kernel and the first Linux x86-64 path, the
semantic and representation core, the first complete derived program, the
hosted Linux path, the native macOS target and its debugging, Cortex-M0 and
compiler-owned firmware, and finally audited every construct and gave every
inherited row a terminal disposition.

What each item contributed is not re-narrated here, and the current roadmap
does not narrate either: the first one grew to thirteen thousand lines doing
it. A completed item gets a short `Done:` paragraph, and the reasoning goes in
the commit and in `spec.md`'s register of decisions. For current compiler
capabilities, see [what refine does today](docs/capabilities.md).

The current roadmap covers a frontend that scales, assembly with
operands, a frontend for an editor, more hosted targets, microcontrollers,
the library split, concurrency and optimization. A build tool,
package acquisition, release versioning and self-hosting stay outside it, with
the successor families in `ROADMAP.md` owning each. Do not change any version
or release designation without explicit user approval, and do not assume
SemVer. Cite a roadmap item or register record in `ROADMAP.md` and nowhere
else: `check.py` refuses a work item or register identity of either roadmap
anywhere outside `ROADMAP.md`, except the status pointer `README.md` and
`handoff.md` carry.

## Design constraints

Changes must preserve the range from a 32 KB microcontroller to a hosted application. The stated 32 TB hosted endpoint is an unverified goal: what it measures and its proof criterion remain open, and current hosted support establishes no 32 TB bound. The central design choices are:

- Manual memory with arenas as the idiom; no GC, reference counting, or destructors. Allocators are threaded as capabilities rather than stored in containers.
- Reference permission and binding mutability are separate. Lifetime checks use local origin/escape analysis, not ownership or a borrow checker. The language is deliberately unsafe with useful local checks rather than claiming memory or resource safety.
- Declared atom-set errors use `fail`/`try` and call-site `else`; foreseeable conditions should generally be represented and recovered from directly.
- Concepts and evidence tables support both static generics and `any` runtime dispatch; specialization is an optimization rather than the semantic basis.
- There is no compile-time execution or macro system. Source generators belong in the future build design.

Before reviving a previously rejected idea, read `ROADMAP.md`'s retained positions and register, and `tour.md`'s `WHAT WAS TRIED AND DROPPED` section.

## Editing the specification

When implementation requires a semantic change, update `tour.md`, the affected prototype-derived tests, and `ROADMAP.md` together. Trace the construct's citations, reread all affected prototypes including cross-prototype interactions, and then run `python3 check.py`. Per-file reasoning has previously missed contradictions found only by comparing prototypes.

Do not modernize obsolete syntax inside prototype finding sections (`Xn`, `Yn`, `Zn`, `Wn`, `Vn`) or the tour's `WHAT WAS TRIED AND DROPPED` section. Those passages intentionally preserve rejected wording next to its resolution, and `check.py` deliberately excludes them from some retired-spelling checks.
