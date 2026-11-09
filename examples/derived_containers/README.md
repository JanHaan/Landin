# Derived container program

An application of the generic containers and allocators: the working
version of prototype 3, derived from `prototype-3-containers.md` without
rewriting its historical sketches or findings. This directory is the
library; its hosted entry and expected exit status are in
`compiler/tests/fixtures/runtime/derived-containers`. From the repository
root, with `refine` installed:

```sh
refine run --root=. compiler/tests/fixtures/runtime/derived-containers
```

It prints nothing and exits with status 42, the status the fixture
expects.

`workload/workload.ldn` composes the repository-owned `core/mem`, `core/cmp`, `core/vec`,
`core/spill`, `core/map`, `core/tree`, `core/sort`, `hosted/heap`, `core/pool`,
and `core/fault` modules. It exposes `containers_run`, the silent integrated
application routine, and `evidence_less`, a small constrained routine the
debugger sessions use with two concrete ordered types.

The fixture's `DERIVATION.md` maps the running evidence to every prototype
section and finding Z1-Z19, including the current representations that
deliberately supersede raw historical sketches. While working on the
compiler, `./scripts/dev-test.sh --fixture=runtime/derived-containers`
builds it and runs this fixture alone, checking the recorded output and the
status; the run reports `FILTERED` because it selects one fixture.

The complete program and its failure and recovery checks also run natively
on macOS arm64 in the six-profile hosted parity matrix, and native GDB and
LLDB inspect the same sources at none/off, size/auto and size/all; see the
[hosted parity guide](../../compiler/tests/darwin/README.md).
