# Native macOS compiler environment

`ROADMAP.md` R5.10 owns this environment. It validates the Ada bootstrap on
native Apple Silicon. Linux acceptance remains in `environments/native-ci/`;
Darwin Landin lowering and source debugging belong to R5.30 and R5.40.

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
Landin still emits Linux x86-64 assembly at this item.

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
guarantee. Remaining flow, folding and IR storage repairs stay in R5.20.

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
