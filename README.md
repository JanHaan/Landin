# Landin

> Ada, but small. Zig, but sweeter. One systems language from 32 KB to
> 32 TB. Move fast, keep the pointers, and let the compiler tell you
> when you are being an idiot.

A systems programming language, its compiler and a small standard
library, designed and built from scratch. Named after Peter Landin, who
coined the term *syntactic sugar* and wrote *The Next 700 Programming
Languages* in 1966 — this one is the 701st.

One target range, and the same way of writing code across all of it: a
Cortex-M0 with 32 KB of flash at one end, a hosted desktop application
at the other.

**Status: specification 0.1.0. R0, R1 and R2.20 are complete, and R2.30 is
active. `refine` scans, parses, resolves names, checks types and definite
assignment, lowers and verifies target-neutral IR, emits Linux x86-64
assembly, and can assemble and link a hosted executable. Runtime fixtures run
those binaries on the native x86-64 gate. The enabled kernel includes scalars,
fixed arrays, recursively nested ordinary structs, unfolded variants,
first-class function signatures with declared atom errors, expression-valued
non-loop control flow, and lexical `defer`/failure-only `undo`; native macOS
arm64, Cortex-M and the standard library remain future work.**

## What is here

| file | what it is |
|---|---|
| `handoff.md` | start here. The design in one page, the principles behind it, how the work is done, and which decisions must not be quietly reversed. |
| `spec.md` | the normative specification: the grammar of the enabled kernel, the rules the tour left unsaid, and the register of decisions taken while implementing them. |
| `tour.md` | the language explained, as a numbered "learn X in Y minutes". Teaches; does not decide. |
| `examples.md` | complete programs the compiler emits and the Linux gate runs today: recursive Fibonacci and three sorting algorithms. |
| `ROADMAP.md` | the sole durable authority for open work, implementation dependencies, phase gates, and dispositions. Read it before proposing or scheduling work. |
| `AGENTS.md` | how to work in this repository: the authority order, the commands, and the rules the chassis already keeps. |
| `check.py` | mechanical checks over the live documents, grammar and fixture corpus. Run it after touching any of them. |
| `compiler/ada/` | the Ada 2022 bootstrap compiler: `refine`, its frontend and verified IR, the Linux x86-64 backend and toolchain path, and its own test harness. |
| `compiler/tests/` | fixtures, in a format that outlives the implementation checking them. |
| `scripts/` | build, test, clean and toolchain commands. Provider-neutral, except `linux-loop.sh`, which drives Apple Container by name. |
| `environments/` | the pinned `linux/amd64` image the local Linux loop builds, and `pins.sh`, the one place a toolchain version or checksum is written. |
| `flake.nix` | `nix develop`, for people who work that way: a shell holding the same pinned toolchain, read from `environments/pins.sh` rather than from nixpkgs. |
| `docs/` | the environments that produce evidence, the agent-facing notes, and the site generator. |
| `prototype-1-driver.md` | a driver written from an ugly vendor SVD: GPIO, an interrupt-driven DMA UART, a vector table, and not one hand-written bitmask. |
| `prototype-2-parser.md` | a parser that recovers, because a real one must not stop at the first mistake. |
| `prototype-3-containers.md` | a generic container library: growing array, small vector, hash map, arena-backed tree. |
| `prototype-4-app.md` | a hosted application whose shape is decided by its command line, so it cannot be written without runtime dispatch. |

The prototypes are not illustrations. They are the test suite: each was
written to make the specification fail, each ends with the list of
places where it did, and each keeps the wording that turned out wrong
beside its resolution. Between them they have recorded forty-two
findings, including several that reversed a decision.

## Reading it online

Every document here is published as a syntax-highlighted reading copy at
**https://www.701.dev** — the tour, the specification, the running examples,
the four prototypes, the roadmap, and the implementation notes. Every
`[NNNN]` citation links to the construct it names, and hovering one shows what
it says.

The canonical repository the pages are generated from is at
**https://git.sr.ht/~sinnfrei/landin**:

```sh
git clone https://git.sr.ht/~sinnfrei/landin
```

An automatically maintained GitHub mirror is at
**https://github.com/JanHaan/Landin**. Changes still originate on SourceHut;
the mirror copies its branches and tags.

The CI gate republishes the pages as its last task on every push to `main`,
so they read what the repository says. To render or publish by hand:

```sh
./scripts/site.sh              # render, verify, package
./scripts/site.sh --publish    # and upload
```

## Checking

```
python3 check.py
```

Keywords standing where names belong, spellings a decision retired,
`when` outside an exit statement, convention markers at call sites,
two declarations of one name in one module, `end` closing nothing,
citations pointing at constructs that do not exist. It resolves the
files next to itself, so it runs from anywhere.

It is not a parser and does not pretend to be one. It is the set of
invariants that are cheap to check and tedious to re-check by hand,
and it found most of what the last several revisions fixed. Every rule
that can be checked cheaply belongs in it, and so does every defect it
missed once.

## Where the history is

The design was argued out over a long sequence of numbered revisions,
four prototypes and two outside reviews, and that archive is kept
separately — the conversation, the review, the implementation handoff
and the full revision log. Nothing here depends on it.

What was worth carrying came along: the specification's closing
section, WHAT WAS TRIED AND DROPPED, keeps
the reversals, the things that were designed and then taken out again,
because a reader who does not know them will propose them back.

## Building

```sh
export LANDIN_GNAT_HOME=...      # the pinned GNAT, see compiler/ada/TOOLCHAIN.md
export LANDIN_GPRBUILD_HOME=...  # the pinned GPRbuild

./scripts/build.sh
./scripts/test.sh
```

For checksum-safe focused feedback during an edit, use
`./scripts/dev-test.sh --suite=NAME`, `--case=SUITE/NAME`, or
`--fixture=CLASS/NAME`. These runs say `FILTERED`; the no-argument command
above remains the complete suite.

On a nix machine, `nix develop` puts the pinned toolchain on `PATH` for you.

`refine --identify` will tell you what it is. Giving it one or more `.ldn`
files runs the frontend, lowering and verification over them as one module.
Without `--emit` an accepted program deliberately writes no output file;
`--emit=asm -o program.s` writes Linux x86-64 assembly, and `--emit=exe -o
program` assembles and links a hosted executable when the target toolchain and
[1970]'s entry point are present. A program it refuses gets a report with a
span, a caret and a note. If what you wrote is a construct the tour describes
and the kernel omits, the note names the paragraph that describes it and the
roadmap item that enables it.

## What comes next

Implementation proceeds in executable vertical slices rather than waiting for
every design foundation to be settled in advance. R0's Ada 2022 bootstrap
chassis and R1's executable language kernel are complete: the compiler builds
on macOS arm64 and passes its full suite there when the Linux target toolchain
is present; the pinned `linux/amd64` container and x86-64 CI run the Linux
binaries. R2 is active; R2.20's
target-parametric aggregate and variant representation is complete, and R2.30
owns functions, control-flow expressions, lexical cleanup, declared errors and
the aggregate ABI; its enabled cleanup forms are unconditional `defer` and
failure-only `undo`.
Language and architecture questions are resolved when the first vertical
slice needs them.

The first major compiler milestone is R3: a complete derived version of the
parser prototype with useful diagnostics, evidence-table dispatch, and `any`;
specialization is explicitly not part of that gate. Target work then proceeds
through the complete hosted Linux x86-64 path, native macOS arm64, and
emulator-first Cortex-M.

The endpoint is feature-complete pre-v1, not production or self-hosting.
Package acquisition, competitive optimization, release versioning, and
self-hosting belong to successor roadmaps or later decisions. No version or
release designation changes automatically.

## License

Copyright (c) 2026 Jan Haan. `MIT OR Apache-2.0`: use this under either
[the MIT license](LICENSE-MIT) or [the Apache License, Version
2.0](LICENSE-APACHE), at your option. [`LICENSE`](LICENSE) says which file
governs what.

What `refine` produces is not a derivative work of `refine`. Compiling a
program places no licensing condition on that program, and neither does
linking `core/*` into it — which is the point of a language that has to fit
in 32 KB of somebody else's flash.
