# Development and validation environments

`ROADMAP.md` R0.70 owns this document. It records which environment produces
which kind of evidence, and it deliberately names no CI provider: hosting is
not selected yet, and every command below is an ordinary shell command.

## The three environments

| environment | role | status |
|---|---|---|
| native macOS arm64 | the development loop while writing the bootstrap | working |
| Apple Container, `linux/amd64` under Rosetta | the local Linux loop | working |
| builds.sr.ht, `debian/stable` on x86-64 hardware | the authoritative Linux gate | working |

The gate runs from `.build.yml` on every push. It installs the pinned
toolchain from `environments/pins.sh`, builds from clean, runs the suite in
debug and in release, runs `check.py`, and prints `refine --identify` so that
the no-version-claim rule is visible in the log rather than only in a test.

Last, and only from `main`, it renders the reading copies and publishes them
to pages.sr.ht. That step produces no evidence and carries no authority: it
runs after every check above has passed, so a red gate cannot put a page up,
and a build with no secrets — a mailed patch has none — never reaches it. It
is there because a page that moves only when somebody remembers to run
`scripts/site.sh --publish` is a page that drifts from the document it reads.

Native macOS arm64 is a *development* loop at R0. It becomes a validated
target of its own at R5, with its own compiler build, platform tools and
debugger gate; a result produced here is not Linux evidence, and a Linux
container is never Darwin evidence.

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

The local Linux loop runs the very same scripts inside the pinned image:

```sh
./scripts/linux-loop.sh              # build and run the suite in linux/amd64
./scripts/linux-loop.sh sh -c '...'  # anything else, in the same environment
```

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
wrong in it -- the same source builds in release natively and on the x86-64
gate. This is written down because the message reads exactly like a compiler
defect in one file and cost an investigation once already.

`environments/linux-amd64/Containerfile` pins its base image by digest and
verifies both toolchain archives against the checksums in
`environments/pins.sh` before unpacking either of them. That file is the one
place a version or a checksum is written; `check.py` holds the recipe,
`compiler/ada/TOOLCHAIN.md`, the CI manifest and the nix shell to the same
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
it, so `check.py` and `scripts/site.sh` work in that shell too.

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

Both of those were found by hand, which is why `.builds/nix.yml` now checks
this shell at builds.sr.ht: it is the only environment that can. It is a
second manifest and deliberately not part of the gate — a red run there says
a convenience broke, not that Landin did — and it runs the ordinary
`scripts/toolchain.sh` and `scripts/test.sh` inside `nix develop`. It also
runs only when a file this shell is made of changed, because the pinned
archives are 501 MB and builds.sr.ht keeps nothing between builds, so the
alternative is paying that on every push to check a convenience.

Its first run settles both halves. The shell built on x86-64 nix with the
pinned GNAT 16.1.0 and GPRbuild 26.0.0, and the suite passed 133 cases with
no failures — `runtime fixtures execute` among them, which is the case that
reported `cannot find Scrt1.o` and the reason any of this was looked at.
That is a result for this shell and for nothing else: the table above is
still what the three environments say.

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
translates them — so once R1.80 emits machine code, instruction-level and
timing-sensitive results from this loop are not authority. That distinction is
why the roadmap named the native gate before there was any code to run in it,
and it is why the gate now exists: from R1.80 onwards, `refine` emits
instructions, and only the sourcehut job runs them on the hardware they were
emitted for.

Hosting is therefore no longer an open question: the repository lives on
git.sr.ht and its CI is builds.sr.ht. `scripts/` stays provider-neutral —
nothing in it names a provider — and `.build.yml` is the one file that does,
which is what makes it replaceable.
