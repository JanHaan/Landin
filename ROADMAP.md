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
Windows, the library a newcomer expects to find, and the install routes
that make a release quick to reach. Optimization runs beside all of it.

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
item beside it. The continuous lane holds R16's and R22's continuous
items. Each of the two phases has a basis in the serial lane, R16.10 and
R22.80; its continuous items take the next ten after the last basis item
and count up by one, R16.20 onward and R22.90 onward. Each depends only on
its phase's basis, may run beside anything, and is never the next item;
any number of them may be active. A phase that declares a
breaking window (R19, then R20) keeps its serial items on one integration
branch and promotes them once, at its gate; a continuous item lands on
main meanwhile and the branch takes it.

```text
Execution order: R17, R16.10, R18, R19, R20, R21, R22.10, R22.11, R22.13, R22.20, R22.21, R22.22, R22.23, R22.30, R22.40, R22.50, R22.60, R22.61, R22.62, R22.63, R22.12, R22.14, R22.15, R22.16, R22.17, R22.18, R22.19, R22.70, R22.71, R22.72, R22.73, R22.74, R22.75, R22.76, R22.80, R23
Continuous: R16.20 onward, R22.90 onward
```

**Gates.** A phase's gate cannot be claimed until all its items have their
exit evidence, its continuous items apart. R16's gate is different: once
its basis is complete it is a standing invariant every later push must
keep, not a milestone; R22's is claimed with its serial items and then
holds the library's baselines in the same way. An item is
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
`SR-387`, SR-596, SR-869 and `SR-1023`, and measures x86-64's two-instruction
reach of a thread instance. This takes on `SR-996` and `SR-275`, and carries the
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
SR-596, SR-869, SR-231, `SR-996`, `SR-577`, SR-583 and `SR-1268` are R16.20's;
`SR-275`, `SR-387` and `SR-1023` are restated with their figures, and `SR-1302`
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
R16.21 to R16.24 took the other backends and their rows, `SR-586` and
`SR-1302` among them. Findings fixed on the way: LLDB's `GetValueAsSigned`
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
D698 lane limit. `SR-1363` files what remains largest, selection's flag
emulation, 22% of RV64's instructions.

### R16.22 — Cortex-M register allocation

Status: complete
Depends on: R16.10

Cortex-M keeps every value in a stack home and forms each home's address in
r6 first: at armv6-m speed-auto 35.2% of the firmware set's instructions are
stack loads and stores and 30.5% form their addresses, and the Thumb-2
levels select Thumb-1. First the homes are addressed from `sp` directly,
then values are allocated through r0 to r7, then at the Thumb-2 levels the
high registers and Thumb-2's forms. This takes on SR-581, SR-582, SR-583
and `SR-584` at the Thumb-2 levels; SR-596's float selection in VFP
registers, measured on `runtime/firmware-mandelbrot` with the AN500
description; SR-869's short `u64` routines on armv6-m; SR-231's atom `match`
arms; `SR-996`'s counterpart against 32 KiB; `SR-577`'s float saves beside an
assembly block; and `SR-586`'s local labels, since every Cortex-M board record
is made again here once.

Exit evidence: the firmware set's size and instructions measured lower than
their R16.10 baselines at every level, the cycles on the boards no slower,
with unchanged behavior, ABI and debugger evidence and the board records
made again.

Done: Cortex-M reaches its homes from sp, a value's home a word written
zero-extended (D1563); at the Thumb-2 levels it branches with one B and
makes constants with MOVW and MOVT (D1564, `SR-584`); a call loads its
scalar register arguments directly (D1565); a comparison only its branch
reads sets that branch's flags (D1566); and at `size` and `speed` it holds
slots and values in r4-r7, r3 and r1 where its first emission writes none of
them over their intervals, over `Landin.Backend.Placement`'s usage, checking
the second emission against the plan (D1567). A kept comparison at the
Thumb-2 levels is an IT block (D1568, part of SR-582); code labels are
assembler-local (D1569, `SR-586`), held by the firmware lane's
`unused-import` case, which the starting compiler fails; a routine saves
only the run of d8-d15 its blocks declare (D1570, `SR-577`); and a far
Thumb-1 branch to a trap is a BL (D1571). The firmware set's `.text` falls
to 0.71 of R16.10's at armv6-m `size` and `speed` and 0.57 at the Thumb-2
levels, `none` falling too, and under QEMU speed-auto executes 0.28 to 0.88
of its instructions, size-auto 0.29 to 0.95 and none 0.56 to 0.95. On the
boards no configuration is slower: at speed-auto the RP2040 runs 0.27 to
0.96 of R16.10's cycles, the RP2350's M33 0.29 to 0.89 and the STM32H753
0.23 to 0.83. Prototype 5's counterpart links within the constrained
reference's 32 KiB at `size`, 32,080 bytes, and `speed` (`SR-996`), and
twelve runtime fixtures whose images did not fit it run on Cortex-M0 at
every profile. The seven Cortex-M board records were made again on the rig.
The programs and corpus lanes, the unit suites and the fixtures pass, the
build modes agree and the scaling bound holds. The candidate passed its
[gate](https://github.com/JanHaan/Landin/actions/runs/44578956148) and
[boards](https://github.com/JanHaan/Landin/actions/runs/44584549572). R16.27
takes what is left: SR-581, SR-582's CBZ, SR-583, SR-596, SR-869 and SR-231,
each with today's figures. Findings fixed on the way: the devices lane's
cached consumer read a register's address only from literal words; and
`runtime/directory-memory`, which now fits the reference at every profile,
overruns its 4 KiB stack at `none`, which the reference's own
`profile_limit` row could not record, so D698 is amended to let it; the RV32
lanes keep limits at `none` for ten of the twelve, whose RV32 code this item
does not change.

### R16.23 — Xtensa selection

Status: complete
Depends on: R16.10

Xtensa's backend writes RISC-V-form words that its machine layer keeps in
memory (`docs/targets.md`): 414 of the firmware mandelbrot's 545
instructions in `in_set` are `l32i` and `s32i` through the frame, and the
report share is 53.5% at xtensa-esp32. An allocator over the RISC-V form
does not remove that class. This item either selects natively from the IR,
placing values as D1403 says, or records why Xtensa is left out. It takes on
`SR-1024`'s frame budget, `SR-1178`'s test of the outgoing area D1110
counts and `SR-1302`'s boot layout of the reference description.

Exit evidence: the ESP32 and ESP32-S3 images measured smaller than their
R16.10 baselines and their cycles no slower, with unchanged behavior and the
board records made again; or the reason Xtensa is left out recorded with its
measurement.

Done: Xtensa places the words of every routine without an assembly block
over the routine's own text (D1627). The emitter keeps its walk of the IR
and its RISC-V-form words and gives each scalar value and each slot no
address reaches a word of its own; the machine layer computes the words'
liveness, joins their definitions into webs and places them by linear scan
in a2-a6, which a call preserves, and a10-a15, the rest in their homes.
Before placing it folds a word set once to a number into the `mul`, `add`,
`divu` or `remu` that reads it, so a division or remainder by a power of
two is a shift or a mask, which takes the Xtensa half of `SR-1429`, now
restated for RISC-V alone; it drops what nothing reads and makes a flag
and its zero test one branch; and a comparison only its branch reads is
that branch (D1628). A routine of more than 150,000 lines, or whose text
the analysis cannot follow, is selected word by word as before. Over the
firmware set every image is smaller at every profile and both levels,
`.text` 0.37 to 0.76 of R16.10's; the report share of stack loads and
stores at xtensa-esp32 speed-auto is 11.1% against 53.5%, and the firmware
mandelbrot's `in_set` 121 instructions against 545, 30 of them stack loads
and stores against 414. On the boards every configuration runs faster: the
ESP32 0.18 to 0.68 of R16.10's cycles and the ESP32-S3 0.17 to 0.67,
mandelbrot, whose doubles are libgcc's, gaining least. The ESP32's and
ESP32-S3's RAM and boot records were made again on the rig, and both chips'
complete corpus lanes, native controls, boundaries and ABI peers pass.
`SR-1024`: the frame budget counts no saves, the window making them, and
the RISC-V save set is gone. `SR-1178`: a unit case holds a prepared
stack's check to the outgoing area, and a negative fixture a firmware entry
whose area alone exceeds the reference's stack. `SR-1302`: the measurement
reads an Xtensa image as its loader writes it, as D1359 has it, so the
reference's boot layout is measured, and an image it cannot measure is
refused naming the segment, symbol or line it met (D1629). SR-1433 files
the frame placement leaves: a bank and a home for every word. Findings
fixed on the way: a lane's relative `--refine` was run from another
directory, so `measure.py size` failed with a traceback; it is now made
absolute where it is given; and the parser suite gave its one-file host
the firmware library only for Cortex-M. The candidate passed its
[gate](https://github.com/701-dev/Landin/actions/runs/44846399913) and
[boards](https://github.com/701-dev/Landin/actions/runs/44849434198).

### R16.24 — The hosted backends' remaining costs

Status: complete
Depends on: R16.10

R16.10 ranked x86-64's costs as mostly not register allocation's: floats
moved through a stack slot inside loops and constants rebuilt in each
iteration, a loop's shape and the bounds check an indexed increment keeps,
`size` giving up the hot loops' registers, and the allocators' treatment of
a routine with an assembly block, which on x86-64 takes no caller-saved
register and whole-routine spans and on arm64 no slot in a register. This
takes on `SR-1268`'s SipHash round state and R551-12, whose atomic and barrier
lowering is taken or recorded with its measurement, and `SR-387`'s heap lock
path, which with no thread started still makes two out-of-line calls an
allocation and free.

Exit evidence: each cost taken measured lower against its R16.10 baseline,
with unchanged behavior, ABI and debugger evidence.

Done: lowering no longer marks every `public` routine exposed, which D415
had ruled out and the routine filling still did, so D339 copies and
specialization reach the library's public routines; the heap reads its
lock flag with the builtin, one load and a branch in `host_alloc` and
`host_free`, and aligns a power-of-two unit with a mask rather than two
divisions (`SR-387`): on x86-64 binary-trees 15 at speed-auto runs in 0.37
s against 0.44 and 0.927 of the instructions. Shifts that rotate are
`rol` and `ror` on x86-64 and arm64 (D1624), and SipHash-1-3 of 16 bytes
takes 730 instructions against 1,041, its round 15, all in registers;
Cortex-M divides by a constant power of two with shifts (D1626); the two
take `SR-1268`. x86-64 keeps floats in XMM registers at `size`, and loads
a float element, field, pointee or datum straight into one (D1625): at
size-auto mandelbrot executes 0.435 of its instructions and fasta and
binary-trees 0.92, and fasta 0.968 at speed-auto. Compiling the hosted set
at speed takes no longer. What stays is filed with its measurement:
SR-1422 the nine registers x86-64 offers, SR-1423 the assembly block's
rule, SR-1424 float constants made in each block, SR-1425 a loop's two
jumps, SR-1426 the order D339 copies in, and R551-12 keeps the bounds
check a loop's end does not name and the calls of `core/atomic`'s cells;
SR-1427, SR-1428 and `SR-1429` record what the work met, and SR-1430 the
STM32H753's binary-search, 9.7% slower at size where the RP2040 and
RP2350 run every configuration faster. Findings fixed on
the way: the public exposure above, and a dead shift kept as if it could
trap. The STM32H753's cached profile's RAM record was made again on the rig.
The candidate passed its
[gate](https://github.com/701-dev/Landin/actions/runs/44751439289) and
[boards](https://github.com/701-dev/Landin/actions/runs/44756840002), timing
included.

### R16.25 — RISC-V's remaining costs

Status: complete
Depends on: R16.10

After R16.21's allocation (D1503) the largest RISC-V cost is selection's
emulation of Arm's condition flags, `SR-1363`: copies into x20 and x21 before
every comparison and a carry and overflow computed for every addition, 22%
of RV64's instructions over four hosted workloads, and five registers kept
from the allocator. This takes on `SR-1363` and `SR-637`, RV32's frames
reserving a home for every scratch register a routine might save, which
R16.21 left as it was.

Exit evidence: RV64's instructions and both targets' sizes measured lower
than their R16.21 baselines, RV32's frames no larger than their saves need,
with unchanged behavior, ABI and debugger evidence and the board records
made again.

Done: D1687 copies no comparison: the branches after a check read its
operands where they are, a comparison's result is `slt`, `sltu`, `seqz`
or one float comparison, and a carry or overflow is computed only for a
checked sum, into x30, so x20, x21 and x23-x25 are offered to the
allocator. D1688 lays a routine's frame out again for the callee-saved
registers its text names, at both XLENs, which takes `SR-637` and stops
RV64 saving ten registers a routine. `SR-1429`, whose activation was this
item's start, is D1689: an unsigned division by a constant power of two
is a shift or a mask, and a remainder `rem` or `remu`. Against the base,
RV64's `.text` falls 20.5% at `none`, 26.3% at `size` and 24.3% at
`speed`, RV32's 5.9-6.2%, 9.3-10.1% and 9.9-10.8%, and RV64 executes 0.73
of its instructions at `speed`, 0.68 at `size` (fasta 0.56,
fannkuch-redux 0.59, mandelbrot 0.71, binary-trees 0.75 at `speed`); the
lines naming the old flag registers fall from 22% to 1.1-1.4%, now held
values. On the ESP32-C3, ESP32-C5 and Pico 2's Hazard3 all 162 timed
configurations are faster, the integer workloads by 25-34% at
speed-auto, SipHash by 15% and mandelbrot by 2%, and their six records
were made again. The RV64 fixtures under QEMU, the RV32 lanes and the
stack report pass; three corpus programs now fit the RV32 lanes at
`none`, and their D698 limits are removed. Found on the way and fixed: a
first draft computed a checked sum's carry into the register the sum was
held in, which `Holds` cannot see, since a write after an operation's
own result at its position looks like the result's; the measurement's
oracles caught it, and selection's temporaries are now never offered.
Filed: SR-1468, an `if`'s comparison computed into a register before its
branch; SR-1465-SR-1467 record the friction met.

### R16.26 — The library's costs

Status: complete
Depends on: R16.10

R16.10 measured costs the library imposes rather than code generation: a
`list` grown by allocate and copy where the text builder grows by `resize`
(`SR-275`), and on Cortex-M0 `text.format` against `text.append` and
`core/mem`'s byte loops (`SR-1023`), with the erased table, `diag.stream`
and `core/README.md`'s Cortex-M size rows not yet measured. This takes on
`SR-275` and `SR-1023`.

Exit evidence: each cost measured, and either lowered against its R16.10
baseline or recorded with its measurement, with the counter fixtures it
changes re-decided.

Done: D1727 grows a storage that holds a block through one call to the
provider's `resize`, so `hosted/heap` moves a large list's pages rather
than copying its bytes: R16.10's 4,000 appends of 64 KiB on x86-64 take
190 ms through `vec.append_bytes` against 383 ms at the base, with 12
`mremap` calls instead of 12 `mremap`, 13 `mmap` and 13 `munmap`, and the
growing builder's 163 ms; an append of the list's own bytes reads them at
the same offset in the grown block (D1122 amended), so no image links two
ways of growing; this takes `SR-275`. A growth through
`core/fault`'s injector is now one attempt and one success, and the
fourteen fixtures and the derived containers' workload that pinned its
counters were rewritten for it; one fixture's provider, which only moved
on `resize`, now grows in place first, as the concept now says a provider
that can should. `SR-1023`'s costs, measured again at its
configurations after the register allocation work, had already fallen:
the format line is 7,020 bytes and 3,889 instructions against 4,480 and
2,259 through `append`, and the byte loops execute 35 instructions a byte
at speed-auto, not 118. Word loops would take 10 instructions a byte on a
4 KiB copy at 1.8 KB more flash, but a program copying short text runs 17%
more instructions with them, so firmware keeps its byte loops, recorded
with these figures in `core/mem/blocks.ldn`. An erased table links only
the entries something projects, and `diag.stream` adds 3.2 KB and 1,000
instructions to the four writes of one note, most of it the decimal
position; recorded. Every Cortex-M size in `core/README.md` was measured
again and corrected, about half what it said, and so were the corpus
records of `runtime/network-addresses`, which now fits at size/auto, and
`runtime/library-map-reserve-rollback`, which fits at size/auto and runs;
this takes `SR-1023`. The k-nucleotide shape's map probe, 2.5 M 12-mers
counted in a `u64` map, takes 2.45 s on x86-64, 39% in `rehash`, 27% in
`locate` and 8% in SipHash, `locate`'s time on the loads after its bucket
and key misses: the map's layout rather than its instructions, recorded in
`compiler/tests/measure/findings.md` for the port. Found on the way and
fixed: the Cortex-M lane's "unreviewed counterpart change" now says how a
counterpart case is made from its hosted fixture.

### R16.27 — Cortex-M's remaining selection

Status: planned
Depends on: R16.10

R16.22 left where its allocation found them the Cortex-M values it does not
hold, eight-byte integers and the floats a unit computes, and the Thumb-2
levels' own registers and forms: SipHash and mandelbrot still spend about
two fifths of their instructions on homes, and r8, r10 and r12 hold nothing.
This takes on SR-581's high registers, SR-582's CBZ and CBNZ, SR-583's
bitfield instructions, SR-596's float selection in VFP registers, SR-869's
short `u64` routines on armv6-m and SR-231's atom `match` arms, and SR-1430, the STM32H753's binary-search and merge-sort running
more cycles after R16.24 while the M33 ran them faster: the cause found and
the configurations no slower than R16.22's figures, or the cause recorded
with its measurement.

Exit evidence: each cost taken measured lower than its R16.10 baseline and
R16.22's figures, the cycles on the boards no slower, with unchanged
behavior, ABI and debugger evidence.

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
R17.50, `SR-1178` on R16.20, SR-1237 on R19.10 and C3 on R20.10; a rig fix
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
one directory refuse each other with L0005 (`SR-1343`); `SR-1287` fixed
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

Status: complete
Depends on: R18.50

Two `refine compile` runs that publish into one output directory at once,
as `make -j` starts them, can refuse each other with L0005, "another
process holds its lock": each inspects the other's live
`.refine-publication-` workspace and waits two seconds for its lock
(D1049). The refusal reads as a stale lock, and nothing says outputs that
share a directory cannot be built in parallel. It failed R18.10's
concurrent measuring builds, and the harness's own runtime fixtures, which
compile into one `bin` directory at once: `runtime/r420-vec-large-list`
failed `compiler-3` in gate run 44424959169's first attempt. This takes on `SR-1343` so that items and builds can work in
parallel.

Exit evidence: concurrent compiles of different outputs into one
directory succeeding, under a control that starts them together on every
hosted target the publication controls run; a workspace that is truly
abandoned still recovered or refused as D1049 says.
Done: builds of different outputs into one directory run at once. A
build syncs its workspace directory after releasing the workspace's lock
rather than while holding it, so the lock covers a rename or a removal
alone, and an inspector that has waited two seconds for a lock asks
whether the workspace's destination record carries its producer's live
write lease; while it does, it waits on for up to a minute, and a lock no
running build holds is refused after two seconds in words that say so
(D1583). `compiler/tests/test_compile_publication.py`'s
`host-concurrent-compiles`, which every hosted publication lane runs,
holds a live producer's lock for four seconds and starts twelve compiles
into one directory three times; at the item's base the first part failed
with the gate's L0005, and `host-foreign-entries` still refuses a held
lock with no producer. `scripts/measure.py` builds every configuration
into one directory again, the workaround R18.10 added for this refusal
having been reverted with its test. The L0005 explanation says builds may
share a directory. `SR-1343` is settled.

### R18.72 — A contributed `refine build`

Status: complete
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

Done: `build` is an external command's name like any other (D1603, D1484
amended): a `refine-build` on PATH is described, dispatched with
`LANDIN_REFINE`, listed by `refine help`, run for `refine help build`, asked
for its prefix by `refine explain` and handed its words by the completion
scripts, which no longer keep `build` back. With none on PATH, `refine
build` and `refine help build` are refused with L0002 saying that `refine`
has no build command of its own and runs a contributed `refine-build`,
rather than D1463's unknown command, which offered `refine check build`.
The dispatcher suite and a stand-in `refine-build` in
`scripts/tests/test_cli_native.py` hold both; refine-build at 265c539 was
dispatched, listed, helped, explained (`RB0102`) and completed by hand.
`docs/commands.md` states the whole contract a contributed command meets,
the description's keys and which may be empty, with an example the native
tests run (`SR-1417`).

### R18 gate
Every existing invocation works or is refused with its new form; every
split command ships in the archive and the flake and keeps its controls;
DAP sessions are scripted in the gate.

Claimed after R18.71, on main `9dcc76831`: every item's completing commit
passed its gate, its boards dispatch and main's gate. R18.40 refuses the
bare-source form, naming the command to write. R18.70's old forms pass
through the dispatcher with their controls, and R18.72 dispatches `refine
build` to a contributed command. The full
[pass](https://github.com/701-dev/Landin/actions/runs/44633646164) on that
tree, which main's gate reused, packaged the archive with `refine-bindings`,
`refine-dap`, `refine-site` and `refine-svd`, which `scripts/package.sh`
refuses to leave out. It built the flake's `.#refine`, which installs each.
It scripted DAP sessions over GDB in `release`, `arm64-release` and
`rv64-qemu-1`, and over LLDB in `darwin-host-release-2` and both FreeBSD
debugger jobs. A local run on the same tree reached each split's
`--describe` and `--help` through the archive's `refine` and the flake's.

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

What a newcomer expects to find, written against the library R20 left: a
mathematical basis broad enough that people in most fields need no
foreign library first, float text, Unicode, encodings, locale formatting
and regular expressions, the five programs the Benchmarks Game comparison
lacks, and at the end a measured basis for the library's optimization
with a continuous lane, as R16 has for code generation.

Placement, data and evidence for each are in `library-inventory.md`'s
appendix B §5. A table derived from outside data (the Unicode Character
Database, the WHATWG and IANA encodings, CLDR) comes from a generator
program with a pinned input, its output checked in and held current by a
check, the route `refine svd` and `scripts/linux_syscalls.py` take. No
build tool is assumed and nothing runs at compile time. Each module has a
consumer outside its fixtures: a port, another module, or an example
program in `examples.md`.

The mathematics is divided by subject and by what depends on what.
R22.10 to R22.19 are the numbers and linear algebra: elementary
functions, complex numbers, special functions, exact big numbers, fixed
point, dense matrices, linear systems, eigenvalues, small geometry and
sparse matrices. R22.70 to R22.76 are the numerical methods built on
them. Coverage is broad, not complete: each item says what it covers and
what it leaves out, and a part left out waits for a consumer. C's
`<math.h>`, GMP, BLAS, LAPACK, Eigen, OpenFOAM and mlpack are checks of
breadth, not interfaces to copy; nothing is bound from them and no
C-callable BLAS or LAPACK names are offered.

Every mathematical module is freestanding in `core/*`: storage is the
caller's, scratch comes from a passed allocator or a caller buffer whose
size the routine states, and nothing keeps global state. Each
floating-point routine comes in `f32` and `f64` on every target, through soft float where there
is no unit; whether it is written once over a concept both meet is R20's
answer on `type is C`. Accuracy is stated per routine and pinned against
an oracle computed outside the program, and each module's image size on
Cortex-M0's soft float is measured. Everything is single-threaded.

### R22.10 — Elementary functions

Status: planned
Depends on: R20

`core/math`, SR-96: the functions of C's `<math.h>` that most programs
use, over `f32` and `f64`, written in Landin so that results agree across
targets. Classification and manipulation of the representation, rounding
and remainders; `sqrt` and `fma` as instructions where the target has
them, since IEEE makes both exact, through a builtin, which D630 has so
far refused, or an assembly block per target, decided here; `cbrt` and
`hypot`; exponentials and logarithms with
their `expm1` and `log1p` forms; powers; the trigonometric and hyperbolic
functions and their inverses; `erf`, `erfc`, `tgamma` and `lgamma`; the
constants. Ported from musl's and FreeBSD's msun or CORE-MATH, each
function's error in units in the last place stated. From R20: the naming
of its module and routines, and whether floats get ordering evidence.

Leaves out: correct rounding where it is not cheap, rounding modes other
than to nearest and the floating-point environment's flags, C23's
pi-scaled, narrowing and decimal functions, and any other format.

Exit evidence: every function within its stated error of MPFR's
correctly rounded values, one-argument `f32` functions exhaustively and
the rest on a random and a hard-case set, on every target; image size on
Cortex-M0's soft float measured.

### R22.11 — Complex numbers

Status: planned
Depends on: R22.10

A complex number over `f32` and `f64`: arithmetic with C's Annex G
treatment of infinities, absolute value, argument and polar form, and the
complex elementary functions: `exp`, `log`, powers, `sqrt`, and the
trigonometric and hyperbolic functions and their inverses. R22.17's
eigenvalues, R22.70's polynomial roots and R22.73's transforms use it.

Leaves out: complex special functions; matrices of complex elements, a
later addition by Q-67's answer.

Exit evidence: each function within its stated error of MPC's values,
with branch cuts and signed zeros as Annex G gives them, on every target.

### R22.12 — Special functions

Status: planned
Depends on: R22.10

The functions statistics, physics and engineering reach for after the
elementary ones: the incomplete gamma and beta functions and their
inverses, the logarithm of the beta function, the digamma function, the
inverse error function, the exponential integral, and the Bessel
functions of the first and second kind and their modified forms for real
order and argument. R22.74's distributions stand on them.

Leaves out: elliptic integrals and functions, hypergeometric and Airy
functions, the zeta function, spherical harmonics, and complex arguments.

Exit evidence: each function within its stated error of MPFR's or
another higher-precision reference's values over its stated domain, on
every target.

### R22.13 — Big integers and rationals

Status: planned
Depends on: R20

Arbitrary-precision arithmetic in two layers. The lower works on
caller-supplied limbs with no allocator, as GMP's `mpn` does, so that
firmware and R22.20's parser can use it: addition, subtraction,
multiplication from schoolbook through Karatsuba to Toom-3, division with
remainder, shifts, comparison, and decimal and hexadecimal text. The
upper is a signed integer and a rational that grow through the caller's
allocator: arithmetic, floor and truncating division, powers, integer
roots, the greatest common divisor, modular inverse and exponentiation,
bit operations, and conversion to and from the machine integers and
floats with stated rounding. By Q-69's answer, arbitrary-precision
floating point is a later addition, and the two layers are designed so
that it can stand on them.

Leaves out: arbitrary-precision floating point, FFT multiplication and
the Toom variants above three, primality proofs and factoring, and
constant-time operations, since Landin writes no cryptography.

Exit evidence: an oracle set computed by another implementation passes
on every target; multiplication and division timed from one limb to a
million bits; the lower layer's image size on Cortex-M0 measured.

### R22.14 — Fixed-point arithmetic

Status: planned
Depends on: R22.10

For targets without a float unit, the Q15 and Q31 formats firmware signal
processing uses: saturating and rounding arithmetic, conversion to and
from floats, square root, reciprocal, the trigonometric functions, `exp`
and `log`, and dot products and FIR filters, which R22.73's fixed-point
transforms use. It stays by Q-70's answer.

Leaves out: other Qm.n formats and fixed-point matrix factorizations.

Exit evidence: each operation within its stated error of an exact or
MPFR reference on every target; its cycles against the same routine in
soft float recorded on Cortex-M0 on the rig.

### R22.15 — Dense vectors and matrices

Status: planned
Depends on: R22.10

The dense array as linear algebra sees it: a vector or matrix as a view
over caller storage, with rows, columns and strides in either order, and
transposed and sub-matrix views without copying; element-wise operations,
reductions and norms; and the products everything after it stands on, in
the breadth of the BLAS's three levels: scaled sums and dot products,
matrix-vector products and rank-one updates, matrix products, triangular
products and solves, and symmetric rank-k updates. The matrix product is
blocked and packed for the cache from the start, the established
strategy. Small fixed-size vectors are R22.18's. By Q-67's answer the
elements are real, and the matrix's design leaves room for complex
elements as a later addition.

Leaves out: banded and packed storage, complex elements,
extended-precision accumulation, arrays of more than two dimensions, and
lazily fused expressions, which need templates Landin does not have.

Exit evidence: the cases of BLAS's own test programs translated as a
fixture, every test ratio under their threshold of 16, on every target;
the `f64` matrix product at n=1000 timed against OpenBLAS on one core.

### R22.16 — Linear systems and least squares

Status: planned
Depends on: R22.15

The factorizations and what they solve: LU with partial pivoting,
Cholesky, symmetric indefinite LDLᵀ with Bunch–Kaufman pivoting, QR by
Householder reflections with and without column pivoting, and the
complete orthogonal factorization; solving for one or many right-hand
sides, the determinant, the inverse and condition estimates; linear least
squares for full-rank and rank-deficient problems, minimum-norm
solutions included; tridiagonal systems. Blocked over R22.15's products
as LAPACK's are.

Leaves out: banded and packed forms beyond tridiagonal, constrained and
generalized least squares, equilibration, extended-precision refinement,
updating a factorization after a low-rank change, and complex matrices
(Q-67's answer).

Exit evidence: LAPACK's scaled residual tests for these families, such as
`norm(A - LU) / (n norm(A) eps)`, under its threshold of 20 over its generator's matrix
kinds, on every target; n=1000 timed against LAPACK over OpenBLAS on one
core.

### R22.17 — Eigenvalues and singular values

Status: planned
Depends on: R22.16, R22.11

The symmetric eigenproblem by tridiagonal reduction and implicit QL or
divide and conquer; the singular value decomposition by bidiagonal
reduction; the general eigenproblem by balancing, Hessenberg reduction
and the shifted QR algorithm, its eigenvalues as R22.11's complex
numbers; eigenvectors on request. On them, the functions of a matrix
most fields use: the exponential by scaling and squaring, the square
root, the pseudo-inverse and the rank.

Leaves out: generalized problems over a pair of matrices and the
generalized SVD, eigensolvers for banded and sparse matrices, selecting
eigenvalues by range, reordering a Schur form, the CS decomposition,
other functions of a matrix, and complex matrices (Q-67's answer).

Exit evidence: LAPACK's residual and orthogonality tests for its
symmetric, general and SVD paths under its threshold, on every target;
times at n=1000 recorded against LAPACK over OpenBLAS on one core.

### R22.18 — Small vectors, rotations and transforms

Status: planned
Depends on: R22.10

Vectors and matrices of two, three and four elements as plain values,
the cross product, rotations as matrices, quaternions and axis and angle
with their conversions and interpolation, rigid and affine transforms,
and a perspective projection: what graphics, robotics and a firmware
program fusing an inertial sensor's readings reach for, with no
allocator.

Leaves out: computational geometry (hulls, triangulation, intersection),
dual quaternions and camera models beyond the perspective projection.

Exit evidence: the identities pinned within stated error on every
target, a rotation's inverse its transpose and a quaternion's round trip
among them; image size on Cortex-M0 measured.

### R22.19 — Sparse matrices and iterative solvers

Status: planned
Depends on: R22.15

Sparse matrices in compressed row and column form built from triplets,
their products with dense vectors and matrices, and the iterative
solvers for the systems discretized fields and graphs give: conjugate
gradients, BiCGSTAB and restarted GMRES, with Jacobi, symmetric
Gauss–Seidel and zero-fill incomplete Cholesky and LU preconditioners.
By Q-68's answer the solvers are iterative, and the format is chosen so
that sparse direct factorizations fit as a later addition.

Leaves out: sparse direct factorizations and fill-reducing orderings,
algebraic multigrid, sparse eigensolvers, and block and hierarchical
formats.

Exit evidence: each solver reaching its stated residual on a set of
matrices from the SuiteSparse collection, fetched by hash, on the hosted
targets, and on a small Poisson problem on Cortex-M0; iterations and
times recorded.

### R22.20 — Float text

Status: planned
Depends on: R22.13

Shortest round-trip writing, correctly rounded fixed-precision writing
and correctly rounded parsing of `f32` and `f64` in `core/text`, SR-97,
with floats made `formattable`; the parser's slow path uses R22.13's
lower layer. With them SR-285: width, padding, alignment, radix and a
float's precision inside a template's `{}`, Rust's format specification
the reference and the spelling decided here. It uses hexadecimal float
literals as R19.10 left them (SC-29). From R20: the byte-sink shape
`formattable` writes to and the names of its failures.

Exit evidence: every `f32` round-tripped exhaustively and `f64` against
an oracle; fixed-precision output byte-equal to C's `printf` over an
oracle set; `docs/from-c.md`'s `printf` entry written with the template;
image size on Cortex-M0 measured.

### R22.21 — n-body and spectral-norm ported

Status: planned
Depends on: R22.10, R22.20

The Benchmarks Game's two numeric programs, ported beside its five
already in the repository, with R22.10's `sqrt` and R22.20's nine-place
writing, from the game's single-threaded programs.

Exit evidence: both as runtime fixtures printing the game's small-input
output (n-body within its `ndiff -abserr 1e-8`, held byte for byte), the
digests pinned in `check.py`, both in `examples.md` and in
`workloads.json`'s hosted set.

### R22.22 — k-nucleotide ported

Status: planned
Depends on: R22.20

Counted with `core/map`, as the game requires the library's table: the
key type declares its own `hashable` with a cheap mixer, as the game
allows, while the map keeps D1360's keyed SipHash; percentages written to
three places by R22.20.

Exit evidence: the game's output for its 1,000 input as a runtime
fixture, pinned and published as R22.21's are; the time at 25,000,000
recorded with the map's share measured.

### R22.23 — pidigits ported

Status: planned
Depends on: R22.13

Gibbons' spigot over R22.13's integers, with no GMP.

Exit evidence: the game's output for 30 digits as a runtime fixture,
pinned and published as R22.21's are; 10,000 digits timed.

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
uses in part: SR-98's locale half, with R22.20's template width and
precision applied to a locale's digits and separators. From R20: the
answer on a locale as an explicit value, and how formatting evidence
takes one.
Exit evidence: CLDR's own test data pass for the locales generated; a
program that uses one locale carries only its data.

### R22.60 — Regular expressions

Status: planned
Depends on: R22.30

`core/regex`, SR-100: patterns compiled at run time with the caller's
allocator and matched in linear time; Unicode classes from R22.30's
tables; a match's position and captures, iteration over the matches, and
replacing every match from a template. Built on the established
strategies, the basis R22.80 later measures: a literal prefilter for a
leading byte, a substring or a small set of literals; a one-pass engine
where the pattern allows; a lazy DFA with a bounded cache, run in reverse
for a match's start; and a Pike VM for captures and as the fallback,
chosen per pattern as RE2 and Rust's `regex` choose. From R20: the
allocator and capability shape, and how a match position is named.

Leaves out: backreferences and look-around, which lose linear time; a
DFA compiled ahead of time; vectorised literal search; sets of patterns.

Exit evidence: linear time pinned on adversarial patterns on a hosted
target and on Cortex-M0; Rust's `regex` test suite passing for the
supported syntax, regex-redux's patterns among the cases; every engine
checked against the Pike VM on generated patterns and inputs, as RE2's
tester does.

### R22.61 — A finished `for` no longer holds its source

Status: complete
Depends on: none

`SR-1405`, a checker defect met writing refine-build (its friction entry 3)
and scheduled by the maintainer on 2026-11-19 ahead of its phase: inside
an outer loop, releasing a list after a `for` over it has ended is L0315,
naming the `for`'s element as still viewing the list. D1084 holds a
`for`'s source only for a call in its body, and D1370 makes a declaration
that runs again a new binding; the reference check's back-edge scan reads
the element in the `for`'s body as the binding asked about. Placed here
so that the R18 gate does not wait for it; it depends on no other item.

Exit evidence: the release accepted after the `for` under `loop`,
`loop ... break when` and `while`, with the list declared inside or
outside the outer loop, by a runtime fixture; a negative fixture still
refusing the release inside the `for`'s body.

Done: D1623 makes a `for`'s element and index new bindings on every walk,
and the reference check's back-edge scan stops at a `for` that binds the
view asked about, reading only its traversal bounds (`SR-1405`).
`runtime/for-finished-in-outer-loop` runs the release after the `for`
under `loop` with its test first and last, `while`, a list declared
outside and a deferred release; `negative/for-source-held-in-outer-loop`
still refuses the release inside the body and one while a kept element
views the list. Gate run 44525120865 (attempt 2; attempt 1's Darwin
artifact upload failed on DNS) and boards run 44535495255 on f968ab7f3.

### R22.62 — regex-redux ported

Status: planned
Depends on: R22.60

The Benchmarks Game's regex program over `core/regex`, its five
replacements by R22.60's replace-all.

Exit evidence: the game's output for its 1,000 input as a runtime
fixture, pinned and published as R22.21's are; 5,000,000 timed.

### R22.63 — The ten programs measured

Status: planned
Depends on: R22.21, R22.22, R22.23, R22.62

`docs/benchmarks.md` compares all ten programs of The Computer Language
Benchmarks Game with the same languages, single-threaded as its method
is, from a script kept in the repository that fetches the other
languages' programs by hash and pins their toolchains, so that one
command reproduces the table. The repository's documents call the game
by its own name.

Exit evidence: the script, the table it wrote for the ten, and its run
recorded.

### R22.70 — Functions of one variable

Status: planned
Depends on: R22.11

Roots by bisection, Brent's method and bracketed Newton; minimization by
golden section and Brent's method; numerical differentiation;
quadrature by Gauss–Legendre and adaptive Gauss–Kronrod rules, over
infinite intervals by substitution; interpolation by barycentric
polynomials, cubic and monotone splines and tables; polynomials, their
arithmetic and all their roots as R22.11's complex numbers; Chebyshev
approximation.

Leaves out: cubature in several dimensions, rational and minimax
approximation, and symbolic differentiation.

Exit evidence: each method on test problems with known answers within
its stated tolerance on every target, its function evaluations recorded.

### R22.71 — Optimization

Status: planned
Depends on: R22.16, R22.70

Minimizing a function of many variables with line searches: BFGS,
limited-memory BFGS with bounds, and nonlinear conjugate gradients;
Nelder–Mead without derivatives; nonlinear least squares and curve
fitting by Gauss–Newton and Levenberg–Marquardt; systems of nonlinear
equations by Newton's method and Powell's hybrid method; dense linear
programs by the simplex method. Derivatives come from the caller or by
finite differences.

Leaves out: general nonlinear constraints, integer and mixed-integer
programming, global and stochastic methods, automatic differentiation,
and conic and semidefinite programming.

Exit evidence: the Moré–Garbow–Hillstrom problems and a set of small
linear programs solved to stated tolerances on every target, evaluations
recorded.

### R22.72 — Differential equations

Status: planned
Depends on: R22.16, R22.70

Initial value problems of ordinary differential equations: fixed-step
Runge–Kutta, adaptive embedded pairs with dense output, an implicit
method for stiff systems over R22.16's factorizations, symplectic
integrators for mechanics, and events located by R22.70's roots.

Leaves out: boundary value problems, delay, stochastic and
differential-algebraic equations; partial differential equations are
R22.75's.

Exit evidence: problems with known solutions within tolerance, stiff
problems such as Robertson's and van der Pol's among them, on every
target; steps and evaluations recorded.

### R22.73 — Fourier transforms and signals

Status: planned
Depends on: R22.11, R22.14

The fast Fourier transform of any length, by mixed radix and Bluestein's
algorithm, for complex and real data in one and two dimensions, with its
inverse and the DCT-II and DCT-III; convolution and correlation directly
and by transform; window functions; FIR filters, IIR filters as biquad
sections, and the design of windowed-sinc and Butterworth filters. The
transform and filters in Q15 and Q31 through R22.14, for firmware.

Leaves out: wavelets, the other DCT and DST kinds, more than two
dimensions, number-theoretic transforms, and adaptive filters.

Exit evidence: transforms against a direct transform computed in higher
precision, error growing with log n, on every target; filters against
reference responses; the Q15 transform's cycles on Cortex-M0 recorded on
the rig.

### R22.74 — Statistics and probability

Status: planned
Depends on: R22.12, R22.16, R22.70

Descriptive statistics, streaming and stable: mean, variance and higher
moments, quantiles, histograms, covariance and correlation. The common
distributions' density, distribution and quantile functions and sampling
over `core/random`'s generator: uniform, normal, log-normal, exponential,
gamma, beta, chi-squared, Student's t, F, Weibull, binomial, Poisson,
geometric, negative binomial and the multivariate normal. The standard
tests with their p-values: t-tests, chi-squared, Kolmogorov–Smirnov and
the rank tests; linear regression with its standard errors.

Leaves out: generalized linear models beyond R22.76's logistic
regression, Bayesian inference and Markov chain Monte Carlo, time-series
models, survival analysis and data frames.

Exit evidence: values against a reference computed outside the program,
named with its version; sampling checked by goodness of fit at fixed
seeds; streaming moments against two-pass results on ill-conditioned
data; on every target.

### R22.75 — Fields on meshes

Status: planned
Depends on: R22.19, R22.72

Partial differential equations discretized: finite differences on
structured grids, and finite volumes on unstructured polygonal and
polyhedral meshes in OpenFOAM's form, cells and faces with an owner and a
neighbour; gradient, divergence and Laplacian operators with upwind and
central interpolation; fixed-value and fixed-gradient boundaries;
assembly into R22.19's sparse matrices; time stepping by R22.72's methods
or implicitly. Its consumer is an example program for heat conduction
and scalar transport.

Leaves out: mesh generation and mesh file formats, finite elements,
pressure–velocity coupling for flow, turbulence models, adaptive
refinement and parallel decomposition.

Exit evidence: manufactured solutions converging at each scheme's order
on structured and unstructured meshes on the hosted targets; the example
program in `examples.md`.

### R22.76 — Learning from data

Status: planned
Depends on: R22.17, R22.71, R22.74

The methods most data work starts with: k-means clustering with
k-means++ seeding, principal component analysis by R22.17's SVD, k
nearest neighbours over a k-d tree, linear, ridge and logistic regression
with regularization, naive Bayes, decision trees for classification and
regression, and the usual scalings and cross-validation splits.

Leaves out: neural networks, support vector machines, ensembles such as
forests and boosting, Gaussian mixtures, kernel methods and
reinforcement learning.

Exit evidence: each method's results on public datasets fetched by hash
against an established implementation's, recorded with its version; k-d
tree queries against brute force; on every target.

### R22.80 — The library measured

Status: planned
Depends on: R22.18, R22.40, R22.50, R22.63, R22.73, R22.75, R22.76

The basis of R22's continuous lane, as R16.10 is of R16's: the time and
size of the library's own code measured, held in the gate and ranked.
Its workloads are each module's operations at stated sizes, the ten
programs of R22.63, and the reference libraries' times on one core for
the same operations (msun, GMP, OpenBLAS and LAPACK, FFTW, RE2 and PCRE2
among them). It measures by R16.10's contract in `docs/measurement.md`
and keeps its baselines beside R16's. A cost of the code the compiler
emits goes to R16's lane; a cost of the library's algorithm, data layout
or blocking goes to R22's.

Exit evidence: the workloads and baselines on every target their
namespaces admit, held as R16.10's are; a ranked list of each part's
largest costs against its reference, from which R22.90 takes its scope.

### R22.90 — The library's first costs

Status: planned
Depends on: R22.80

The costs at the head of R22.80's ranked list.

Exit evidence: each cost taken measured lower than its R22.80 baseline,
and no other workload over its own.

### The library's continuous items

Numbered on from R22.90, each is added when it is taken up, or planned
when an item splits it off, with its own status and a dependency on
R22.80. Each takes one cost from R22.80's ranked list, in any part of the
library. Exit evidence: the cost measured lower against its R22.80
baseline, and no other workload over its own.

### R22 gate
Each addition on every target its namespace admits, with its oracle; each
generated table held by its check; the ten programs measured by the kept
script. Once R22.80 is complete, the library's baselines are a standing
invariant every push keeps, as R16's are.

## R23 — Install routes

Four routes to an installed `refine`, which the maintainer added on
2026-11-20. Today a release archive (Linux x86-64, Linux arm64 and macOS
arm64, the Linux ones linked against glibc), nix, which builds from source
in minutes, a Homebrew tap kept outside the repository, and a build from
source are the ways in; a newcomer on NixOS, Alpine or in a container has
none that is quick. These items make the releases that exist reachable:
they add steps to the release recipe and the flake, and make no release
and change no version, which stay outside this roadmap. Package
repositories (apt, rpm, the AUR) and further hosts (Windows, an Intel Mac,
FreeBSD) are not among them; R21 owns Windows.

Their dependencies are inside the phase, so each may start beside the
serial lane's item, as R17.50 did; while R19 to R22 have an item, the
pointers keep naming it. An item that changes a step of the release
recipe writes that step into `docs/process.md`. The recipe, a declaration
commit, the gate, the tag, the release workflow's publication and the
commit that records the published hashes in the flake, is written today
only in comments of `.github/workflows/release.yml` and `flake.nix`, so
the first such item writes the whole recipe down.

### R23.10 — Container images on releases

Status: complete
Depends on: none

Two images under `ghcr.io/701-dev`, for Linux amd64 and arm64 in one
manifest each, published by the release workflow and only at a release,
never from main or a commit. The user image holds a release archive's
prefix (`bin/refine`, `libexec/landin`, `lib/landin`) and the C compiler
and binutils `refine` links with, under the GNU triplet name it asks for
(`libexec/landin/<triplet>-gcc`, as `flake.nix`'s `refineBin` arranges);
it is built from the two Linux release archives without compiling. The
contributor image is the pinned GNAT and GPRbuild environment for building
the compiler, grown from `environments/linux-amd64/Containerfile` with an
arm64 counterpart; it reads `environments/pins.sh`, so `check.py`'s pin
agreement covers it. Neither carries a Cortex-M, RISC-V or Xtensa
toolchain; the installing documentation says how a user adds the
dependencies for a cross build, and that debugging inside a container
needs `--cap-add=SYS_PTRACE`. A base image's packages move only at a
release. Whether a release also moves a `latest` tag is Q-65.

Exit evidence: a gate job that builds the user image from the gate's
packaged release compiler and compiles and runs the first program inside
it, as `outside-user-stock` does outside one, on amd64 and arm64; the
contributor image built and the compiler built inside it, in the gate or,
where its cost forbids, in the release workflow; the release workflow
building and checking both images before its approval and pushing them
after it, shown on a run whose push is withheld; both images in the
installing documentation and `docs/capabilities.md`; the release recipe's
image step, and how to check a published image, written in
`docs/process.md`. The first published images are the next release's
evidence, not this item's.

Done: `environments/images/user.Containerfile` unpacks a Linux
release archive into `/usr/local` over Debian 13's own `gcc` and
`libc6-dev`, whose driver names `refine` already asks for, so no
`libexec/landin/<triplet>-gcc` link is made (D1667);
`environments/images/contributor.Containerfile`, the former
`environments/linux-amd64/Containerfile`, installs the toolchain through
`pins.sh` for amd64 or arm64 and names no version, and `check.py` holds
both recipes to the pins (D1668). `scripts/container_image.py` builds,
checks, saves and publishes both; the gate builds the user image from its
packaged compiler in `outside-user-stock` and `arm64-release` and runs
the first program in it as the README says. `release.yml` builds and
checks both images, the contributor one by building the compiler inside
it, and assembles each into one two-platform index before the approval,
then pushes and attests them after the release is public, tagged with the
version alone (Q-65's default); a `rehearse` dispatch runs all of it on
any ref and publishes nothing (D1669). Rehearsal run 44823357861 on
bddf062e7 is the run whose push is withheld; its two predecessors found
that an untagged commit's compiler is `refine dev` and that podman could
not push a list made from loaded archives, now assembled with skopeo. It
also measured that GDB in the user image stops at `main` without
`--cap-add=SYS_PTRACE`, which then only leaves the address-randomisation
warning in place, so the README says that instead. `docs/process.md`
writes the whole release recipe down in a section of its own, image step
and published-image checks included. Gate run 44823246775 on bddf062e7.

### R23.20 — Nix installs the prebuilt compiler

Status: complete
Depends on: none

`nix profile install github:701-dev/Landin` builds `refine` from source,
which takes minutes, though the flake already has `refine-bin`, the
published release archive for the same three hosts, which the installing
documentation does not name; and the flake defines no `apps`, so `nix run`
has nothing to run. The route the documentation gives takes the prebuilt
compiler on a host the release covers and the source build elsewhere, and
`nix run github:701-dev/Landin -- ...` runs `refine`. The source build
stays one name away for a contributor and for a host without an archive.

Exit evidence: `nix profile install` and `nix run` of the documented
reference fetching the release archive rather than compiling, and the
source build still reachable, in the gate's flake jobs; the installing
documentation giving both commands; the release recipe's flake-hash step
in `docs/process.md` checking `nix run` against the newly published
archives before that commit is promoted.

Done: the flake's default package is `refine-bin`, the release archive,
on every system whose release hash it records, all three today, and the
source build stays `#refine`; `apps.default` runs `bin/refine` from the
default, so `nix run github:701-dev/Landin -- ...` runs the released
compiler (D1707). The README gives `nix profile install`, `nix run` and
`#refine`, and keeps `profile install`, which Nix 2.34 calls an alias of
`add`, because older Nix has no `add`. `scripts/nix_route.py` installs the
flake into a scratch profile and holds it to the `refine-bin` store path
and version, runs the first program through `nix run`, and refuses a
`#refine` that is not the source build; the gate's `flake-compiler` leg runs it after building both
packages, and `test_nix_route` holds its refusals. The release recipe's
flake step runs it on the branch that moves the hashes and checks
`nix run github:701-dev/Landin -- version` once that is on `main`. Gate
run 44873069309 and boards run 44875115933 on the merged tree 9e62c8b88.

### R23.30 — A one-line install script

Status: complete
Depends on: none

A script a user pipes from `curl` into `sh`: it names the release archive
for the host it runs on, downloads it and its `.sha256`, refuses on a
mismatch, unpacks it into a directory of the user's choosing or a default
under the home directory, and says what to put on `PATH`. A host no
archive serves is refused with the routes that do serve it. It installs a
named version or the newest, and says it can check the archive's
attestation with `gh` when that is installed. Where the script is served
from, the address the documentation prints, is Q-66.

Exit evidence: the script run in the gate on Linux x86-64, Linux arm64
and macOS arm64 against the gate's packaged compiler served as a release
would be, installing a program that runs the first program, and refusing
a damaged archive and an unserved host, each in a control; the
installing documentation's command; the release recipe's step that checks
the script's archive names against the assets the release workflow
publishes, in `docs/process.md`.

Done: `install.sh`, served unchanged at `https://www.701.dev/install.sh`
(Q-66's answer), which the site's render copies from the repository,
installs the host's release archive into `~/.landin` or `--dir`, the
newest release or `--version`, after checking it against its `.sha256`;
it replaces an earlier install whole, refuses a directory holding anything
else, edits no shell profile, prints the `PATH` line and, when `gh` is
installed, the attestation commands; it refuses a host no archive serves,
NixOS and a Linux without glibc's loader among them, naming nix and the
source build (D1747). `scripts/install_check.py` serves a packaged
compiler from 127.0.0.1 in a release's layout and runs the script against
it: the newest and a named version installed and running the first
program, a reinstall, a foreign directory, a damaged archive, a missing
version and two unserved hosts refused; the gate runs it in `release`,
`arm64-release` and `darwin-host-release`, and
`test_install_script` runs the cases against a stand-in archive and holds
the script's names to `release.yml`'s. The README gives the command first
among six routes, and the release recipe's check of the published
release runs `install_check.py --published`, holding the names to the
release's assets, and the documented command. Met on the way and fixed:
the links check would race the Pages deployment on the push that
publishes the script, so `lychee.toml` leaves that one address to the
render and the recipe. Q-65 is answered too: version tags only. Gate run
44896732794 and boards run 44898787764 on the merged tree fcd9ada74.

### R23.40 — Whether a static Linux `refine` can be built

Status: complete
Depends on: none

A Linux `refine` linked statically, against musl, would run on Alpine,
NixOS and a minimal container without the glibc loader the Linux archives
ask for. Nobody knows whether the pinned GNAT makes that hard: its runtime
is built for glibc, and its tasking, exceptions and the C adapters each
need a look. This item looks, tries a static build of `refine` and the
split commands on Linux x86-64 and arm64, and writes what it found, with
the cost and the toolchain it would pin, under `roadmap/inputs/`.

Exit evidence: the finding in `roadmap/inputs/`, with a static `refine`
that passed the release test program if one was built; R23.50 confirmed or
rewritten to match, or, if it cannot be done at a cost worth paying, a
question asking the maintainer to retire it.

Done: the pinned GNAT links `refine`, its four split commands and the
test program statically against glibc with no source change: the GNAT
runtime was static already, nothing calls the name service, `dlopen` or
`iconv`, and the build only adds `-largs -static` or `-static-pie`. On
Linux x86-64 both builds passed the whole release test program, 1279
cases each. The arm64 build, made under emulation, passed the suites it
reached before runtime fixture execution, which emulation could not finish;
R23.50's gate job runs it natively. Both architectures' archives ran in
Alpine 3.24's minirootfs with no glibc, the first program through Alpine's
`gcc` and five `--link=libc` fixtures against musl. The archive grows
3.7 %. musl would need a GNAT 16.1 toolchain built and maintained by the
project, since none is published, for no reach static glibc lacks; the
finding is `roadmap/inputs/static-linux-refine.md`, R23.50 is rewritten to
it, and Q-116 asks whether the static archive replaces the glibc ones,
defaulting to yes. Met on the way and fixed: the flake's `aarch64-linux`
shell and `refine` package did not build, GPRbuild's arm64 archive wanting
`libgmp.so.10`, which the flake now supplies. Rows SR-1515 to SR-1517 hold
what outlives the item.

### R23.50 — A static Linux archive

Status: active
Depends on: R23.10, R23.30, R23.40

The release workflow publishes a Linux `refine` linked statically against
glibc with `-static-pie`, for x86-64 and arm64, as R23.40 found it builds
with the pinned toolchain and no source change
(`roadmap/inputs/static-linux-refine.md`); a musl build is not attempted,
since no published GNAT targets musl. The static archive replaces the glibc
archives under their names or is published beside them as Q-116 answers.
The install script takes it on a musl or NixOS host, and the user image
takes it where it makes the image simpler. The archive carries glibc's
licence and names the glibc it holds, and the build is refused when a
static link prints glibc's warning that a call needs that glibc's shared
libraries at run time.

Exit evidence: a gate job that runs the packaged static compiler on
Alpine and in an image with no C library of its own beyond the linker it
needs, compiling and running the first program and the `--link=libc`
runtime fixtures against musl, or a row for each that does not run there;
the release test program passed by the static build on both
architectures; the install script choosing it on Alpine in its control;
the archive in the installing documentation; the release recipe's step for
it in `docs/process.md`.

### R23 gate
Every route in the installing documentation and exercised by the gate or,
where only a release can, by the release workflow; the release recipe
written in `docs/process.md` with each route's step.

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
- **Release readiness:** distribution beyond R23's routes, production
  claims and every release or version decision.
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
