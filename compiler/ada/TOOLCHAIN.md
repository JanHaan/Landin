# Pinned toolchain

`ROADMAP.md` R0.20 requires one canonical Ada toolchain, recorded exactly,
reproduced from a clean environment, and named without a provider.

## Canonical release

| part | pin |
|---|---|
| Ada language version | Ada 2022 (`-gnat2022`) |
| compiler | GNAT (GCC) 16.1.0, FSF build `gnat-16.1.0-1` |
| builder | GPRbuild 26.0.0, build `gprbuild-26.0.0-1` |
| runtime profile | full standard runtime; no restricted or zero-footprint profile |
| bootstrap dependencies | none beyond the GNAT runtime |

The bootstrap uses no Alire authority, no AUnit, no GNATCOLL and no SPARK.
Alire's published FSF archives are one convenient way to obtain the pinned
compiler; the pin is the compiler version, not the distributor.

## External binding-generator frontend

R4.40's `bindings/generate.py` is a separate source tool, not part of the Ada
bootstrap and not a C or LLVM product backend.  The Linux environments provide
Clang 19.1.7 as the external C11 header frontend and compiler for its generated
C adapters.  The selected target is always `x86_64-pc-linux-gnu`; on the
gate and local container, `clang-19` comes from the existing `debian/stable`
package channel and `libc6-dev` supplies the matching headers and root
sysroot.  The versioned package name prevents a moving default Clang major;
`scripts/ci/policy.json` requires `clang-19 --version`; native acceptance
retains the exact installed revision and binary hash.

The Linux nix shell selects `llvmPackages."19".clang`, with `glibc.dev`, from
the package set fixed by `flake.lock`.  The Darwin shell deliberately gains no
Linux C frontend or sysroot: Apple headers are not evidence about the selected
Linux ABI. Use native Linux development slots for that validation.  No independent Clang archive
is downloaded and no new checksum authority is introduced; each environment
uses its existing package-set provenance.

## Native macOS environment

R5.10's `scripts/macos.sh` validates the native arm64 bootstrap in both modes.
GNAT and GPRbuild retain the canonical pins above. The Apple environment is
recorded in `environments/macos-arm64/policy.json`:

| part | tested pin or bound |
|---|---|
| macOS major | `26` |
| macOS SDK | `26.5` (build `25F70`) |
| Apple Clang | `Apple clang version 21.0.0 (clang-2100.1.1.101)` |
| Apple assembler (`as --version`) | `Apple clang version 21.0.0 (clang-2100.1.1.101)` |
| Apple linker (`ld -version_details`) | `1267` |
| LLDB | `lldb-2100.0.17.203` |

The command records exact host/tool identities and checks native assembly,
linking, execution and an LLDB stop/resume before building and running
`refine`. The SDK is selected through `xcrun --sdk macosx` and passed as
`SDKROOT` to the builds. These are host validation tools, not new bootstrap
libraries. See `environments/macos-arm64/README.md` for the commands, expected
historical Linux runtime-case refusal and bounded resource probes. A Linux container
cannot supply this evidence. R5.40 supplies emitted Darwin source debugging;
R5.50 requires matching full hosted parity acceptance in both compiler modes.

## External source debugger

R4.60's `scripts/debug.sh` uses GDB and GNU binutils to inspect and run the
emitted Linux x86-64 executable. They are external validation tools, not
bootstrap dependencies. The Debian gate and local Linux image install `gdb`
from their existing package channel; the Linux nix shell takes it from
`flake.lock`'s package set. The script uses GDB from the configured PATH
(which can select the GDB bundled in the pinned toolchain), or `LANDIN_GDB`
when explicitly set, and records that executable's version. The native Linux
gate runs the sessions with release `refine` for routine debugger risk and both compiler modes at
milestones, separately from the emitted program's optimization policy.

### Archives and checksums

The releases below are the ones the pins name. Every checksum here has been
verified against the archive it names, before that archive was unpacked: the
macOS rows on the development machine, the Linux rows inside the pinned
linux/amd64 image built by `environments/linux-amd64/Containerfile`, which
runs `sha256sum -c` before it unpacks anything. A host may build the same
versions from source instead.

| platform | archive | sha256 |
|---|---|---|
| macOS arm64 | `gnat-aarch64-darwin-16.1.0-1.tar.gz` | `657cf254323eb91f79768918e8bd8887d6da7ac6056732a38f21e2848267da18` |
| macOS arm64 | `gprbuild-aarch64-darwin-26.0.0-1.tar.gz` | `6bf7d80c8a9702d851c5b992d7c72a07a9dbf13e8de9947b80927ea2667b6be8` |
| Linux x86-64 | `gnat-x86_64-linux-16.1.0-1.tar.gz` | `9f74f58a827a2ad40dd84c72a413e75ea52888e0d8f7e252fba4d26762402703` |
| Linux x86-64 | `gprbuild-x86_64-linux-26.0.0-1.tar.gz` | `e3f27f2515ec04d963f6badade6595993b1c091ba15d1919a7c75aad1b7ed49b` |

## Warning and style policy

Set once, in `compiler/ada/landin_common.gpr`, and inherited by every project:

| switch | why |
|---|---|
| `-gnat2022` | the language version the bootstrap targets |
| `-gnatwa` | every optional warning is on |
| `-gnatwe` | warnings are errors; a compiler that tolerates its own warnings teaches nobody |
| `-gnatyy` | standard style checks, including the 79-column limit |
| `-gnatW8` | sources are UTF-8 |
| `-fno-common` | no tentative definitions |

Debug mode adds `-O0 -g -gnata -gnatVa -fstack-check`: assertions, contracts
and validity checks are on while the compiler is being written. Release mode
uses `-O2 -g -gnatn` and keeps debug information.

The shared library also compiles `src/platform/landin_file_identity.c` and
`src/platform/landin_tool_process.c` with the pinned toolchain's host C compiler
and the host's system headers. These small POSIX adapters keep host-specific
structures and wait/signal constants out of Ada; they do not inspect Landin
target layout. Their switches are
`-std=c11 -Wall -Wextra -Werror -pedantic -fno-common -O2 -g` in both modes:
C warnings are errors too. `scripts/build.sh` includes C sources and headers
in the same source-checksum manifest as Ada, so editing an adapter cannot
reuse stale objects. The adapters use only the host C runtime, already a
GNAT runtime dependency; it adds no separately acquired library.

Before comparing that manifest, `scripts/build_config.py` asks the pinned
GPRconfig to select the native Ada/C configuration. It records the configuration
hash and the selected C driver's absolute path, binary hash and complete version
response. Both project builds receive that same configuration snapshot, stored
beside the per-mode build lock so cleaning objects cannot remove it. Changes to
that identity force a clean rebuild in both ordinary and checksum modes;
failed configuration or version probes preserve the previous successful build.
An unchanged snapshot keeps its content and timestamp. This identifies the
configured C driver, which need not be the bare `gcc` printed by the toolchain
log. The wrappers own this native configuration and reject `--config` and
`--autoconf` overrides; direct GPRbuild experimentation is outside their manifest
contract. Configuration and version probes each have a ten-second limit.

`Ada 2022` contracts (`Pre`, `Post`, `Dynamic_Predicate`) are load-bearing in
debug builds, and debug is the default mode for that reason. Release mode
drops those checks, so a rule that a package has to keep is written into its
body as well: `Landin.Source.Position_Of` raises `Compiler_Defect` on an
offset past the end whether assertions are on or not. Both modes are green,
and a rule that only holds in one of them is not a rule the package keeps.

## Reproducing

```sh
# Point at the pinned toolchain however this host provides it.
export LANDIN_GNAT_HOME=/path/to/gnat-16.1.0-1
export LANDIN_GPRBUILD_HOME=/path/to/gprbuild-26.0.0-1

./scripts/toolchain.sh    # record exactly what is about to be used
./scripts/clean.sh        # remove every artefact
./scripts/build.sh        # build refine and the test program
./scripts/test.sh         # build, then run the test program
```

On macOS replace the last command with `./scripts/dev-test.sh --host`.
Every selected case must pass. Run Linux workload/GDB checks on the native
Linux runner and Darwin workload/LLDB checks natively; the unfiltered Linux
harness's missing-tool refusal is not a successful current Mac test run.

Every command prints the toolchain identification first, so a captured log
names its own compiler.

## Keeping the records together

`environments/pins.sh` is the one place a version or a checksum is written.
The container recipe, the CI manifest and the nix shell all read it, and
`check.py` compares this file against it on a full run — including that
`flake.nix` reads the pins rather than naming a version of its own. Several
files naming a compiler version is several chances to be wrong, and the one
that drifts is the one nobody reads.

## Newer local toolchains

A newer GNAT may be used locally while the canonical one stays green. It is
not evidence: a result that only reproduces on an unpinned compiler is not a
result. Changing the pin is a recorded decision, not a side effect of an
upgrade.

R5.40 additionally pins dsymutil and dwarfdump to `Apple LLVM version 21.0.0`
in the native Mac policy. Their actual paths and binary hashes are retained
with LLDB sessions and Mach-O debug artifacts.

## External embedded environment tools

R6.10 separately pins Arm EABI GCC, binutils, GDB, QEMU and Renode in
`environments/cortex-m/tools.lock.json`. The
[profile guide](../../environments/cortex-m/README.md) gives exact versions,
options and native Debian reproduction. They compile only small environment
controls, are not Ada bootstrap dependencies and do not enable a Landin
Cortex-M backend.


## Cortex-M emitted-code runtime

R6.50's external execution harness uses the existing pinned Arm tools in
[`environments/cortex-m/tools.lock.json`](../../environments/cortex-m/tools.lock.json).
Generated arithmetic may require the GCC 14.2.1 `thumb/v6-m/nofp/libgcc.a`
multilib. This is a target runtime dependency, not an Ada bootstrap dependency
or a C backend. Each linked test records its archive hash, requested helpers,
map members, ELF attributes and unresolved-symbol check. The
[target guide](../../docs/targets.md#runtime-helper-boundary) records provenance,
calling conventions and the R6.60/R6.70 freestanding handoff. Cortex executable
linking through `refine` remains refused.
