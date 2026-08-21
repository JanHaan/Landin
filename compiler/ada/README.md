# The Ada bootstrap compiler

This directory holds the bootstrap implementation described by `ROADMAP.md`.
It is a real compiler under construction, not a prototype: `tour.txt` remains
the normative language specification, and nothing here may quietly decide
language semantics.

## Layout

```
compiler/ada/
  landin_common.gpr     build policy: language version, warnings, modes
  landin_lib.gpr        the compiler library, built by everything else
  refine.gpr            the `refine` executable
  landin_tests.gpr      the repository's own test program
  TOOLCHAIN.md          the pinned toolchain and warning policy
  src/
    base/               the root package and the exceptions
    source/             source snapshots, spans, line maps, provenance
    diagnostics/        diagnostic transport and text rendering
    platform/           host adapters and their native implementations
    stages/             target facts and the stage/pipeline seams
    syntax/             the tokens and the scan; the parser joins at R1.40
    driver/             the request/result boundary
    main/               the `refine` entry point
  tests/src/            the harness, the fakes and the suites
```

`compiler/tests/` sits outside this directory on purpose. Fixtures describe
the language, not this implementation, and must survive the bootstrap being
replaced.

## Package ownership

| package | owns | must not |
|---|---|---|
| `Landin` | the namespace and the three exceptions | contain any logic |
| `Landin.Source` | immutable snapshots, byte offsets, spans, line maps | read a file, or know an encoding beyond bytes |
| `Landin.Source` storage | heap-allocated text and line maps, never freed while the process lives | put a source file in an automatic object |
| `Landin.Source.Sets` | a compilation's snapshots and their identities | acquire bytes from a host |
| `Landin.Provenance` | origins and the declaration side table | know what a declaration means |
| `Landin.Source.Names` | identities for the byte runs a program names | know that a spelling is reserved |
| `Landin.Tokens` | the lexical vocabulary, the token, the fault, the stream | render prose, assign a diagnostic code, or build a token |
| `Landin.Tokens.Lexer` | the scan, and the only construction of a token | know what a token means |
| `Landin.Diagnostics` | codes, severities, labels, notes, ordering | render, or own the catalogue of codes |
| `Landin.Diagnostics.Text` | deterministic rendering | decide severity or ordering policy |
| `Landin.Platform` | the host interfaces every effect goes through | perform an effect |
| `Landin.Platform.Native` | the only filesystem implementation | be reached except through the interface |
| `Landin.Platform.Native.Tools` | the only process spawning, and the only GNAT-specific dependency | grow a second host concern |
| `Landin.Targets` | target facts and layout arithmetic | ask the host how wide a pointer is |
| `Landin.Stages` | the compilation context, the stage interface, pipelines | know which stages exist |
| `Landin.Driver` | argument classification and the result | implement a language rule |
| `Refine` | printing and the exit status | contain a decision |

Public specifications stay narrow, and a representation is private wherever a
caller could otherwise assemble a value the package would not have produced:
`Landin.Targets.Target_Facts` is private because a description must come from
a named target, not from a record literal that happens to describe the
development host. Where a type is limited, that is deliberate too: a
compilation cannot be copied out from under its stages.

A snapshot's bytes and line map are allocated once and not freed. A
compilation owns its sources for as long as it exists, the process is short,
and a compiler that frees source text while a diagnostic still points into it
has traded a leak for a dangling span. That is a decision, not an oversight;
when the roadmap needs a longer-lived process it will be revisited there.

## What is deliberately absent

There is no parser, checker, IR or backend here yet. `refine` reads a `.ldn`
file and reports `L0001`, because the frontend is not wired to it until
R1.40. The scanner exists and is held to the grammar: `check.py` compares
`Landin.Tokens`' reserved words with the tour's own `keyword` production, and
the harness lexes every program in the corpus and compares each token with
what `check.py`'s independent tokeniser produced.

`Landin.Tokens` knows two things the kernel grammar does not, both on
purpose. A band of deferred lexemes -- `1.5`, `"text"`, `+=`, `!` -- is read
as one token each so that `[1830]` can refuse a construct by name instead of
reporting a stray byte, and so that enabling one later cannot change how a
file that never used it was read. Every deferred kind names the tour
construct it belongs to, and `check.py` holds it to naming one that exists
and to not being a lexeme the grammar already spells.

The stage seam is one interface and one pipeline, contract-tested with fake
stages. Named per-stage packages arrive as each stage is written, which is
what keeps the seam a seam rather than an empty directory tree with
aspirational names in it.

## Building

See `TOOLCHAIN.md`. From the repository root:

```sh
./scripts/build.sh
./scripts/test.sh
```
