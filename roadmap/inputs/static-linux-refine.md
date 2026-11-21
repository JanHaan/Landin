# A static Linux `refine`: what R23.40 found

*The finding of R23.40, placed under `roadmap/inputs/` for R23.50, which
builds on it. It is not edited once R23.50 is complete.*

2026-11-21, over `origin/main` `d6c0b762f`, on epycmicro (NixOS, AMD EPYC
7302) with the pinned GNAT 16.1.0 and GPRbuild 26.0.0 from the flake's
development shell. The arm64 builds ran in the flake's `aarch64-linux`
shell under QEMU user emulation, through the host's binfmt registration.

## The answer

A static Linux `refine` can be built today, with the pinned toolchain and
no source change, by linking it statically against **glibc** rather than
musl. It runs on Alpine, on NixOS and in a root file system with no C
library at all, because a static executable asks for no loader. Building a
musl `refine` would need a GNAT toolchain nobody publishes, and buys
nothing a static glibc build does not, beyond a licence point.

## What `refine` needs from the system

- **The GNAT runtime is already static.** The release `refine` links
  `libgnat` and `libgnarl` from their archives; the dynamic archive's
  `NEEDED` entries are glibc's alone: `libc.so.6`, `libpthread.so.0`,
  `libdl.so.2`, `librt.so.1` and the loader.
- **Tasking** is one protected object (`Landin.Serials`) and
  `Ada.Real_Time`'s clock, so `libgnarl` and its POSIX threads are linked.
- **Exceptions** are GCC's table-driven unwinding, which links statically
  with the rest; the test program's exception cases pass in the static build.
- **The C adapters** under `compiler/ada/src/platform/` call POSIX:
  `posix_spawn` and its attributes, `pthread_sigmask`, `getrusage`,
  `getgroups`, and two glibc extensions, `mallinfo2` (the heap figure of
  the resource report) and `posix_spawn_file_actions_addfchdir_np`. Neither
  matters to a static glibc link. musl has the second and not the first.
- **Nothing calls the name service**, `dlopen` or `iconv`: a static glibc
  link warns for each such call it finds ("requires at runtime the shared
  libraries from the glibc version used for linking"), and the links of
  `refine`, the four split commands and the test program print none.

## What was built and run

The build is the ordinary one with the link switched:

```sh
LANDIN_BUILD_MODE=release LANDIN_BUILD_VARIANT=static \
  ./scripts/build.sh -q -R -largs -static -L"$GLIBC_STATIC/lib"
```

`$GLIBC_STATIC` is the flake's `glibc.static`, needed only because the nix
compiler wrapper names glibc's shared directory alone; on an Ubuntu runner
`libc6-dev` already holds `libc.a` where GCC looks. `-static-pie` in place
of `-static` builds too, keeping the address randomization the present
archives have.

| what | Linux x86-64 | Linux arm64 |
| --- | --- | --- |
| `refine`, four split commands, test program linked statically | yes, `-static` and `-static-pie` | yes, `-static`, in 44 minutes emulated |
| whole release test program, unfiltered | passed with `-static` and with `-static-pie`: 1279 cases, 0 failed, 261437 checks, 42 to 49 minutes each | not completed: under emulation 16 suites, 619 cases, passed, and all 290 positive fixtures were emitted, but runtime fixture execution had run 16 of 970 fixtures, all passing, when it was stopped; a native arm64 runner is where it belongs |
| packaged by `scripts/package.sh`, run in Alpine 3.24's minirootfs (no `/lib64`, no glibc), PATH and HOME only | `refine version`, `refine run` of the first program, output identical; each split command's `--help` | the same, in the arm64 minirootfs |
| `--link=libc` runtime fixtures linked against Alpine's musl and run | `clock-system-libc`, `environment-variables-libc`, `thread-creation-and-join-order-writes-libc`, `thread-storage-under-libc`, `posix-accounts-libc`: each its expected status 42, and the one with an expected output printed it | the same five, each status 42 |

Alpine's `gcc` package is the linker driver there: `refine` finds it as
`gcc`, the last name it tries, so `apk add gcc musl-dev` is all a user
adds, as the README already says of NixOS.

The cost, measured on the same tree:

| | dynamic | static |
| --- | --- | --- |
| archive (`package.sh`, debug information split off) | 18.75 MB | 19.44 MB (+3.7 %) |
| `refine`'s `.text` | 23.58 MB | 24.35 MB |
| `refine version`, 50 runs | 1.50 s | 1.21 s |
| `refine compile --emit=asm` of the first program, 10 runs | 2.51 s | 2.45 s |

The arm64 static archive is 17.88 MB, against 16.84 MB for 0.2.11's
dynamic one.

## What it costs to keep

- **The release environment** needs nothing new: the release jobs already
  run on `ubuntu-24.04` and `ubuntu-24.04-arm` with the pinned GNAT, and
  their `libc6-dev` holds `libc.a`. The build gains `-largs -static-pie`
  in release mode.
- **glibc's fixes reach users only through a release.** A static `refine`
  keeps the glibc it was linked with, Ubuntu 24.04's 2.39, until the next
  release. `refine` is a compiler that reads source, not a network service.
- **A future call into the name service would break silently on hosts
  without that glibc.** The gate should fail a static link that prints
  glibc's runtime warning, so the first such call is refused where it is
  made.
- **glibc is LGPL-2.1-or-later.** A statically linked program is
  distributed so that its user can relink it against a modified glibc;
  `refine`'s complete source and build are public under MIT or Apache-2.0,
  which meets that, and the archive should carry glibc's licence and say
  which glibc it holds. The GNAT runtime is linked statically today already,
  under the GCC Runtime Library Exception.
- **The kernel floor** is the one the linked glibc was configured for,
  as it is for the dynamic archive on the host's own glibc.

## Why not musl

- **No pinned GNAT targets musl.** The Alire FSF builds the toolchain pin
  names publish, for `gnat-16.1.0-1`, glibc-hosted Linux archives only,
  besides Darwin, Windows and bare-metal ones. Alpine packages GNAT
  (`gcc-gnat` 15.2.0 in 3.24), which is not the pinned 16.1.0, and no
  GPRbuild. A musl `refine` needs GCC 16.1 with Ada built for
  `x86_64-linux-musl` and `aarch64-linux-musl`, GPRbuild configured for
  it, both published somewhere the pins can check, and rebuilt at every
  GNAT update: days of toolchain work, and a toolchain the project would
  then maintain alone.
- **Linking the glibc-built GNAT runtime against musl's `libc.a`** might
  link, but the runtime's C structures (`pthread_mutex_t`, `sigset_t`,
  `struct stat`) are laid out for glibc's headers, so it would be unsound
  even where it passed. Not tried.
- **`mallinfo2` has no musl counterpart**: the resource report's heap
  figure would need another source or disappear on musl.
- **What musl would give** is a permissive licence for the C library and
  no name-service caveat. Its allocator is slower than glibc's, which a
  compiler that allocates as much as `refine` would feel; that was not
  measured.

## Found on the way

The flake's `aarch64-linux` development shell and its `refine` package did
not build: GPRbuild's arm64 Linux archive links its tools other than
`gprbuild` itself, `gprconfig` among them, against `libgmp.so.10`, which the
archives' patching did not supply. Nothing in the gate builds the flake on
arm64 (`nix flake check --all-systems` only evaluates), so it went unseen.
R23.40 adds `gmp` to the patched archives' libraries.

## For R23.50

Publish a `-static-pie` glibc archive for x86-64 and arm64. Whether it
replaces the glibc archives under their names or sits beside them is the
maintainer's choice, asked as a question; this finding argues for replacing
them, since the static archive runs everywhere the dynamic one does, and
one archive per architecture leaves `install.sh`, the Homebrew formula and
the flake's `refine-bin` taking the same asset, `install.sh` no longer
refusing musl and NixOS hosts. The test program has never run on musl, so the five fixtures
above are a sample, not evidence that every `--link=libc` program links
against musl as against glibc.
