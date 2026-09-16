# Cortex-M execution profile

ROADMAP.md R6.10 owns the selection and completion evidence. This environment
runs small C/assembly controls, not Landin output. R6.20 adds layout and ABI planning with independent controls below; later
items retain the memory model, encodings, backend and firmware startup.

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
R6.20 separately selects the internal Landin transport described in the
[target guide](../../docs/targets.md#cortex-m0-layout-and-abi-planning).
The compiler describes Cortex-M0 layout but has no Cortex-M emitter.

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
role and R6.90's QEMU obligation is unchanged.

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

| Prototype pressure | Route and current evidence | Limit / semantic owner |
|---|---|---|
| Reset, zeroed static storage, vector table and kept handlers | `start.S`, `memory.ld`, QEMU GDB initial MSP/PC/vector assertions, step, reset and second boot | handwritten environment startup; Landin sections/keep/entry R6.60 |
| Traps, exceptions, timer and wait-for-interrupt | `cpu.c`: SVC, PendSV, SysTick/WFI, IRQ0; `fault_probe` UDF reaches HardFault with IPSR 3 | no cycle timing, every fault class or general priority/nesting proof; R6.50/R6.60 |
| Debugger control | QEMU GDB breakpoint, step, memory/register inspection, resume, reset, rerun; exact log assertions | C/assembly debug only; Landin source debug/stack evidence R6.100 |
| GPIO whole images, indexed packed fields, AF selection, reserved bits | `peripheral.c`: explicit mask/shift RMW, retained high bits, AF image, set/reset; model input injection | stored image behavior, not electrical pins/pull/speed/alternate routing; packed-language legality R6.40 |
| UART configuration and bytes | QEMU exact TX bytes; stock UART-to-DMA control; synthetic `Feed` writes its DR and transfers one supplied byte | synthetic divisor is storage only; no serial line, baud accuracy, FIFO overrun or framing/parity model |
| DMA descriptor, escaping static buffer, enable handoff | `peripheral.c` supplies a static ordinary byte array and descriptor; feed while disabled leaves it untouched | C pointer handoff only; Landin origin refusals and complete driver R6.90 |
| DMA count, increment, circular wrap and CPU visibility | five ordered feeds into four bytes, checked halfword count 4/2/4/3, wrap replaces first byte, CPU reads the transferred bytes | model serializes byte copy before count/status; no asynchronous bus races or cache-coherence proof |
| Completion, half-transfer and transfer error | model status `0x20/40/80`, enables in config bits 1/2/3, NVIC IRQ0, firmware records three IRQs and clears status | synthetic status convention follows sketch stream 5; not stock STM32 status layout |
| Critical section and event collection | PRIMASK masks delivery while DMA updates RAM/count; restoring it permits pending completion handler | proves this model's mask/delivery behavior, not Landin happens-before; R6.30 |
| One-clears and access modes | firmware clears pending bits; `model-checks.py` proves writing zero preserves error, one clears it, read-only/write-only/unknown accesses refuse | other access modes are absent; normative register rules remain R6.40/R6.80 |
| Bad descriptor, bounds, unsupported direction | model controls reject bad destination, count above 65535 and unsupported direction; no transfer occurs | no physical bus fault/overrun timing; driver `buffer_empty`, `buffer_too_big`, `bad_baud` and recovery execute in R6.90 over this lane |
| Ordinary-slice read, head/tail and short output | current lane exposes count and circular RAM for the complete derived driver | R6.90 must execute its `available`/`read` cases and failure oracles; this environment is not that driver |
| SVD-derived types, encoded values, named refusals | checked-in model and map are explicit device inputs; malformed access controls already execute | R6.40 packed encodings; R6.70 `noreturn`; R6.80 generated `.ldn` fixtures; general generator stays with companion tooling |

Feeds happen while virtual execution is paused, followed by a fixed 1 ms
virtual run and a checked firmware stage. No host sleep decides firmware
success. Only the debugger socket startup uses a bounded readiness poll.
The [Renode time framework](https://renode.readthedocs.io/en/latest/advanced/time_framework.html)
is execution scheduling, not physical bus timing. The model's transfer order
is an explicit harness assumption. The ordinary C buffer is reloaded across
opaque memory-clobber barriers; that is no definition of Landin DMA visibility.
R6.30 must define races, tearing, atomics, compiler/hardware barriers and cache
maintenance, with models for behaviors this cacheless M0 profile cannot expose.
Supplemental hardware can test actual bus/interrupt timing, electrical behavior
and a real device's DMA visibility; it cannot replace the emulator gates or
by itself establish language concurrency semantics.

## Reproduction and evidence

On the documented native Linux host, with Python 3 and `dpkg-deb`:

```sh
python3 environments/cortex-m/setup.py
python3 environments/cortex-m/test.py
python3 environments/cortex-m/run.py --output /absolute/new/evidence-directory
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

The Linux acceptance documents job executes both the failure controls and
these live probes from the same committed archive as every native job.
`job.py` copies its `cortex-m` evidence into the exported, hash-verified bundle.
Thus the annotated dual-native approval binds the environment's actual run,
not only this document or a development transcript. Darwin retains native
compiler/workload/LLDB evidence and does not impersonate this probe host.
R6.10 selects routine scope with debugger coverage because it adds debugger
control checks and changes acceptance commands/evidence retention. This is
not the full R6.100 milestone matrix. Nix CI and scheduler/cache/resume work
retain R5.51's dispositions.

The retained development result is indexed by [validation.json](validation.json).
Its successful probe images contain 643 and 836 text bytes respectively, no
initialized data and 24 BSS bytes each. These are environment-control sizes,
not measurements of the future Landin driver or a stack-usage guarantee.

## R6.20 layout and ABI evidence

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
R6.10 lock cleanup refusal for linked or nonempty replacements.

Every subprocess retains the original deadlines (GDB 20 seconds, build/tools
30, debugger readiness three) and owned process-group cleanup. The final
exact-archive Linux documents job repeats all lanes and retains tool/input
hashes alongside the new ABI artifacts. Its ordinary dual-native approval binds
these results to the same revision as the hosted checks. Development results
are indexed separately in `abi-validation.json`; `validation.json` keeps its
historical R6.10 meaning.

These bounded probes establish neither floating arithmetic helpers, general
unwind support, a complete C language ABI surface, firmware stack bounds,
physical hardware behavior nor a Cortex-M compiler backend. R6.50 must consume
the plans with native selection and frame code; R6.60 must implement image
placement/startup; R6.100 must establish Landin debugging and stack evidence.
R6.30/R6.40 retain concurrency and invalid packed encodings. Existing resource,
evidence, scheduling, Nix and general-generator dispositions are unchanged.

## R6.30 memory evidence

The mandatory `run.py` path additionally executes `memory.py`, without changing
R6.10/R6.20's CPU, peripheral, independent ABI or lock-cleanup obligations.
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

## R6.40 image and access controls in development

The mandatory `run.py` path now also executes `packed.py`. It preserves every
R6.10/R6.20/R6.30 lane and the verified empty Renode lock cleanup. The new
`EncodingPeripheral.cs` is a separate, synthetic peripheral at `0x40030000`:

| offset | access | explicit device contract |
|---|---|---|
| 0 | normal 32-bit read/write | initial `0xa50000f0`; bits 8..31 must retain `0xa50000` |
| 4 | destructive 32-bit read | returns initial `0x9b`, then zero; writing refuses |
| 8 | write-only 32-bit command | bits 8..31 must be zero; reading refuses |
| 12 | 32-bit status and one-clears command | initial `0xf3`; ones clear, zeros preserve; written bits 8..31 must be zero |
| 16 | normal 16-bit count | initial `0xffff`; word accesses and other widths refuse |

Pinned GCC compiles `probes/packed.c` to real M0 instructions. Its ordinary
unsigned images enumerate all byte inputs, four two-bit indexed elements and
every three-bit encoding of the independently tabulated named set 0/1/4.
Firmware then performs the device accesses. `packed.py` asserts a literal
14-event oracle, including each direction, width, address and value; that
oracle is neither generated from the C code nor derived from the C# model.
Reading the model's final properties does not access its emulated registers.
Seven invalid direction/width/reserved operations must raise without adding
an event. A destructive read is consumed once locally; a second explicit read
returns zero. Write-only and one-clears commands issue no preparatory read.
The count is never widened to the neighboring halfword.

The runner retains the generated platform, Monitor and assertion scripts,
ELF/map/disassembly, trace, tool identities, exact commands and hashes under
the same exported evidence directory. The existing 30-second subprocess limit,
fixed virtual-time execution and process-group cleanup apply. The new
firmware has 660 text bytes, zero data and 16 BSS bytes; these are control sizes,
not Landin firmware or stack bounds. `packed-validation.json` indexes the
successful development run and its independent local copy.

This is actual peripheral-harness execution of independent C controls. The
Ada `targets/packed image algebra and access plans` test separately checks
compiler-library algebra with an independent bit oracle. Neither supplies
Landin packed source support, a new IR operation, an implemented Cortex-M
backend or R6.40 completion. ROADMAP.md owns the remaining integration.
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
this synthetic map describes vendor hardware. R6.80 retains generated-device
fixture provenance, and general SVD tooling remains outside this item.
