# Checked-in device fixtures

ROADMAP.md R6.80 owns this bounded fixture set and its completion gate. These
are reproducibly generated ordinary Landin modules, not a general SVD importer
or a supported RP2040 board port. The compiler consumes the checked-in `.ldn`
files without Python, network access, package acquisition or generator tooling.

R6.100's source/resource evidence uses these unchanged modules through the
complete derived driver. Source breakpoints can enter generated accessors;
the line/function debugger exposes no device-variable display and performs no
hidden register reads. Generator provenance and source snapshots remain off
target. No additional device semantics or companion-tool capability follows.

## Inputs and provenance

[fixture.json](fixture.json) records every input SHA-256, upstream identity,
selection and reviewed policy. The retained original
[RP2040.svd](inputs/RP2040.svd) is Raspberry Pi's device `RP2040`, version `0.1`,
SVD schema `1.1`, from official
[pico-sdk 2.2.0](https://github.com/raspberrypi/pico-sdk/tree/2.2.0), commit
`a1438dff1d38bd9c65dbd693f0e5db4b9ae91779`. Its SHA-256 is
`49f53398e0496b6de0849faf17a9f4e58565af311b98b727e4ebeee964619bc6`.
The same commit's five independently shipped `hardware/regs` headers are
retained for the oracle; the manifest gives their full acquisition URL pattern
and hashes. They are vendor outputs, not outputs of our transformation.

The source SVD carries Raspberry Pi's 2024 copyright and BSD-3-Clause terms;
the headers carry their own copyright notices. The unmodified upstream
[license](inputs/LICENSE.pico-sdk) and notices are retained, and generated
modules identify that license. Only these permitted sources are vendored.
The official [RP2040 datasheet](https://datasheets.raspberrypi.com/rp2040/rp2040-datasheet.pdf)
consulted here has build date **2025-02-20**, build version **3184e62-clean**,
and SHA-256 `be56fbb75ba0ae9e26558a73c93ac3e75c2ad4e6878d3b6703de2a76d886ea8c`.
Its document notice is CC BY-ND 4.0 with separate notices for additional
resources. It is not redistributed here. Acquisition of that exact hash is
required to repeat the manual review; a changed live PDF is not equivalent
input. No manual download is required for generation or acceptance.

Current official [CMSIS-SVD documentation](https://open-cmsis-pack.github.io/svd-spec/main/index.html)
was consulted on 2026-09-18, pinned by documentation repository commit
`250e414da502885efc7c7ef96b0a19bac9abf8da`. Its
[register](https://open-cmsis-pack.github.io/svd-spec/main/elem_registers.html)
and [special-element](https://open-cmsis-pack.github.io/svd-spec/main/elem_special.html)
rules distinguish inherited properties, dimensions, alternate views and access
side effects. This does not upgrade the vendor file's declared schema.

## Selected surface and prototype derivation

| Module under `generated/rp2040` | Selected vendor registers | Pressure and limits |
|---|---|---|
| `io_bank0` | GPIO0_CTRL, GPIO1_CTRL | Two pin function/override images, stride 8; different enumerated domains despite identical field names. No pad/electrical model. |
| `sio` | GPIO_IN, GPIO_OUT, GPIO_OUT_SET, GPIO_OUT_CLR | Input/output and separate write commands; 30-bit masks, sparse offsets, no implicit RMW. |
| `timer` | ALARM0–3, TIMERAWL, INTR | Four explicit alarm registers, stride 4, low counter word and one-clears interrupt image. No timekeeping driver or 64-bit counter protocol. |
| `uart0` | UARTDR, UARTRSR, UARTFR, UARTIBRD, UARTFBRD, UARTLCR_H, UARTICR, UARTDMACR | FIFO read side effects, divisors, flags, clear commands and DMA enable. No serial timing or full UART driver. |
| `uart1` | UARTFR | Peripheral `derivedFrom="UART0"` with a distinct base. No alias collapse. |
| `dma` | CH0_READ_ADDR, CH0_WRITE_ADDR, CH0_TRANS_COUNT, CH0_CTRL_TRIG, CH1_READ_ADDR, CH1_CTRL_TRIG, CH0_AL1_CTRL, INTR, INTE0 | Channel stride 64, alternate control view, encoded width/request selectors, sparse request values, mixed access bits and one-clears interrupt status. No full channel or abort driver. |

Prototype 1's conceptual map combines 16-pin GPIO banks, a timer, UART and eight
DMA streams with a 16-bit count. It does not identify one vendor part. RP2040
instead has 30 GPIOs, a separate SIO block, PL011-derived UARTs and twelve DMA
channels with 32-bit counts. Its dual Cortex-M0+ CPUs and physical memory map
are not the accepted Cortex-M0 execution profile. No address/interrupt/width
from the sketch is silently attributed to RP2040.

The sketch's `register` images become D228 `layout(packed, u32)` types; encoded
sets become explicitly encoded unsigned atom-set types. Its volatile pointer
sketch becomes ordinary scalar pointers passed to D227/D228 operations.
Compiler-recognized directives remain D202's closed `compiler`, `assembler` and `linker`
module-directive namespaces and D229's machine annotations. Generator metadata remains JSON/comments,
not new compiler directives. No language or compiler extension is needed.

## Metadata decisions

[correspondence.json](generated/correspondence.json) preserves the original
properties and the reviewed output for every selected field. Addresses,
offsets, masks, encodings and access metadata are available without reverse
engineering source code. Decisions below apply only to this selected input.

| Feature | Representation, normalization or refusal |
|---|---|
| Property inheritance | Register size/access/reset defaults resolve from register, peripheral, then device. UART1's only admitted peripheral inheritance copies UART0 registers and retains UART1's base. Register/field inheritance and other inheritance shapes are refused. |
| Arrays, dimensions, clusters | This SVD flattens repeated registers; it contains no `dim`, cluster or alternate-register elements. Explicit names/offsets remain explicit; GPIO/alarm/channel strides have independent literal assertions. The helper refuses selected dimension/alternate structures and does not implement cluster expansion or a general array importer. |
| Sparse offsets and holes | Constants preserve actual addresses; no ordinary aggregate fills holes or permits bulk transactions. Size is inherited explicit 32-bit register size, never the sum of field widths. |
| Alternate/overlapping views | CH0_AL1_CTRL remains a distinct raw type/address with unknown reset, and no write convenience. UARTRSR/UARTECR shares a read/error-clear address; the SVD's one-to-clear metadata and prose's write-to-clear semantics are insufficiently consistent for a safe generated write, which is refused. No alias is silently merged. Overlapping fields are refused. |
| Encodings and incomplete lists | GPIO FUNCSEL and DMA DATA_SIZE/TREQ_SEL retain exact named values and holes. Raw images preserve unnamed values; extraction validates membership. RING_SIZE lists only RING_NONE but its description/manual defines numeric 0–15: the manifest explicitly normalizes it to `u4`, retaining the original enum in correspondence. Unlisted request values remain invalid. |
| Names and collisions | Lowercase register/field names are deterministic; fields use `f_`, atoms include register and field prefixes. Vendor `null` and `EN` therefore do not collide with language vocabulary. GPIO0/1's different domains remain distinct. Normalized field/enum collisions and duplicate encodings are refused. |
| Reset knowledge | The original inherited reset value/mask remain recorded. Public reset masks contain only named bits known by the independent vendor headers. UARTDR/UARTICR are wholly unknown, UARTFR knows only mask `0xf8`, and DMA AL1 control is unknown. Reserved/unknown bits are not promised zero. Reset constants perform no initialization. |
| Read/access policy | Missing forbidden accessors produce ordinary name-resolution refusal. UARTDR uses exactly one volatile scalar read: its `readAction=modify` consumes FIFO data and is not falsely described as clear-on-read. UARTFR and GPIO_IN have no writer. SET/CLR and UARTICR have no reader. |
| Write policy | TIMER/DMA INTR and UARTICR use one-clears commands with zero reserved bits. SIO SET/CLR remain separate command addresses, not stored output values. DMA CTRL writers admit configuration bits `0x00ffffff` only, so RO status and W1C errors cannot be accidentally acknowledged. UARTDR writer admits only low eight data bits. All writes are one 32-bit transaction; no helper adds a read. |
| Reserved bits | Raw decode/encode preserves every bit. Write-zero accessors check disallowed bits before access; GPIO_OUT's preserve policy transports the supplied full image without fetching an old value. The caller owns any explicit safe RMW and supplies a meaningful raw image. |

The manual's narrow-I/O-write replication rule (§2.1.4) reinforces the explicit
32-bit transaction choice. D187's admitted byte/halfword/word operations are
unchanged; no width is inferred from an eight-bit data field. Errata E12 warns
against inferring DMA progress from channel addresses (including ring cases);
these consumers use TRANS_COUNT. E13's abort/completion limitation is not
resolved by an interrupt or barrier; no abort convenience or complete recovery
protocol is offered by these small consumers. R6.90's separate
[complete driver](../compiler/tests/driver/DERIVATION.md) uses the unchanged
public accessors under an explicitly different synthetic protocol.

## Reproduction and public use

```sh
python3 devices/generate.py
python3 devices/test.py
python3 devices/generate.py --output /tmp/new-device-output
# With an independently copied fixture.json and inputs/ tree:
python3 devices/generate.py --inputs /tmp/copied-inputs --output /tmp/new-copy-output
refine --root=devices/generated --root=. --target=cortex-m0 \
  --firmware-entry=start --emit=exe devices/consumers/images -o fixture.elf
```

`generate.py` is a fixture-specific Python standard-library projection, identified
by its committed source hash and the acceptance Python identity. It accepts the
pinned input inventory, six selected modules and reviewed policies only. It is
not schema-complete, a general metadata validator, an acquisition tool or a
sandbox. Extending its selection requires another reviewed fixture decision;
rehashing arbitrary SVD input does not establish support. It resolves explicit
properties, emits encoded/image declarations and existing access primitives,
and writes canonical JSON and LF-terminated UTF-8. There are no timestamps,
host-layout queries or network calls. New output directories must not exist.
The default command compares both inventory and every byte, reporting stale
inputs or specific stale outputs. [outputs.json](generated/outputs.json)
records output hashes; its own hash is bound by the repository archive.

The manual stage is selection, policy/reset review and transcription of the
independent expected values in `test.py` and the execution model/oracles. No
manual editing of generated `.ldn` files is part of regeneration. Tests generate
from two fresh equivalent input trees, compare all outputs with the checked-in
bytes, then deliberately alter input hashes, widths, dimensions, output bytes
and inventory. Vendor header/literal checks independently cover every selected
register/field geometry, enum, address and known reset bit. The two vendor
formats may share an upstream database; they are independent of our projection,
not a claim of independent silicon verification.

Each module exports `base`, register `_offset`, `_address`, `_named_mask`,
`_reset_mask`, `_reset_value`, `_image`, `_decode` and `_encode`, plus admitted
`_read(device_base)` and `_write(device_base, raw)` operations. Base arguments
permit explicit synthetic relocation; the real `_address` constants stay vendor
facts. Pointer validity, base arithmetic, lifetime and device authority remain
caller obligations. Raw image construction/copy is distinct from checked field
extraction, policy and physical access. Modules allocate nothing, import no
library and have no module initialization. They introduce no ownership system,
hidden allocator, hosted reporting storage or mandatory source/provenance data.

## Executable evidence and limits

The mandatory [device runner](../environments/cortex-m/devices.py) follows all
inherited lanes in `run.py`. Five consumers run at the inherited six profiles
`none/off`, `size/off`, `size/auto`, `speed/auto`, `none/all`, `speed/all`; the new lane records six QEMU sessions, 24 generated
Renode runs, one independent C/assembly Renode control, seven precise source
refusals and 168 fresh-directory ELF/object/assembly/linker/map/source-map
comparisons. Exact accepted results belong to ROADMAP.md and the verified
native bundle, not this interface guide.

The QEMU consumer cold-boots compiler-generated reset/vectors/linker output,
checks initialized data and BSS, immutable flash, RAM-code copying, literal
addresses/strides/layouts, raw reserved/unnamed bits, encoded updates and nested
`core/cpu` mask restoration. Stack paint reports only observed writes. Renode
executes compiler-generated firmware against `FixturePeripheral.cs`, whose
literal offsets/masks and independent C consumer do not read generated JSON.
It checks exact ordered 32-bit traces, FIFO consumption, RO/WO refusals,
one-clears/zero writes, reserved-bit failures, encoded holes and misalignment.
Failure consumers independently calculate D232 kind/site from D150 import-order
source bytes and prove no later action. Seven source cases retain precise
codes for absent accessors, an unknown compiler metadata directive, eight-byte
MMIO and atomic RMW. `unchecked` does not remove mandatory register checks.

This separate synthetic map relocates IO_BANK0/SIO/UART0/TIMER/DMA to
`0x40070000/0x40070100/0x40070200/0x40070300/0x40071000`. Its GPIO registers,
two-byte UART FIFO, stored timer alarm and four-byte DMA transfer are bounded
premises, not faithful RP2040 emulation. DMA feeds occur while execution is
paused. A synthetic half notification does not establish completion; count zero
and explicit memory boundaries precede ordinary buffer reads. Masking interrupts
does not stop the second transfer; restoring PRIMASK delivers the pending IRQ.
There is no circular-buffer consumption, overrun recovery or serial/timer timing
claim. The independent C/assembly control uses the external environment startup;
it is not language-startup evidence. Hosted-to-Renode, older backend harnesses
and abstract models retain their separate inherited meanings.

All generated firmware keeps the accepted little-endian ARMv6-M Thumb M0 map:
32 KiB flash, 16 KiB RAM, 4 KiB reserved stack; no M0+ board substitution, VTOR,
FPU, exclusive operations or cache hardware. Architectural premises retain the
[Arm ARM DDI0419E](https://documentation-service.arm.com/static/5f8ff05ef86e16515cdbf826)
and [Cortex-M0 guide DUI0497A](https://documentation-service.arm.com/static/5ea6ce5e9931941038def8c1).
ABI/ELF references are Arm's [2025Q4 AAPCS32 and AAELF32](https://github.com/ARM-software/abi-aa/releases/tag/2025Q4);
assembler/linker semantics retain the pinned GNU manuals and tools in the
[environment guide](../environments/cortex-m/README.md). The ordinary eight-byte
r11/LR frame, reserved r9, r12 private status, interrupt EXC_RETURN and naked
obligations are unchanged. No new assembly surface or calling convention exists.

The runner retains inputs, tool/compiler identities, timeouts, reset/linker
scripts, ELF/map/assembly/disassembly/relocations, symbols, runtime archive and
member hashes, traces and assertions. Closure permits only the generated object,
pinned `thumb/v6-m/nofp/libgcc.a` and applicable linker stubs. Undefined symbols,
hosted startup/libc/heap dependencies fail. Optional panic maps stay off target;
JSON provenance is never linked. Existing Renode process/lock cleanup remains
mandatory. R6.100 owns complete firmware/stack measurement and source debugging;
R6.90 owns the [complete driver derivation](../compiler/tests/driver/DERIVATION.md); R551-33 retains the general SVD generator,
package acquisition and sandboxed generator orchestration; the broader standard
library retains its own disposition. This guide creates no additional work owner.
