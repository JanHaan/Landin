# Development, acceptance and publication

`ROADMAP.md` owns this process and its remaining work. R5.20 records the
maintainer's decision: full gates only at major milestones, Linux work on
native Linux, debugger checks only for substantial regression risk, and Nix
CI deferred.

## Choose checks for their consequence

| stage | work | evidence |
|---|---|---|
| edit/test loop | checksum-based build and exact affected case/suite/fixture selectors; affected Python tests | development feedback |
| Mac compiler host | `scripts/dev-test.sh --host`; diagnostics, compiler units and complete IR golden | explicit host scope; no Linux workload emission/execution |
| Linux development | `scripts/ci/controller.py dev --slot NAME -- COMMAND...` on the native runner | focused native feedback; no approval |
| native Darwin candidate | schema-4 debug/release host checks and complete release source/runtime/ABI, derived programs and bindings | required matching archive and compatible Linux scope |
| routine main promotion | five committed jobs: debug host suite, full release suite/runtime/ABI and native report identity, release object quality, bindings, documents/tooling | exact-commit routine approval |
| substantial debugging risk | routine coverage plus full native release GDB and LLDB | exact-commit routine approval that includes the debugger job |
| major phase/parity milestone | full Linux suite/quality/GDB and Darwin host/source/runtime/ABI/bindings/LLDB in both compiler modes, plus documents/tooling | exact-commit milestone approval |
| publication | verified export, annotated approval, atomic main/tag promotion, guarded Pages rendering | delivery of the approved revision |

Do not run Linux containers or Linux workload matrices on the Mac during R5/R6
development. In-process compiler units may still inspect target-specific data;
that is host-compiler coverage, not Linux execution. `--host` excludes the two
native target-workload cases and requires every remaining case to pass. The
IR comparison that exposed R5.10's Ada argument-order defect remains included.

Choose the smallest test that can expose the changed behavior first. When it
passes, broaden only for another affected subsystem or a remaining concern.
Run routine acceptance once for the final committed promotion candidate;
Linux can resume verified successful jobs after interruption. Darwin has no
resume path: interrupted or failed runs require a new run. Failed Linux jobs
or changed source also require a new acceptance run. Do not repeat full local matrices before
that gate. Documentation changes still receive full `check.py`; the checker
retains every invariant and fixture.

Debugger risk means changed debug metadata, source/variable locations,
unwind/frame conventions, debugger transport, debugger checks, or acceptance
selection/verification of debugger evidence. Record the
reason for enabling it. A status-page edit or an unrelated tool change is not
a reason to run debugger matrices. Historically, the R5.10 ordering repair preserves the existing Linux IR
and copy behavior, changes no debug encoding/location/unwind code, and passed
the unchanged IR golden and traversal execution checks in both compiler modes;
that delivery used routine scope without GDB. R5.51 changes debugger selection
and verification, so its closure uses routine scope with full release GDB/LLDB.

Before a major milestone such as R5.50 or R6.100, select and commit milestone
scope with the closure candidate. A routine approval cannot be cited as a full
milestone result. Subsequent development returns to routine scope.

```sh
python3 scripts/ci/policy.py routine
python3 scripts/ci/policy.py routine --debugger
python3 scripts/ci/policy.py milestone
```

These commands edit both native policy files; commit them before acceptance.
Darwin schema 4 records host modes, hosted modes and debugger modes explicitly.
Routine retains complete release coverage; `--debugger` adds every release
native debugger profile and derivative. Milestones run both modes. Approval
validates the exact commands, selected scope and matching archive. Historical
Linux schema-1 approvals remain full eight-job evidence; Darwin schemas 1/2/3
retain their original contracts, including schema 3's Linux milestone rule. The native
operations guide documents acceptance, export, approval and promotion.

## What the measurements say

The retained full Linux run `20260914T204024Z-147ccbe20b60` ran its eight jobs
concurrently. Its slowest job determined about 91 minutes of wall time:

| component | debug compiler, seconds | release compiler, seconds |
|---|---:|---:|
| complete suite command | 4738.5 | 1096.4 |
| object-quality command | 5438.8 | 1070.2 |
| native debugger command | 2823.9 | 555.8 |

The document/tooling job took 111.0 seconds, including 88.2 in `check.py`,
10.5 in CI failure-path tests and 2.1 in rendering. The complete R5.10 Mac
harness took 2522.2 seconds in debug and 911.3 in release, largely compiling
Linux workloads before the inevitable missing-tool refusal. Those runs remain
historical evidence, not the future development cadence.

A local Python profile put 99.9 of 106.5 instrumented seconds in the grammar
corpus check: 50.9 in recognition and 44.7 in lexical membership. The lexical
matcher was called 952266 times. It now reuses repeated spellings within one
file with a bounded cache. Grammar edits cannot reuse answers from a previous
invocation, and token offsets/refusals remain checked. No corpus is skipped
and no persistent cache supplies acceptance evidence.

The subsequent same-host profile took 72.6 seconds, about 32% less. Lexical
membership fell to 101568 calls and 8.2 instrumented seconds. The new debug
host run passed 711 cases and 192905 checks; its transcript timestamps span
about 280 seconds including incremental rebuilding. These local measurements
describe this checkout and host, not fixed performance bounds.

The first routine run, `20260915T082011Z-70a07a37aea3`, measured 1208.5
seconds for its slowest job. Release suite and quality commands took 1094.9
and 1081.5 seconds; their separate bootstrap builds took 111.6 and 113.8.
Debug host checks took 437.3 seconds after a 46.1-second build. Documents
and bindings jobs took 84.1 and 60.6 seconds. These are measured results,
not fixed performance bounds.

## Parallel work and build reuse

The outer jobs already run in parallel. The remaining opportunity is inside
long jobs: independent workload/profile compilations run sequentially, and
the same compiler mode or workload is built for several consumers.

The proposed build graph is: one compiler build per mode, independent program
builds keyed by their complete inputs and flags, then separate execution,
quality and debugger consumers. Share immutable artifacts with verified
identities, not mutable output paths. Use one aggregate CPU/memory budget;
nested unrestricted worker pools would oversubscribe the runner. Keep
GPRbuild's existing Ada dependency and checksum handling.

R5.20 evaluated one versus two workers on native Linux using the same
immutable release compiler and fresh outputs for the parser/container
programs under none/off and size/auto. The four compilations took 111.15
seconds sequentially and 55.55 with two workers; every assembly hash matched.
Individual peak RSS was at most 50372 KiB. These samples justify two-worker
experimentation; they do not bound memory for the whole fixture matrix.

The evaluated dependency graph keys a compiler artifact by complete source,
project/pin inventory, host/tool identities, mode, flags and path mapping.
A workload artifact additionally keys reached source/roots, configuration,
profile, debug settings, compiler identity, adapter inputs and target tools.
Execution, quality and debugger consumers retain independent run records.
The two existing release compiler artifacts have different binary hashes and
sizes in their different build contexts; they cannot simply be exchanged
under today's acceptance identity records. Their builds already overlap, so
sharing would save CPU but is not a measured 112-second wall-time improvement.

The production scheduler/cache remains deferred to the scale and self-hosting
successor under ROADMAP.md's R5.20 disposition. Integrating bounded workers
requires shared cancellation, timeout ownership and aggregate resource tests;
artifact sharing requires an acceptance-schema change for producer identities.
The quality command's second compilation deliberately checks determinism and
must stay fresh. Cache hits must be labelled as reuse, and native execution
must still run. This closes the evaluation without weakening those oracles or
introducing nested worker pools into the routine gate.

## Nix later

The current `flake.nix` supplies development shells. It does not define a
cached `refine` package or the project's test derivations. More `nix develop`
invocations alone would not remove repeated compilation.

Nix could later own compiler packages and suitable `checks` with narrow,
complete inputs, and schedule them on the correct native builders. Its flake
checks build the declared check derivations; distributed builds and separate
job/core controls provide the scheduling mechanisms.
[Flake checks](https://nix.dev/manual/nix/2.35/command-ref/new-cli/nix3-flake-check.html),
[distributed builds](https://nix.dev/tutorials/nixos/distributed-builds-setup.html),
[job/core controls](https://nix.dev/manual/nix/2.32/advanced-topics/cores-vs-jobs).

Nix CI is explicitly deferred. A later evaluation must account for the pinned
Apple SDK, native debugger permissions, input selection, cache provenance and
the existing native acceptance record. Build reuse cannot replace the native
Darwin, Linux or freestanding executions required at a milestone.


## Historical Darwin acceptance progression

R5.30 adds `scripts/ci/darwin.py accept COMMIT` to ordinary promotion. It runs
the committed native Mac policy and exports source, tools, artifacts and
execution evidence. Approval uses `approve LINUX_BUNDLE --darwin DARWIN_BUNDLE`;
the two bundles must describe exactly the same archive. The annotated approval
binds both. R5.40 adds native LLDB source-debugger acceptance and selects the sixth Linux
routine job, release GDB, because DWARF serialization is now shared. Full
hosted parity is the separate R5.50 milestone scope.

R5.30 used a focused LLDB session to locate an Ada precondition failure in
variant emission and a native C frame-chain probe for the newly implemented
arm64 frame convention. No Linux GDB matrix is selected: Linux frame layout,
DWARF and instruction selection are unchanged. Nix CI remains deferred.

R5.40 uses the exact same archived source for the native LLDB policy and Linux
routine acceptance with GDB. Native debugger, dsymutil and dwarfdump versions
are checked against the Mac policy, with binary hashes retained. Source maps,
Mach-O UUIDs, dSYM identities and stripped behavior are required evidence.
The production scheduler/cache and broader resource dispositions remain as
recorded in R5.20; Nix CI stays deferred.

R5.50 selects and commits `policy.py milestone` before its closure candidate.
Its Linux gate runs complete suite, quality and native GDB in both compiler
modes, plus bindings and documents/tooling. Matching Mac schema-3 acceptance
runs compiler-host checks, the complete shared source/runtime/ABI corpus and
all three derived programs with native LLDB in both compiler modes. The
[parity guide](../compiler/tests/darwin/README.md) records exact coverage and
platform limits. The accepted revision keeps its milestone policy; routine
scope returns only in subsequent development. No local Linux containers,
production scheduler/cache changes or Nix CI are added.

## R6.10 environment acceptance

The Linux documents job additionally runs the pinned
[Cortex-M environment probes](../environments/cortex-m/README.md) and their
failure controls. Its exported `cortex-m` artifacts bind the live result to
the accepted archive. Missing tools or failed probes refuse acceptance.
This addition selects routine debugger-risk coverage for R6.10's debugger
controls and acceptance command/retention changes; it does not select the
R6.100 full milestone matrix. Darwin keeps native hosted/LLDB validation.

R6.20 retains compatible routine policies with release native GDB/LLDB because
it adds ABI/frame obligations and executable debugger assertions. The Linux
embedded path now also runs the layout/ABI controls; the original CPU,
peripheral and Renode-lock regression obligations remain mandatory. This is
not R6.100 milestone acceptance. Pure target/compiler checks use the Mac host
selector; embedded execution uses only the supported Linux runner.

R6.30 retains compatible routine debugger-risk policies: new instruction
selection, scratch use, alignment traps and verifier coverage affect the native
code/debug boundary. Full release GDB/LLDB accompanies complete release hosted
coverage and both Mac compiler-host modes. This is not R6.100 milestone scope.
The existing Linux embedded evidence export also includes the memory controls
and models, from the identical candidate archive. Nix CI remains deferred.

R6.40 selects routine debugger risk because packed extraction/selection,
verification and raw-carrier DWARF change. Its Linux documents job builds the
committed debug compiler before the mandatory combined embedded probe. The
probe exports compiler-generated native/Renode execution alongside independent
M0 C/assembly and model controls, with existing lock cleanup and ABI/memory
lanes preserved. These development or model results do not authorize promotion;
matching native archive acceptance and the guarded publication path still do.
