# Landin roadmap

## Authority and scope

`spec.md` decides the language and `tour.md` explains it. This file is the
sole authority for open work: its phases, lanes, dependencies and gates. A
work item cannot overrule the specification. A semantic change updates
`tour.md` or `spec.md`, the fixtures that pin it and this file together.

The first roadmap, R0 to R7, built the bootstrap compiler to a
feature-complete pre-v1 slice, last at commit `335b0814`. The second, R8 to
R16, took it to an editor, more hosted targets, the microcontrollers people
buy, a library split along the capability line, concurrency and the start
of measured optimization; its text is in the history, last at commit
`d27308107`. Its R16 continues here. Its R15,
Windows, was never started; its three items are retired and its content is
rewritten as R21 for today's library, second Io and threads.

This roadmap makes the language smaller and the tools around it ordinary:
the project's own process first, then `refine` split into commands, a
breaking simplification of the language, a review of the standard library,
Windows, and the library a newcomer expects to find. Optimization runs
beside all of it.

Outside it, and staying outside: a build tool and package manager, the
Companion tool and ecosystem family's; self-hosting and separate
compilation, Scale and self-hosting's; a browser or WebAssembly target;
dates and times in the library; and every release or version decision, each
of which needs an explicit decision of its own. Landin does not assume
SemVer.

The stated 32 TB hosted endpoint remains an unverified goal; what it
measures and what would prove it are still open, and nothing here claims it.

Work item, register and question identities are cited in this file, in the
register and question files, in the inputs under `roadmap/inputs/`, and
nowhere else, save the status pointer
`README.md` and `handoff.md` carry. `check.py` refuses such a citation
anywhere else. `docs/capabilities.md` is the capability inventory and
`README.md` summarises it; `Done:` paragraphs record evidence, not a second
summary.

## Mechanics

**Identities.** Phases run from R15, where the second roadmap's numbering
left off, in identity order without a gap, and each ends in one gate. A
phase retired before it started, as R15 was, keeps only its heading,
marked `(retired)`, and a paragraph saying why: no item and no gate.
Items are `R19.10`, `R19.20` and so on, spaced in tens; work found between
two items takes a unit identity, the earlier item's number plus one, so 21
after 20. Identities are never reused or renumbered, the earlier
roadmaps' included. Every item has
one status line, one dependency line and its exit evidence:

```text
Status: planned
Depends on: R17.10

```

A status is `planned`, `active`, `blocked` or `complete`; `blocked` carries
one `Blocked because:` line, which no other status keeps. Any item whose
dependencies are complete may be `active`, several at once, and a complete
item's dependencies are complete. There are no dates, estimates or
versions here.

**Lanes.** Work runs in the lanes the execution order declares. The serial
lane is one item at a time. Its item is the first in execution order that
is `active`, or `planned` with its dependencies complete, a blocked item
passed over, and `README.md` and `handoff.md` name it and no other: as
current work while it is active, as the next item while it is planned. An
item of a serial phase whose dependencies are complete may start beside
it, as R17.50, which depends on nothing, ran beside R17.10 to R17.30; it
is `active` while it runs, and the pointers keep naming the serial lane's
item. The site's front page shows that item first and every other active
item beside it. The continuous lane holds R16's continuous items. R16's
basis is R16.10, in the serial lane; the continuous items take the next
ten after the last basis item and count up by one from R16.20. Each depends only
on the basis, may run beside anything, and is never the
next item; any number of them may be active. A phase that declares a
breaking window (R19, then R20) keeps its serial items on one integration
branch and promotes them once, at its gate; a continuous item lands on
main meanwhile and the branch takes it.

```text
Execution order: R17, R16.10, R18, R19, R20, R21, R22
Continuous: R16.20 onward
```

**Gates.** A phase's gate cannot be claimed until all its items have their
exit evidence. R16's gate is different: once its basis is complete it is a
standing invariant every later push must keep, not a milestone. An item is
complete when its exit evidence exists: the complete gate passed on the
completing commit and, for a claim about a host the gate does not run, a
named run recorded in the item. It then gets a short `Done:` paragraph; the
reasoning goes in the commits and in `spec.md`'s register of decisions.

**Authority.** An item's agent may push its candidate, promote it to main
once its gate has passed, and remove its worktrees and branches, without
asking again. An item opts out with one line, `Promotion: maintainer`,
which returns that step to the maintainer; `check.py` refuses any other
spelling. Releases and versions are never covered.

**The register.** A row is only for what outlives the item that met it
and waits for a trigger. A finding the item fixes is named in its commit
message and its `Done:` paragraph, not filed. Each row is one file,
`roadmap/register/`, its identity the file name: a front matter
block of `key: value` lines, then a body of a few lines at most saying
what stands and what would complete it. The keys are `kind` (`limit`,
`watch`, `defect`, `proposal` or `usability`), `family`, `status` (`open`,
or `scheduled` with the items that take it on), `opened` (a date),
`activation`, and `effort` and `impact`, each `S`, `M` or `L`. `check.py`
validates them. `roadmap/register.md` is generated from the files and is
never edited.

A row moved from the second roadmap keeps its identity, SR-n, R551-n or
another. A new row takes the next SR number from the allocation script
R17.10 provides; two branches that take the same number collide as an
add/add conflict on the file, which is the detection, and the integrator
renumbers the later one. The script is `scripts/register_next.py`;
`--file` writes the row with its keys to fill in. A retired or completed
row has no file: it is deleted in the commit that says why, and the
history keeps it. There is no departures list, and the second roadmap's
retired rows were not migrated.

A moved row's `opened` is the date it first appeared, which the migration
script takes from the history.

An item's agent may delete a row its change fixed, or one that duplicates
another, naming the evidence in the commit. Retiring a row as not worth
doing, and anything a row asks the maintainer to choose, is a question and
waits for the maintainer.

The register holds at most 60 open rows; a scheduled row does not count,
and a row may be scheduled only on an item whose text names it. A row that has stood through ten
completed items without being scheduled is reviewed at the next item's
close: scheduled, retired, or kept with one sentence saying why, a body
line beginning `Kept:`, which restarts its count. At the cap,
an item cannot close until it has brought the count under it.

For a moved row the ten completed items count from the exchange, since the
sweep before it has just reviewed every live row; for a new row, from its
filing.

**Questions.** A decision only the maintainer can take is a question, one
file under `roadmap/questions/`, Q-1 onward, never a register row and never
a question asked only in a report or a chat. The file begins with the
question as its heading, `# Q-7 — ...?`, and the line `Asked by R17.50 on
2026-11-17.`, then what the maintainer needs to decide it, and four
paragraphs each opening with its label in bold: `Options:`, a list
numbered from 1 with at least two; `Recommendation:`; `Default until
answered:`, which says what the default is in words and not by its option
number alone; and `What waits on the answer:`, the work it holds up or
`nothing`. The asker carries on with the default and with everything the
answer cannot change. A question closes with one paragraph,
`**Answer (YYYY-MM-DD, the maintainer):**`, and, where the answer is a
rule, a decision in `spec.md`; a decision reopened is a new question.
`check.py` refuses a file without these parts, a question cited that has
no file, and a question's identity outside the roadmap's files, and the
generated `roadmap/register.md` lists the open ones with their defaults
and what waits, the table a report to the maintainer quotes. A decision an
item's text gives to its own run, as R18.10 answers the command
inventory's questions, becomes questions when that item starts.

The gate is a safety net rather than a verdict: green says a tree passed
there, and no item claims more.

## R15 — Windows (retired)

Never started. Its three items are retired unused; their content is R21's,
and nothing cites them. This phase has no gate; it is the one
phase the gate rule exempts.

## R16 — Optimization

Measured first, and then only where the measurement says. R16.10 is the
basis and runs in the serial lane right after R17; R16.20 onward are
continuous.

### R16.10 — Measure generated code

Status: complete
Depends on: R17

Record the size and time of the same workloads for every supported target,
each CPU feature level `Landin.Targets.Levels` gives it (`refine targets`
lists them), and all nine combinations of `--optimize=none|size|speed` and
`--specialize=off|auto|all`, and hold every later change to them in the gate.
The level list is read from the compiler, never written out here.

The first deliverable is the measurement contract, reviewed before any
baseline is recorded:

- **Workloads.** A hosted set, the five ports of `docs/benchmarks.md` and a
  fibre and a thread program, which pay the prologue's stack check; and a
  firmware set that fits the 32 KiB reference, with prototype 5's
  counterpart on the firmware profile it fits. Each keeps the oracle its
  fixture already has, and a target runs the set its kind allows.
- **Size** is the exact bytes of each section of the linked image, read from
  the image: the build report gives a firmware image's totals, and its
  routine counters count emission sites, not bytes. Emission is deterministic, so size has no tolerance: growth
  fails unless the commit declares the new baseline.
- **Time** depends on where the code runs. On a native runner it is the
  median wall time over several fresh copies of each executable, since
  placement alone was found moving it by up to 50%. On the rig's boards
  it is the core's cycle counter over a RAM run where it has one (DWT CYCCNT on
  the M7 and M33, `mcycle` or the vendor's counter on RISC-V, CCOUNT on
  Xtensa), and a SysTick or timer count where it does not, as on the
  RP2040's M0+; the runner table names each board's.
  Under emulation alone (RV64, FreeBSD arm64 and the QEMU firmware lanes) it
  is a deterministic instruction count, or the target records size alone;
  an emulator's wall time does not measure the code. Each class's tolerance
  comes from a noise study recorded on its runner before the gate enforces
  it.
- **Runners.** A table names the runner and the class of every
  target/level pair. A level no runner executes, `x86-64-v4` if the hosted
  runners lack AVX-512, is a `limit` row with its activation, never a
  skipped measurement or a lower level in its place.
- **Baselines** are committed data keyed by target, level, firmware profile
  where there is one, optimization profile, workload and runner class, with the runner's CPU model and image. A candidate is
  compared with its base commit's baselines, never its own; a commit that
  changes one names each key it changes, and a changed runner class
  re-baselines rather than fails.
- **Cost.** Configurations whose emitted bytes are identical are measured
  once and cite the identity. Size runs on every push; time runs on the
  schedule and on dispatch: the schedule and a `scope=boards` dispatch run
  the boards, documents and scripts but no software lanes today, and this
  item adds the timing jobs to them. A pilot over the whole matrix records its minutes, its
  jobs against the account's concurrent-job limits and its noise before the
  thresholds are enforced.

The build report (D791) and `scripts/quality.sh` are the starting point; the
new parts are time, the matrix and the baselines. A report format change here
also says where a program's compile time goes among its sources, and gives
the build and depth reports one name for each frame quantity. A measured code-quality cost attributable to
assembly's fixed memory effect is recorded against `SR-09` before any narrower
effect is proposed. Its ranked list answers the activations of SR-231,
SR-387, SR-596, SR-869 and SR-1023, and measures x86-64's two-instruction
reach of a thread instance. This takes on SR-996 and SR-275, and carries the
fresh-copy requirement. The instruction count under emulation is the
per-routine cost report `SR-1267` asked for.

Exit evidence: the contract, the runner table and committed baselines for the
whole matrix; the gate failing a deliberately larger image and a deliberately
slower one in each execution class and passing an unchanged one; the pilot's
recorded cost; and a ranked list of each backend's largest measured costs,
from which R16.20 takes its scope.

Done: `docs/measurement.md` is the contract, reviewed twice by an
independent agent before any baseline (D1375-D1382), with its runner table
as `compiler/tests/measure/runners.json`, which `measure.py runners` holds
to `refine targets --json`, now giving each level's features (D1377).
Every push holds each allocated section of 1,566 configurations' images,
every target, level and profile, to committed baselines exactly, and the
instructions of 468 under QEMU, RV64's and Cortex-M's; the schedule and
any dispatch time the hosted workloads in pairs on one processor and the
firmware set by each board's counter. The candidate `25159f4a8` passed its
[gate](https://github.com/JanHaan/Landin/actions/runs/44255590398) and
[boards](https://github.com/JanHaan/Landin/actions/runs/44259826354),
timing included, and
[main's gate](https://github.com/JanHaan/Landin/actions/runs/44265284174);
two never-promoted branches cut from it failed: a larger image
([run](https://github.com/JanHaan/Landin/actions/runs/44265298161)) on every
size key of Linux, firmware and FreeBSD and every instruction count, and a
slower one ([run](https://github.com/JanHaan/Landin/actions/runs/44265297675),
[dispatch](https://github.com/JanHaan/Landin/actions/runs/44265301923)) on
the same and on wall time, 126 of 126 pairs on x86-64, 84 of 84 on arm64 and
62 of 66 on Darwin. Its board legs never ran, since `board-bundles` refuses
a changed image on record drift first; a named rig run timed it on the
ESP32 and STM32H753, 108 of 108 configurations failing by 1.26 to 12.1
times where `a9e880430` passed all 108. On the demonstration branches
Darwin's host suite fails before its size step. `compiler/tests/measure/
pilot.json` records the cost, three jobs a push and three a timed run, and
the noise studies are under `compiler/tests/measure/noise/`: none in size
and instructions once RV64 runs in a reserved address space, per port in
cycles, and up to 1.085 in an A/A wall run, so a pair past its tolerance is
timed again. `compiler/tests/measure/findings.md` is the ranked list:
arm64's allocator unused at `size`, RV64's far jumps, Cortex-M's homes
addressed through r6, then allocation. `SR-09` and `SR-1267` are settled;
SR-596, SR-869, SR-231, SR-996, SR-577, SR-583 and SR-1268 are R16.20's;
SR-275, SR-387 and SR-1023 are restated with their figures, and SR-1302
records the Xtensa reference's boot layout. Findings fixed on the way: the
stack report names its frame quantities as the build report does (D1380),
the stage report gives each source's scanning and parsing (D1381), and an
RV64 count no longer depends on its environment.

### R16.20 — Register allocation

Status: complete
Depends on: R16.10

Keep values in registers where R16.10's ranked costs show stack traffic
leading. R16.10's ranked list (`compiler/tests/measure/findings.md`) orders
the work by measured gain: arm64's existing allocator at `size`, RV64's near
jumps within a routine and then its allocation, Cortex-M's stack homes
addressed from `sp` and then allocation through r0 to r7, then RV32 and
Xtensa. Whether one allocator over `Landin.IR.Liveness` serves every backend
is decided first. This item then takes the two costs that change no
firmware image: arm64's allocator at `size`, on Linux, Darwin and FreeBSD
alike, and RV64's near jumps. The rest is split by backend into R16.21 to
R16.24, each with its backend's rows, so that the board records are made
again only by the items that change a firmware image.

Exit evidence: a direct test of `Landin.IR.Liveness`'s intervals, its
conservative whole-routine fallback included, before any allocator change that
relies on it; measured improvement for affected target/level/profile
combinations against their matching R16.10 baselines, with unchanged behavior,
ABI and debugger evidence. Every supported combination remains under the same
size and time regression gate, including unaffected levels and profiles.

Done: D1403 keeps `Landin.IR.Liveness` the one analysis and placement each
backend's own; `ir opt/slot intervals`, `slot interval fallback` and `loop
depths` test it directly, committed before the allocator change. arm64 runs
its allocator at `size` (D1404): over the seven hosted workloads at
`size-auto` `.text` falls about a third on Linux, Darwin and FreeBSD
(497,380 to 327,272 bytes at Linux armv8-a), and under QEMU mandelbrot
executes 0.30 of its instructions, fannkuch-redux 0.37, fasta 0.38 and
binary-trees 0.66. RV64 jumps near within a routine provably inside JAL's
reach (D1405): `.text` 19.9% smaller at `speed`, counted instructions 9.5%
to 20% fewer. No firmware, x86-64 or arm64 `speed` image changed; the build
modes agree and the scaling bound holds. The candidate passed its
[gate](https://github.com/JanHaan/Landin/actions/runs/44407003576) and
[boards](https://github.com/JanHaan/Landin/actions/runs/44413857908).
R16.21 to R16.24 took the other backends and their rows, SR-586 and
SR-1302 among them. Findings fixed on the way: LLDB's `GetValueAsSigned`
read a zero-extended `i32` in a register whole, so the Darwin sessions read
integers at their type's width; a failed Darwin LLDB session keeps its
transcripts; a wall pair whose candidate image is the base's is no longer
timed, and each timed image runs once untimed first, since macOS's vetting
of a program's first launch failed two pairs on a single sample;
`measure.py plugin` names a program for a user-mode QEMU; and
`measure_costs.py routines` takes `--library`.

### R16.21 — RISC-V register allocation

Status: complete
Depends on: R16.10

RV64 and RV32 keep every value in a stack home: R16.10 measured a report
share of 37.8% at rv64gc and 53.9% at rv32imc, speed-auto, and RV64
executing five to seven times arm64's instructions on the same runs. Keep
their values in registers over `Landin.IR.Liveness`, as D1403 has each
backend place its own, and with them RV32's 64-bit values, copied through a
scratch home pair before every store to their own home. Its placement is the
first written since D1403: where it agrees with arm64's it is shared rather
than written again, which answers R551-16's activation for the backends'
shared code, and the row stays open for the stage closures. RV32 changes the
firmware images of three boards, whose records are made again.

Exit evidence: RV64's instructions and both targets' sizes measured lower
than their R16.10 baselines, RV32's cycles on the boards no slower, with
unchanged behavior, ABI and debugger evidence and the board records made
again.

Done: D1503 holds RISC-V's slots and values in registers at `size` and
`speed`. Selection names nearly every integer register as scratch, so a
routine is emitted once with every value in its home while what each
position writes is recorded; locations take x10-x17, x9, x18, x19 or x22
only where nothing writes them over their intervals, with arm64's placement,
and the second emission is checked against the plan, keeping the first if
any write meets a held register. RV32 holds eight-byte values in register
pairs, and held operands are read in place. The usage both allocators read
is `Landin.Backend.Placement`, which answered R551-16's activation for the
backends' shared code; arm64's output is byte-identical. Over the seven
hosted workloads RV64's `.text` falls 15.8% at `size` and 19.4% at `speed`,
and under QEMU speed-auto executes 0.55 of mandelbrot's instructions, 0.67
of fasta's, 0.72 of fannkuch-redux's and 0.82 of binary-trees'; RV32's
firmware `.text` falls 17.5% at `size` and 18.4% at `speed`. On the
ESP32-C3, ESP32-C5 and Pico 2's Hazard3 no configuration is slower: at
speed-auto their cycles fall to 0.56-0.82 of R16.10's for the integer
workloads, 0.87-0.93 for SipHash and 0.97-0.98 for mandelbrot, whose
soft-float helpers dominate. Their six records were made again on the rig.
The RV64 GDB sessions, the RV32 lanes and RV64's fixtures pass, the build
modes agree and the scaling bound holds on the host and on RV64. The
candidate passed its
[gate](https://github.com/JanHaan/Landin/actions/runs/44452396582) and
[boards](https://github.com/JanHaan/Landin/actions/runs/44459720484).
Findings fixed on the way: the RV64 GDB session's source still assumed a
dead argument stays readable, and is now the LLDB lanes' source, whose
argument is read after the call; `runtime/directory-memory` now fits the
RV32 lanes' 32 KiB and at `size` overruns their 4 KiB stack, recorded as a
D698 lane limit. SR-1363 files what remains largest, selection's flag
emulation, 22% of RV64's instructions.

### R16.22 — Cortex-M register allocation

Status: planned
Depends on: R16.10

Cortex-M keeps every value in a stack home and forms each home's address in
r6 first: at armv6-m speed-auto 35.2% of the firmware set's instructions are
stack loads and stores and 30.5% form their addresses, and the Thumb-2
levels select Thumb-1. First the homes are addressed from `sp` directly,
then values are allocated through r0 to r7, then at the Thumb-2 levels the
high registers and Thumb-2's forms. This takes on SR-581, SR-582, SR-583
and SR-584 at the Thumb-2 levels; SR-596's float selection in VFP
registers, measured on `runtime/firmware-mandelbrot` with the AN500
description; SR-869's short `u64` routines on armv6-m; SR-231's atom `match`
arms; SR-996's counterpart against 32 KiB; SR-577's float saves beside an
assembly block; and SR-586's local labels, since every Cortex-M board record
is made again here once.

Exit evidence: the firmware set's size and instructions measured lower than
their R16.10 baselines at every level, the cycles on the boards no slower,
with unchanged behavior, ABI and debugger evidence and the board records
made again.

### R16.23 — Xtensa selection

Status: planned
Depends on: R16.10

Xtensa's backend writes RISC-V-form words that its machine layer keeps in
memory (`docs/targets.md`): 414 of the firmware mandelbrot's 545
instructions in `in_set` are `l32i` and `s32i` through the frame, and the
report share is 53.5% at xtensa-esp32. An allocator over the RISC-V form
does not remove that class. This item either selects natively from the IR,
placing values as D1403 says, or records why Xtensa is left out. It takes on
SR-1024's frame budget, SR-1178's test of the outgoing area D1110 counts and
SR-1302's boot layout of the reference description.

Exit evidence: the ESP32 and ESP32-S3 images measured smaller than their
R16.10 baselines and their cycles no slower, with unchanged behavior and the
board records made again; or the reason Xtensa is left out recorded with its
measurement.

### R16.24 — The hosted backends' remaining costs

Status: planned
Depends on: R16.10

R16.10 ranked x86-64's costs as mostly not register allocation's: floats
moved through a stack slot inside loops and constants rebuilt in each
iteration, a loop's shape and the bounds check an indexed increment keeps,
`size` giving up the hot loops' registers, and the allocators' treatment of
a routine with an assembly block, which on x86-64 takes no caller-saved
register and whole-routine spans and on arm64 no slot in a register. This
takes on SR-1268's SipHash round state and R551-12, whose atomic and barrier
lowering is taken or recorded with its measurement, and SR-387's heap lock
path, which with no thread started still makes two out-of-line calls an
allocation and free.

Exit evidence: each cost taken measured lower against its R16.10 baseline,
with unchanged behavior, ABI and debugger evidence.

### R16.25 — RISC-V's remaining costs

Status: planned
Depends on: R16.10

After R16.21's allocation (D1503) the largest RISC-V cost is selection's
emulation of Arm's condition flags, SR-1363: copies into x20 and x21 before
every comparison and a carry and overflow computed for every addition, 22%
of RV64's instructions over four hosted workloads, and five registers kept
from the allocator. This takes on SR-1363 and SR-637, RV32's frames
reserving a home for every scratch register a routine might save, which
R16.21 left as it was.

Exit evidence: RV64's instructions and both targets' sizes measured lower
than their R16.21 baselines, RV32's frames no larger than their saves need,
with unchanged behavior, ABI and debugger evidence and the board records
made again.

### R16.26 — The library's costs

Status: planned
Depends on: R16.10

R16.10 measured costs the library imposes rather than code generation: a
`list` grown by allocate and copy where the text builder grows by `resize`
(SR-275), and on Cortex-M0 `text.format` against `text.append` and
`core/mem`'s byte loops (SR-1023), with the erased table, `diag.stream`
and `core/README.md`'s Cortex-M size rows not yet measured. This takes on
SR-275 and SR-1023.

Exit evidence: each cost measured, and either lowered against its R16.10
baseline or recorded with its measurement, with the counter fixtures it
changes re-decided.

### The continuous items

Numbered on from R16.20, each is added when it is taken up, or planned when
an item splits it off as R16.20 split R16.21 to R16.24, with its own status
and a dependency on R16.10. Each takes one cost from R16.10's
ranked list, a further backend's register allocation among them.
Exit evidence: the cost measured lower against its R16.10 baseline, and no
other combination over its own.

### R16 gate
The standing invariant: every supported target, level and optimization
combination within its committed baselines on every push.

## R17 — Process, register and skills

The move's own debt; first in the serial lane.

### R17.10 — The register reviewed and typed

Status: complete
Depends on: none

The first item, on a tree `check.py` already accepts: the exchange has moved
every live row into its file. R17.10 reviews each moved row against
"outlives its item", gives it its `kind`, `effort` and `impact`, deletes
those its authority covers and puts the rest it would retire to the
maintainer as questions. It provides the SR allocation script and files the
rows-to-be in `roadmap/inputs/rows-to-be.md`. The rows that describe R22's
additions (SR-96 math, SR-97 float text, SR-98 locale and Unicode, SR-100
regular expressions, SR-285 format width and radix) become `scheduled` on
the R22 items that take them.
Exit evidence: every row typed and under the cap; the allocation script and
its control; the cap and age rule refused in a control.

Done: every moved row typed, the rows-to-be filed as `SR-1282` to `SR-1298`,
`scripts/register_next.py` with its controls, and `check.py` refusing a
register over its cap or a row past its age in controls. The maintainer's
answers to Q-1 to Q-5 retired 43 rows and scheduled `SR-195` and `SR-768` on
R17.50, SR-1178 on R16.20, SR-1237 on R19.10 and C3 on R20.10; a rig fix
rooting the GPIO shell retired one more, leaving 57 open with R17.50's
fixes merged. The retired rows' standing facts moved to
`docs/capabilities.md`, `docs/targets.md` and `devices/README.md`.

### R17.20 — The question queue

Status: complete
Depends on: R17.10

`roadmap/questions/`, its checks and the open maintainer decisions moved
into it.
Exit evidence: every open maintainer decision a `Q-n` file; `check.py`
refusing a question without options, default or what waits on it.

Done: the Mechanics give a question its form, and `check.py` refuses a
question without its heading, asker, options, recommendation, default,
what waits on it or a well-formed answer, a default given by its option
number alone, a `TODO`, a question cited without its file, and a question
identity outside the roadmap's files, each in a control.
`roadmap/register.md` lists the open questions with their defaults and
what waits. `scripts/register_next.py --question --file` allocates and
writes the next one. Q-1 to Q-6 gained their `What waits on the answer:`
paragraphs, and the one open decision held outside the queue, the Darwin
determinism manifests' compiler, is Q-7.

### R17.30 — Lanes and standing authority in the checks

Status: complete
Depends on: R17.10

`check.py`, the site's progress track and the status pointers read lanes,
continuous items and the promotion opt-out. It takes three rows-to-be:
the phase rule the Mechanics do not state (`SR-1282`), the progress track
that fails on a second active item (`SR-1283`), and a reference before a
full stop that is never resolved (`SR-1295`). It also lets any item whose
dependencies are complete be active, several at once, where `check.py`
allowed one, so that R17.50 said `planned` while it ran; states in the
Mechanics that an item of a serial phase may start beside the serial
lane's item, as R17.50 did, which is neither lane; and makes a real
`Status: blocked` item one the checks and their controls accept, which
the first R17.50 session found they did not.
Exit evidence: the front page showing the serial item beside two active
continuous items in a control; the pointers naming the serial lane's
item, with an item of a serial phase active beside it and with a blocked
item, each in a control.

Done: one reader in `roadmap_order.py`, `roadmap_items` and `lane_state`,
serves `check.py` and the site. The serial lane's item is the first in
execution order that is active, or planned and ready; the pointers name it
alone, and the front page shows it with every other active item beside
it, where it had refused a second active item (`SR-1283`). `check.py`
accepts several active items and refuses one whose dependencies are not
complete, a `Blocked because:` line on an item not blocked, and a
promotion line other than `Promotion: maintainer`; it resolves an
identity before a full stop (`SR-1295`), which found the Mechanics' unit
example naming an item that does not exist. A blocked item's reason no
longer hides its dependencies from the site, and the controls that broke
on a real blocked item, found when the first R17.50 session tried the
status, no longer assume none exists. The Mechanics state the phase rule
(`SR-1282`), that several items may be active, and that an item of a serial
phase may start beside the serial lane's item. The controls show the
serial item beside two active continuous items on the front page, and
the pointers holding to the serial item with an early item active beside
it and with a blocked item.

### R17.40 — The item skill rebuilt

Status: complete
Depends on: R17.30

`landin-change` for the new mechanics; scripts for every step that needs
no agent (starting an item with its worktree, brief and reserved
identities; closing it with its clean-up; promotion; a check for a stalled
agent); reopen-safe session state on disk; and the report form that ends
with what the maintainer must answer, each with the default taken. Fixes
from a review run between items, never across a running one.
Exit evidence: the skill and its scripts used to run the next item start
to finish, and a session reopened in mid-item resuming from
its state on disk.

Done: `scripts/item.py` runs every step that needs no agent: `start`
(worktree and branch from `origin/main`, the item made active and the
pointer moved, reserved decision, row and question numbers that
`register_next.py` gives out first, and the brief), `resume`, `note` and
`run` for a session's state on disk, `gate`, `boards`, `promote`, which
pushes only on the promotion rule's evidence, `finish`, which removes the
worktree and branches once main's gate passed, `status`, `stalled` and
`report`. The state lives under the clone's common Git directory, which
every worktree shares. `landin-change` is rebuilt around those steps, with
the report form beside it, its question section last, and a part for a
session that dispatches items; `docs/process.md` has "Running an item".
This item was taken on with `start --adopt` once the script existed and
ran from there under it: its gate (run 44158296103), its boards (run
44163378136), its promotion, main's gate and its clean-up go through the
script. Closing it met two defects the script's controls had not: `run`
refused its documented form, on the gate's Python 3.12 after a first fix
under the shell's 3.14, and promotion while a boards run was going said to
dispatch one; both are fixed, and the Python the gate's script jobs run,
which nothing names, is `SR-1301`. A fresh session with no context resumed it from
disk with `item.py resume` while the gate ran; it said what the next step
was, but not what came after the wait, nor what to do with an
uncommitted file, which `resume` now says. Whether that run is this
item's exit evidence, with the start-to-finish run left to R16.10 and the
R17 gate, is Q-8; the R17 gate is not claimed until R16.10 has run start
to finish under the scripts. The manager's finding that `agent_hook.py
--check` sees only its own checkout is `SR-1300`.

### R17.50 — Gate wall time

Status: complete
Depends on: none

The gate's wall time cut: Xtensa shards, release build and queueing,
against a measured baseline. It takes on `SR-775`, the stock-user job's
unbounded package downloads, and `SR-1276`, `emit_manifest.py modes` printing
no progress, each a gate-time failure it meets, and two rows-to-be of
`roadmap/inputs/rows-to-be.md`:

- The release-build cache mostly misses (`SR-1296`). Its key names the runner image
  version, and GitHub serves two image versions within one run, so a job
  restores an entry only when it shares an image with the job that saved
  it: on run 44030898347 main's entry was saved on image 20261111.127.1,
  `linux-release-build` ran on 20261111.370.1, found none and took as long
  as the clean build. The key names what the C adapters compile against,
  the C library headers' and the C compiler's versions, instead.
- The cached Darwin release build (`SR-1297`), prepared on the local branch
  `ci-darwin-cached-release`: whole-file identity through `ZERO_AR_DATE=1`,
  a modelled Darwin end of 25 to 30 minutes by kind of change. It is
  rebased onto main, given the cache key's brace fix its Linux sibling
  got, and waits for the key decision above.

It also takes on `SR-195`, the Cortex-M shared-GDB session's failures on a
loaded host, and `SR-768`, the Xtensa corpus's heavy fixture timing out.

The baseline: the gate ended 44 to 51 minutes after its creation before
the second roadmap's last CI rework and 31.1 minutes on run 44030898347
after it, with `flake` (31.0) and the last Darwin job (28.3) last.
Exit evidence: the baseline and the new wall time of the complete gate,
each over several runs.

Done: the gate alone ends 30.3 to 30.5 minutes after its creation (runs
44076856511 and 44082338698, both complete passes; the latter on the
promoted tree, with boards dispatch 44087207692), against 31.1 on both
baseline runs, 44030898347 and 44052328931. Its Linux lanes now end about
21 minutes in rather than 26 to 31, and its end is the account's five
macOS runners, about 115 job-minutes of Darwin work; Q-6 asks about more
macOS capacity. Beside another item's gate the cap is shared: run
44062808053 took 51 minutes. The cache key names the C headers and
compiler (`SR-1296`), and the cache now saves time when it hits: GPRbuild
recompiled every unit whose source's time stamp a checkout had renewed, so
a restored tree saved nothing, and the sources' times now travel with it;
the cached Linux and Darwin builds take 1.6 and 2.1 minutes against 8 and
12 from clean. The Darwin cached build is on main (`SR-1297`), with
main's own entry and its release lanes ordered after the comparison. The
determinism manifests and `modes` deal requests to shards by key digest
(D1374), and `modes` reports progress (`SR-1276`); the flake builds in
three jobs; the stock-user downloads are bounded with an official-mirror
fallback (`SR-775`); and the `documents` job reads full history for the
register's age rule (`SR-1299`).

`SR-195`'s cause: GDB waits `remotetimeout`, two seconds by default, three
times for each reply and then carries on as if it were empty, so an
emulator stalled past that on a loaded host had its late `vCont?` reply
read as the answer to `vMustReplyEmpty`. The shared GDB server now sets
`remotetimeout` to each session's own limit, and the `cpu` lane holds it to
a stub that stalls `vCont?` seven seconds, failing under the default and
passing as served. `SR-768`'s: the Xtensa oracle judged a guest by wall time,
and the heaviest fixture, which needs 11 CPU seconds alone and 16 beside
two or four busy threads per hardware thread, took 32 and 70 wall seconds
there. A guest's 20 seconds are now the wall time less the time Linux kept
QEMU waiting to run; it passed with 16 of them at four threads per
hardware thread, a `nonterminating-control` guest that spins still ends at
its limit, and a host that starves a guest for ten times its limit is named.

### R17 gate
The third roadmap's checks pass on the live file; one item run start to
finish under the new mechanics.

Claimed at R16.10's close, Q-8's default: R16.10 ran under `scripts/item.py`
from `start` through its gates, boards dispatches, two promotions and
main's gates, five parallel streams in their own worktrees, and its
`finish` follows this commit; what in the scripts misled is in its report.

## R18 — refine's commands

`refine` becomes a dispatcher in cargo's manner: the compiler's own commands
stay built in, and a command that links little of the compiler, or is a tool
beside it, becomes its own executable `refine-NAME`. Its input is
`roadmap/inputs/command-inventory.md`: the thirteen commands, what each
links, the rules a command is held to, and eight questions with a default
each. Nothing in it is decided until R18.10 decides it. The items after
R18.10 are written as the inventory's defaults would shape them, and R18.10
may regroup them.

### R18.10 — Decide the commands

Status: complete
Depends on: R17

The maintainer answers the inventory's questions: lockstep linking of
shipped split commands, the discovery rule, what a contributed tool is
released from, the diagnostics a split or contributed tool emits, `lsp`
built in or split, how help and completion list external commands, and
whether cutting the edge from `Driver.Library` to `Driver.Loading` comes
first; and with them whether `dap` is built in or external. Retiring the
bare-source form, the inventory's third question, is already decided and is
not reopened. The output is each answer recorded as a decision in `spec.md`,
the classification of every command as built in or split, and the items
below confirmed or regrouped here.
Exit evidence: the decisions in `spec.md`; this phase's items match them.
Done: the maintainer answered Q-9 to Q-13 on 2026-11-18, each option 1,
and `spec.md` records them as D1383-D1387. `check`, `compile`, `run`,
`fmt`, `explain`, `lsp`, `version`, `help`, `completion` and `targets` stay
built in; `svd`, `bindings`, `site` and the new `dap` are split commands in
lockstep with the compiler's library (D1383). A shipped name is found
beside `refine` alone and any other on PATH (D1384). A contributed tool is
held to nothing and its codes never enter the catalogue; `refine explain`
forwards a code to the one tool claiming its prefix (D1385). The loading
edge is cut first (D1386). On Q-11's condition `refine` refuses an
incompatible `refine-NAME`, judged by a description each prints and, for a
shipped one, its source digest (D1387). R18.20 measures `Source_Maps` too,
R18.50 takes the check and the forwarding, and R18.60 is the split
`refine-dap`; `SR-1277`, `SR-1196` and `SR-1224` with `SR-1275` are scheduled on
R18.40, R18.50 and R18.70. Found on the way: the cut shrinks no executable
shipped today, since `fmt`, `explain` and `version` stay inside `refine`;
it matters for `refine-dap`, which reaches `Driver.Library` through
`Source_Maps`.

### R18.20 — Cut the loading edge

Status: complete
Depends on: R18.10

`Driver.Library`'s body withs `Driver.Loading` for one path helper, which
links the whole front end into `fmt`, `explain` and `version`, and into
`Landin.Source_Maps`, which `refine-dap` reads. The helper moves below
both, so each links what it uses (D1386).
Exit evidence: the release text of `explain`, `version` and `fmt`
measured before and after, near the inventory's 0.5, 0.6 and 1.9 MB, and
`Source_Maps`' closure without the front end.
Done: the helpers became the pure `Landin.Paths`, and `Driver.Library`
became `Landin.Library`, outside `Landin.Driver`, whose body every child
linked with the whole compiler (D1423). Release text of each command's
code closure, before and after: `explain` 6.79 to 0.49 MB, `version` 7.01
to 0.71 MB, `fmt` 7.02 to 1.86 MB; finding the library, 4 units and
0.09 MB. A program withing only the library linked 24.35 MB of text and
now links 0.36 MB. `Source_Maps` went from 7.26 to 6.55 MB and keeps the
front end, since it writes the map from a compilation (Q-19);
`scripts/tests/test_unit_closure.py` holds the library's closure, and
`scripts/unit_closure.py` measures any unit's.

### R18.30 — The docs agree with the tool

Status: complete
Depends on: R18.10

The disagreements the inventory found, each fixed on whichever side is
wrong: `refine targets --identify` against `docs/capabilities.md`
(`SR-1289`); L0004, L0009 and `docs/targets.md` sending the reader to
`refine --identify` (`SR-1290`); README's command table missing `targets`,
`completion` and `help` (`SR-1291`); the `Explain_Command` and
`Format_Command` comments (`SR-1292`, `SR-1293`); and a check that holds
`refine help reference` to the documents, which nothing outside the
`commands` suite does today (`SR-1294`).
Exit evidence: each row-to-be of `roadmap/inputs/rows-to-be.md` it names
closed; the new check refuses a command or flag the documents do not name.

Done: `docs/capabilities.md` says `refine targets --identify` is refused
and only the bare compatibility spelling prints the older summary; L0004,
L0009 and `docs/targets.md` send the reader to `refine targets`, which
lists the targets and their levels both promise. README's command table
has rows for `targets`, `completion` and `help` and both forms of `site`.
The `Explain_Command` comment names `citations.txt`, and the
`Format_Command` comment a directory operand. `refine help reference` is
recorded in `compiler/tests/commands.reference`: a commands-suite case
holds the record to the catalogue, and `check.py` holds README's command
table and `docs/capabilities.md` to the record, refusing a command or
option they do not name, with controls in
`scripts/tests/test_check_inventories.py`. The check found what the
inventory had called clean: `-h`, `--output`, `--option`, `--build-mode`,
`--toolchain`, `--linker`, `--define`, `--system-include-dir` and
`--stdio` were named nowhere in either document, and `--define` and `-h`
in no document at all; each is now named where its command is described.
The first gate (run 44324479031) found the cached release build's
`landin_tests` unequal to the clean build's in its line tables: GNAT's
checksum leaves out comments, so GPRbuild's checksum mode recompiled no
dependent of `landin-driver.ads` after a comment moved its lines.
`scripts/build.sh` now compiles again every unit whose ALI file names a
changed source, and says which file changed without calling it one the
compiler is not built from.

### R18.40 — Retire the bare-source form

Status: complete
Depends on: R18.10

`refine NAME` with an unknown NAME is read today as `refine check NAME`.
That form is refused, naming `refine check NAME`, so an unknown NAME can
name a command. A break of its own, promoted on its own, not held for
R19's window. Every command line `refine` prints for its reader is read
again with it, the closing hint "run it with `refine run ...`" included,
which a recorded report holds with the recording host's target
(`SR-1277`).
Exit evidence: the refusal and its explanation in the catalogue; every
fixture, script and document that used the form rewritten; no recorded
report holds a line that depends on the recording host.
Done: a request with an operand and no command is refused with L0002,
status 2, writing the request again after `check` or after the command
its options belong to, and a first word that is neither a source nor a
path is told that `refine help` lists the commands (D1463). The closing
line went with the form, so `SR-1277` is settled: the 24 reports that
held it are re-recorded and none names a target its fixture does not. A
fixture's `args` are `check`'s unless they name a command (D1464); the
test program, every lane, script and the release smoke test, and the
documents name their command. Found on the way: parallel compiles into
one directory refuse each other with L0005 (SR-1343); `SR-1287` fixed
at [1230].

### R18.50 — The dispatcher

Status: complete
Depends on: R18.40

`refine NAME` runs a built-in command; else, for a split command it was
built with, `libexec/landin/refine-NAME` beside the executable, found
through `Landin.Platform` as the library is, and nowhere else; else
`refine-NAME` on PATH (D1384). It refuses an incompatible one, with a
diagnostic that says what to do: each answers `refine-NAME --describe`,
and a shipped one's source digest must be `refine`'s own (D1387). Help
lists external commands under their own heading; completion delegates to
`refine-NAME --complete`; `refine explain` forwards a code outside the
catalogue to the one contributed tool claiming its prefix, and refuses
when none or several do (D1385). `refine version`
describes the installation it runs from: the split commands it finds, and
the `citations.txt` `refine explain` reads and whether it can (`SR-1196`).
The release archive, the flake and the release smoke test ship and run
every split command.
Exit evidence: the dispatch order pinned by fake-filesystem driver cases;
a shipped command of another digest, one without a description and a
contributed one claiming `L` each refused; a contributed test tool found
on PATH and its code forwarded in a native case; the archive and flake
carry `libexec/landin`.
Done: `refine NAME` dispatches its first word alone when it could name
a command and names no built-in one, and passes every word after it as
written (D1484). A split command is looked for at
`libexec/landin/refine-NAME` under the executable's prefix and nowhere
else, refused with L0694 when missing; any other name is the first
`refine-NAME` on PATH. Each is asked `--describe` within ten seconds and
refused with L0695 when its answer does not hold (D1387), and runs with
`LANDIN_REFINE` naming the refine that dispatched it (D1486). `--describe`,
`--help` and `--complete` are a split's whole contract (D1485): help lists
external commands under their own heading and `refine help NAME` runs the
command's own help (D1488), the bash, zsh and fish scripts hand an
external command's words to it, and `refine explain` forwards a code of
another prefix to the one contributed command claiming it (D1385).
`refine version` names the citations file and whether it can be read and
each split command (D1487), settling `SR-1196`. One list,
`compiler/ada/split-commands.json`, names the split commands; the digest's
inputs, the generated built-with list, `build.sh`, `package.sh`, the
flake, the release smoke test and `check.py` read it, and a case holds
that editing a split's own source changes the digest (D1483). It is
empty: the archive and the flake carry an empty `libexec/landin` until
R18.60 and R18.70 add to it. Lockstep is worded without the implementation
language, D1383 and D1385 amended, on the maintainer's answer of
2026-11-18, and Q-19 is answered. Pinned by the commands suite's `the
dispatcher` on the fake host and `scripts/tests/test_cli_native.py`'s
contributed tool on PATH. Found on the way: `item.py run` runs only in the
item's worktree (`SR-1353`), and `unit_closure.py --cut` reports closures no
link can have (`SR-1354`, scheduled on R18.70).

### R18.60 — `refine dap`

Status: complete
Depends on: R18.20, R18.50

The first new command: a Debug Adapter Protocol server over the GDB and
LLDB sessions the targets already script, the split command `refine-dap`
(D1383), in lockstep with `refine` (D1383), shipped in the archive
and the flake and run as `refine dap`, written to the split's rules from
its start.
It reads source maps without `Landin.Source_Maps`, which writes them from
a compilation and keeps the front end (D1423).
Exit evidence: `refine-dap` linked without the front end; scripted DAP sessions in the gate over GDB and LLDB, the
debuggers the targets script today, on every hosted target the debugging
suites run. A further debugger is its own adapter backend.
Done: `refine-dap` is the split command `refine dap` runs, listed in
`compiler/ada/split-commands.json` and so built, digested, packaged and
shipped as every split is. It frames the protocol as the language server
does and reaches a debugger through `Landin.Platform.Debugger_Session`:
GDB over GDB/MI, every request answered from GDB's records, and LLDB
through LLDB's own adapter, `lldb-dap`, relayed and renumbered, the
debugger chosen from the program's format (D1523). A launched program's
output reaches the editor through pipes GDB's shell redirects to, and
`attach` reaches a QEMU or `lldb-server` stub (D1524); library files map
one namespace at a time, since a checkout's library is the whole checkout
(D1525); a stop in `panic_handler` is an exception at the source of its
site (D1526); D1527 lists what is answered over GDB. Source tables are
read through `Landin.Site_Tables`, which `refine site` now shares and
which takes no compilation, so `refine-dap` links 18 units of the
compiler's sources and no front end, pinned in
`scripts/tests/test_unit_closure.py`. The dap suite holds it on the fake
host; `compiler/tests/dap/session.py` scripts a session through `refine
dap` over GDB in the `release` and `arm64-release` jobs and on RV64 under
QEMU's stub, and over LLDB in `darwin-host-release-2` and both FreeBSD
debugger jobs, the guest's `lldb-server` reached from the runner's
`lldb-dap`. Found on the way: the FreeBSD arm64 lane's refusal for a
missing UEFI firmware now says where it looked and what to install, and
looks beside the QEMU on the search path; a program or dispatched command
a closed pipe ends no longer reports itself as a failure (D1528); and the
gate's `measure-time` jobs take `refine`, not the last executable the build
names.

### R18.70 — The existing splits

Status: complete
Depends on: R18.50

`svd`, `bindings` and `site` become `refine-svd`, `refine-bindings` and
`refine-site`, each in lockstep with `refine` (D1383) and each
keeping its suites and its black-box "destroys nothing" and determinism
controls. Those controls take the command they test as an argument, so the
lanes' shared `--refine` becomes one helper (`SR-1224`), and
`compiler/tests/test_compile_publication.py` reports every selected
control's failure rather than the first (`SR-1275`).
Each moves out from under `Landin.Commands`, whose body withs the whole
compiler, and stops withing `Landin.Driver` for `Outcome`. Its own main
parses its own arguments and response files and answers `--help`,
`--describe` and `--complete`, the process surface that is its whole
contract with `refine`, and it enters `compiler/ada/split-commands.json`.
A closure pin for each main in `scripts/tests/test_unit_closure.py` holds
it without the front end, as D1423 pinned `Landin.Library`, and
`scripts/unit_closure.py` refuses or reports a cut parent a real link
would bring back (`SR-1354`). `svd` gains
toy-SVD goldens that run offline through the executable: the output
bytes, and the report and exit status of each fault code. The `SR-1224`
helper takes an executable path, so one suite runs `refine svd` or
`refine-svd`.
Exit evidence: each split linked without the front end; its black-box
suites, and every invocation of the old form, pass through the
dispatcher.
Done: `svd`, `bindings` and `site` are `refine-svd`, `refine-bindings` and
`refine-site`, entered in `compiler/ada/split-commands.json` and built,
packaged and shipped from it. Each is `Landin.Splits.Svd`, `.Bindings` or
`.Site` under `Landin.Splits`, which reads a split's own options and
response files, keeps `refine`'s shared presentation options and answers
`--help`, `--describe` and `--complete` (D1544); none withs `Landin.Driver`
or `Landin.Commands`, since a command's outcome, its presentation and
response files moved out to `Landin.Outcomes`, `Landin.Presentation` and
`Landin.Response_Files` (D1543). A closure pin per main in
`scripts/tests/test_unit_closure.py` holds `refine-svd` to 35 units,
`refine-bindings` to 33 and `refine-site` to 25, where `refine` links 155,
and `scripts/unit_closure.py` refuses a cut a link cannot honour
(`SR-1354`). An option written before a split's name is told its form, the
name first (D1545). Every lane takes `--refine` from
`scripts/lane_refine.py`, which runs `refine NAME` or `refine-NAME` by the
path it is given and judges a split by its description (`SR-1224`, D1307
amended); `test_compile_publication.py` runs every selected control and
lists the failures together (`SR-1275`); `devices/test.py`'s `ToyGoldens`
hold the toy device's output bytes and each fault code's report and
status offline through the executable. The fake-host suites call each
split's entry; the devices, bindings and publication controls pass
through `refine` and through each split directly.

### R18.71 — Concurrent compiles into one directory

Status: planned
Depends on: R18.50

Two `refine compile` runs that publish into one output directory at once,
as `make -j` starts them, can refuse each other with L0005, "another
process holds its lock": each inspects the other's live
`.refine-publication-` workspace and waits two seconds for its lock
(D1049). The refusal reads as a stale lock, and nothing says outputs that
share a directory cannot be built in parallel. It failed R18.10's
concurrent measuring builds, and the harness's own runtime fixtures, which
compile into one `bin` directory at once: `runtime/r420-vec-large-list`
failed `compiler-3` in gate run 44424959169's first attempt. This takes on SR-1343 so that items and builds can work in
parallel.

Exit evidence: concurrent compiles of different outputs into one
directory succeeding, under a control that starts them together on every
hosted target the publication controls run; a workspace that is truly
abandoned still recovered or refused as D1049 says.

### R18.72 — A contributed `refine build`

Status: planned
Depends on: R18.50

`build` is reserved (D1484): `refine build` refuses with L0002, "build is
reserved for future project orchestration", even with a compatible
`refine-build` on PATH, which is left out of `refine help`, is an unknown
command to `refine help build`, and is asked for no code prefix, so
`refine explain` refuses its codes, and nothing says a `refine-build` was
found and passed over. The maintainer decided on 2026-11-19 to lift the
reservation when a compatible contributed `refine-build` is found, so that
it is dispatched, listed in help, asked for its prefix and given its
explanations as any contributed command is. Whether the reservation goes
outright or L0002 stays for the case where none is found is this item's to
design and record against D1484. Met writing refine-build, a contributed
build tool (its friction entry 16).

Exit evidence: a contributed `refine-build` that answers `--describe`,
`--complete` and `explain` (refine-build at ce197f9, prefix `RB`, is the
subject) dispatched by `refine build`, listed by `refine help`, shown by
`refine help build` and given `refine explain RB...`, under the
dispatcher's black-box controls; the case with no `refine-build` refused
as the item decides; D1484 amended.

### R18 gate
Every existing invocation works or is refused with its new form; every
split command ships in the archive and the flake and keeps its controls;
DAP sessions are scripted in the gate.

## R19 — A smaller language

Breaking, serial. Its input is the list of simplification candidates,
SC-01 onward, each with a stable identifier. Nothing in the list is decided
until R19.10 decides it.

### R19.10 — Decide the candidates

Status: planned
Depends on: R18

The maintainer takes each candidate in or leaves it out, and groups the
ones taken in. The output is the accepted list in its groups, with each
group's items added here, and each answer recorded as a decision in
`spec.md`. Range subtypes (SC-16) are already decided: the maintainer
removed them on 2026-11-16, replaced by a `distinct` type with a checking
constructor, and R19.10 records that and groups it. The candidates that
wait on R20 (SC-17, SC-18) are recorded as such, not forced. The answers
on labels, `break with` and `complete` (SC-01, SC-02) settle E1.
It takes on SR-1288: the answer on SC-24 either folds the
value-model decisions or marks each boundary a later decision lifted, so
that a superseded boundary no longer reads as a live rule. SC-27 is
decided on a count, not an estimate, so R19.10 takes on SR-1286 and counts
the constructs over the library, the examples and the corpus first.
R19.10 also decides SR-1237 itself, whether a type application's fixed
actual folds compiler facts and `sizeof` as an array length does or D135
stands, rather than leave it to R19.20, which runs only if SC-24 is taken.

### R19.20 — How far the checker folds

Status: planned
Depends on: R19.10

Taken only if the value-model fold (SC-24) is accepted. It reads the
checker and lowering against D24-D109 and says which per-slice paths
collapse into one rule and which stay. The fold's item takes its scope
from this reading.

### R19.30 — One write order for an aggregate assignment

Status: planned
Depends on: R19.10

SC-26, a behaviour fix as much as a simplification. D29 writes a literal
into its destination element by element; D209 keeps array operands whole
before writing. One rule for both, with in-place writing where no overlap
is shown. Taken unless R19.10 leaves it out.

### R19.40 — The migration aid

Status: planned
Depends on: R19.10

A `refine fix` rewrite for every accepted change that is mechanical, and a
refusal naming the replacement for every removed form. It grows with each
group item, which lands its rewrite with it. The same command applies the
exact fix a diagnostic carries, which SR-1242 asks for.

### Groups accepted in R19.10
Written after R19.10, one item per group, each depending on R19.10 and on
R19.40; the fold's item also depends on R19.20.

### R19 gate
R19's breaking window: every accepted group, R19.30 and R19.40 integrate on
one branch and reach main together in one promotion, so main never carries
half of the breaking changes and no release falls between them. Every
removed form is refused with its replacement named, and `refine fix`
rewrites the mechanical ones. The corpus, the library and the examples are
rewritten, and the prototypes reread.

## R20 — The standard library reviewed

A review of structure and concepts, on the smaller language. Its input is
`roadmap/inputs/library-inventory.md`: the module graph, the concepts, how
capabilities are received, the conventions and their departures, and ten
questions with a default each. Its result is one list of breaking renames
and restructurings, applied at once. The items after R20.10 are written as
the inventory's defaults would shape them, and R20.10 may regroup them.

R20 has a breaking window of its own after R19's: each integration
branch lives one phase, and a release can fall between the two, while
R19.40's `refine fix` is reused for R20's renames. `iterable`, `zeroable`
and `caller`, which R19 leaves to R20, land in R20's window.

### R20.10 — Decide the review's questions

Status: planned
Depends on: R19

The maintainer answers the inventory's questions: when a routine takes
`type is C` and when `any C`; one task concept for fibres and threads;
whether `core/failure` keeps importing the modules whose atoms it names;
`platform/posix` below the protocol concepts; how the I/O concepts group;
one name per idea; parameter order; a locale as an explicit value; and
whether the modules only fixtures import have their consumers. How R22
generates its tables is already decided, and the inventory's question on
it is not reopened. With these come the questions R19 left here:
`iterable` (SC-17), `zeroable` (SC-18) and `caller`, and C3, whether a
call tree's host authority gets a checkable boundary. The output is each
answer recorded as a decision in `spec.md` and the items below confirmed
or regrouped here.
Exit evidence: the decisions in `spec.md`; this phase's items match them.

### R20.20 — How a capability is received

Status: planned
Depends on: R20.10

The rule for `type is C` against `any C` and the order of parameters
written into `core/README.md`'s conventions, and every routine that
departs from them put on the breaking list.
Exit evidence: the conventions stated; a check, where one is mechanical,
that holds the library to them.

### R20.30 — The concepts

Status: planned
Depends on: R20.10

One task concept for `core/fibre` and `hosted/thread`; the I/O concepts
grouped, and `world` giving each of its parts without `lent`; whether
containers iterate through `iterable`, and the fate of `zeroable` and
`caller`. It takes on SR-1284: either the library declares `iterable` and
`fallible_iterable`, which the compiler recognises by name, or the tour
says a program declares its own. Each change goes on the breaking list.
Exit evidence: the concept changes on the list, prototype 3's concept
uses reread against them.

### R20.40 — Layers and consumers

Status: planned
Depends on: R20.10

`platform/posix` moved below the protocol layer as far as its types
allow; what importing `core/fibre` costs a firmware image measured, and
`core/failure`'s registry kept or split on that measurement; an example
program for each module only fixtures import.
Exit evidence: the import graph without the upward edges; the firmware
measurement recorded.

### R20.50 — One name per idea

Status: planned
Depends on: R20.10

One name each for absence, running out of room, the end of an iteration,
a length and giving storage back, and one meaning each for the names
that carry several. Each rename goes on the breaking list.
Exit evidence: the list's naming entries, each with its old and new name.

### R20.60 — The breaking list applied

Status: planned
Depends on: R20.20, R20.30, R20.40, R20.50, R19.40

The list, applied on R20's own integration branch and promoted alone in
one promotion: every renamed or moved name refused with its replacement,
and rewritten by R19.40's `refine fix` where the rewrite is mechanical.
Exit evidence: the library, the corpus, the examples and the documents
rewritten; `docs/library.md` regenerated.

### R20 gate
R20's breaking window: the list reached main in one promotion, so main
never carries half of it; every removed name refused with its replacement;
prototypes 3 and 4 reread against the result.

## R21 — Windows

R15's proposal rewritten for today's library, second Io and threads.

### R21.10 — Windows x86-64

Status: planned
Depends on: R20

Win64 convention, COFF, unwind tables, a hosted layer over the Windows
API; assembler and linker chosen here. Decides `utf16`, which R19 leaves
to it.
Exit evidence: the corpus runs on a Windows x86-64 runner in the gate;
the `utf16` decision in `spec.md`.

### R21.20 — Windows' Io and threads

Status: planned
Depends on: R21.10

Both Io providers and `hosted/thread` over the Windows API.
Exit evidence: the Io and thread suites pass on Windows x86-64 in the
gate.

### R21.30 — Windows debugging

Status: planned
Depends on: R21.10

CodeView in the objects, PDBs from the linker, and the Windows debugger
added as a backend of R18.60's adapter, which is shown only against GDB
and LLDB; it takes nothing from R18.60 but the protocol layer.
Exit evidence: scripted debugger sessions, directly and through `refine
dap`, on Windows x86-64 in the gate.

### R21.40 — Windows arm64

Status: planned
Depends on: R21.30

Exit evidence: the corpus, the Io and thread suites and the debugger
sessions on Windows arm64 in the gate.

### R21 gate
The corpus and debugger sessions on both architectures on GitHub's Windows
runners.

## R22 — Library additions

What a newcomer expects to find, written against the library R20 left.
Placement, data and evidence for each are in `library-inventory.md`'s
appendix B §5. A table derived from outside data (the Unicode Character
Database, the WHATWG and IANA encodings, CLDR) comes from a generator
program with a pinned input, its output checked in and held current by a
check, the route `refine svd` and `scripts/linux_syscalls.py` take. No
build tool is assumed and nothing runs at compile time. Each module has a
consumer outside its fixtures.

### R22.10 — Math

Status: planned
Depends on: R20

`core/math`, SR-96: the elementary functions over `f32` and `f64`, written in
Landin so results agree across targets, with `sqrt` and `fma` as
instructions where IEEE makes them exact. From R20: the naming of its
module and routines, and whether floats get ordering evidence.
Exit evidence: results against a correctly rounded oracle on every
target; image size on Cortex-M0's soft float measured.

### R22.20 — Float text

Status: planned
Depends on: R20

Shortest round-trip printing and correctly rounded parsing of `f32` and
`f64` in `core/text`, SR-97, with floats made `formattable`; it uses hexadecimal
float literals as R19.10 left them (SC-29). From R20: the byte-sink shape
`formattable` writes to and the names of its failures.
Exit evidence: every `f32` round-tripped exhaustively and `f64` against
an oracle; image size on Cortex-M0 measured.

### R22.30 — Text and Unicode

Status: planned
Depends on: R20

Character properties, case, normalisation and segmentation over `utf8`,
from a generated UCD table: SR-98's Unicode half. Settles how a large constant table is laid
out and what it costs a firmware image. From R20: where it lives, the
sink it writes to, the end-of-iteration form segmentation uses, and
whether it iterates through `iterable`.
Exit evidence: the Unicode conformance test files pass; the generator's
check in the gate; table cost on Cortex-M0 measured.

### R22.40 — Character encodings

Status: planned
Depends on: R22.30, R21.10

Conversions between `utf8`, `utf16` and the legacy encodings from
generated WHATWG tables, whole scalars or nothing into a caller's buffer.
Implements `utf16` as R21.10 decided it. From R20: the failure names and
the buffer conventions.
Exit evidence: the WHATWG test data pass on every target the namespace
admits.

### R22.50 — Locale formatting

Status: planned
Depends on: R22.20, R22.30

Numbers and text formatted for a locale, an explicit value from a BCP 47
identifier and never global state, from generated CLDR data a program
uses in part: SR-98's locale half, and SR-285's width, padding and radix
in a template, whose spelling is decided here. From R20: the answer on a
locale as an explicit value, and how formatting evidence takes one.
Exit evidence: CLDR's own test data pass for the locales generated; a
program that uses one locale carries only its data.

### R22.60 — Regular expressions

Status: planned
Depends on: R22.30

`core/regex`, SR-100: patterns compiled at run time with the caller's allocator,
matched in linear time, no backreferences; Unicode classes from R22.30's
tables. From R20: the allocator and capability shape, and how a match
position is named.
Exit evidence: linear time pinned on adversarial patterns on a hosted
target and on Cortex-M0; an external conformance suite passes for the
supported syntax.

### R22 gate
Each addition on every target its namespace admits, with its oracle; each
generated table held by its check.

## Successor families

The first roadmap named six families as destinations for what it did not do,
and the second added Usability. They are kept as the owners of register records, not as roadmaps of their
own; a record that an item here takes on says so, and one that none does
waits for its activation.

- **Scale and self-hosting:** separate compilation and interface files,
  caching, cross-language stage transport and the incremental replacement of
  tested Ada stages.
- **Companion tool and ecosystem:** a build tool, package acquisition, version
  solving, manifests, locks, publishing, naming authority and generator
  orchestration. A build description between Zig's build program and a
  makefile was discussed when this roadmap was written and left out of it.
- **Broader standard library:** library facilities beyond what the prototypes
  needed.
- **Competitive optimization:** optimization beyond correct deterministic
  baseline code.
- **Language evolution:** parked constructs, watches and proposals whose
  triggers have not fired.
- **Release readiness:** distribution, production claims and every release or
  version decision.
- **Usability:** what a person meets using Landin from its documentation
  alone: knowledge a newcomer cannot guess, workarounds, refusals that do
  not say what to do, and documentation that disagrees with the tool.
  `AGENTS.md` makes recording it everyone's job.

## The concurrency execution model

Carried from the first roadmap, because a settled position written nowhere
reads as an open question and gets reopened.

Concurrency is not a property of a function. It is a capability — an Io the
caller hands down, an ordinary parameter like an allocator, commonly minted at
the entry point [1660]. Code using only that Io blocks or does not according to
the provider it was given. The argument list does not prevent a routine from
minting a separate host root [1680]. No keyword, second calling convention or
colored function type is used to say it. The refusal this replaces is recorded
in `tour.md` under WHAT WAS TRIED AND DROPPED.

- **Two Io providers share one interface.** `hosted/blocking` blocks the
  thread while it waits and `hosted/events` lets other fibres run; the
  caller chooses which one to hand down, and `core` code written against
  the interface runs over either.
- **Stackless coroutines are a non-goal.** Cutting functions into state
  machines is a compiler project of its own, and it puts the property into
  every function type that reaches one — the coloring the ambient environment
  was removed to avoid. This is a refusal, not a park: no trigger reopens it,
  only a decision to reverse it.
- **Stackful fibres are the route, and the backends keep them reachable on
  purpose.** A backend decision that forecloses switching stacks is a defect
  in that backend rather than a trade-off. The conditions are held for other
  reasons already: call-bearing frames retain a frame pointer, the callee-saved
  discipline is explicit, and no capability rides in a reserved register.
  Call-free Cortex-M leaves may omit the pointer because they cannot switch
  stacks. The case to design against is a single-core freestanding target, where the
  honest answer to a request for concurrency is that there is none.

## Retained positions

Six positions an outside review challenged and the project kept. Reopen one
only with new evidence that answers its rationale, and record the reopening.
They are numbered RP1 to RP6, apart from `spec.md`'s decisions D1 onward,
and are cited by those numbers here and in `spec.md`.

| Position | What was kept, and why |
| --- | --- |
| RP1 | Integer indexing of UTF-8 text by codepoint ordinal, linear, for ergonomics [0610]; reopen only with program or measurement evidence. |
| RP2 | No weak conformances and no orphan rule: a collision is an error, answered with `distinct` or an explicit function [1280], because a weak conformance lets an application silently change a generic library's behaviour; reopen on ecosystem-scale evidence. |
| RP3 | No compile-time execution and no macros; generated source comes from programs the build runs [1540]. Reviewed when the third kind of generated source appeared, and held for now: SVD modules, C bindings and `platform/linux/numbers` are each generated by a program run outside compilation, `refine svd`, `refine bindings` and `scripts/linux_syscalls.py`; none needed compile-time execution or a macro, and each generated file is checked in and held current by a check. The build-tool suggestion in [the roadmap discussion](https://github.com/JanHaan/Landin/discussions/2#discussioncomment-19264955) may bring a generalized source-generator stage, which would be reviewed against this position. |
| RP4 | `escaping` and `from` are written, not inferred, to keep checking local and because an allocator is a counterexample to inferred `from` [0790] [0900]. |
| RP5 | Landin's own backends emitting assembly; not LLVM, a dependency larger than the language, and not C, which loses the calling convention, the traps and the debug information [1550]. |
| RP6 | One version of a package name per program: 32 KB of flash, nominal types and one conformance register [1470]. |
