# Hosted parity on native Darwin

This directory holds the full hosted parity contract and its scope selection.
Shared fixtures, metadata and prototype derivations supply the application
oracles; spec.md owns language semantics. Schema 4 uses the same
archived revision and scope/debugger choice as Linux. Both compiler modes run
host checks. Routine runs complete release hosted coverage; debugger risk adds
all release LLDB coverage. Milestones run everything below in both modes:

- Compiler-host checks with `test.sh --host`.
- Every applicable positive and negative source verdict with Darwin selected,
  including ordered diagnostic codes and exact diagnostic files.
- Every shared runtime and ABI case, using the four standard profiles or all
  six specialization profiles. Native counterparts and regenerated bindings
  use all four standard profiles.
- The complete parser, containers and hosted application under native LLDB at
  none/off, size/auto and size/all, followed by the full macOS source-debugging
  contract.

`check.py --parity` derives its schedule from shared metadata. `parity.json`
records each source-selected verdict, native replacement and demonstrated
platform limitation; it cannot silently omit a new fixture. `cases.json`
retains the historical selected scope of the first Darwin lowering corpus.
`--case`, `--profile` and debugger `--workload` are filtered development
feedback, never acceptance.

```sh
python3 compiler/tests/darwin/check.py --parity \
    --refine compiler/ada/build/darwin-arm64/release/bin/refine \
    --case runtime/derived-parser --output .scratch/parser-darwin
python3 scripts/ci/darwin.py accept FULL_COMMIT
```

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
| Large static reservation | The unchanged 2 GiB zero-reserved global still expects status 42. On the pinned Darwin default image layout, dyld aborts before `main`; `large_image.c` reproduces the same loader abort with native Clang. Every profile retains both executions and requires their exact signal and loader diagnostic. Rows are `platform-limited`, never passing runtime rows. General large-image placement remains open work. |

The last row does not change array semantics or claim all large executables
are impossible on macOS. The compiler must still emit the complete byte
offset and the assembler/linker must succeed. A bounded Ada seam regression
checks both read and write without assembling a large object. Acceptance
retains the small zero-reservation objects and the actual loader failures;
an unexplained signal, timeout or missing control fails verification.

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
source closure for both native debugger runners.

Each complete program retains assembly, object, executable, dSYM, source map,
DWARF verification, unwind/UUID output, command logs and LLDB assertions.
A stripped copy executes alone, has no source breakpoint locations, and still
matches retained identity data. Lookup refuses a mismatched map. The selected
source-debugging sessions additionally retain all thirteen scalars, source aliases,
unavailable locals, the three-u32 caller ABI, optional filename deployment,
comment-only source identity changes and mismatched dSYM refusal.

Schema-3/4 verification reconstructs coverage and producer/consumer commands
from the accepted source archive, checks shared output oracles and artifact
hashes, and checks LLDB values against the committed source-derived oracle.
Missing profiles, altered source/compiler commands, failed or timed-out
sessions, substituted artifacts and weakened expected values are refused.
Schema-1/2 records retain their original lowering/debugging meaning. Schema 3
retains both-mode parity and its archived Linux milestone requirement. The
versioned derivative oracle reads marker lines from the accepted archive;
changing live debugger helpers cannot silently reinterpret old evidence.
