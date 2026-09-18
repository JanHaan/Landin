# Development and validation environments

`ROADMAP.md` R0.70 owns this document. Canonical hosting remains git.sr.ht;
GitHub is an automated mirror. Explicit committed-revision native acceptance
is the current Linux authority. Historical SourceHut gate results below keep
their original meaning.


Native Darwin acceptance uses `python3 scripts/ci/darwin.py accept COMMIT`
from the Mac with its pinned tool homes. Its verified bundle must match the
Linux bundle with compatible committed scope at approval (`--darwin DARWIN_BUNDLE`). Both source and
execution identities are retained; Linux acceptance alone cannot close the
Darwin item. See [native Mac acceptance](../environments/macos-arm64/README.md).

Embedded firmware and freestanding library consumers run on the supported
native Linux host through `environments/cortex-m/run.py`. They retain separate
QEMU and synthetic Renode evidence in the native export. Mac `--host` checks
compiler behavior for Cortex; they do not execute embedded workloads.

## Environments

| environment | role | status |
|---|---|---|
| native macOS arm64 | compiler-host development and exact-revision Darwin acceptance | working |
| Apple Container, `linux/amd64` under Rosetta | retained environment troubleshooting, outside the R5/R6 workflow | available |
| native Linux x86-64 runner | explicit exact-revision acceptance | working |
| builds.sr.ht | approved-main Pages publication and GitHub mirror | working |

The acceptance controller runs the committed `scripts/ci/policy.json` scope
against one committed archive. Routine promotion runs debug compiler-host
checks, the complete release suite and native identity, release quality,
bindings, and document/tooling checks. GDB runs only for substantial debugging
regression risk or a major milestone. Milestones restore the full matrix in
both compiler modes. Actual versions, binary hashes, commands, logs and
artifacts are retained; verified export, annotated approval and atomic main
promotion remain required. See
[`environments/native-ci/README.md`](../environments/native-ci/README.md) for
operations and [`docs/process.md`](process.md) for the workflow.

SourceHut's `.build.yml` publishes only current canonical main with its exact
validated approval tag, before accessing the licensed font checkout. Manual
`scripts/site.sh --publish` uses the same guard. `.builds/github-mirror.yml`
mirrors every canonical branch and tag. Neither manifest runs compiler tests;
the former automatic Nix manifest has been retired in favor of explicit supplemental native
Nix checks when the shell's inputs change.

Native macOS arm64 is a *development* loop at R0. It becomes a validated
target of its own at R5, with its own compiler build, platform tools and
debugger gate; a result produced here is not Linux evidence, and a Linux
container is never Darwin evidence.

R5.10 adds `./scripts/macos.sh --output .scratch/macos-validation-1` to capture
the native environment, assemble/link/run an arm64 smoke program, exercise
LLDB, build and run compiler-host checks in both modes, and sample
the inherited resource limits. The Apple tool policy, reproduction commands
and the historical full-harness option are documented in
[`environments/macos-arm64/README.md`](../environments/macos-arm64/README.md).
This established the compiler host at R5.10; R5.30/R5.40 subsequently added
Darwin lowering and source debugging. R5.51 selects compatible native policies
with full release hosted coverage for routine changes and full release GDB/LLDB
for debugger risk. Historical schema 3 remains both-mode milestone evidence.

QEMU full-system x86 is supplemental. It is not the daily loop and it is not
the Linux gate.

## Commands

The same commands run in every environment:

```sh
export LANDIN_GNAT_HOME=...      # the pinned GNAT for this host
export LANDIN_GPRBUILD_HOME=...  # the pinned GPRbuild for this host

./scripts/toolchain.sh
./scripts/clean.sh
./scripts/build.sh
./scripts/test.sh
```

On a Mac use `./scripts/dev-test.sh --host`, optionally with an exact
`--suite` or `--case`. Every selected check must pass. R5.10's unfiltered
missing-Linux-driver result is a historical environment observation, not a
current success rule.

Linux work during R5/R6 runs on the native Linux runner, using focused
development slots or committed acceptance. The container commands below are
retained for explicit environment troubleshooting; they are not part of the
Mac development or delivery loop:

```sh
./scripts/linux-loop.sh              # build and run the suite in linux/amd64
./scripts/linux-loop.sh sh -c '...'  # anything else, in the same environment
```

Artifact-writing checks need a guest filesystem with known name rules. The
shared virtiofs mount cannot prove the host volume's rules for absent output
names, so the collision guard can refuse distinct-looking output paths there.
For runtime and quality checks, copy the sources and place the executable and
its output directory on the container's own `/tmp` filesystem. R4.50's local
evidence in `ROADMAP.md` records the same requirement. Building the bootstrap
and comparing its recorded IR can still use the shared mount.

For the edit/test loop, two developer wrappers retain checksum-safe staleness
checking while avoiding a clean rebuild for every Ada edit:

```sh
./scripts/dev-build.sh
./scripts/dev-test.sh --suite='fixture execution'
./scripts/dev-test.sh --case='harness/filters select exact cases'
./scripts/dev-test.sh --fixture=runtime/variant-match-selects-tag

./scripts/dev-test.sh --host --suite=checking
python3 scripts/ci/controller.py dev --slot my-change -- ./scripts/dev-test.sh --fixture=runtime/variant-match-selects-tag
```

The selectors are exact, accept one selection at a time, and print `FILTERED`
in the transcript. They are fast feedback, not validation evidence. The
developer build asks the pinned GPRbuild for checksum-based Ada recompilation;
a changed source inventory or project file still makes it clean. The ordinary
`build.sh` and `test.sh` remain complete native Linux commands; `--host`
selects Mac compiler checks. Exact-revision acceptance owns approval. The
container command is retained troubleshooting, not a routine gate.

`LANDIN_BUILD_MODE` accepts only `debug` or `release`, before any build path
is used. Builds and tests hold an OS lock for their host tag and mode through
the entire command, including the build nested in `test.sh`. Different modes
and tags can run concurrently. Host cleanup waits for both modes; `clean.sh
--all` waits for every tag. The permanent lock files live in
`compiler/ada/.build-locks/`, outside the directories cleanup removes. Python's
standard-library `fcntl` supplies these locks on the supported macOS and Linux
hosts; the kernel releases them when the last using process exits.

The R2.20 session profile had enough timestamps to set the priority: clean
debug and release builds and whole-fixture runs occupied almost all measured
time, while all six measured container lifecycle phases rounded to zero
seconds and the complete one-shot startup stayed below one second. Keeping a
persistent container would add state without attacking the bottleneck. The
default Linux loop instead stopped calling `build.sh` before `test.sh`, since
`test.sh` already owns its build, and `test.sh --record-and-run` now records
and runs after one build when both are deliberately requested.

The loop asks for 4 GiB, and `LANDIN_LINUX_MEMORY` overrides it. That is not
a preference. A release build is `-O2` with `-gnatn`, so gprbuild's `-j0`
runs one `gnat1` per core doing cross-unit inlining, and in a default-sized
VM the kernel kills one of them:

```
gcc: fatal error: Killed signal terminated program gnat1
compilation terminated.
   compilation of landin-ir.adb failed
```

The unit named there is whichever was unlucky, not a unit with anything
wrong in it — the same source builds in release natively and on the x86-64
gate. This is written down because the message reads exactly like a compiler
defect in one file and cost an investigation once already.

`environments/linux-amd64/Containerfile` pins its base image by digest and
verifies both Ada toolchain archives against the checksums in
`environments/pins.sh` before unpacking either of them. It also installs the
versioned Debian stable `clang-19` package beside `libc6-dev` for R4.40 header
extraction and generated-adapter tests. The frontend is deliberately separate
from the pinned GNAT that builds `refine`: Clang supplies an external JSON AST,
not a product backend. Its package comes from the container's existing Debian
channel rather than a third download authority. R4.40 refreshed that one base
pin from Debian 12 to the official Debian 13 `trixie-20260824` image index so
the local loop and the native `debian/stable` gate select the same Clang
19.1.7 frontend and Debian 13 C-header baseline. GNAT and GPRbuild retain their
existing versions and archive checksums.

R4.60 adds GDB from that same Debian channel for `scripts/debug.sh`; the Linux
nix shell provides GDB from its locked package set. The native gate runs the
script in both compiler build modes. It checks source debugging of emitted
programs, which is separate from debugging the Ada compiler itself.

Native GDB cannot read registers through Rosetta's `ptrace` interface:
even `/bin/true` reports `Cannot PTRACE_GETREGS` and `Couldn't get CS register`.
The local image therefore also supplies `qemu-user`. Its `qemu-x86_64` GDB
remote stub supports the same breakpoint, register and stack operations
without Rosetta's ptrace path. This explicit local transport remains emulated
evidence; the native gate uses GDB directly and has no fallback.

`environments/pins.sh` remains the one place an independently downloaded Ada
toolchain version or checksum is written; `check.py` holds the recipe,
`compiler/ada/TOOLCHAIN.md`, the native acceptance policy and the nix shell to those same
values. Objects are kept
apart per host by `LANDIN_BUILD_TAG`, which `scripts/env.sh` defaults to
`os-arch`: one checkout is built by two hosts, and `.ali` files from both in
one directory is a build that fails confusingly.

`scripts/toolchain.sh` prints the host, the build mode and the exact compiler
and builder versions, and `build.sh` and `test.sh` print it before doing
anything. A captured log therefore names its own toolchain, which is what
R0.20 and R0.70 require of recorded evidence.

## Recorded results

| date | environment | toolchain | result |
|---|---|---|---|
| 2026-08-20 | macOS arm64 (Darwin 25.5.0, Apple M1 Pro) | GNAT 16.1.0, GPRbuild 26.0.0 (aarch64-apple-darwin) | clean build; debug and release |
| 2026-08-20 | Apple Container 1.2.2, `linux/amd64` under Rosetta, Linux 6.18.15 | GNAT 16.1.0, GPRbuild 26.0.0 (x86_64-pc-linux-gnu) | build from an empty build directory; debug |
| 2026-08-20 | builds.sr.ht `debian/stable`, Linux 6.12.94 x86-64 hardware, [job 1867022](https://builds.sr.ht/~sinnfrei/job/1867022) | GNAT 16.1.0, GPRbuild 26.0.0 (x86_64-pc-linux-gnu) | both archives verified against their checksums; clean build; debug and release; `check.py` clean; 47 seconds |

The gate job also prints `refine --identify`, so "no release version is
assigned" appears in the log of every run rather than only inside a test.

Case and check counts move as the suite grows, so they are not recorded here;
the run itself is the record, and `scripts/toolchain.sh` output heads every
one. What is recorded is that each environment built from clean and finished
with no failures, in the modes named.

The two transcripts are byte-identical, which is the property worth having:
the same cases in the same order with the same counts, on two hosts whose
toolchains were built for different architectures.

One caveat, recorded because it was seen: a single early run ended in an
unhandled exception and a traceback, and it has not reproduced in thirty
subsequent runs including four from a clean checkout. The exception was not
captured, so there is nothing to diagnose from. What changed as a result is
that `Landin.Testing.Run` now catches an exception from a case, reports it as
that case's failure, and keeps running the rest; a defect that used to take
the whole transcript with it now costs one line of it.

## A nix shell, for convenience

`flake.nix` provides `nix develop` with the pinned toolchain, contributed by
ZAZPRO. It installs the same archives the container recipe and the CI
manifest install, verified against the same checksums, because it reads
`environments/pins.sh` rather than naming a nixpkgs attribute — at the time
of writing nixpkgs carries GNAT 16.2.0 and GPRbuild 25.0.0, and the pin is
GNAT 16.1.0 with GPRbuild 26.0.0.

It sets `LANDIN_BUILD_TAG=nix`, so its object files stay out of the ones the
other environments leave in the same checkout. `python3` and `hut` come with
it, so `check.py` and `scripts/site.sh` work in that shell too. On Linux it
also selects `llvmPackages."19".clang` and `glibc.dev` from the package set
fixed by `flake.lock`, matching the Debian environments' Clang major without
following nixpkgs' default. The Darwin shell does not pretend that its SDK is a
Linux sysroot; run binding-generator tests through `scripts/linux-loop.sh`
there.

Its Linux behaviour is not settled by the local container, and that is not a
formality. The pinned gprbuild dies with a segmentation fault when argv[0]
names something other than the executable that is running — which is exactly
what nixpkgs' `makeWrapper` arranges — and under Rosetta the same store paths
ran without complaint. Evidence about this shell therefore comes from nix on
x86-64 hardware, running the same scripts as every other environment.

Measured since, and the reason that is not merely a preference: the local
loop cannot build this shell at all. Rosetta's `binfmt` handler replaces a
custom `argv[0]` with the interpreted binary's own path — a program exec'd as
`I-AM-ARGV0` reads its own path back out of `/proc/self/cmdline` — so every
nixpkgs wrapper built with `--inherit-argv0` loses the name it was given.
`auto-patchelf` is one of them: it runs under a bare interpreter that cannot
import `elftools`, `autoPatchelfHook` fails, and the pinned archives are
never patched. That is the paragraph above read from the other side — the
same sensitivity, met by the translation rather than by the toolchain — and
it is why this shell is answered for on hardware.

R1.80 needed one more thing of it, and only running programs found it. nixpkgs
wraps a compiler under the names `gcc`, `cc`, `g++` and `cpp`, and prefixes a
driver's name with a GNU triplet only when it is cross-compiling; `refine`
names its driver by triplet, so it reached the pinned archive's own
`x86_64-pc-linux-gnu-gcc` rather than the wrapper, and linked with a compiler
holding no libc — `cannot find Scrt1.o`. gprbuild was unaffected, because it
links through the wrapper, which is why the compiler built in that shell and
the programs it emitted did not. The flake now points every triplet-prefixed
driver the archive ships at the wrapper.

Both of those were found by hand. The former automatic Nix manifest checked
the shell at builds.sr.ht as a non-gate only when shell inputs changed.
That automatic manifest is now retired. Run the same `scripts/toolchain.sh`
and `scripts/test.sh` explicitly inside `nix develop` on native Linux after
shell-input changes; this remains supplemental environment validation.
Its first run settles both halves. The shell built on x86-64 nix with the
pinned GNAT 16.1.0 and GPRbuild 26.0.0, and the suite passed 133 cases with
no failures — `runtime fixtures execute` among them, which is the case that
reported `cannot find Scrt1.o` and the reason any of this was looked at.
That is a result for this shell and for nothing else: the table above is
still what the three environments say.

R4.30's static-library fixture also needs nixpkgs' separate static glibc
output. The Linux shell includes it as a library input so an explicit
`linker.library("m")` request can find `libm.a`. The shared glibc output
precedes the archive output so the driver's own `-lc` stays dynamic; the
shell check verifies that dependency on the static-library fixture.
[Job 1883411](https://builds.sr.ht/~sinnfrei/job/1883411) passes the complete
418-case suite with 12,425 checks and verifies the dynamic libc dependency.

It is a convenience for editing on a nix machine and carries no authority of
its own: the table above is unchanged by it, and a result produced in it is
not evidence for any of the three environments. `flake.lock` pins the nixpkgs
revision the shell is built from, but what it installs is decided by
`environments/pins.sh` rather than by that revision.

## What each environment is authority for

What the container does and does not settle is worth being exact about. It
runs a real Linux kernel and a real x86-64 userspace, so it catches everything
that depends on the operating system, the C library, the linker and the
64-bit-little-endian layout of the target: the whole suite passing there is
real evidence, and it is why the Linux checksums in
`compiler/ada/TOOLCHAIN.md` are now verified rather than transcribed. What it
does not do is execute x86-64 instructions on x86-64 hardware — Rosetta
translates them — so since R1.80 produces runnable executables, instruction-level and
timing-sensitive results from this loop are not authority. That distinction is
why the roadmap named the native gate before there was any code to run in it,
and it is why the gate now exists: from R1.80 onwards, `refine` emits
instructions. The original SourceHut gate ran them on their target hardware;
explicit native acceptance now preserves that requirement.

Hosting remains canonical git.sr.ht. SourceHut handles Pages and mirroring;
`scripts/ci/` owns explicit native acceptance and canonical approval validation.
The underlying compiler and test commands remain ordinary repository scripts.

R5.40 adds native LLDB acceptance through `scripts/debug.sh --target=darwin-arm64`
and the committed Mac policy. It validates emitted Landin programs with the
pinned Apple debugger, dsymutil and dwarfdump, retaining dSYM/UUID and source-map
matching evidence. The shared DWARF change selects routine Linux release GDB;
R5.50 adds full hosted parity and its dual-native milestone matrix in both
compiler modes. See [the native parity guide](../compiler/tests/darwin/README.md)
for the complete coverage and explicit physical-image limitation.

## Embedded environment probes

R6.10 selects native Debian 13 x86-64 for the pinned QEMU and Renode
[execution profile](../environments/cortex-m/README.md). The native Linux
acceptance documents job executes and retains these small C/assembly probes
from its exact archive. The Mac continues native compiler-host and Darwin
workload/LLDB validation; it does not run Linux containers for embedded tests.
QEMU owns CPU/startup evidence and Renode owns the explicit synthetic
peripheral lane. Neither is physical hardware fidelity or Landin backend proof.

R6.20 extends the mandatory QEMU lane with independently compiled C layouts
and C/assembly ABI witnesses, compared with the compiler's Cortex-M planner
and original synthetic-32 goldens. The existing verified export retains all
new artifacts beside R6.10's CPU and peripheral evidence. No embedded tools
run on the Mac; both native hosted acceptance policies retain their own work.

R6.30 adds M0 scalar atomic, barrier and nested interrupt controls and bounded
memory/cache models to this same Linux path. Native hosted fixtures execute
Landin atomics, generic evidence calls, SC fences and an escaping ordinary DMA
slice on each real host. Cacheless emulator results never stand in for cached
DMA maintenance. The containing dual-native archive binds all three evidence
classes; the memory [probe guide](../environments/cortex-m/README.md) records limits.

R6.40 adds compiler-generated packed image execution on both native hosts and
the Linux/Renode transport lane, including unnamed-encoding traps at all six
optimization/specialization profiles. Independent M0 C controls and literal
access traces remain separate from native Landin execution. The mandatory
documents job builds the archived compiler and exports these new lanes beside
all previous embedded evidence; it does not imply a Cortex-M compiler backend.

R6.50 extends the same pinned tool and evidence path with compiler-generated
Cortex-M0 execution of the inventoried shared runtime corpus and direct
Renode packed/byte/ordinary-slice DMA transactions. The external startup and
linker test harness does not enable Landin firmware entry or vectors. The
export retains objects, ELF/map/disassembly, literal ABI and device oracles,
helper identities and bounded image/stack observations; complete measured
firmware and Landin source debugging remain R6.100. Native GDB/LLDB coverage
still checks each hosted backend at the identical accepted revision.


R6.60's compiler-owned Cortex firmware lane runs only in the existing native
Linux embedded environment. It extends the same pinned tool inventory and
acceptance export with generated startup/vector/linker inputs and fresh-image
comparisons. The external backend harness, hosted Renode transport and
independent C/assembly probes remain separate evidence. See the
[firmware execution contract](../environments/cortex-m/README.md#r660-compiler-owned-firmware).
The Mac remains the native compiler-host/Darwin/LLDB lane; no local Linux
container or Nix CI path is introduced.

R6.80's generated-device lane is also mandatory in the native Linux documents
job, after the inherited R6.10–R6.70 probes. It exports separate `devices`
artifacts; vendor-input and regeneration checks run offline on both hosts.
The selected vendor is provenance, not a replacement QEMU board.

R6.90 appends the complete [derived driver](../compiler/tests/driver/DERIVATION.md)
to mandatory native Linux embedded execution. Its QEMU boot, separate Renode
protocol model and independent layout control retain their distinct evidence
roles. Native GDB/LLDB routine risk coverage validates the checking and linker
repairs; full Cortex source debugging and measured stack closure remain R6.100.

R6.100's mandatory `evidence.py` lane adds actual Cortex line/function GDB
sessions and complete-application resource scenarios to that Linux documents
job. It preserves the fixed board map and separate CPU/peripheral/control
identities, and recursively exports source/debug matching, ELF load accounting,
SP/paint/frame observations and bounded results. The dual-native milestone
policies retain both compiler modes and native GDB/LLDB; no Cortex debugger
session replaces a native one. See the [evidence contract](../environments/cortex-m/README.md#freestanding-evidence-r6100).
