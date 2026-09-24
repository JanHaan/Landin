# Development and validation

`ROADMAP.md` owns the work left on this process. The loop below is the
one that runs now. Everything after it describes the exact-revision native
acceptance that approved every revision through 0.2.0 and was retired with
SourceHut: nothing submits it, `scripts/ci/` is gone, and no revision is
accepted. It is kept as the record of how those approvals were chosen and
what they cost.

## The loop that runs now

| stage | command | what it says |
|---|---|---|
| edit/test loop | `./scripts/dev-test.sh` with one exact `--suite`, `--case` or `--fixture` selector | checksum-safe feedback; the transcript says `FILTERED` |
| Mac compiler host | `./scripts/dev-test.sh --host` | compiler checks only; every selected case passes, and no Linux workload is emitted or run |
| before pushing | `./scripts/test.sh` on Linux, with `LANDIN_TEST_JOBS` to split the corpus across workers, and `python3 check.py` | the complete suite and every document invariant |
| after touching the harness | `./scripts/parallel-equivalence.sh --suite='fixture execution'` | a wider run reaches the same verdicts, byte for byte |
| every push and pull request | `.github/workflows/gate.yml` | the documents, and the complete corpus on Linux x86-64 in debug mode |
| Darwin and LLDB | the suite and `scripts/debug.sh` run by hand on a Mac | nothing automates them, so a Darwin claim needs a Mac run behind it |

Choose the smallest test that can expose the changed behavior first, broaden
only for another affected subsystem, and run the complete suite once before
pushing. The gate is a safety net rather than a verdict: it is Linux only and
debug only, with no Darwin, no Cortex-M execution, no debugger, no bindings
and no release mode, and `ROADMAP.md` schedules the rest. Documentation
changes still receive the full `check.py`.

## Historical: choosing acceptance scope

The maintainer's decision for the retired acceptance was: full
gates only at major milestones, Linux work on native Linux, debugger checks
only for substantial regression risk, and Nix CI deferred. The rest of this
section is that policy as it stood at 0.2.0.

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

Do not run Linux containers or Linux workload matrices on the Mac during
development. In-process compiler units may still inspect target-specific data;
that is host-compiler coverage, not Linux execution. `--host` excludes the two
native target-workload cases and requires every remaining case to pass. The
IR comparison that exposed the first native Mac run's Ada argument-order defect
remains included.

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
a reason to run debugger matrices. An Ada evaluation-order repair that changed
no debug encoding, location or unwind code and passed the unchanged IR golden
used routine scope without GDB; a change to debugger selection and
verification used routine scope with full release GDB and LLDB.

The judgments made under these definitions ran as follows. Noreturn and panic
control flow, frames and source-site identity needed debugger-risk coverage,
and so did the generated device fixtures' debugger-controlled boot and stack
assertions. A new debugger-visible type — the several-atom pointer union, with
GDB and LLDB presentation checks — selected routine scope with debugger
coverage; it closed no phase and added no target, ABI convention or
instruction selection, so milestone scope was not warranted. Committing a
check that reads and verifies debug metadata on all three targets forced
debugger coverage even though no emission changed, because selecting or
verifying debugger evidence is itself debugger risk; the size of the run did
not make it a milestone. The derived prototype coverage register changed no
debug metadata and selected or verified no debugger evidence, so it ran at
routine scope without debugger coverage: every result it records came from a
job routine scope runs anyway, and running the prototypes according to the
applicability matrix is not a parity claim.

Milestone scope was selected for a phase or parity closure: complete hosted
parity, the freestanding evidence that closed the Cortex-M0 work, and the
first roadmap's endpoint. The endpoint changed no compiler code, which is why
the items before it that closed no phase ran routine; a phase closure is
answered by milestone scope whatever the code change, because a routine
approval cannot later be cited as a milestone result. Its debugger coverage
arrived with the full matrix rather than with a risk.

Before a major milestone, select and commit milestone scope with the closure
candidate. A routine approval cannot be cited as a full milestone result.
Subsequent development returns to routine scope.

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
10.5 in CI failure-path tests and 2.1 in rendering. The complete first native
Mac harness took 2522.2 seconds in debug and 911.3 in release, largely compiling
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

An evaluation compared one and two workers on native Linux using the same
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
successor that `ROADMAP.md`'s register names. Integrating bounded workers
requires shared cancellation, timeout ownership and aggregate resource tests;
artifact sharing requires an acceptance-schema change for producer identities.
The quality command's second compilation deliberately checks determinism and
must stay fresh. Cache hits must be labelled as reuse, and native execution
must still run. This closes the evaluation without weakening those oracles or
introducing nested worker pools into the routine gate.

## Nix later

The current `flake.nix` supplies development shells and two `refine`
packages, one built from the checkout and one fetched from a release. It does
not define the project's test derivations. More `nix develop` invocations
alone would not remove repeated compilation.

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

Native Darwin lowering added `scripts/ci/darwin.py accept COMMIT` to ordinary
promotion. It ran the committed native Mac policy and exported source, tools,
artifacts and execution evidence. Approval used `approve LINUX_BUNDLE --darwin
DARWIN_BUNDLE`; the two bundles had to describe exactly the same archive, and
the annotated approval bound both. macOS source debugging added native LLDB
acceptance and selected the sixth Linux routine job, release GDB, because DWARF
serialization became shared. Full hosted parity was a separate milestone scope.

The Darwin lowering work used a focused LLDB session to locate an Ada
precondition failure in variant emission and a native C frame-chain probe for
the newly implemented arm64 frame convention. No Linux GDB matrix was selected:
Linux frame layout, DWARF and instruction selection were unchanged. Nix CI
remained deferred.

macOS source debugging used the exact same archived source for the native LLDB
policy and Linux routine acceptance with GDB. Native debugger, dsymutil and
dwarfdump versions were checked against the Mac policy, with binary hashes
retained. Source maps, Mach-O UUIDs, dSYM identities and stripped behavior were
required evidence. The production scheduler/cache and broader resource
dispositions stayed as recorded; Nix CI stayed deferred.

Hosted parity selected and committed `policy.py milestone` before its closure
candidate. Its Linux gate ran the complete suite, quality and native GDB in both
compiler modes, plus bindings and documents/tooling. Matching Mac schema-3
acceptance ran compiler-host checks, the complete shared source/runtime/ABI
corpus and all three derived programs with native LLDB in both compiler modes.
The [parity guide](../compiler/tests/darwin/README.md) records exact coverage
and platform limits. The accepted revision kept its milestone policy; routine
scope returned only in subsequent development. No local Linux containers,
production scheduler/cache changes or Nix CI were added.

## Historical Cortex-M environment acceptance

The Linux documents job additionally ran the pinned
[Cortex-M environment probes](../environments/cortex-m/README.md) and their
failure controls. Its exported `cortex-m` artifacts bound the live result to
the accepted archive. Missing tools or failed probes refused acceptance.
Adding the environment selected routine debugger-risk coverage for its debugger
controls and acceptance command/retention changes, not the full milestone
matrix. Darwin kept native hosted/LLDB validation.

The Cortex-M0 layout and ABI work kept compatible routine policies with release
native GDB/LLDB because it added ABI/frame obligations and executable debugger
assertions. The Linux embedded path also ran the layout/ABI controls; the
original CPU, peripheral and Renode-lock regression obligations stayed
mandatory. Pure target/compiler checks used the Mac host selector; embedded
execution used only the supported Linux runner.

The concurrency memory model kept compatible routine debugger-risk policies:
new instruction selection, scratch use, alignment traps and verifier coverage
affect the native code/debug boundary. Full release GDB/LLDB accompanied
complete release hosted coverage and both Mac compiler-host modes. The Linux
embedded evidence export also included the memory controls and models, from
the identical candidate archive. Nix CI remained deferred.

Packed images selected routine debugger risk because packed
extraction/selection, verification and raw-carrier DWARF changed. The Linux
documents job built the committed debug compiler before the mandatory combined
embedded probe. The probe exported compiler-generated native/Renode execution
alongside independent M0 C/assembly and model controls, with existing lock
cleanup and ABI/memory lanes preserved. These development or model results did
not authorize promotion; matching native archive acceptance and the guarded
publication path did.

Generated Cortex-M0 code ran through the supported native Linux runner and the
existing Cortex probe/export path. The complete corpus ran under an external
startup/linker test harness. Its physical-limit and source-restriction records
remain distinct from execution passes. This changed neither native
Linux/Darwin acceptance nor the firmware publication path; the identical
archive still needed both native bindings before approval and promotion.

Compiler-owned firmware added mandatory execution to that same embedded
probe/export command. Its fresh-image comparisons, QEMU boot/exception runs,
Renode device traces and independent C/assembly controls remain
distinguishable from the old external backend harness. Startup, frame and
exception changes selected routine acceptance **with debugger risk**: full
release Linux GDB and Darwin LLDB, debug compiler-host checks and complete
release hosted execution. Both policies were committed before the closure
candidate, and all embedded artifacts bound to that archive.

The derived driver kept routine debugger-risk scope because it exposed a
checking control-flow defect and a firmware ELF load-address defect. Both native
policies had to match; the mandatory embedded lane included every inherited
probe plus `environments/cortex-m/driver.py`. Its complete program and protocol
ran on native Linux, while Mac development used `--host`. The exact accepted
archive bound the source, model premises, literal oracles, firmware/linker
artifacts and bounded resource observations.

The freestanding evidence selected compatible **milestone** policies on both
native hosts before the closure candidate. They kept debug/release
compiler-host, hosted execution, quality and native debugger coverage plus every
inherited embedded lane. The mandatory embedded entry also invoked
`evidence.py`: complete-driver resource scenarios, Cortex source sessions,
source/debug selection refusals and independent stack/exception controls.
Cortex remote GDB is distinct from native Linux GDB and native Darwin LLDB. An
isolated development function call did not replace execution through this
mandatory entry or exact-revision acceptance, and failed or interrupted
resource runs remained failed evidence. That closure needed both native
archives and all of its embedded gates to pass; delivery promoted precisely
that shared revision, without a later bookkeeping commit.
