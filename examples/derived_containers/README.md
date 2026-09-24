# Derived container program

This directory is the reusable library/application portion of the derived
container program, derived from `prototype-3-containers.md` without rewriting its historical
sketches or findings.

`workload/workload.ldn` composes the repository-owned `core/mem`, `core/vec`,
`core/small`, `core/map`, `core/tree`, `core/sort`, `core/heap`, `core/pool`,
and `core/failing` modules. It exposes `containers_run`, the silent integrated
application routine, and `evidence_less`, a small constrained routine used by
the debugger acceptance path with two concrete ordered types.

The hosted entry and status oracle are in
`compiler/tests/fixtures/runtime/derived-containers`. Its `DERIVATION.md` maps
the running evidence to every prototype section and finding Z1-Z19, including
the current representations that deliberately supersede raw historical
sketches.

The complete derivative and its failure/recovery oracles also run on native
Darwin arm64 in the shared six-profile hosted parity runtime matrix. Native GDB and LLDB
inspect the same complete sources at none/off, size/auto and size/all; see the
[hosted parity guide](../../compiler/tests/darwin/README.md). The retired native acceptance
required the same committed source archive on both hosted targets; nothing
checks that now.
