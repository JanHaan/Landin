# Derived container program

This directory is the reusable library/application portion of the derived
container program, derived from `prototype-3-containers.md` without rewriting its historical
sketches or findings.

`workload/workload.ldn` composes the repository-owned `core/mem`, `core/cmp`, `core/vec`,
`core/spill`, `core/map`, `core/tree`, `core/sort`, `hosted/heap`, `core/pool`,
and `core/fault` modules. It exposes `containers_run`, the silent integrated
application routine, and `evidence_less`, a small constrained routine used by
the debugger acceptance path with two concrete ordered types.

The hosted entry and status oracle are in
`compiler/tests/fixtures/runtime/derived-containers`. Its `DERIVATION.md` maps
the running evidence to every prototype section and finding Z1-Z19, including
the current representations that deliberately supersede raw historical
sketches.

From the repository root, in the pinned development environment, run its
complete hosted entry:

```sh
./scripts/dev-test.sh --fixture=runtime/derived-containers
```

This is a `FILTERED` run. The harness builds the compiler and checks the
recorded output and expected status 42; the library directory itself has
no hosted entry point.

The complete derivative and its failure/recovery oracles also run on native
Darwin arm64 in the shared six-profile hosted parity runtime matrix. Native GDB and LLDB
inspect the same complete sources at none/off, size/auto and size/all; see the
[hosted parity guide](../../compiler/tests/darwin/README.md). The retired native acceptance
required the same committed source archive on both hosted targets; nothing
checks that now.
