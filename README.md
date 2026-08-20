# Landin

> Ada, but small. Zig, but sweeter. One systems language from 32KB to
> 32TB. Move fast, keep the pointers, and let the compiler tell you
> when you are being an idiot.

A systems programming language, its compiler and a small standard
library, designed and built from scratch. Named after Peter Landin, who
coined the term *syntactic sugar* and wrote *The Next 700 Programming
Languages* in 1966 — this one is the 701st.

One target range, and the same way of writing code across all of it: a
Cortex-M0 with 32 KB of flash at one end, a hosted desktop application
at the other.

**Status: specification 0.1.0. The compiler does not compile anything yet.
The bootstrap chassis is built, tested on three environments, and the
language frontend is next.**

## What is here

| file | what it is |
|---|---|
| `handoff.md` | start here. The design in one page, the principles behind it, how the work is done, and which decisions must not be quietly reversed. |
| `tour.txt` | the specification, written as a numbered "learn X in Y minutes". The source of truth for the language. |
| `ROADMAP.md` | the sole durable authority for open work, implementation dependencies, phase gates, and dispositions. Read it before proposing or scheduling work. |
| `AGENTS.md` | how to work in this repository: the authority order, the commands, and the rules the chassis already keeps. |
| `check.py` | mechanical checks over the specification, roadmap, and prototypes. Run it after touching any of them. |
| `compiler/ada/` | the Ada 2022 bootstrap compiler. Today: the chassis, `refine`, and its own test harness. |
| `compiler/tests/` | fixtures, in a format that outlives the implementation checking them. |
| `scripts/` | build, test, clean and toolchain commands. Provider-neutral, except `linux-loop.sh`, which drives Apple Container by name. |
| `environments/` | the pinned `linux/amd64` image the local Linux loop builds. |
| `docs/` | the environments that produce evidence, and the agent-facing notes. |
| `prototype-1-driver.txt` | a driver written from an ugly vendor SVD: GPIO, an interrupt-driven DMA UART, a vector table, and not one hand-written bitmask. |
| `prototype-2-parser.txt` | a parser that recovers, because a real one must not stop at the first mistake. |
| `prototype-3-containers.txt` | a generic container library: growing array, small vector, hash map, arena-backed tree. |
| `prototype-4-app.txt` | a hosted application whose shape is decided by its command line, so it cannot be written without runtime dispatch. |

The prototypes are not illustrations. They are the test suite: each was
written to make the specification fail, each ends with the list of
places where it did, and each keeps the wording that turned out wrong
beside its resolution. Between them they have recorded forty-two
findings, including several that reversed a decision.

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

`refine --identify` will tell you what it is and admit that it has no
frontend. Giving it a `.ldn` file gets you a diagnostic saying the same
thing, with a span pointing into your file, which is more than nothing: the
source, diagnostic, host, target and stage foundations underneath it are
real and tested.

## What comes next

Implementation begins immediately rather than waiting for every design
foundation to be settled in advance. `ROADMAP.md` starts with the Ada 2022
bootstrap chassis at R0, which is complete: it builds and passes its suite on
macOS arm64, in a pinned `linux/amd64` container, and on x86-64 hardware in
CI. R1 builds an executable language kernel and the first Linux x86-64
compile/assemble/link/run path. Language and architecture questions are
resolved when the first vertical slice needs them.

The first major compiler milestone is R3: a complete derived version of the
parser prototype with useful diagnostics, evidence-table dispatch, and `any`;
specialization is explicitly not part of that gate. Target work then proceeds
through the complete hosted Linux x86-64 path, native macOS arm64, and
emulator-first Cortex-M.

The endpoint is feature-complete pre-v1, not production or self-hosting.
Package acquisition, competitive optimization, release versioning, and
self-hosting belong to successor roadmaps or later decisions. No version or
release designation changes automatically.
