# Native macOS compiler environment

> **The acceptance half is retired.** `scripts/ci/darwin.py accept` no longer
> runs; the Darwin evidence it produced stands for the revisions it named. The
> environment itself -- the pinned tool homes, the Mac `--host` workflow and
> LLDB -- is current and still how this machine is used. See
> [`MOVING.md`](../../MOVING.md).

`ROADMAP.md` R5.10 records the bootstrap environment; R5.51 owns the current
acceptance handoff. The reproduction sections below preserve R5.10
environment validation, while the exact-revision section describes current
acceptance. It validates the Ada bootstrap on
native Apple Silicon. Linux acceptance remains in `environments/native-ci/`;
R5.30 adds exact-revision native lowering acceptance here; R5.40 adds required
native LLDB source debugging. R5.50 extends the committed path to full hosted
parity in both compiler modes.

## Reproduce

Make the Ada archives pinned in `environments/pins.sh` available, with Apple's
Command Line Tools or Xcode selected through `xcode-select` / `DEVELOPER_DIR`.
No package manager or CI provider is required. Python 3 uses only its standard
library. The command rejects a translated process, a different Ada version,
or Apple tools outside `policy.json` before building.

```sh
export LANDIN_GNAT_HOME=/path/to/gnat-16.1.0-1
export LANDIN_GPRBUILD_HOME=/path/to/gprbuild-26.0.0-1
./scripts/macos.sh --output .scratch/macos-validation-1
```

Use a new output directory on each run. Its basename must contain only lower
case letters, digits, hyphens, underscores or dots, with no consecutive dots.
The run builds clean debug and release trees under a fresh `macos-` build tag,
using the ordinary wrappers and their locks. It retains each build's selected
GPR configuration and checksum manifest. `SDKROOT` selects the recorded SDK
for those builds. Existing development objects are not removed.

`--mode debug` or `--mode release` validates one mode and records that scope
in the summary. Separate mode runs may run concurrently with different output
directories; both modes supply R5.10's evidence.

The command records the OS version/build, kernel, translation flag, selected
developer directory and SDK path/version/build, tool paths, binary hashes and
full version responses. GNAT/GPRbuild versions come from `environments/pins.sh`.
The Apple SDK and tool identities come from `policy.json`; macOS is bounded to
major 26. This is an exact tested SDK/tool set, not a claim that every tool
shipped with macOS 26 is compatible. A new tool set needs an explicit policy
change and a new native run. Installation paths are not pins.

The native smoke test assembles arm64 source with Apple's assembler, links it
through Apple Clang with the selected SDK, executes it, and uses LLDB to stop
at `main` and continue to exit zero. Each built `refine` must be an arm64
Mach-O executable and run `--identify`. This checks the platform tools;
At R5.10 Landin emitted Linux x86-64 only; R5.30 added native Darwin lowering.

## Harness oracle

Both modes now run `scripts/test.sh --host`. This explicitly excludes the
two native target-workload emission/execution cases while retaining
compiler units, diagnostics and the complete recorded IR comparison.
The transcript must identify `HOST-ONLY` scope, all cases must pass, and the
exit must be zero. An incomplete, filtered or failed transcript is refused.

`--full-harness` preserves R5.10's original validation: the unfiltered harness
attempts Linux runtime fixtures and must fail only because the Linux driver
is absent. Every failure in that case is checked against the missing-driver
diagnostic or ABI C-link refusal. This historical scope recompiles large
derivatives for every profile before refusing Linux linking; it is not the
daily Mac loop. Each mode retains a two-hour wall limit and captured logs.

This exception belongs only to R5.10's bootstrap environment evidence. It does
not turn the underlying harness green or satisfy hosted Darwin parity.

## Resource characterization

The readiness intake's CHK-FLOW-1, CHK-FE-2 and CHK-FE-3 are sampled separately
with deterministic generated source: forward type aliases, forward module
constant dependencies, and sixteen nested flow branches over increasing local
declaration counts. Flow has both a scalar control and a 64-field record
variant: the widest record sizes every flow-state row, so the latter exercises
both dimensions of the declaration-by-field matrix. Each shape runs at chain
lengths or local counts of 8, 256, 1024 and 4096 in
both compiler modes. Eight is a required successful control. Larger samples
record acceptance, a language diagnostic, reported resource exhaustion, raw
exception, CPU limit, other signal, wall timeout or unexpected failure separately.

Each probe inherits the recorded stack limit without raising it, has a
20-second CPU limit and a 30-second wall limit, and disables core dumps.
Probe inputs and both output streams are retained, including for killed
processes. These finite samples characterize this host and source shape;
they do not establish a universal exhaustion threshold or recoverability
guarantee. R5.20 assessed the remaining flow, folding and IR storage limits; R5.51
R551-06 records their successor owner and activation condition.

## Evidence

The output contains `commands.json` (argv, working directory, elapsed time,
return status and timeout), per-command stdout/stderr, generated source,
build configuration/manifests, and `summary.json` with source, tool and artifact
hashes and the harness/probe results. A failed run retains its logs and a
failed summary. Keep this directory when moving or sharing evidence; it is
not an annotated acceptance tag and does not promote or publish a revision.

`python3 scripts/tests/test_macos_environment.py` exercises the evidence
oracle on any supported Python host, including false passes and timeouts.
The full `python3 check.py` also runs those checks and holds the recorded Apple
tool versions to the policy.

## Recorded native result

[`validation.json`](validation.json) records R5.10's original completed native
debug and release runs, before the host-only workflow, on macOS 26.6.2,
build 25G83, with the policy's SDK and tools.
Both clean builds and both LLDB smoke sessions passed. Each unfiltered harness
reported 712 cases, 711 passed and 195410 checks, with only the expected Linux
runtime-driver refusal. The two runs used the same verified inventory of 4221
compiler, fixture, core and build-tool inputs. Full logs, generated probe
sources and per-run hash manifests remain at the recorded evidence paths.

The native runs exposed and repaired an Ada argument-evaluation ordering
dependency in concrete evidence traversal capture. Separate address-building
calls now retain the existing Linux IR order. The unchanged golden matches in
both compiler modes on macOS and Linux; the Linux traversal execution fixture
also passes all four profiles in both modes on the guest filesystem.

| final sample at 4096 | debug | release |
|---|---|---|
| forward type aliases | accepted | accepted |
| forward module values | accepted | accepted |
| scalar flow, sixteen branches | accepted | accepted |
| flow with a 64-field record, sixteen branches | reported exhaustion, exit 71 | reported exhaustion, exit 71 |

All smaller samples passed. Both runs inherited a soft stack limit of 8372224
bytes and a hard limit of 67092480 bytes. The CPU/wall caps bound the experiment;
these observations do not define a maximum supported input or guarantee
recovery for other exhausted programs. `ROADMAP.md` R5.20 owns the remaining
resource work and the broader target-contract audit.


## Native exact-revision acceptance

The environment loop above is development evidence. The committed
`acceptance.json` schema 4 records routine/milestone scope, the debugger choice
and explicit host, hosted-workload and debugger modes. Both scopes require debug
and release compiler-host checks. Routine runs all applicable shared source
verdicts, the full hosted runtime/ABI profile matrix, complete derived programs
and generated bindings/archive execution with the release compiler. Debugger
risk adds full release LLDB, including all derivatives and every R5.40
object/dSYM, DWARF and Mach-O identity check. Milestones run all coverage in both
compiler modes. Select both native policies with `scripts/ci/policy.py` before
committing; a substituted or incompatible Linux scope fails verification. It uses the same pinned GNAT, GPRbuild, Apple tools and
SDK policy. [The parity guide](../../compiler/tests/darwin/README.md) lists
coverage, native adapters and the explicitly retained large-image loader limit.

From a clean checkout with the pinned homes exported:

```sh
python3 scripts/ci/darwin.py accept HEAD
python3 scripts/ci/darwin.py verify ~/.local/state/landin/darwin/exports/RUN_ID
python3 scripts/ci/controller.py accept HEAD
python3 scripts/ci/controller.py approve LINUX_BUNDLE --darwin DARWIN_BUNDLE
python3 scripts/ci/controller.py promote FULL_COMMIT
```

The Mac worker runs from the exact committed archive in a fresh source tree.
It retains source archive/inventory, tool paths/hashes/versions, OS/SDK identity,
selected GPR configuration and build manifest, the actual compiler binary,
commands, assembly, Mach-O objects/executables, generated bindings and execution
results. Source inventory is checked before and after; tool hashes are checked
again after execution. A separate verified export omits only the unpacked build
cache, retaining the complete source archive. Failed runs remain failed and
require a new run; this initial Mac path has no resume/cache mechanism.
Timeouts terminate the owned process session, including compiler-created tool
groups. R5.20's broader resource and scheduler/cache dispositions remain intact.

An approval for a source inventory containing `acceptance.json` requires a
matching Darwin bundle in addition to the Linux acceptance bundle. Historical
R5.50 schema 3 requires the committed eight-job Linux milestone matrix; schema 4
requires matching Linux scope and debugger selection. Commit, tree,
archive and source hashes must agree. The annotated approval carries the Darwin
record and policy hashes; promotion and Pages validate that binding. Linux-only
approvals cannot close or publish such a revision. Historical approvals retain
their original scope. Schema-2 acceptance adds R5.40 source debugging; the
original schema-1 lowering bundles keep their historical meaning. Schema 3
requires both compiler modes and full coverage; old scopes cannot be relabelled
as parity evidence.

When debugging is selected, the command retains the shared selected R4.60 source fixture and all
thirteen scalar representations under none/off, size/auto and size/all. It
keeps assembly, objects, executables, dSYMs, maps, UUID/identity results, unwind
dumps and complete native LLDB sessions. Source inventories and compiler/tool
identities are checked against the containing archive and native environment.
Filtered or missing profiles, failed sessions and substituted artifacts refuse
acceptance. See [target debugging contracts](../../docs/targets.md#native-source-debugging).

R6.30 uses routine debugger-risk scope for its new verified memory opcode and
native scalar/LL-SC lowering. Full release parity executes the memory, pthread
and ordinary-slice fixtures in all six specialization profiles; source verdicts
include ordering, width, permission and unsupported-target refusals. Release
LLDB remains mandatory. Embedded M0/peripheral/model evidence stays on Linux
and is bound by the same dual-native approval.

R6.40 packed images use the native Darwin arm64 backend. The shared release
corpus covers raw copies, checked extraction and insertion, register-image
intrinsics, ordinary-slice completion observation, generic/evidence dispatch
and independent ABI controls. Packed DWARF exposes a single unsigned `raw`
member and its true size; named bitfield/array presentation is not claimed.
The routine debugger-risk policy retains full release LLDB scope. Embedded
QEMU/Renode probes continue to run only on the supported native Linux host.

R6.100 selects milestone scope: debug/release compiler-host, complete hosted
parity and native LLDB. The Linux archive independently retains all inherited
embedded lanes plus Cortex source-debugging and complete firmware/resource
evidence. `--debug=lines` is a Cortex interface; native Darwin keeps its full
DWARF/dSYM/UUID contract. Matching successful native archives are required for
approval of the identical revision. The Mac does not emulate this Linux lane.
