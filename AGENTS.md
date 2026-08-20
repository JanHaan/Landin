# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository state

Landin is currently a language specification, not an implementation. There is no compiler, standard library, build system, dependency manifest, or executable prototype yet. The four prototype files are specification stress tests written as code sketches; they contain omissions such as `...` and are not standalone programs.

## Commands

```sh
# Run every available mechanical check over the specification and prototypes
python3 check.py

# Check one specification/prototype file (the narrowest supported test scope)
python3 check.py prototype-2-parser.txt
```

`check.py` uses only the Python standard library and changes to its own directory, so it can also be invoked by absolute path from elsewhere. It is a heuristic invariant checker, not a parser, compiler, formatter, or semantic test suite. There are currently no build, lint, typecheck, or runnable-test commands. Run the full command after documentation changes; targeted checking of an absolute `tour.txt` path does not run all citation checks.

## Sources of truth

Use the repository documents in this order:

1. `tour.txt` is the normative language specification. Its four-digit construct IDs (`[NNNN]`) are stable citation anchors, spaced in increments of ten so new constructs can be inserted without renumbering existing decisions.
2. `BACKLOG.md` is the sole list of unresolved work. Read it before proposing design changes; do not create a parallel TODO list in the tour or prototypes. Items cite tour constructs and prototype findings.
3. `prototype-{1..4}-*.txt` are specification tests, not illustrative samples. Each deliberately stressed the design, and its ending findings record both obsolete wording and the resulting resolution.
4. `handoff.md` summarizes the design principles, working process, and decisions that should not be reversed without new evidence.
5. `check.py` enforces cheap textual invariants across the tour and prototypes. Extend it when a new mechanically checkable invariant is introduced or when it misses a textual defect.

`R§n` and `H§n` citations in the backlog refer to an external design archive; the tracked repository does not depend on that archive.

## Prototype coverage

The prototypes jointly define the implementation pressure on the specification:

- Prototype 1 covers freestanding hardware: generated SVD modules, packed registers, volatile access, DMA, interrupts, and vector placement.
- Prototype 2 covers a recovering parser and distinguishes foreseeable syntax diagnostics from failures such as allocation failure.
- Prototype 3 develops the conceptual `core/mem`, `core/vec`, `core/map`, and `core/tree` layers and stresses generics, allocators, evidence tables, origins, and raw storage.
- Prototype 4 builds on prototypes 2 and 3, adds hosted I/O, and exercises heterogeneous runtime dispatch through `any C`.

Repeated module names describe shared future subsystems, not separately checked source dependencies. Prototypes 1 and 4 cover the freestanding and hosted authority roots respectively; capabilities below those roots are passed as ordinary arguments.

## Intended implementation architecture

The planned compiler is whole-program and uses one flat, QBE-inspired intermediate representation. It will emit assembly and rely on platform assembler/linker tooling. Initial targets are arm64 and x86-64, followed by Cortex-M; C and LLVM backends are explicitly rejected design alternatives.

`core/*` is reserved for the future standard library. `landin/compiler`, `landin/assembler`, and `landin/linker` are reserved toolchain modules. Package acquisition and arrangement of package roots belong to a separate companion tool rather than the compiler, and a program may contain only one version of a package name.

Do not begin a front end by guessing through unresolved foundations. `BACKLOG.md` section A lists the blockers (grammar, raw storage, value layout, invalid packed encodings, guarantees, compiler-supplied conformances, evidence ABI, and diagnostics), while section F defines the implementation milestone and its amendment. The first milestone is a stable subset with useful diagnostics that can run a meaningful part of the parser prototype, not full-tour support.

## Design constraints

Changes must preserve the range from a 32 KB microcontroller to a hosted application. The central design choices are:

- Manual memory with arenas as the idiom; no GC, reference counting, or destructors. Allocators are threaded as capabilities rather than stored in containers.
- Reference permission and binding mutability are separate. Lifetime checks use local origin/escape analysis, not ownership or a borrow checker. The language is deliberately unsafe with useful local checks rather than claiming memory or resource safety.
- Declared atom-set errors use `fail`/`try` and call-site `else`; foreseeable conditions should generally be represented and recovered from directly.
- Concepts and evidence tables support both static generics and `any` runtime dispatch; specialization is an optimization rather than the semantic basis.
- There is no compile-time execution or macro system. Source generators belong in the future build design.

Before reviving a previously rejected idea, read `BACKLOG.md` section D and `tour.txt`'s `WHAT WAS TRIED AND DROPPED` section.

## Editing the specification

When changing a construct, trace its citations and reread all affected prototypes, including cross-prototype interactions, before running `python3 check.py`. Per-file reasoning has previously missed contradictions found only by comparing prototypes.

Do not modernize obsolete syntax inside prototype finding sections (`Xn`, `Yn`, `Zn`, `Wn`) or the tour's `WHAT WAS TRIED AND DROPPED` section. Those passages intentionally preserve rejected wording next to its resolution, and `check.py` deliberately excludes them from some retired-spelling checks.

## Agent skills

### Issue tracker

Issues and specs are tracked as local Markdown files under `.scratch/`. See `docs/agents/issue-tracker.md`.

### Triage labels

Triage uses the five default canonical role names. See `docs/agents/triage-labels.md`.

### Domain docs

This repository uses a single-context domain-doc layout. See `docs/agents/domain.md`.
