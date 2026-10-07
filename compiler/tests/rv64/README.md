# Physical RV64 Linux evidence

The gate cross-emits RV64 Linux LP64D with the checked Linux release compiler
and GNU RISC-V tools, then transfers the binaries to the RISE service's
physical runners. Its exact runner label is `ubuntu-24.04-riscv`. No native
RISC-V Ada host is required. Four independent execution verdicts cover the
applicable runtime corpus, native GDB, the C ABI and ISA levels; four emission
jobs prepare their inputs. Emission is recorded as `emitted` and never
supplies an execution verdict.

Every prepared payload names its CI revision, compiler checksum, source-tree
checksums and every bundle file's checksum. Execution refuses another
revision, changed source bytes, changed binary or peer object bytes, missing
profiles, changed fixture oracles and empty selections. Filtered development
payloads cannot supply CI evidence. Native execution requires Linux riscv64
and refuses explicitly identified emulation. Each execution job retains its
CPU identity and verdict transcripts for fourteen days in one compressed
tar archive, including the generated GDB session scripts. Binaries remain
in their separately retained emission payloads.

The runtime lane selects metadata-applicable fixtures at four ordinary
optimization/specialization profiles, plus two specialization profiles where
requested, and checks applicable positive and negative source verdicts on
the supported compiler host. `assembly-operands` executes integer inputs,
outputs, inout operands, fixed registers, narrow values and declared callee
saves. Each emission job also requires the backend suite's RV64 invalid-IR
register regression.

The ISA lane executes the same fixtures at `rv64gc` and
`rv64gc_xtheadba`. A fixed-if feature program returns 42 at baseline and 43
when the extension is selected, making a mistaken feature fact observable.
An indexed array access must contain the baseline shift/add sequence or
`th.addsl` in the linked `indexed` routine as appropriate, and both images
execute. A conditional assembly block executes the same extension operation.
A separate unconditional block must assemble at the extended level and be
refused at baseline. Before any extended binary executes, a separately
compiled C probe executes `th.addsl` under an isolated SIGILL handler; an
unsupported instruction fails the whole lane. No vector or Zbb support is
assumed from the CPU name.

The ABI lane refuses fixtures without separately compiled C peers and
requires a nonempty coverage set for imported and exported scalar and
floating calls, `layout(c)` aggregates, callbacks and variadic calls. LP64D
specific fixtures stress high-bit unsigned word arguments/results, observe
native main's complete XLEN return register through an independent linker
wrapper, and check
promoted unnamed floating arguments through integer registers and stack
slots. A peer independently checks Linux `struct stat` using the native
headers. GDB sessions at four profiles require source-line stops, three
nested frames, callee and caller local values, completed unwinding to the
caller at its call source line, and the caller's result value at a subsequent
source stop, followed by the expected final exit status. The shared DWARF
describes Landin's native result carriers through source locals; it does not
declare a C return type that makes GDB's `finish` print a return value.

For local cross-emission on a supported Linux compiler host:

```sh
python3 compiler/tests/rv64/check.py --prepare-only --kind=runtime \
    --refine=compiler/ada/build/linux-amd64/release/bin/refine \
    --output=/tmp/rv64-payload
```

Transfer that directory and the matching source revision to physical RV64
Linux, then select `--prepared=/tmp/rv64-payload --output=/tmp/rv64-evidence`
and the same `--kind`. The other kinds are `debugger`, `abi` and `isa`.
`--case=NAME` is an exact development filter. This evidence is the recurring
gate's safety net, not revision acceptance.
