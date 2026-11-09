# Hosted parity on native Darwin

This directory holds the hosted parity contract for macOS arm64 and its
scope selection. Shared fixtures, metadata and prototype derivations supply
the expected outputs; spec.md owns language semantics. On a Mac, a focused
check names its exact cases, and `--profile` and the debugger's
`--workload` narrow it further:

```sh
python3 compiler/tests/darwin/check.py --parity \
    --refine compiler/ada/build/darwin-arm64/release/bin/refine \
    --case runtime/derived-parser --output .scratch/parser-darwin
./scripts/dev-test.sh --host --target=linux-x86-64 --suite=checking
```

The complete contract runs in the gate's Darwin jobs on `macos-26`:

- `darwin-host` and `darwin-host-release`: the compiler host suite,
  `test.sh --host`, in each compiler mode.
- `darwin-parity`, with the release compiler: every shared runtime and ABI
  case through `check.py --parity`, at the four standard profiles or, for a
  fixture that asks, all six specialization profiles, with the native
  counterparts at the four; every applicable positive and negative source
  verdict with Darwin selected, ordered diagnostic codes and exact
  diagnostic files included, through `diagnostics.py`; and the regenerated
  bindings and archives through `bindings.py --parity`.
- The last step of `darwin-host-release`: the complete parser, containers
  and hosted application under native LLDB at none/off, size/auto and
  size/all, followed by the full macOS source-debugging contract, through
  `scripts/debug.sh --target=darwin-arm64 --parity`.

`check.py --parity` derives its schedule from shared metadata. `parity.json`
records each source-selected verdict, native replacement and demonstrated
platform limitation; it cannot silently omit a new fixture. `cases.json`
holds the first Darwin lowering corpus's selected scope, which a run
without `--parity` checks. A run with `--case` or `--profile` records its
scope as filtered.

## Cross-target comparison

| pressure | comparison and native evidence |
|---|---|
| Ordinary language behavior | Shared status, trap and byte-output oracles; the default merged stream is captured through one pipe, preserving diagnostic order. Darwin checked traps require SIGTRAP from `brk`. |
| Fixed target configuration | Unchanged architecture-selecting sources can intentionally accept, refuse or return another status. Every such verdict is enumerated in `parity.json`; ordinary generic/tool configuration runtime cases select the shared branch on both architectures. |
| C transport | Shared bidirectional peers cover scalars, aggregates, register banks, callbacks, narrow arguments, aliases, errno and callee saves. Native arm64 register probes preserve x18 and check x19–x28/d8–d15. |
| External names and interposition | C peers apply Mach-O's leading underscore; native linker aliases implement the shared GNU-wrap probes. Landin logical names stay target-neutral. |
| Variadic calls and indirect results | Native counterparts check Apple's stack tails and x8 result destination. SysV's `al` count and returned `rax` destination are not Darwin ABI obligations. |
| Generated bindings and archives | The same header, policy categories and peer regenerate with the pinned Apple triple. Exact `.a` selection, a competing dylib, missing archive refusal and a custom path with spaces execute natively. The SDK has no Linux `libm.a`. |
| System fault endpoints | `io_endpoints.c` supplies only the two named `/sys/landin-r420-denied` and `/dev/full` fault endpoints absent on Darwin. All other operations call libSystem. The shared Landin errno, failure and cleanup oracles are unchanged. This is explicit fault injection, not evidence that those Linux devices exist on Darwin. |
| Large static reservation | The unchanged 2 GiB zero-reserved global still expects status 42. Every profile builds and runs the independent native Clang control `large_image.c`. Both programs abort before `main` on the observed macOS 26.6.2 host, but both return 42 on the observed macOS 27.0.1 VM. A runtime pass requires both to return 42, the original Landin output oracle and a silent control. A `platform-limited` row requires both to abort with SIGABRT and the exact shared-region loader diagnostic; it is never a passing runtime row. Asymmetric or unknown outcomes fail. General large-image placement remains open work. |

The last row does not change array semantics or claim all large executables
are impossible on macOS. The compiler must still emit the complete byte
offset and the assembler/linker must succeed. A bounded Ada seam regression
checks both read and write without assembling a large object. A run keeps
the small zero-reservation objects and both programs' actual outcomes; an
unexplained signal, timeout or missing control fails it.

## Complete source debugging

The parser sessions inspect recursive frames, suspended caller values, token
positions, recovery and allocation/diagnostic failure flags. Container sessions
inspect the sorted list, all fourteen completion flags and signed/unsigned
generic evidence arguments, then step into each provider, out through the
evidence caller, and over the result assignment. Hosted sessions inspect the
mutable erased filter state and destination through the complete application
stack. All sessions finish the original application oracle, including exact
parser diagnostics. They retain full reached-source inventories and
specialization reports. `debugging/workload-sources.json` pins each complete
source closure for both native debugger runners; the test program holds it
to the closures too, and `debugging/workload_sources.py --write` rewrites it.

Each complete program retains assembly, object, executable, dSYM, source map,
DWARF verification, unwind/UUID output, command logs and LLDB assertions.
A stripped copy executes alone, has no source breakpoint locations, and still
matches retained identity data. Lookup refuses a mismatched map. The selected
source-debugging sessions additionally retain all thirteen scalars, source aliases,
unavailable locals, the three-u32 caller ABI, optional filename deployment,
comment-only source identity changes and mismatched dSYM refusal.

## Historical

Through 0.2.0 the retired exact-revision acceptance verified these runs
against an archived revision; its schema 1 to 4 records keep that meaning.
