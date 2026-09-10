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
`.build.yml` records the exact installed revision with `clang-19 --version`.

The Linux nix shell selects `llvmPackages."19".clang`, with `glibc.dev`, from
the package set fixed by `flake.lock`.  The Darwin shell deliberately gains no
Linux C frontend or sysroot: Apple headers are not evidence about the selected
Linux ABI, so use `scripts/linux-loop.sh` there.  No independent Clang archive
is downloaded and no new checksum authority is introduced; each environment
uses its existing package-set provenance.

## External source debugger

R4.60's `scripts/debug.sh` uses GDB and GNU binutils to inspect and run the
emitted Linux x86-64 executable. They are external validation tools, not
bootstrap dependencies. The Debian gate and local Linux image install `gdb`
from their existing package channel; the Linux nix shell takes it from
`flake.lock`'s package set. The script uses GDB from the configured PATH
(which can select the GDB bundled in the pinned toolchain), or `LANDIN_GDB`
when explicitly set, and records that executable's version. The native Linux
gate runs the sessions with both debug and release
builds of `refine`, separately from the emitted program's optimization policy.

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

The shared library also compiles `src/platform/landin_file_identity.c` with
the pinned toolchain's host C compiler and the host's system headers. This
small `stat` adapter keeps host-specific structure layout out of Ada; it is
not a Landin backend and does not inspect target layout. Its switches are
`-std=c11 -Wall -Wextra -Werror -pedantic -fno-common -O2 -g` in both modes:
C warnings are errors too. `scripts/build.sh` includes C sources and headers
in the same source-checksum manifest as Ada, so editing the adapter cannot
reuse stale objects. The adapter uses only the host C runtime, already a
GNAT runtime dependency; it adds no separately acquired library.

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

On macOS the last command ends with the fixture-execution case failing, by
design: runtime fixtures need `x86_64-pc-linux-gnu-gcc`, and the harness
fails rather than skips on a host that cannot finish the target. Only that
case red is the expected Mac result; `scripts/linux-loop.sh` runs them.

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
