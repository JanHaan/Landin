# Cortex-M execution profile

The profile keeps independent C/assembly, memory-model and hosted transport
controls beside compiler-generated ARMv6-M execution with direct synthetic
peripheral access. A separate lane runs compiler-owned startup and firmware
linking, and rooted `core/mem`, `core/vec`, `core/pool`
and `core/cpu`/`core/panic` consumers run through that compiler-owned firmware path.

## Selected lanes and pins

| Component | Exact selection |
|---|---|
| Probe host | native Linux x86-64, Debian 13; the existing native runner is supported |
| CPU/startup lane | QEMU 10.0.13, Debian `1:10.0.13+ds-0+deb13u1`, `-M microbit -accel tcg,thread=single` |
| Core | nRF51822 Cortex-M0, ARMv6-M, Thumb, little endian, 16 MHz model clock; no FPU, caches or exclusive-access instruction requirement |
| Peripheral lane | Renode 1.17.0 Linux x86-64 portable, build `1.17.0+20260907gitf1dd1b4af`, bundled .NET 8.0.12; `prototype.repl` with Cortex-M0 at 16 MIPS and NVIC |
| EABI compiler | `arm-none-eabi-gcc` 14.2.1 20241119, Debian `15:14.2.rel1-1` |
| Assembler/linker | GNU Arm binutils 2.44, Debian `2.44-3+23+b1` |
| Debugger | `gdb-multiarch` 16.3, Debian `16.3-1`, loopback QEMU remote stub |
| Probe options | `-mcpu=cortex-m0 -mthumb -mfloat-abi=soft -mabi=aapcs -ffreestanding -fno-builtin -fno-omit-frame-pointer -g3 -O1 -nostdlib`; warnings are errors |

`tools.lock.json` pins URLs and SHA-256 for every downloaded package, including
shared-library dependencies and GDB's Python support. The portable Renode
archive SHA-256 is
`4ba7c68b59e2447f188ef4b4b112fcccd2802582c460beedceb63b84e5605a5f`.
The installer verifies archives before extraction. Each probe verifies the
installation inventory and versions before execution, checks it again afterward,
and retains that inventory. Debian 13 supplies the base libc and Python;
this is a supported host profile, not a hermetic operating-system image.

These C probe flags select base AAPCS soft-float transport and ELF32 EABI.
The internal Landin transport is selected separately, as the
[target guide](../../docs/targets.md#cortex-m0-layout-and-abi-planning) describes.
The compiler-generated assembly lane retains external startup/linking test
support. The firmware lane uses compiler-owned reset, vectors and linking. The
general C source surface remains disabled.

## Memory and device map

| Region | QEMU CPU lane | Synthetic Renode peripheral lane |
|---|---|---|
| Vectors | address 0, 48 words / 192 bytes, initial MSP `0x20004000`; Thumb reset address in word 1 | identical probe image convention |
| Flash | machine provides 256 KiB at 0; linker limits probes to 32 KiB | 32 KiB mapped at 0 |
| RAM | 16 KiB at `0x20000000` | identical |
| Probe stack | top `0x20004000`; linker reserves upper 4 KiB | identical; this is a reservation, not a measured stack bound |
| NVIC / SysTick | `0xe000e000`; 32 external IRQ entries | same address; synthetic device uses IRQ0 |
| GPIO | Nordic registers at `0x50000000` | prototype GPIO A at `0x40020000`; mode, speed, alternate-function and image storage, input injection, output set/reset |
| UART | Nordic UART at `0x40002000`, transmitted bytes captured to a file | synthetic divisor at `0x40021000`, received data at `0x40021004` |
| DMA | no prototype DMA | controller status/clear at `0x40026000/04`; stream 5 config/count/peripheral/memory at `0x40026058/5c/60/64` |

The prototype is a sketch combining M0 CPU pressure with vendor-like registers;
it does not identify a real part matching that whole map. The Renode platform
is deliberately named `prototype`, not micro:bit or STM32. GPIO B, unused
streams and unspecified UART registers are absent. Unknown modeled-register
accesses and invalid access directions throw; unsupported bus widths generate
warnings which fail the runner. Explicit halfword support covers the 16-bit
count and GPIO data, without automatic read/modify/write translation.
The linker refuses initialized data (this probe startup only clears BSS), a
wrong vector extent, flash overflow and BSS entering the reserved stack area.

## Why QEMU plus Renode

Current official [QEMU documentation](https://www.qemu.org/docs/master/system/arm/nrf.html)
identifies the micro:bit's M0 and Nordic devices. Selection also inspects the
[pinned SoC implementation](https://github.com/qemu/qemu/blob/98f88efe8f07067667b8d9b1a5ce9551d34036c1/hw/arm/nrf51_soc.c)
and runs the controls below. Device presence does not prove the prototype's
behavior: Nordic GPIO/UART addresses differ, clock registers include stubs,
and this is not a prototype DMA model. QEMU retains the mandatory CPU/startup
role and the derived driver's QEMU obligation is unchanged.

Renode's [official documentation](https://renode.readthedocs.io/en/latest/)
and [peripheral modeling guide](https://renode.readthedocs.io/en/latest/advanced/writing-peripherals.html)
provide composable devices, bus access, IRQ wiring and C# models loaded from
source. Those are useful here because the same firmware can execute against
an explicit, small contract model. An independent host-only register simulator
would not exercise CPU loads/stores and the NVIC together. Extending QEMU's
native device tree would require a separately maintained emulator build.
For this bounded lane, Renode's runtime model loading is the selected route.

Stock STM32 models were evaluated, not assumed faithful from a board list.
The shipped binary identifies source `f1dd1b4af`; its Infrastructure submodule
is `cd4b002aac2398994c4a61a34a8b31b5700facf2`, distinct from the release tag's
submodule. The inspected [DMA implementation](https://github.com/renode/renode-infrastructure/blob/cd4b002aac2398994c4a61a34a8b31b5700facf2/src/Emulator/Peripherals/Peripherals/DMA/STM32DMA.cs)
implements request-driven copies and completion IRQs but tags CIRC, HTIE and
TEIE. It does not supply the required circular reload or half/error behavior.
The [UART implementation](https://github.com/renode/renode-infrastructure/blob/cd4b002aac2398994c4a61a34a8b31b5700facf2/src/Emulator/Peripherals/Peripherals/UART/STM32_UART.cs)
can signal DMA reception; stock platform wiring alone does not establish that
route. `stock.repl` explicitly connects it. `stock.py` demonstrates two received
bytes reaching RAM, completion status/clear, GPIO set/reset and zero remaining
count despite CIRC. Its expected warnings identify tagged CIRC and unclocked
UART reception: this control proves no baud or idle-line behavior.

## Executable routes and limits

| Prototype pressure | Route and current evidence | Limit / where the language covers it |
|---|---|---|
| Reset, zeroed static storage, vector table and kept handlers | `start.S`, `memory.ld`, QEMU GDB initial MSP/PC/vector assertions, step, reset and second boot | handwritten environment startup; Landin sections/keep/entry are compiler-owned firmware |
| Traps, exceptions, timer and wait-for-interrupt | `cpu.c`: SVC, PendSV, SysTick/WFI, IRQ0; `fault_probe` UDF reaches HardFault with IPSR 3 | no cycle timing, every fault class or general priority/nesting proof; generated code and firmware lanes |
| Debugger control | QEMU GDB breakpoint, step, memory/register inspection, resume, reset, rerun; exact log assertions | C/assembly debug only; Landin source debug/stack evidence under Freestanding evidence |
| GPIO whole images, indexed packed fields, AF selection, reserved bits | `peripheral.c`: explicit mask/shift RMW, retained high bits, AF image, set/reset; model input injection | stored image behavior, not electrical pins/pull/speed/alternate routing; packed-language legality is D228's |
| UART configuration and bytes | QEMU exact TX bytes; stock UART-to-DMA control; synthetic `Feed` writes its DR and transfers one supplied byte | synthetic divisor is storage only; no serial line, baud accuracy, FIFO overrun or framing/parity model |
| DMA descriptor, escaping static buffer, enable handoff | `peripheral.c` supplies a static ordinary byte array and descriptor; feed while disabled leaves it untouched | C pointer handoff only; Landin origin refusals and the complete derived driver |
| DMA count, increment, circular wrap and CPU visibility | five ordered feeds into four bytes, checked halfword count 4/2/4/3, wrap replaces first byte, CPU reads the transferred bytes | model serializes byte copy before count/status; no asynchronous bus races or cache-coherence proof |
| Completion, half-transfer and transfer error | model status `0x20/40/80`, enables in config bits 1/2/3, NVIC IRQ0, firmware records three IRQs and clears status | synthetic status convention follows sketch stream 5; not stock STM32 status layout |
| Critical section and event collection | PRIMASK masks delivery while DMA updates RAM/count; restoring it permits pending completion handler | proves this model's mask/delivery behavior, not Landin happens-before; D227 |
| One-clears and access modes | firmware clears pending bits; `model-checks.py` proves writing zero preserves error, one clears it, read-only/write-only/unknown accesses refuse | other access modes are absent; normative register rules are D228's and the generated device fixtures' |
| Bad descriptor, bounds, unsupported direction | model controls reject bad destination, count above 65535 and unsupported direction; no transfer occurs | no physical bus fault/overrun timing; driver `buffer_empty`, `buffer_too_big`, `bad_baud` and recovery execute in the derived driver over this lane |
| Ordinary-slice read, head/tail and short output | current lane exposes count and circular RAM for the complete derived driver | the derived driver executes its `available`/`read` cases and failure oracles; this environment is not that driver |
| SVD-derived types, encoded values, named refusals | checked-in model and map are explicit device inputs; malformed access controls already execute | D228 packed encodings; D231 `noreturn`; generated `.ldn` device fixtures; general generator stays with companion tooling |

Feeds happen while virtual execution is paused, followed by a fixed 1 ms
virtual run and a checked firmware stage. No host sleep decides firmware
success. Only the debugger socket startup uses a bounded readiness poll.
The [Renode time framework](https://renode.readthedocs.io/en/latest/advanced/time_framework.html)
is execution scheduling, not physical bus timing. The model's transfer order
is an explicit harness assumption. The ordinary C buffer is reloaded across
opaque memory-clobber barriers; that is no definition of Landin DMA visibility.
D227 defines races, tearing, atomics, compiler/hardware barriers and cache
maintenance, with models for behaviors this cacheless M0 profile cannot expose.
Supplemental hardware can test actual bus/interrupt timing, electrical behavior
and a real device's DMA visibility; it cannot replace the emulator gates or
by itself establish language concurrency semantics.

## Reproduction and evidence

On the documented native Linux host, with Python 3 and `dpkg-deb`:

```sh
python3 environments/cortex-m/setup.py
python3 environments/cortex-m/test.py
./scripts/build.sh
python3 environments/cortex-m/run.py \
  --refine compiler/ada/build/linux-amd64/debug/bin/refine \
  --output /absolute/new/evidence-directory
```

The default private tool root is `~/work/.cortex-m`; `--tools` selects another
installation. Setup refuses an existing root; install deliberately into a new
root to change tools. No sudo, host package replacement, Linux container on
the Mac, Nix job or compiler dependency is introduced. Missing tools, wrong
pins/host, subprocess failures, deadline expiration, model errors, unexpected
warnings and absent assertions all fail. Renode returning zero after a script
error is insufficient: the runner requires the unique final marker and scans
its log for failures. The stock control allows only its two known warnings.

After Renode exits, the runner removes only its verified empty
`renode.config.lock` coordination file before inventorying evidence. Native
export omits lock files, so recording that transient file would correctly
fail export verification. Nonempty or linked replacements fail instead.

Each subprocess has a 30-second deadline, GDB 20 seconds, and QEMU startup
three seconds; timeout cleanup terminates the owned process group, escalating
after two seconds. Each run needs a new output directory and retains failure
logs as well as successes. Evidence includes exact commands, version replies,
installed file hashes, input hashes, linker maps, ELF headers/attributes, sizes,
ELFs, generated GDB/Monitor scripts, logs, UART bytes and `result.json`.

The retired Linux acceptance's documents job executed both the failure
controls and these live probes from the same committed archive as every native
job, and `job.py` copied its `cortex-m` evidence into the exported,
hash-verified bundle. Thus the annotated dual-native approval bound the
environment's actual run, not only this document or a development transcript.
Darwin retains native compiler/workload/LLDB evidence and does not impersonate
this probe host. The environment's debugger control checks ran at routine
scope with debugger coverage, which is not the full milestone matrix.

The retained development result is indexed by [validation.json](validation.json).
Its successful probe images contain 643 and 836 text bytes respectively, no
initialized data and 24 BSS bytes each. These are environment-control sizes,
not measurements of the future Landin driver or a stack-usage guarantee.

## Layout and ABI evidence

The same mandatory `run.py` now also builds `probes/abi.c` and `abi.S` with
the original pinned flags, startup and memory limits, then executes them in
QEMU. Renode remains a separate peripheral lane; its result is never counted
as ABI evidence. No library or tool pin changes. The additional ELF,
disassembly, macro dump, GDB script/log, measured JSON and both layout contract
inputs are retained in the existing exported `cortex-m` directory. The original
Renode lock-file cleanup and its regression controls remain required.

Three independent comparisons meet:

1. The Ada `cortex ABI` suite computes scalar, aggregate, variant, evidence,
   any and multiple-result layouts and physical call plans from compiler
   packages, comparing with `compiler/tests/cortex-m.contract`. It also checks
   eight existing source fixtures through lowering and entry/direct/indirect
   planning under Cortex-M0 and synthetic-32, comparing detailed neutral IR.
   These are compiler-host tests, not target execution.
2. `abi.py` compares the contract with **every original synthetic-32 row** in
   `layout.targets`, without regenerating that golden. GCC independently lays
   out C control structures, unions and tables. QEMU/GDB reads their emitted
   measurements and compares them with the contract. Static assertions also
   cover data/code pointers, slices, ILP32, plain-char policy and 64-bit
   alignment. The C union is a representation control, not C semantics for
   a Landin variant.
3. Independently written assembly captures actual GCC-produced r0–r3,
   incoming sp and stack argument words. Assertions compare meaningful words
   with the compiler plan for double-word gaps, split 12-byte records, narrow
   stack arguments, soft floats, float-only records, promoted varargs and
   result-pointer displacement. Separate hand callers check GCC callees, and
   C callers check hand returns/callbacks, including 3/4/5-byte records and
   integer/double 64-bit results. Padding and skipped registers are unspecified
   and are not asserted as values.

The Landin convention has a separate handwritten witness: hidden aggregate
result and direct/parent evidence addresses, an address-passed value, a stacked
u64, successful and failing r12 outcomes, r0/r1 scalar results, multiple-result
storage, and erased data/table dispatch through Thumb code pointers. GDB checks
the nested r11 frame records, saved lr, chain termination and aligned sp;
firmware checks callee-save registers and restoration. These execute the
selected contract with real M0 instructions; they are not compiler-generated
Landin calls or Landin source-debugging acceptance.

Compiler refusal/boundary controls cover wrong targets, unavailable C and
emission capabilities, narrow extension, the four-byte C result threshold,
empty C carriers, unpromoted varargs, declared C errors, stack-budget rounding
and a target-overflowing argument without materializing it. Source checks
cover pointer-sized integer/address overflow and the array byte-extent boundary.
The Python controls refuse duplicate/missing/invalid contract rows, synthetic
mismatches, missing markers, subprocess errors and timeouts. They preserve the
original lock cleanup refusal for linked or nonempty replacements.

Every subprocess retains the original deadlines (GDB 20 seconds, build/tools
30, debugger readiness three) and owned process-group cleanup. The final
exact-archive Linux documents job repeats all lanes and retains tool/input
hashes alongside the new ABI artifacts. Its ordinary dual-native approval binds
these results to the same revision as the hosted checks. Development results
are indexed separately in `abi-validation.json`; `validation.json` keeps its
historical meaning as the CPU and peripheral environment's record.

These bounded probes establish neither floating arithmetic helpers, general
unwind support, a complete C language ABI surface, firmware stack bounds,
physical hardware behavior nor a Cortex-M compiler backend. The backend
consumes the plans with native selection and frame code, compiler-owned
firmware implements image placement and startup, and the freestanding evidence
below establishes the bounded Landin debugging and stack evidence. D227 and
D228 cover concurrency and invalid packed encodings.

## Memory evidence

The mandatory `run.py` path additionally executes `memory.py`, without changing
the CPU, peripheral, independent ABI or lock-cleanup obligations above.
`probes/memory.c` executes GCC's scalar 8/16/32-bit atomic loads/stores, DMB,
DSB and ISB, nested PRIMASK save/restore, pending interrupt exclusion and
ordinary RAM publication in both directions across handler delivery. QEMU/GDB
requires result `0x630` and no fault. These are independent C/assembly controls,
not compiler-generated Cortex-M code. GCC separately compiles an atomic RMW
control to an object whose unresolved `__atomic_fetch_add_4` is asserted; no
helper is linked or inferred as a Landin capability.

`memory_model.py` explores a finite FIFO store-buffer machine and compares its
fenced outcomes with an independently enumerated SC permutation oracle and
a separate reads-from/SC-fence constraint oracle. It checks twelve
release-sequence source cases, including plain-store interruption. It
also enumerates payload/notification propagation with and without the device
ordering premise, split-byte tearing, DMA progress while IRQ delivery is
masked, and a write-back cache-line model. The cache controls require stale
reads without invalidation, visible bytes after invalidation, destructive
post-receive cleaning, and loss of an unrelated dirty byte on a shared line.
These assertions test the stated abstractions, not the complete Arm model or
cache instructions. No absence of a weak emulator outcome counts as proof.

The original Renode lane remains the executable DMA witness: static ordinary
byte storage, circular overwrite, count/status updates and delayed IRQ while
masked. Feeds are serialized at stopped virtual-time boundaries. D227 supplies
the language contract; the model supplies only its explicit device premise.
A cached profile needs platform-specific maintenance, cache levels/aliases and
visibility-point evidence before it can be admitted. M0 has no cache and supplies
none of that evidence. Hardware testing stays supplemental.

Each new subprocess uses the existing 30-second tool and 20-second debugger
limits, three-second readiness deadline and owned process-group cleanup.
Commands, logs, ELF/map/disassembly, generated controls and GDB input, tool/input
hashes and `memory-model.json` are retained under the same exported `cortex-m`
directory. Native Linux and Darwin separately execute the Landin scalar and
pthread ABI fixtures over their selected optimization profiles. Those results
are compiler-generated hosted execution, not embedded or model evidence.

## Image and access controls in development

The mandatory `run.py` path executes `packed.py` and `packed_native.py`. It preserves every
earlier lane and the verified empty Renode lock cleanup. The new
`EncodingPeripheral.cs` is a separate, synthetic peripheral at `0x40030000`:

| offset | access | explicit device contract |
|---|---|---|
| 0 | normal 32-bit read/write | initial `0xa50000f0`; bits 8..31 must retain `0xa50000` |
| 4 | destructive 32-bit read | returns initial `0x9b`, then zero; writing refuses |
| 8 | write-only 32-bit command | bits 8..31 must be zero; reading refuses |
| 12 | 32-bit status and one-clears command | initial `0xf3`; ones clear, zeros preserve; written bits 8..31 must be zero |
| 16 | normal 16-bit count | initial `0xffff`; word accesses and other widths refuse |
| 20 | normal 32-bit read/write | initial `0xffffff00`; written bits 8..31 must be one |

Pinned GCC compiles `probes/packed.c` to real M0 instructions. Its ordinary
unsigned images enumerate all byte inputs, four two-bit indexed elements and
every three-bit encoding of the independently tabulated named set 0/1/4.
Firmware then performs the device accesses. `packed.py` asserts a literal
16-event oracle, including each direction, width, address and value; that
oracle is neither generated from the C code nor derived from the C# model.
Reading the model's final properties does not access its emulated registers.
Eight invalid direction/width/reserved operations must raise without adding
an event. A destructive read is consumed once locally; a second explicit read
returns zero. Write-only and one-clears commands issue no preparatory read.
The count is never widened to the neighboring halfword.

The runner retains the generated platform, Monitor and assertion scripts,
ELF/map/disassembly, trace, tool identities, exact commands and hashes under
the same exported evidence directory. The existing 30-second subprocess limit,
fixed virtual-time execution and process-group cleanup apply. The new
initial firmware had 660 text bytes, zero data and 16 BSS bytes before the
write-one reserved-bit register was added; current sizes are retained in
`size-packed.log`. These are control sizes,
not Landin firmware or stack bounds. `packed-validation.json` indexes the
successful development run and its independent local copy.

The C firmware is one independent control. `packed_native.py` separately
compiles `probes/packed-native.ldn` using the actual native Linux compiler at
six optimization/specialization profiles. Its C peer only transports explicit
width/address/value commands and replies; it performs no field arithmetic,
encoding validation or expected-image calculation. The native Landin program
computes packed indexed updates and images, then Renode executes each bus
transaction against the same device. Every run must match the literal
16-event oracle and final register values. This is compiler-generated hosted
execution against an actual peripheral harness, not compiler-generated M0
firmware. The Ada algebra suite and abstract oracle remain distinct evidence.

At each of the same six profiles, `probes/packed-native-hole.ldn` starts a
fresh peripheral, reads the destructive register once, and extracts its
unnamed mode inside `unchecked`. The independently specified reply is `0x9b`
and the complete trace is `r32:4:0000009b`. The native process must terminate
with SIGILL (exit 132 through .NET's process API), without a second access or
the normal completion reply. Discarding the extracted value cannot remove
validation. The transport disables core dumps; it still contains no encoding
logic. This negative compiler-generated lane complements the positive raw
copy of the same invalid image and the independent C membership control.

The runner requires `--refine`, retains its SHA256 and `--identify` output,
the native GCC identity, Landin/C input hashes, assembly, executable, transport
commands, Renode trace and assertions. Compilation is bounded to 60 seconds;
the Renode process group and native peer have a 30-second outer bound and a
17-command positive limit; the negative case permits exactly one command.
Both success and failure paths remove only a verified empty
Renode lock file after exit. Tool inventories are checked before and after
execution. Native acceptance builds the committed debug compiler in its
documents job and retains this lane in the existing verified `cortex-m` export.
No Cortex-M emitter or generated vendor fixture programme is implied.
The original DMA lane continues to test ordinary externally written buffer
storage under D227's explicit serialized-device premise.

The current official
[CMSIS-SVD register description](https://open-cmsis-pack.github.io/svd-spec/main/elem_registers.html)
distinguishes access permission, modified writes, read actions and reset
metadata. Its
[format guide](https://open-cmsis-pack.github.io/svd-spec/main/svd_Format_pg.html)
identifies omitted fields as reserved, without supplying one universal
reserved-bit write policy. The
[Arm Cortex-M0 user guide](https://documentation-service.arm.com/static/5ea6ce5e9931941038def8c1)
requires aligned accesses for this core. These documents were consulted on
2026-09-16; they inform the explicit control contracts, not an assertion that
this synthetic map describes vendor hardware. The generated device fixtures
keep their own provenance, and general SVD tooling remains companion-tool work.


## Compiler-generated execution

`run.py` preserves every earlier lane, then requires `backend_acceptance.py`.
The same installed tool inventory is verified before and after all lanes.
`backend/corpus` retains the complete shared runtime/ABI inventory from
`compiler/tests/cortex-m/corpus.json`. Every ordinary runtime case uses the
four inherited profiles; specialization cases add none/all and speed/all.
Ten explicit 32-bit/architecture counterparts retain the original hosted
sources and independent numeric expectations. `counterparts.json` records
exact reviewed textual differences, checked before execution. Missing/new
fixtures or counterpart drift fail the supervisor. Compiler-verdict and
neutral-IR golden fixtures retain their native compiler-host checks; they have
no independent execution oracle.

The corpus keeps source refusals, the disabled general C surface and physical
image limits distinct from executed programs. Every whitelisted image-limit
profile is still compiled and attempted within the materialization guard;
when it fits, it must execute successfully. Only a demonstrated oversized
frame/static extent or the selected linker's flash/RAM overflow can produce a
limit record. Missing helpers, bad instructions, wrong results and timeouts
cannot. The original multi-gigabyte image and oversized hosted stress programs
retain their original oracles and recorded image-limit dispositions. Their
unchanged hosted execution does not become a Cortex execution claim.

`backend-start.S` and `backend-memory.ld` are small external test support:
reset/vector words, bytewise initialized-data copying, BSS clearing, a stack
watermark and result/fault observation. The compiler emits ordinary routines,
not reset or interrupt entries. The map remains 32 KiB flash, 16 KiB RAM and
4 KiB stack. A single routine requiring more than that stack reservation is
recorded as a profile limit. Returned SP, terminated r11 chain, callee-saved
sentinels and a bottom watermark are asserted. The lowest changed watermark
word is retained as an observation, explicitly not a proved stack bound.
Freestanding evidence below records measured stack/firmware and source debugging.

QEMU uses exactly `microbit`, single-threaded TCG and a loopback-only GDB port.
Each program has a bounded startup wait and a 20-second debugger deadline;
process groups are stopped on failure. Expected traps require HardFault at
the emitted UDF #1, not merely any fault. Normal results use the shared fixture's
exit-byte oracle and require r12 zero. Build reports, sources, compiler identity,
requested runtime helpers, the exact v6-M/nofp archive hash, empty unresolved
symbol set, ELF attributes, map, disassembly and commands are retained.
Assembly expansion is bounded before invoking GNU as, including nested compact
repetitions, so a multi-gigabyte source image cannot materialize in the harness.

Independent controls are kept separate:

| Evidence | What actually executes |
|---|---|
| `backend-abi.ldn` with `backend-abi.S` | Generated entries called by literal assembly ABI oracles: double-word register gap/stack tail, caller-owned multiple and aggregate results, aliased value/inout transport, separate failure status, indirect Thumb address and runtime helpers |
| Frame stepping | GDB observes the old r11 until both record words exist, then the published record; checks nested and leaf links, return addresses and aligned SP |
| `backend-veneer.ld` | The generated leaf is copied to SRAM by the external harness, forcing a real GNU Thumb call veneer over the flash/RAM gap; frame and result assertions remain identical |
| `backend-boundaries.ldn` | Generated accesses across frame/immediate boundaries through a 2304-byte array, nontrivial literals and a long conditional transfer |
| `backend-instructions.S` | Independent maximum literal/branch/conditional encodings execute; separate one-past-limit and forbidden high-register/Thumb-2/FPU/exclusive forms must be rejected by GNU as |
| `backend-words.ldn`, signed/unsigned multiply trap controls | Literal multiword product/division/remainder boundaries, including signed minimum and maximum unsigned product, plus checked overflow reaching UDF #1 |
| `backend-symbols.ldn` | Source helper-name collisions, assembly register-like names and direct/indirect code-pointer identity |
| `backend-byte.ldn` | Five exact byte transactions, independently expected as `r8:18:a5;r8:18:00;w8:19:41;w8:1a:02;r8:1a:f1`; no widened/destructive extra read or hidden write-only read |
| `backend-memory.ldn` | Generated D227 8/16/32-bit atomic loads/stores, volatile operations and barriers, with literal values independent of selection |
| `packed-cortex.ldn` and `packed-cortex-hole.ldn` | Actual generated M0 instructions drive the existing EncodingPeripheral model. The unchanged literal 16-event trace pins halfword/word widths, counts, destructive reads, one-clears and reserved policies. The hole path performs exactly one destructive read before trapping. |
| `backend-dma.ldn` | Generated packed config/count/status operations publish an ordinary slice to PrototypePeripheral; four externally supplied bytes precede completion. A half-complete observation does not permit return. After completion and a device barrier, ordinary reads sum the bytes to 174. Count accesses are exactly one halfword write and one halfword read, with no word count access. |

ABI, memory, frame/boundary and all four peripheral controls run all six
profiles. The standalone encoding control remains independent assembly.
PrototypePeripheral's added count-width telemetry leaves its earlier C control
and interrupt behavior intact. Renode remains a synthetic device lane and its
verified empty lock file is removed before evidence inventory/export. The
hosted Landin packed-image transport remains separately identified and required.

For focused development on the supported native Linux host:

```sh
python3 environments/cortex-m/backend_corpus.py --refine PATH_TO_REFINE --output NEW_DIRECTORY --case runtime/r640-packed-hole --profile speed-all
python3 environments/cortex-m/backend_controls.py --refine PATH_TO_REFINE --output NEW_DIRECTORY
python3 environments/cortex-m/backend_peripheral.py --refine PATH_TO_REFINE --output NEW_DIRECTORY --all-profiles
```

Filtered commands are development feedback. The retired exact-revision native
acceptance ran the complete mandatory path and exported
`artifacts/cortex-m/backend` with all prior evidence; nothing runs it now, and
[`ROADMAP.md`](../../ROADMAP.md) schedules these lanes into the gate. The [target guide](../../docs/targets.md#cortex-m0-assembly-implementation)
records instruction, allocation, ABI, runtime-helper and memory decisions.
Language startup/linking/sections/interrupt/naked/inline-assembly surfaces,
the freestanding core and `noreturn`, the checked-in device fixtures and the
complete driver each have their own lane below. General SVD generation stays
with its companion tool. No scheduler, interrupt-masking abstraction, C source
expansion or new DMA ownership model is introduced.

## Compiler-owned firmware

`firmware.py` is a mandatory addition to `run.py` and its existing evidence
export, separate from every earlier lane. It invokes the compiler with
`--target=cortex-m0 --firmware-entry=start --emit=exe` and the pinned Arm GCC
path. The compiler generates reset, vectors and the linker script; neither
`backend-start.S` nor `backend-memory.ld` supplies these semantics. The older
533-fixture corpus, 72 generated controls and independent controls remain
mandatory and retain their own startup and applicability records.

The fixed image remains 32 KiB flash, 16 KiB RAM and a 4 KiB stack reservation.
D229/[1990] specify the source/request, convention, section and assembly
contracts. Initialized data and `.ramtext.*` have separate flash load and RAM
execution addresses; compiler reset copies both and clears BSS. Immutable
images stay in flash. The compiler retains `.s`, `.o`, `.ld`, `.map` and ELF;
the probe also retains readelf sections/program headers/relocations/attributes,
disassembly, symbols, independently decoded load extents, tool identities,
commands, timeouts, debugger assertions and device traces. Empty undefined
symbols and explicit runtime-archive identity supplement map-based closure
checks. The archive must be the pinned `thumb/v6-m/nofp/libgcc.a`.

The six optimization/specialization profiles each exercise:

- Two fresh builds, each cold-booted and reset again after poisoning RAM.
  Assertions observe initial SP/reset Thumb identity, zero reserved vectors,
  copied data, cleared BSS, source entry and the entry-return HardFault trap.
- Generated SVC, ordinary helper and higher-priority nested IRQ0, checking
  hardware frames, EXC_RETURN, every preserved register, flags, r11 records,
  eight-byte stack alignment and source results. A painted 4 KiB stack retains
  an untouched lower guard; its observed write extent is evidence for this
  small execution, never a whole-program bound.
- Naked source entry selecting PSP, naked SVC returning through EXC_RETURN,
  and a specialized generic opaque-assembly memory write with live values.
  A separate naked-fallthrough image reaches its appended trap without a frame.
- Copied RAM code and RAM handler, flash/RAM veneers, integer libgcc helpers
  and private success/failure transport through checked ordinary calls.
- Four Renode runs: DMA IRQ0 half/completion notifications, packed register
  images, invalid-encoding HardFault and byte transactions. The latter three
  execute ordinary generated programs inside a generated SVC handler. Expected
  values and exact access traces remain independent device-side observations.
  DMA continues with PRIMASK set; half notification is not completion; only
  observed completion plus the explicit boundary precedes ordinary slice reads.

This adds 37 QEMU sessions (36 generated, one independent C/assembly control)
and 24 generated Renode runs. The independent control establishes PSP/MSP,
four-byte interrupted SP with hardware alignment padding, nested exception
returns and C callee saves independently of Landin emission. Ten retained
failure programs cover flash overflow, stack overlap, materialization budget,
missing symbol, invalid instruction encoding, later-core instruction, wrong
vector placement, owned reset slot, invalid entry and reserved symbol.
Source unit controls additionally refuse incompatible conventions/calls,
invalid naked bodies, duplicate directives, unavailable slots and hosted use.

Equivalent inputs in fresh directories must produce byte-identical ELF,
object, assembly, script and map for every generated scenario/profile. ELF
identity includes sections and relocations. Log paths, TCP debugger ports,
command durations and host/compiler identity records intentionally vary and
are retained as execution metadata, not image bytes. Renode lock cleanup and
failure-oracle requirements are inherited unchanged from `Run.renode_script`.
The new records are under `artifacts/cortex-m/firmware` in accepted evidence.

For a focused development run on the supported Linux host:

```sh
python3 environments/cortex-m/firmware.py --refine PATH_TO_REFINE --output NEW_DIRECTORY --all-profiles
```

The contract was checked against Arm's [ARMv6-M Architecture Reference Manual DDI0419E](https://documentation-service.arm.com/static/5f8ff05ef86e16515cdbf826),
[Cortex-M0 Devices Generic User Guide](https://documentation-service.arm.com/static/5ea6ce5e9931941038def8c1),
[AAPCS32 and AAELF32 2025Q4](https://github.com/ARM-software/abi-aa/releases/tag/2025Q4),
the selected-device [nRF51 reference manual](https://docs-be.nordicsemi.com/bundle/nRF51-Series/raw/resource/enus/nRF51_RM_v3.0.1.pdf),
and GNU binutils' [section flags](https://sourceware.org/binutils/docs/as/Section.html),
[retention](https://sourceware.org/binutils/docs/ld/Input-Section-Keep.html),
[load addresses](https://sourceware.org/binutils/docs/ld/Output-Section-LMA.html)
and [Arm veneers](https://sourceware.org/binutils/docs/ld/ARM.html).
Executable controls establish behavior on the pinned microbit/ARMv6-M profile;
they do not generalize to another core, board, real peripheral or timing model.
Core/CPU-library packaging and `noreturn`, the generated fixtures, the complete
driver, source debugging and complete measured stack/firmware evidence have
their own lanes below. General SVD generation remains companion-tool work.

## Freestanding library consumers

`freestanding.py` compiles rooted ordinary modules through the same generated
reset/vector/linker path. It is mandatory after `firmware.py` in `run.py`, with
its own `artifacts/cortex-m/freestanding` export directory. The old 533-fixture
backend corpus and the firmware lane's 37 QEMU/24 Renode sessions and 270 comparisons are
unchanged. The shared inventory adds two explicitly restricted hosted C peers
for D231/D232; neither replaces an inherited case. The declared additional lane
has eleven consumers at six profiles: 198 QEMU sessions, six Renode runs and 336
fresh-directory comparisons. Panic consumers additionally compare optional
source-map bytes. A focused run is development feedback, not complete acceptance.

| Consumer | Independent observation |
|---|---|
| `core-cpu.ldn` | Poisoned initialized data/BSS are repaired by compiler reset; scalar assembly preserves live values, generic/discarded operations execute, PRIMASK restoration handles enabled/disabled entry, nesting and deferred early return. Masked pending IRQ wakes WFI before handler entry; exception return restores volatile/callee registers, flags, stack alignment, r11 and private status. |
| Default panic derivative | The same source with the hook removed traps on arithmetic, violated nonreturning return and firmware entry return. It retains neither a panic latch nor a source map; the independent hardware exception frame points at UDF. |
| `core-panic.ldn` | Seventeen independently expected kind/site paths per profile, including conversion/bounds/arithmetic, alignment, packed membership, nonnull pointer construction, reserved bits, UTF-8 decoding, recursive panic, forced nonreturning-callee return, normal firmware-entry return and a real NVIC handler. Poisoned data/BSS, no later actions, stack bounds and off-target source lookup are checked. |
| `core-noreturn.ldn` | Six cold boots select direct, generic, static/erased evidence, deferred and recovery paths; independent memory assertions check completed stores, skipped later actions/cleanup and retained kept data. The expected frame-chain depth and each previous-r11/incoming-LR record are checked at every selected nonreturning path. Nonreturning entry and 200–376-byte observed stack writes execute in the fixed profile. |
| `core-pool.ldn` | Misaligned caller backing yields aligned slots; zero-size allocation consumes one slot, an oversize request preserves state, exact free permits address reuse, exhaustion preserves live values and valid frees restore zero live slots. Raw writes initialize bytes before reading them. |
| `core-zero.ldn` | Zero-sized vector elements retain maximum u32 `usize` capacity, one logical element and zero arena byte consumption; release follows the existing provider contract. |
| `core-vec.ldn` | Successful reserve/push followed by injected exhaustion preserves capacity, length and values. Byte-count overflow refuses before allocation and release remains idempotent. |
| Inherited `core-mem-allocators`, `core-mem-arena-boundaries`, `core-mem-raw-storage` | Original status-42 oracles run from compiler startup; only the already-reviewed Cortex raw-storage counterpart supplies its 32-bit expected pointer extent. The complete original corpus inventory is checked before using these sources. |
| Library-derived DMA | The unchanged firmware-lane peripheral oracle checks independent register state, exact halfword count accesses, handler delivery, half/completion states, externally written ordinary storage and subsequent ordinary reads. Only CPU/barrier calls are replaced with the new library surface. |

The runner copies only its declared `core/mem`, `core/vec`, `core/pool` and
`core/cpu`/`core/panic` import closure. Maps must list the generated object and pinned
`thumb/v6-m/nofp/libgcc.a`, with optional GNU linker stubs and no other LOAD
input. Closure records include source hashes, selected archive members, all
symbols and decoded image extents. Undefined symbols and hosted runtime names
fail. This permits private compiler/toolchain helpers, not general C source.
Per-command timeouts, process cleanup, independent failure markers and Renode
lock removal use the existing supervisor unchanged. Standalone failures retain
their logs, artifacts and failed result record.

For development on the supported Linux host:

```sh
python3 environments/cortex-m/freestanding.py --refine PATH_TO_REFINE --output NEW_DIRECTORY --case cpu
python3 environments/cortex-m/freestanding.py --refine PATH_TO_REFINE --output NEW_DIRECTORY --all-profiles
```

PRIMASK/WFI premises follow the official Arm architecture and M0 guides cited
above; argument/result and linker-stub obligations retain the cited AAPCS32,
AAELF32 and GNU contracts. Actual controls run on ARMv6-M. WFI is not a
completion proof and masking does not stop DMA. The selected profile remains
32 KiB flash/16 KiB RAM/4 KiB reserved stack. Stack paint measures observed
writes only. [The core guide](../../core/README.md) documents the public surface;
`ROADMAP.md` owns the successor measurement gates.

## Checked-in generated devices

[The device guide](../../devices/README.md) records pinned RP2040 provenance,
manual corrections, regeneration, public interfaces and unsupported metadata.
`devices.py` follows all inherited probes in `run.py`, retaining its own
`artifacts/cortex-m/devices` evidence. Five firmware consumers at the six
inherited profiles supply six QEMU sessions, 24 generated Renode runs and 168
deterministic artifact comparisons; a separate C/assembly control adds one
Renode run. Seven precise source refusals and independent vendor-header/literal
oracles run without network or companion tooling. The 30 selected registers
are vendor data, not a faithful RP2040 model or a larger execution board.

```sh
python3 environments/cortex-m/devices.py --refine PATH_TO_REFINE --output NEW_DIRECTORY --case images
python3 environments/cortex-m/devices.py --refine PATH_TO_REFINE --output NEW_DIRECTORY --all-profiles
```

Compiler-owned reset/vectors/linker scripts remain distinct from the independent
C/assembly startup. The new synthetic model asserts exact word transaction
traces, FIFO reads, commands and bounded interrupt/DMA handoff. Its feeds and
half notification are explicit premises; no circular-buffer or physical timing
claim follows. Linker closure, stack paint and optional panic maps are retained
with the fixed map and runtime contract. The new runner uses unchanged process
and Renode lock cleanup. The complete derived driver, source debugging and full
measurements have their own lanes below.

## Complete derived driver

[`compiler/tests/driver/DERIVATION.md`](../../compiler/tests/driver/DERIVATION.md)
is the subordinate declaration/finding map and public driver contract.
`driver.py` runs the complete application and a public-API client through the
compiler-owned firmware path, across the six inherited profiles. QEMU executes
two poisoned resets per linked program, checking data/BSS, vectors, immutable
flash and application RAM-code copying. Renode's separate `driver.repl` and
`DriverPeripheral.cs` execute GPIO, timer, UART, interrupts and ordinary-slice
DMA consumption, loss detection, stop and recovery. Existing models and
C/assembly/hosted transport controls retain their separate identities.

The model uses unchanged generated RP2040 images/accessors at explicit synthetic
bases. Its finite, non-reloading count and EN-clear/BUSY-clear drain protocol
are not RP2040 hardware claims. Masked/coalesced notifications cannot hide
producer progress. More-than-capacity unread data fails with sticky `overrun`
and explicit discard/restart. Device faults require external maintenance; an
eight-poll stop timeout preserves the storage lifetime obligation. The
application executes echo/GPIO commands, periodic partial-data polling, overrun
recovery and observable terminal policy. Detailed premises and limitations are
in the derivation.

Evidence under `artifacts/cortex-m/driver` retains compiler/tool identities,
source roots, assertions, timeouts, QEMU/GDB and Renode scripts, startup/linker
inputs, ELF/map/assembly/object/disassembly/relocations, private runtime closure
and fresh-build comparisons. NOLOAD BSS has a RAM LMA, checked independently
from ELF headers; the original memory map is unchanged. Stack paint is an
observation, not a worst-case bound. The shared runner still rejects unexpected
model warnings and removes only the exited Renode process's empty lock.

For focused development on the supported Linux host:

```sh
python3 environments/cortex-m/driver.py --refine PATH/TO/refine \
  --output /ABSOLUTE/NEW/EVIDENCE --profile size-auto --case protocol
```

Use `--all-profiles` for this complete lane. Normal acceptance invokes it
through `run.py`, preserving every earlier mandatory lane. Source refusal
checks are also safe compiler-host feedback via `compiler/tests/driver/check_sources.py`.

## Freestanding evidence

The mandatory `run.py` entry invokes `evidence.py` after every inherited lane.
It builds the complete application, protocol client and layout control with
`--target=cortex-m0 --firmware-entry=start --emit=exe --debug=lines` in all six
optimization/specialization profiles. The [Cortex debugging contract](../../docs/targets.md#cortex-source-debugging)
is line/function debugging with ordinary-frame CFI; full variable/type debug
remains refused. QEMU and Renode run source breakpoints, stepping and call-stack
assertions, including imported core/device code, copied RAM code, veneers,
interrupts, generic/specialized allocation, noreturn and panic paths. Separate
symbol selection refuses stale executable, assembly, table and source inputs.

`scripts/cortex_debug.py` reads ELF32 headers directly. Flash is the highest
physical end of a nonempty PT_LOAD payload, measured from flash address zero,
including vectors, gaps, immutable data, private helpers, veneers, initialized
RAM and RAM-code load images. Static RAM is the highest RAM PT_LOAD memory end
minus `0x20000000`, including alignment and zero-fill. Segment payload sums and
section/symbol extents are retained separately, so neither ELF file size nor a
sum that omits alignment substitutes for the occupied extents. Linker maps
retain the exact compiler object, pinned private archive members and linker
stubs. Section flags and file ranges establish that debug metadata is not
loaded. Debug and nondebug LOAD contents/addresses/zero-fill extents must match.

`resources.py` executes the unchanged complete application through cold boot,
partial and wrapped reads, coalesced half/full notifications, delayed drain,
overrun/discard/restart, later successful echo, timeout, open failure, external
repair-required failure and a complete finite 65535-byte epoch. The epoch
services each 256-byte batch before the next, checks every cumulative count,
echoes the final short read and then observes exhaustion/restart. The separate
protocol client preserves its independent exact transaction and unsafe-source
oracles; these application scenarios do not replace it.

Stack paint reports the lowest changed byte, not a worst-case bound. A retained
disassembly-derived hook list observes every emitted SP-changing instruction's
successor and every function entry, including private helpers and veneers.
`StackObserver.cs` reads SP, frame/LR and IPSR on the host; it adds no firmware
instructions, storage or device reads. Its minimum retains the actual ordinary
frame records and stops following an EXC_RETURN record. Guards, written extent,
reserved extent, scenario and sample counts are retained. Hardware exception
stacking is observed at handler entry. The independent `stack-control.S` uses
external startup, deliberately reserves 256 unwritten bytes, then exercises
36-byte aligned exception entry, 8 software-save bytes and 32-byte nested
entry. QEMU register assertions and the Renode observer independently distinguish
256 reserved bytes from 80 painted bytes. Application measurements do not
claim every possible interrupt arrival, nesting, future input or stack bound.

The observer selects one-instruction Renode translation blocks and samples
the retained address set through a block-begin callback. This observes the
successor of every decoded SP mutation without inserting breakpoint hooks
into copied RAM code. The fixed Cortex profile and firmware bytes are
unchanged; these are emulator observation settings, not target cache or
scheduler interfaces. Every process has a bounded timeout and failure record;
Renode lock cleanup remains mandatory.

Artifacts under `artifacts/cortex-m/evidence` retain sources, identities,
commands/assertions/timeouts, ELF/object/assembly/linker/map/disassembly/debug
records, closure and resource JSON, source-selection failures, measured SP/frame
snapshots and repeat-emission comparisons. Debug CUs retain their compilation
directory, so deterministic debug comparisons repeat within that directory;
relocation does not imply identical source identity. Acceptance binds the
entire artifact tree to its committed archive. Physical board testing remains
supplemental and is not claimed by these emulator lanes.
