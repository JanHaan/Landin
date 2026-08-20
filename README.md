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

**Status: specification 0.1.0. There is no compiler yet. That is what
comes next.**

## What is here

| file | what it is |
|---|---|
| `handoff.md` | start here. The design in one page, the principles behind it, how the work is done, and which decisions must not be quietly reversed. |
| `tour.txt` | the specification, written as a numbered "learn X in Y minutes". The source of truth for the language. |
| `BACKLOG.md` | everything open, each item traced to where it came from. Read it before proposing anything. |
| `check.py` | mechanical checks over the specification and the prototypes. Run it after touching either. |
| `prototype-1-driver.txt` | a driver written from an ugly vendor SVD: GPIO, an interrupt-driven DMA UART, a vector table, and not one hand-written bitmask. |
| `prototype-2-parser.txt` | a parser that recovers, because a real one must not stop at the first mistake. |
| `prototype-3-containers.txt` | a generic container library: growing array, small vector, hash map, arena-backed tree. |
| `prototype-4-app.txt` | a hosted application whose shape is decided by its command line, so it cannot be written without runtime dispatch. |

The prototypes are not illustrations. They are the test suite: each was
written to make the specification fail, each ends with the list of
places where it did, and each keeps the wording that turned out wrong
beside its resolution. Between them they have produced more than fifty
corrections, including several that reversed a decision.

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

## What comes next

Not more design. `BACKLOG.md` section A is what has to be settled
before a front end can be written without guessing; section F is the
order to build in. The first milestone is not full-tour support — it is
a compiler that parses a stable subset, reports diagnostics worth
reading, accepts the coherent examples, rejects the contradictory ones,
and runs a meaningful part of the parser prototype.

From there the implementation drives the design, which is the whole
point of stopping here.
