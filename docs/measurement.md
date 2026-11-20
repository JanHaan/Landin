# Measuring generated code

This is the measurement contract for generated code: what the gate measures
of the code `refine` emits, where, and how a change is held to it. It is a
maintained reference. The choices it makes are decisions in `spec.md`'s
register under the toolchain, and the data is under
`compiler/tests/measure/`. `scripts/measure.py` measures and compares; its
`--help` names every command used below.

## What is measured

A **configuration** is a target, one of its CPU feature levels, a firmware
profile where the target has them, an optimization profile (`--optimize`
`none`, `size` or `speed`) and a specialization policy (`--specialize`
`off`, `auto` or `all`). Every supported target is measured at every level
`refine targets --json` gives it, with the features each level assumes, and
at all nine profiles. Nothing in the data lists the levels: a level the
compiler adds is measured from the commit that adds it, and fails the
comparison as unrecorded until its baselines and its runner-table row exist.

A **workload** is a program with an oracle. A run whose oracle fails is a
failed measurement, never a figure.

| set | workloads | runs on |
|---|---|---|
| hosted | the five Benchmark Game ports of [`docs/benchmarks.md`](benchmarks.md); `measure-fibre-switches` and `measure-thread-switches`, two fibres taking turns through a chain of calls, on the main stack and on a started thread's, which pay the prologue's stack check on every call | every hosted target |
| firmware | `sieve-of-eratosthenes`, `merge-sort`, `binary-search` and `cmp-siphash-vectors`, which the firmware lanes already execute; and firmware forms of fannkuch-redux and mandelbrot, new fixtures, each fitting the constrained 32 KiB reference | every firmware target and level |
| counterpart | prototype 5's firmware counterpart, which fits the constrained reference's 32 KiB at `size` and `speed` since D1567 | `cortex-m0`, on the 256 KiB description its lane uses (D1036) |

`compiler/tests/measure/workloads.json` names each workload, its fixture and
the set it is in. An existing fixture keeps the oracle it has: its status,
and its output where it has one. A new one brings its own, held by the
test program like any fixture's.

A firmware workload's size is measured on the image `refine` itself links,
with the entry `compiler/tests/measure/entry.ldn` that runs the fixture's
`main` and keeps its status: at the target's reference profile, the one a
program importing no description gets, except on Xtensa, whose reference
gives initialized data no load address at boot, so its workloads link
against the ESP32's and the ESP32-S3's own descriptions, the boards'. Its
time is measured on the image the timing lane runs: an emulator lane's own
profile, or a board's RAM layout.

A hosted workload's **timing run** uses arguments large enough to be timed,
named in the same file. Its output is not the fixture's, so the output's
digest is recorded with the baseline and must be the same for every
configuration of every target; the thread program's output names no thread
order. A firmware program takes no arguments and prints nothing: its oracle
is its status, and the new firmware fixtures also leave a full-width
checksum in a named word that the emulator and the probe read after the run.

## Size

Size is the byte count of each allocated section of the linked image, read
from the image by `scripts/measure.py`'s own ELF and Mach-O readers. Debug
sections, symbol and string tables, `.comment` and notes are not allocated
and not counted. For a firmware image the build report's `flash_used`, the
load segments' extent, is kept beside the sections. The report's routine
counters count emission sites, not bytes, and are not compared.

The linker is part of the image. Each size baseline records its
**environment**, the linker's own version line and the pinned environment's
name. When a runner's image moves Darwin's `ld` or FreeBSD's toolchain, a
measurement that still matches its baseline passes and names the new
environment; one that differs fails, saying the environment moved and that
`record --from-run` takes the new figures, exactly as a compiler change
would. No growth passes in the window between the two.

Emission is deterministic, so size has no tolerance. A section that differs
from the base commit's baseline in either direction fails, unless the
candidate's own baseline files record exactly the measured figure for that
key. Changing those files is the declaration, and their diff names each key
it changes; the comparison prints those keys grouped by target, level and
profile with their base and new totals, and the commit message says why. A
smaller image is declared the same way, so a later change cannot grow back
into it unnoticed. The base is the merge base with `main` for a branch and
the first parent for a commit on `main`.

`scripts/measure.py record --from-run RUN` writes the figures a gate run
measured, read from its artifacts, into the candidate's files, so a change
seen on Darwin or FreeBSD is recorded from a Linux checkout. `--key` limits
it to named keys.

Configurations whose images are byte-identical are measured once, for size
and for time; the others cite it by the image's digest. A wall pair whose
candidate image is byte for byte the base's is recorded as identical and
not timed: it can only measure the runner, which once judged an image
against itself 2.04 times slower on a single sample. Every timed image runs
once untimed before its samples, since macOS vets a newly linked program
on its first launch.

## Time

How time is measured depends on where the code runs. Each way is a
**class**, and the runner table gives every target/level pair its classes.

| class | where | the figure | compared with |
|---|---|---|---|
| `wall` | a native hosted runner | the median wall time of the timing run over several fresh copies of each executable, each copied to a new path before it runs, since placement alone moved a run by up to 50% | the base commit's own images, built in the same job by the base's compiler and run interleaved with the candidate's |
| `cycles` | a board on the rig, in a RAM run | the core's counter, started by the probe and read by the program itself just before `main` and just after it returns; the probe stops the program at the return with a breakpoint and reads the two words; the lower median of three runs, and a count past 2³¹ fails rather than risk a wrap | the committed baseline of the same board, clock and RAM placement, within the port's tolerance from its noise study |
| `instructions` | an emulator | the instructions the program's own code executed, counted by a QEMU plugin of the repository's own over the image's address range | the committed baseline of the same emulator |
| `size-only` | an emulator whose count is not the program's | nothing: the target records size alone | — |

A `wall` figure is compared in pairs because the hosted runners are not one
machine: GitHub gives a job one of several processor models and moves its
image weekly, so a committed figure would rarely meet a run on its own
processor. The ratio of candidate to base in one job, on one processor,
is what the tolerance judges. The committed `wall` figures record the
processor model and image beside the median, a trend and not a threshold.

The `cycles` counters, each enabled by the probe before the run:

| board | core | counter |
|---|---|---|
| RP2040 | Cortex-M0+ | the chip's 1 µs timer, `TIMERAWL`, at the 12 MHz crystal, twelve cycles a count; the M0+ has no cycle counter |
| RP2350 Arm | Cortex-M33 | DWT `CYCCNT`, after `DEMCR.TRCENA` and `CYCCNTENA` |
| STM32H753 | Cortex-M7 | DWT `CYCCNT`, likewise; it wraps after 9 s at 480 MHz, so a run stays shorter |
| RP2350 Hazard3 | RISC-V | `mcycle`/`mcycleh`, with `mcountinhibit` cleared |
| ESP32-C3 | RISC-V | the vendor counter `mpccr`, after `mpcer` and `mpcmr` select cycles |
| ESP32-C5 | RISC-V | `mcycle`, with `mcountinhibit` cleared, as ESP-IDF reads it on the C5 |
| ESP32, ESP32-S3 | Xtensa LX6, LX7 | `CCOUNT` |

A `cycles` key includes the board, its clock and where the code ran, since
the same image costs a different count from another RAM. The helper moves
the RP chips to their 12 MHz crystal, as each board's application does,
and reads and decodes the others' clocks. The counter is read by the
program rather than the probe because the ESP32-C3's `mpccr` runs while
the hart is halted, so a probe's span carried 130,000 to 190,000 cycles of
its own against a program's 4,600 to 19,000. The study in
`compiler/tests/measure/noise/cycles.json` found the ESP32, ESP32-S3,
ESP32-C3 and Hazard3 exact, the M33 within 0.05%, the C5 within 0.31% and
the RP2040 within one count; the M7's first run after a load is up to 5%
high and the runs after it equal, which the lower median of three takes.
A board's images are identical when their loaded segments and entry are,
whatever the ELF file's debugging information says.

An `instructions` count is deterministic where the emulator runs the
program alone: QEMU's user mode for RV64, given an environment of
`QEMU_CPU` alone since the runtime's start walks every variable, and an
address space QEMU reserves itself (`-R`), since a heap the host's kernel
placed differently once in about fifty runs took another 7,200
instructions of 159 million, and the
Cortex-M lanes' machines. The study in
`compiler/tests/measure/noise/instructions.json` counted every hosted
workload on RV64, the thread program among them, and every firmware
workload on each Cortex-M machine five times or more, with no spread, and
the Cortex-M counts are the same with `-icount` and without. A count is
taken at the fixture's own arguments: it is exact at any size, and the
timing arguments would cost hours of emulation. Espressif's QEMU, which
runs the RV32 and Xtensa lanes, is built without plugins, so those levels
are timed on their boards and record size alone under emulation. FreeBSD
arm64 runs as a whole system under emulation, its kernel and timer in any
count, and records size alone.

The plugin, `compiler/tests/measure/qemu/count.c`, declares the dozen
calls it makes rather than including QEMU's header, which needs glib's and
which the Cortex-M lanes' Debian QEMU does not ship; `scripts/measure_count.py`
builds it for the plugin interface the running QEMU accepts, the version
the two in use differ by, and its `check-header` holds the declarations to
a QEMU's own header.

Each class's tolerance comes from a noise study recorded on its runner
before the gate enforces it: the same tree measured repeatedly, its spread
kept in `compiler/tests/measure/noise/`, and the tolerance set above it.
Until a class has its study its comparison reports and does not fail. A
`wall` pair past its tolerance is timed again with three times the samples
and judged on that, since the second A/A run of x86-64 drew one pair at
1.085 with no change to the emitted code, and one already past twice its
tolerance after a single sample of each side is judged on that sample, so
a grossly slower candidate is a verdict rather than a job that runs out
its time; the tolerances, in
`compiler/tests/measure/noise/wall.json`, are 10% on `ubuntu-24.04`, 6% on
`ubuntu-24.04-arm` and 40% on `macos-26`, whose virtual M1 spread to
1.198. The
`instructions` class's study found no spread, so it is held exactly, as
size is.

The same counter answers a contributor's question about one routine.
`scripts/measure.py count` (or `scripts/measure_count.py count`) runs a
firmware or RV64 program under its
lane's emulator and prints the instructions executed in all, and between
two symbols with `--from` and `--to`. The Cortex-M corpus's `--program`
option (`environments/cortex-m/backend_corpus.py`), which runs any `.ldn`
file or module directory, prints the same count for each program it runs,
which is what choosing between implementations by their cost on a
firmware target needs.

## Runners

| target | level | classes | runner |
|---|---|---|---|
| linux-x86-64 | x86-64-v1, v2, v3 | `wall` | `ubuntu-24.04` |
| linux-x86-64 | x86-64-v4 | `limit`: no hosted runner is promised AVX-512 | — |
| freebsd-x86-64 | x86-64-v1, v2, v3 | `wall`, in the lane's KVM guest | `ubuntu-24.04` |
| freebsd-x86-64 | x86-64-v4 | `limit`, as Linux's | — |
| linux-arm64 | armv8-a, armv8.1-a | `wall` | `ubuntu-24.04-arm` |
| darwin-arm64 | armv8-a, armv8.1-a | `wall` | `macos-26` |
| freebsd-arm64 | armv8-a, armv8.1-a | `size-only`: the guest is emulated | — |
| linux-rv64 | every level | `instructions`, QEMU user mode | `ubuntu-24.04` |
| cortex-m0 | armv6-m | `instructions` on the micro:bit machine; `cycles` on the RP2040 | `ubuntu-24.04`; the rig |
| cortex-m0 | armv7-m | `instructions` on MPS2 AN385 | `ubuntu-24.04` |
| cortex-m0 | armv7e-m | `instructions` on MPS2 AN500; `cycles` on the STM32H753 | `ubuntu-24.04`; the rig |
| cortex-m0 | armv8-m.main | `instructions` on MPS2 AN505; `cycles` on the RP2350 | `ubuntu-24.04`; the rig |
| rv32 | rv32imc | `cycles` on the ESP32-C3; `size-only` under Espressif's QEMU | the rig |
| rv32 | rv32imac | `cycles` on the RP2350's Hazard3 and the ESP32-C5; `size-only` under emulation | the rig |
| xtensa | xtensa-esp32 | `cycles` on the ESP32 | the rig |
| xtensa | xtensa-esp32s3 | `cycles` on the ESP32-S3 | the rig |

`compiler/tests/measure/runners.json` holds this table as data, and
`scripts/measure.py runners` checks it against every target/level pair the
compiler gives: a pair with no row fails. A runner that lacks a feature its
row's level needs fails the timing job rather than reclassifying the level.
A `limit` row has a register row with its activation; it is never a skipped
measurement or a lower level measured in its place.

## Baselines

Baselines are committed JSON under `compiler/tests/measure/baselines/`, one
file per target and class, keyed by level, firmware profile where there is
one, optimization profile and workload, with the environment or runner class
and, for time, the processor model, image, sample count and spread. A
candidate is compared with its base commit's baselines, never its own.

## Showing that the gate holds

The exit evidence is three runs of each class's comparison: one of an
unchanged tree, which passes, and one each of two demonstration branches,
which fail. Each branch is cut from `main` once the measurement and its
baselines are there, so a difference fails as undeclared rather than
unrecorded; it is never promoted, and has
one commit in the target-neutral lowering: one adds to every routine a
block reached only when a volatile load reads a value it never holds,
making every image larger; the other adds at each routine's entry a loop
whose count is a volatile load, longer than any class's tolerance, making
every workload slower. Neither can be removed by the optimizer, and the
comparison itself shows each present in every profile's image. The runs are named in the item's `Done:`
paragraph.

## Cost

Size runs on every push, in jobs that already have the target's linker:
the Linux, RV64 and firmware targets in one job inside the pinned
environment, Darwin on its native runner and FreeBSD beside its lanes.
The instruction counts, exact and a few minutes each, run on every push
too: RV64's in the same job, Cortex-M's in the `cortex-m` job, which has
the lanes' tools. Wall time and board cycles run on the weekly schedule
and on a dispatch, `scope=boards` included, in timing jobs beside the
boards, unless a passed dispatch on the branch already timed the same key
over the same base (D1649). The pilot over the whole matrix, recorded in
`compiler/tests/measure/pilot.json`, gives each job's minutes, the jobs it
adds against the limit it ran under, 20 concurrent jobs and 5 macOS (60
and 15 since 2026-11-20), and
each class's noise, before any tolerance is enforced.

## Reports

The stage report says where a program's compile time goes among its
sources. The stack report's format becomes `landin-stack-report-2`, in
which each frame quantity has the build report's name: `frame_bytes` is
what a routine's prologue reserves and `stack_bytes` its whole stack.
Version 1's `frame_bytes` was the whole stack, so a consumer that reads it
by name must ask for the version.

## What the measurements found

The ranked list of each backend's largest measured costs, from which the
register allocation work takes its scope, is
[`compiler/tests/measure/findings.md`](../compiler/tests/measure/findings.md).
A cost is attributed by measuring the same workload with and without the
construct that pays it, at the same configuration. Its answers are the
ones the roadmap's rows ask of this measurement: the atom `match` table,
the heap's lock flag, float selection on Cortex-M, short `u64` routines on
armv6-m, the library's erased tables and formatting, the counterpart's
flash against 32 KiB, list growth through `resize`, any cost attributable
to assembly's fixed memory effect, and x86-64's two-instruction reach of a
thread instance.
