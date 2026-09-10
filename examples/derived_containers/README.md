# Derived container program

This directory is the reusable library/application portion of ROADMAP R4.70,
derived from `prototype-3-containers.md` without rewriting its historical
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
