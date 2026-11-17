# What the measurements found

The measurement item's ranked list of each backend's largest measured
costs, and the answers to the register rows its roadmap text names, each
named here by its subject as `docs/measurement.md` names them. This is
derived evidence: it decides nothing, and `ROADMAP.md` and
`roadmap/register/` record what is done with it. A cost is attributed by
measuring the same workload with and without the construct that pays it,
at one configuration, or, where the compiler offers no switch for the
construct, against a hand-written equivalent, which the entry names.

## How it was measured

- Compiler: `refine dev (b60b0170)`, the debug build of
  `./scripts/dev-build.sh`; emission does not depend on the build mode.
- Host: AMD EPYC 7302 (Zen 2), NixOS, Linux 6.18, shared with other
  sessions (load average 11 to 35 during the runs). Wall times are the
  median of five or more runs of a fresh copy of each image, interleaved,
  and are trends on a shared host, not thresholds. `perf stat -e
  instructions` counts user-mode instructions.
- Static counters: `python3 scripts/measure_costs.py routines --refine R
  --target T --profile size-auto --profile speed-auto --profile none-off
  --output DIR`, at every level `refine targets` gives, over
  `compiler/tests/measure/workloads.json`'s set for the target; the
  firmware targets also took the two firmware fixtures of branch
  `r16-10-count` (68ae4b6d6), `runtime/firmware-fannkuch-redux` and
  `runtime/firmware-mandelbrot`, through `--fixture`. "Report share" is the
  build report's `stack_loads + stack_stores` over its `instructions`.
- Instruction classes: `python3 scripts/measure_costs.py classify IMAGE
  --target T [--symbol S]`, from the target's objdump, C runtime helpers
  (`__*`) excluded. *stack*: a load or store through the stack or frame
  pointer or a register set from one; *address*: an instruction that forms
  such an address (Cortex-M's `mov r6, sp`, `adds r6, #N`); *far*: the
  extra instructions of a jump that takes more than one.
- Executed instructions: QEMU user mode (`qemu-x86_64`, `qemu-aarch64`,
  `qemu-riscv64` with `QEMU_CPU=max,xtheadba=true`), the plugin
  `compiler/tests/measure/qemu/count.c` of `r16-10-count` counting only
  the image's executable range, over each workload's timing run; and
  `scripts/measure_count.py count --target cortex-m0 --level L --tools
  ~/.cache/landin/cortex-m-r1320 IMAGE` from the same branch for firmware.
  Over the hosted images the one-off loop ran, for each image, `qemu-ARCH
  -plugin count.so,lo=…,hi=…,out=F IMAGE ARGS` with the plugin built by
  that branch's `measure_count.py` and the bounds of the image's
  executable segment.

## The figures behind the ranking

Static, summed over the set at the base level (seven hosted workloads, six
firmware ones):

| target | level | profile | `.text` bytes | report share | stack / address / far (classify) |
|---|---|---|---|---|---|
| linux-x86-64 | x86-64-v1 | speed-auto | 254,027 | 26.6% | 18.0% / — / — |
| linux-x86-64 | x86-64-v1 | size-auto | 245,674 | 30.7% | 24.8% / — / — |
| linux-arm64 | armv8-a | speed-auto | 263,064 | 12.5% | 8.7% / — / — |
| linux-arm64 | armv8-a | size-auto | 451,068 | 38.2% | 24.4% / — / — |
| linux-rv64 | rv64gc | speed-auto | 742,572 | 37.8% | 33.4% / 9.5% / 21.8% |
| linux-rv64 | rv64gc | size-auto | 747,156 | 37.4% | 33.7% / 11.2% / 20.8% |
| cortex-m0 | armv6-m | speed-auto | 30,740 | 38.1% | 35.2% / 30.5% / 1.9% |
| cortex-m0 | armv7e-m | speed-auto | 23,516 | 37.9% | 35.2% / 31.3% / 1.9% |
| rv32 | rv32imc | speed-auto | 34,932 | 53.9% | 38.2% / 5.0% / 0 |
| xtensa | xtensa-esp32 | speed-auto | 54,640 | 53.5% | 37.2% / 1.7% / 0 |
| xtensa | xtensa-esp32s3 | speed-auto | 64,748 | 46.3% | — |

The x86-64 levels v2 to v4 and the RV64 extension levels move these by
under 2 points; armv7-m, armv7e-m and armv8-m.main emit the same `.text`
for every firmware workload. `none-off` is 2.5 times x86-64's `speed`
`.text` and 3.3 times arm64's.

Executed instructions of each timing run, in millions, speed-auto / size-auto:

| workload | x86-64 v1 | arm64 armv8-a | RV64 rv64gc |
|---|---|---|---|
| fannkuch-redux 10 | 1,852 / 1,935 | 2,005 / 6,320 | 12,704 / 12,704 |
| mandelbrot 2000 | 2,657 / 6,183 | 2,276 / 7,769 | 15,827 / 15,828 |
| fasta 2,500,000 | 4,476 / 5,489 | 3,773 / 11,634 | 25,149 / 26,629 |
| reverse-complement (×6000 input) | 2,330 / 2,548 | 2,250 / 8,399 | 14,363 / 14,623 |
| binary-trees 15 | 5,002 / 7,014 | 5,121 / 11,448 | 25,424 / 30,465 |

Every output digest agreed across the three targets and both profiles.
x86-64 wall time, speed-auto / size-auto, ms: fannkuch-redux 265 / 315,
mandelbrot 321 / 1,593, fasta 377 / 518, reverse-complement 207 / 303,
binary-trees 478 / 1,195.

## Ranked costs, by backend

### x86-64

1. **The hosted heap's call path.** `perf record` of binary-trees 15 at
   v1 speed-auto: `host_alloc` 22.5% of samples, `class_of` 6.5%,
   `host_free` 6.5%, `unit_for` 4.2%, `threads_started` 3.9% and
   `load_relaxed_u32` 3.7%, `system_alloc`/`system_free` 5.2%,
   `take_slot` 2.8%: about 58% of the run is the allocator's path, much of
   it calls to routines of a few instructions. The lock flag alone costs
   83 instructions a pair (below). Not register allocation: an inlining
   and library cost.
2. **`size` gives up the hot loops' registers.** mandelbrot executes 2.3
   times the instructions at size-auto that it does at speed-auto and runs
   5.0 times as long; binary-trees 1.4 and 2.5 times; for a `.text` 3.3%
   smaller over the set (mandelbrot 1.6%).
3. **Values moved through a stack slot inside loops.** fasta's
   `select_symbol` (46% of the run) loads each `f64` into a general
   register, stores it to `-0x58(%rbp)` and compares from there: that one
   store holds 18.9% of the routine's samples (`perf annotate`). The loop
   also keeps its bounds check, its count's overflow check and an
   unrotated shape (test at the head, a `jmp` back) in every iteration.
   mandelbrot's `in_set` rebuilds its constants `2.0` and `4.0` with
   `movabs` and `movq` in every iteration.
4. **A routine with an assembly block.** The allocator gives a routine
   that contains `assembler.block` no caller-saved registers, no in-place
   reads and whole-routine slot spans (`landin-backend-x86_64-allocation.adb`,
   `Has_Assembly`). A 4,096-element sum loop with an empty `nop` block in
   it executes 6.55 G instructions against 2.87 G without (2.29 times) and
   takes 394 against 212 ms. Only `platform/linux`'s `system_call` and the
   thread start carry a block in the workloads; see assembly's fixed
   memory effect below.
5. Stack traffic's report share at speed-auto is 26.6%, mostly in
   prologues, calls and cold code; the hot loops measured keep their
   values in registers.

### arm64

1. **`size` has no register allocation.** `landin-backend-arm64.adb`
   allocates only when `Options.Optimize = Speed`. At size-auto the set's
   `.text` is 451,068 bytes against 263,064 at speed-auto (1.71 times
   larger), and the timing runs execute 2.2 to 3.7 times the instructions
   (fasta 11.6 G against 3.8 G). mandelbrot's `in_set` is 107 instructions
   with 79 stack accesses at size-auto and 43 with 3 at speed-auto. This
   is the largest cost on any hosted backend and the allocator already
   exists.
2. **A routine with an assembly block keeps every slot in its home**
   (`Speed and then not Has_Assembly`): the sum loop above is 45
   instructions against 29.
3. Stack traffic at speed-auto, report share 12.5%.

### RV64

1. **Every value in a stack home.** Report share 37.8% at speed-auto; by
   class 33.4% stack and 9.5% stack-address arithmetic (`addi t0, s0, N`
   for a frame past the immediate). Executed instructions are 4.96 to 6.95
   times arm64 speed-auto's on the same runs (fannkuch-redux 12.7 G against
   2.0 G); size-auto executes the same to 20% more (binary-trees).
2. **Every jump in a routine is a far jump.** `landin-backend-riscv.adb`
   emits `j` as `lla x26, L; jr x26` and a conditional branch as the
   inverse branch around it unless the firmware profile bounds the text
   (D678), which RV64 never has: 21.8% of RV64's instructions at speed-auto
   are these extra `auipc`/`addi`/`jr`, 2,531 far jumps in mandelbrot's
   image alone, each at least six bytes over `j` (about 15 KB of its
   123,060). A routine's jumps stay within the routine. Cheap, and
   independent of register allocation.
3. `.text` is 2.9 times x86-64's for the same set.

### Cortex-M (Thumb-1 and Thumb-2)

1. **Every value in a stack home, its address formed in r6 first.** In
   the firmware set at armv6-m speed-auto, 35.2% of the instructions are
   stack loads and stores and 30.5% form their addresses; 67.7% with far
   jumps. In `failure.words` 69% (`classify --symbol words`); in the
   counterpart 57%.
2. **The address forming is not needed even without allocation.** All
   1,236 word loads and stores through r6 at armv6-m speed-auto (1,449 at
   armv7e-m) are at offsets `ldr`/`str [sp, #imm]` reaches (at most 1,020,
   aligned), so the 1,274 `mov r6, sp` and `adds`/`subs r6` before them,
   12.6% of the set's instructions, could go. One-off count over the
   disassembly: each `mov r6, sp` then `adds`/`subs r6, #N` followed, and
   each load or store through r6 checked for the reach of `[sp, #imm]`.
3. **Thumb-2 levels select Thumb-1.** armv7-m, armv7e-m and armv8-m.main
   emit byte-identical `.text` for every firmware workload, and armv7e-m's
   address share (31.3%) equals armv6-m's: no wide immediates, no
   `[sp, #imm12]`, no high registers. Their `.text` differs from
   armv6-m's mainly in the C runtime's helpers the link takes (its
   soft-float and division routines), and in `udiv` and a few `b.w`.
4. **Selection misses the IR leaves to it**, measured in `core/line`
   and `core/mem` (below): a comparison of two zero constants
   (`movs r1, #0; movs r4, #0; cmp r1, r4; beq`) in index paths, an index
   scaled by `muls` with one, an atom set re-tested at each comparison of
   a sealed atom, a struct argument copied in, and each trap reached by
   `ldr r7, [pc]; bx r7` and a literal (1.9% of the set's instructions).
5. **Floats with a float unit** (below): the firmware mandelbrot's inner
   loop on the M7 description is 237 instructions an iteration, 9 of them
   VFP arithmetic.

### RV32

1. **Every value in a stack home.** Report share 53.9% at rv32imc
   speed-auto; the firmware mandelbrot's `in_set` is 72% stack loads and
   stores. A 64-bit value is copied through a scratch home pair
   (`sw s11,-172(s0); sw t0,-176(s0); lw s11,-172(s0); lw t0,-176(s0)`)
   before every store to its own home. Branches are near (D678).
2. Executed counts are not available: Espressif's QEMU has no plugins, and
   the boards' cycle counts belong to the timing jobs.

### Xtensa

1. **RISC-V-form registers kept in memory.** Report share 53.5% at
   xtensa-esp32 speed-auto. The firmware mandelbrot's `in_set` is 545
   instructions, 414 of them (76%) `l32i`/`s32i` through the frame `a7`:
   the machine layer stores each RISC-V-form register it writes and
   reloads each it reads (`landin-backend-xtensa_machine.adb`). Selecting
   natively from the IR removes this class, not an allocator over the
   RISC-V form.
2. xtensa-esp32s3's `.text` is 18% larger than esp32's for the same set.

### Across backends

The share of `.text` and instructions that stack homes take leads on
every backend but x86-64, where the hot loops already allocate. Between
those, the cheapest large items are code that already exists or that
needs no allocator: arm64's allocator at `size`, RV64's near jumps,
Cortex-M's sp-relative homes.

## What the register allocation work should take first

In order of measured gain for the work:

1. arm64: run the existing allocator at `size` (1.71 times `.text`, 2.2 to
   3.7 times executed instructions).
2. RV64: near jumps within a routine (21.8% of instructions, about 12% of
   `.text`), then register allocation (5 to 7 times arm64's executed
   instructions).
3. Cortex-M: stack homes addressed from `sp` directly (12.6% of
   instructions), then allocation through r0 to r7, and the high registers
   and Thumb-2 forms at the Thumb-2 levels.
4. RV32, and Xtensa by native selection or by recording why not: both
   above 50% report share.
5. x86-64's costs are not register allocation's: the heap path and small
   calls (a continuous item), floats through memory and loop shape, and
   `size`'s loops.

The assembly block's allocator conservatism (x86-64 and arm64) belongs to
whichever allocator change meets `Has_Assembly`.

## The rows

**The atom `match` table.** `failure.words` at cortex-m0 armv6-m size-auto
(and armv7e-m, identical) is 4,336 bytes for 34 arms, about 127 bytes an
arm, against the 3,552 its row records from when the subject was first
tested once; 69% of its 1,984 instructions are stack traffic and address
forming, and each arm's test is a range compare-and-jump with a far
branch. A table of 34 (address, length) pairs would be 272 bytes of data.
Command: `refine compile --target=cortex-m0 --level=armv6-m
--optimize=size --specialize=auto --firmware-entry=start --root=../../..
runtime/failure-words/main.ldn ../tests/measure/entry.ldn` then
`measure_costs.py top`. Recommendation: restated; its completion still
holds (a multiway terminator), activation "the register allocation work's
Cortex-M allocation measured", since about three quarters of each arm is
the stack homes and far branches the register allocation work takes, not
the chain.

**The heap's lock flag.** 20,000,000 allocations and frees of 24 bytes on
x86-64 v1, the library's heap against a copy whose
`take_classes`/`give_classes` take nothing (`--library` over a patched
copy): speed-auto 742.4 against 582.5 ms (37.1 against 29.1 ns a pair,
+27%), 9,460 M against 7,800 M instructions, 83 instructions a pair;
size-auto 2,026 against 1,707 ms, 124 instructions a pair. The flag-clear
path is two out-of-line calls a pair to `threads_started` (22
instructions, with two dead `lea`s of its evidence table), each calling
`load_relaxed_u32` (12, with an alignment test of a static address), plus
the callee-saved registers those calls cost `host_alloc` and `host_free`.
Recommendation: restated, completion unchanged, activation the continuous
item that inlines small direct calls and atomics; it is 7.6% of
binary-trees' run on x86-64.

**Float selection on Cortex-M.** `runtime/firmware-mandelbrot` at armv7e-m
with `lane-mps2-an500.ldn` (the M7's double-precision unit), speed-auto:
`in_set` is 804 bytes and 354 instructions against gcc 16.1 `-O2
-mcpu=cortex-m7 -mfpu=fpv5-d16 -mfloat-abi=hard`'s 104 bytes and 28; its
loop is 237 instructions an iteration (9 VFP arithmetic, 26 `vldr`/`vstr`,
70 integer loads and stores, about 65 forming addresses) against gcc's 13.
The whole run executes 6,164,429 instructions under QEMU. Recommendation:
scheduled on the register allocation work with Cortex-M's allocation, VFP
registers included, this workload and description as its measure.

**Short `u64` routines on armv6-m.** `runtime/library-shared-line` at
size-auto: `core.line.divisor` 1,382 bytes (646 instructions), and
`frame_bits` 508 (250), against the same functions in C under gcc 16.1
`-Os -mcpu=cortex-m0`, 190 and 32 bytes (`-O0`: 414 and 64). Of the
divisor's instructions 37.6% are stack traffic, 18.1% address forming and
5.0% far branches; 9 calls go to libgcc's 64-bit helpers. `frame_bits`
spends 68% on homes and their addresses, re-tests the atom set at each
comparison (7 trap branches) and copies its struct argument in. none-off
is 1,784 bytes. Proposed size target: within twice gcc `-Os`, about 400
bytes for the divisor. Recommendation: scheduled on the register
allocation work (Cortex-M homes and selection), the size target as its
completion.

**The library's erased tables and formatting.** On cortex-m0 armv6-m
size-auto, "ch3 C" written into a fixed 24-byte builder through
`text.format(line, "ch{} {}", [any(addr channel), any(addr unit)])` is a
13,212-byte image executing 8,144 instructions, and the same line through
`text.append`/`text.append_usize` 7,664 bytes and 4,551: formatting costs
5,548 bytes and 1.8 times the instructions for one line. `core/mem`'s
firmware byte loops: 64 rounds of two 4 KiB `mem.copy` at speed-auto
execute 62.0 M instructions (about 118 a byte) against 14.0 M with the
library's word loops forced on firmware, at a cost of 4,472 bytes of flash
(armv6-m: 2,692 against 7,164); armv7e-m alike (62.0 M, 14.0 M, +4,100
bytes). The byte loop is 118 instructions a byte because of homes, a
bounds check a byte, a multiply by one and an unfolded zero comparison.
Not measured here: D484's erased tables reaching every entry,
`diag.stream` through `any io.writer`, and `core/README.md`'s Cortex-M
rows. Recommendation: restated with these figures; the copy loops on the
register allocation work's Cortex-M selection (a word loop is 4.4 times
fewer instructions but 4 KB the 32 KiB reference cannot spare until the
homes shrink), formatting and the remaining three on the continuous item
that takes the library's costs.

**The counterpart's flash.** Built as `environments/cortex-m/
counterpart.py` builds it (micro:bit description): size-auto 56,468 bytes,
speed-auto 56,760, none-off 66,692, size-all 56,468, against the 32 KiB
reference's 32,768; static RAM 5,248. Its 110 routines: `uart.open` 2,560,
`start` 2,268, `take_lines` 2,108, `answer_lines` 1,968, `round_yield`
1,890, `parse` 1,874, `core.fibre.admit` twice (1,506 and 1,498),
`divisor` 1,418, `launch_run` twice (858 each); libgcc 954. Classes: 30.6%
stack, 26.5% address, 4.7% far. If bytes follow instructions, removing the
address forming and the far branches alone leaves about 39 KB, so the
reference needs allocation too. Recommendation: restated, completion
unchanged, activation the register allocation work's Cortex-M allocation;
the duplicated `admit` and `launch_run` are 2,356 bytes to look at first.

**List growth through `resize`.** 4,000 appends of 64 KiB (262 MB) on
x86-64 v1 speed-auto: a `vec.list(u8)` through `vec.append_bytes` 402.2
ms, the growing text builder 199.5 ms. `strace -c`: the list makes 12
`mremap`, 13 `mmap` and 12 `munmap`, copying its bytes at each growth
`grow` does not take in place; the builder makes 12 `mremap` and one
`mmap`, its `resize` moving pages rather than bytes. Completion not met: a
list still grows by allocate and copy where `grow` refuses.
Recommendation: scheduled on the continuous item that takes the library's
costs, with these two programs as its measure: a `main` that appends a 64
KiB module array 4,000 times to `vec.new(item: u8)` through
`vec.append_bytes` over `heap.new()`, and one that appends it to
`text.growing(any(addr memory))` through `text.append`, each returning 42
when the length is 262,144,000.

**Assembly's fixed memory effect.** No measured cost is attributable to
the memory effect. The cost a block causes comes from how the allocators
treat a routine that contains one: x86-64 gives it no caller-saved
registers, where D248's clobber of the call-clobbered set holds only at
the block, and no in-place reads or short slot spans (2.29 times the
instructions of a hot loop with an empty block); arm64 gives it no
allocation at all. D248 asks neither: every operand and clobber is
declared. The values the loop keeps are locals whose address is never
taken, which the memory effect does not reach. On Cortex-M, RV32, RV64 and
Xtensa every value is in its home already, so `platform/cortex_m`'s
critical sections pay nothing for the effect. Recommendation: settled as
"the fixed effect stands", the completion's second branch, with this
measurement; the allocator rule goes to the register allocation work.

**x86-64's two-instruction reach of a thread instance.** Already one
instruction: a3aafdd05 (2026-11-10) reaches an instance through one
`%fs`-relative operand. No x86-64 image of the set at any level or profile
contains a `%fs:0x0` load (`objdump -d | grep -c "%fs:0x0,"`, all 84
zero). A loop adding to a `link(thread)` `u64` 500 M times executes
3,500,005,345 instructions, the same loop over an ordinary module binding
3,500,005,534, and built with `--link=libc` it reaches the instance
through the same one operand. Recommendation: settled; nothing to
schedule.
