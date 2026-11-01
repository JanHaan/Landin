# Learning a device from its SVD

`refine svd` reads a vendor's CMSIS-SVD file and a reviewed selection policy
and writes Landin: one register module per selected peripheral, a
correspondence that records every selected register and field as the SVD gave
it beside what was generated, a manifest of the files it wrote, and the
generated half of the device's description, `interrupts.ldn` (D542). The
importer is part of `refine`, written in Ada; nothing here needs Python
except the repository's own fetcher and tests. The compiler consumes the
generated `.ldn` files as ordinary source, without network access, package
acquisition or generator tooling.

```sh
python3 scripts/fetch_inputs.py rp2040/RP2040.svd
refine svd --policy=devices/policies/rp2040.json --out-dir=devices \
    ~/.cache/landin/inputs/rp2040/RP2040.svd
refine --root=devices/generated --root=. --target=cortex-m0 \
    --firmware-entry=start --emit=exe devices/consumers/images -o fixture.elf
```

This tree holds two devices: Raspberry Pi's RP2040 and ST's STM32H753. A
description is imported as `descriptions/DEVICE` with `--root=devices`, and
its register modules as `DEVICE/PERIPHERAL` with `--root=devices/generated`.

## Device descriptions

`descriptions/DEVICE/` holds a device's description (D542): Landin source of
tool directives the compiler reads into the profile a firmware program is
built for, imported as `descriptions/DEVICE` with `--root=devices`, apart from
the register modules under `generated/`. `interrupts.ldn` is the half an SVD
gives, in the one text D542 fixes, and `memory.ldn` the half a developer
writes. RP2040's `interrupts.ldn` was first written in that form by hand and is now
what `refine svd` generates; `devices/test.py` regenerates it, and renders
D542's form from the fetched SVD with nothing of the compiler's, and
requires the file's bytes to be both. Its `memory.ldn` follows
pico-sdk 2.2.0, checked against
[`memmap_default.ld`](https://github.com/raspberrypi/pico-sdk/blob/2.2.0/src/rp2_common/pico_crt0/rp2040/memmap_default.ld)
(SHA-256 `d409afb35ec0a8c3edf5ad6935907cb45f225a3cbdfd4c3b8505a7ed92df28dc`),
whose FLASH comes from
[`pico_flash_region.template.ld`](https://github.com/raspberrypi/pico-sdk/blob/2.2.0/src/rp2_common/pico_standard_link/pico_flash_region.template.ld)
(`a8cfe6d5eeea94ae1d67eddbcc8c7f9167de30fbac3b196ee51cc52833e6f22a`) at
`0x10000000` and its 2 MiB from the Pico's
[`pico.h`](https://github.com/raspberrypi/pico-sdk/blob/2.2.0/src/boards/include/boards/pico.h)
(`e88d258b92a7653c360d32042c2cac0de99010a6bc67d6935f6095b9612336d0`); none of
them is vendored. Its stack takes the whole of SCRATCH_Y, where pico-sdk puts
core 0's, and its boot kind is `rp2040-boot2`. Its `boot2.ldn` is the second
stage that boot kind's ROM enters before the image (D587): one naked routine
marked `link(boot_stage)`, a port of pico-sdk 2.2.0's generic
`boot_stage2/boot2_generic_03h.S` with its `exit_from_boot2.S`, which sets
the flash interface up for serial 03h reads at a quarter of the system
clock, writes nothing to the flash, points VTOR at the vector table and
enters reset. Its constants are numbers, each named beside the pico-sdk
macro it is, and refine seals the assembled stage with the boot ROM's
checksum (D588). The Cortex-M
[descriptions lane](../environments/cortex-m/README.md#device-descriptions)
compares what it selects with expectations recorded from those files, and
the stage's stores with the ones pico-sdk's own source makes.


| Path | What it is |
|---|---|
| [`inputs.json`](inputs.json) | the lock: each vendor input's URL and SHA-256 |
| [`policies/`](policies) | one selection policy per device |
| [`generated/`](generated) | the register modules, correspondences and manifests `refine svd` writes |
| [`descriptions/`](descriptions) | each device's description: the generated `interrupts.ldn`, the hand-written `memory.ldn`, and RP2040's second stage, `boot2.ldn` |
| [`notices/`](notices) | the licences the generated files are derived under |
| [`consumers/`](consumers) | firmware that uses the generated modules |
| [`test.py`](test.py) | the offline checks, and with `--refine` the regeneration and the vendor-header oracles |
| [`check_sources.py`](check_sources.py) | the precise source refusals against the generated interface |

## Inputs, fetched by hash

No SVD, header or manual is in this tree (D559). [`inputs.json`](inputs.json)
pins each input by the URL it is fetched from and its SHA-256, and
`python3 scripts/fetch_inputs.py [NAME ...]` fetches each into
`$LANDIN_INPUTS`, or `~/.cache/landin/inputs`, as `CACHE/NAME`, verifies it,
and prints its path. A cached file is verified every time it is used; bytes
of another hash are refused and never cached. `--offline` uses the cache
alone. An input marked `"fetch": "by hand"`, RM0433, is one a person puts in
the cache; the fetcher verifies it when named or with `--all` and never
downloads it.

Such a manual stays supplied by hand: www.st.com resets a script's HTTP/2
stream and times out over HTTP/1.1, and its terms do not let the tree carry
the file. A reviewer opens the pinned URL in a browser, saves the PDF as
`CACHE/rm0433/RM0433.pdf` and runs `python3 scripts/fetch_inputs.py
rm0433/RM0433.pdf`, whose refusal names the path and hash wanted. The URL
serves the current revision, so once ST publishes a newer one than the
pinned Rev 9, the copy wanted is the maintainer's, and no job verifies it.

| Input | Source | Licence |
|---|---|---|
| `rp2040/RP2040.svd` | official [pico-sdk 2.2.0](https://github.com/raspberrypi/pico-sdk/tree/2.2.0), commit `a1438dff1d38bd9c65dbd693f0e5db4b9ae91779`; device `RP2040`, version `0.1`, SVD schema `1.1` | BSD-3-Clause, Raspberry Pi Ltd 2024 |
| `rp2040/{clocks,dma,io_bank0,m0plus,pads_bank0,resets,sio,timer,uart,vreg_and_chip_reset,watchdog,xosc}.h` | the same commit's `hardware/regs` headers, used only by the oracle | BSD-3-Clause |
| `rp2040/boot2_generic_03h.S`, `rp2040/exit_from_boot2.S` | the same commit's `boot_stage2/boot2_generic_03h.S` and `boot_stage2/asminclude/boot2_helpers/exit_from_boot2.S`, which `descriptions/rp2040/boot2.ldn` ports and the descriptions lane reads as the stage's oracle | BSD-3-Clause |
| `rp2040/{addressmap,ssi}.h` | the same commit's `hardware/regs` headers, whose macros that oracle evaluates | BSD-3-Clause |
| `stm32h753/STM32H753.svd` | Arm's [STM32H7xx_DFP](https://github.com/Open-CMSIS-Pack/STM32H7xx_DFP) tag `v4.1.3`, commit `4c77d2ffa6e885b6da9d6fe949c2d6070b21fe7d`, the device family pack Keil publishes; device `STM32H753`, version `2.0`, SVD schema `1.1` | Apache-2.0, STMicroelectronics 2024, stated in the file's own header |
| `stm32h753/stm32h753xx.h` | ST's [cmsis-device-h7](https://github.com/STMicroelectronics/cmsis-device-h7), commit `81db1ec63cdc191fae1565b772da3ea5aa29a683`, used only by the oracle | Apache-2.0, per that repository's licence |

ST also publishes the STM32H7 SVDs from st.com under its own licence
agreement, SLA0048, which admits derivative representations for developing
software for ST devices; the DFP's copy is the same file under Apache-2.0,
which is the plainer grant and has a fixed URL, so it is the one pinned.
`cmsis-svd-data`, a third party's collection, was not chosen over ST's own
pack. The generated STM32H753 files are derivatives under Apache-2.0: each
module names [the licence](notices/LICENSE-Apache-2.0.stm32h7), which is in
the tree as Apache-2.0 asks a copy to be given. The generated RP2040 files
are derivatives under BSD-3-Clause, which asks that a redistribution keep the
licence's text; [its notice](notices/LICENSE.pico-sdk) is in the tree and
each module names it.

The official [RP2040 datasheet](https://datasheets.raspberrypi.com/rp2040/rp2040-datasheet.pdf)
consulted for the RP2040 review has build date **2025-02-20**, build version
**3184e62-clean**, and SHA-256
`be56fbb75ba0ae9e26558a73c93ac3e75c2ad4e6878d3b6703de2a76d886ea8c`; the
policy's `provenance` records it. Its notice is CC BY-ND 4.0 and it is not
redistributed or needed for generation. Current official
[CMSIS-SVD documentation](https://open-cmsis-pack.github.io/svd-spec/main/index.html)
was consulted on 2026-09-18, pinned by documentation repository commit
`250e414da502885efc7c7ef96b0a19bac9abf8da`.

## The selection policy

A policy is JSON, schema 2, read by refine without Python (D556). Every
member below except the first four has a default or may be left out; a
member refine does not read is refused, except `provenance`, which holds the
reviewer's notes and is not read.

| Member | Says |
|---|---|
| `schema` | `2` |
| `device`, `svd_version` | the SVD's `device/name` and `version`, which must match |
| `svd_sha256` | the SHA-256 of the SVD the policy was reviewed against; another file is L0527 |
| `notice` | the lines each module begins with, after `-- `: provenance and the licence |
| `modules` | the import root under `--out-dir`; default `.` |
| `prefix` | the directory each peripheral's module is in, under the root; default the device's name in lowercase |
| `correspondence`, `manifest` | their paths under the root; default `PREFIX/correspondence.json` and `PREFIX/outputs.json` |
| `description` | where `interrupts.ldn` goes under `--out-dir`; default `descriptions/DEVICE` |
| `selection` | each peripheral's selected registers, in the order generated |
| `policies` | for each `PERIPHERAL.REGISTER`: `read` `normal`, `modify` or `refused`; `write` `normal`, `one_clears` or `refused`; `reserved` `zero` or `preserve`; an optional `write_mask` |
| `numeric_enums` | the `PERIPHERAL.REGISTER.FIELD`s whose enumeration is read as a plain number |
| `reset_mask_overrides` | the reset knowledge a reviewer promises for a register, replacing the SVD's |
| `reset_corrections` | a reviewed reset `value` and the `source` it was read from, where the SVD is wrong |
| `field_corrections` | for a `PERIPHERAL.REGISTER.FIELD`, its reviewed `bits` as `[HIGH:LOW]`, or `omit: true`, and the `source` |
| `interrupt_corrections` | for an interrupt's name, the `value` it is added or moved to, or `omit: true`, and the `source`; `interrupts.ldn` says each in a line (D542) |

A refused read or write leaves no accessor, so a program that tries one is
refused by name resolution. `modify` reads with one volatile load, for a FIFO
whose read consumes data. `one_clears` writes a command that clears the bits
written as one. A write admits only the named fields, or `write_mask`.

## What the importer reads

D557 says it in full. Properties are inherited from the register, its
peripheral, the peripheral that is derived from, and the device. A derived
peripheral takes its parent's registers and keeps its own base, once. An
alternate register is generated at the address it shares. A field lies where
its `bitRange`, `bitOffset` and `bitWidth`, or `lsb` and `msb` say, and may
or may not enumerate its values. Arrays, clusters, derived registers and
fields, alternate groups, default enumerated values and widths other than 32
are refused by name (L0528), and what cannot be generated as described, such
as overlapping fields, is L0529.

Each module exports `base`, and for each register `_offset`, `_address`,
`_named_mask`, `_reset_mask`, `_reset_value`, `_image`, `_decode` and
`_encode`, and the admitted `_read(device_base)` and
`_write(device_base, raw)`. Base arguments permit explicit synthetic
relocation; the `_address` constants stay vendor facts. Raw decode and encode
preserve every bit. Reset constants perform no initialization. Modules
allocate nothing, import no library and have no module initialization.

`refine svd` replaces its outputs whole or not at all (D558): every
destination is checked, each new file is written beside its destination and
read back, and only then is each replaced, its old bytes kept until all are.
A file whose bytes are already the new ones is left alone, and a file the old
manifest names that is no longer made is removed. Files beside them that the
manifest does not name, such as a description's `memory.ldn`, are the
developer's and are not touched.

## Regeneration and its checks

```sh
python3 devices/test.py                          # offline, as check.py runs it
python3 devices/test.py --refine "$(command -v refine)"   # fetches and regenerates
```

Offline, the test holds the lock and the policies to the same SVD hashes,
every generated file to its manifest's hash, and every module to its notice.
With `--refine` it fetches the inputs, regenerates both devices twice into
fresh directories and requires every byte to be the checked-in one, puts back
a changed output and removes a deselected one, refuses each unsupported form
in a mutated, rehashed SVD with its code, and compares every selected register
and field with the vendor's own C headers, which refine never reads. The
gate's `cortex-m` job runs it with the release compiler. The two vendor
formats may share an upstream database; they are independent of the
projection, not a claim of independent silicon verification.

## STM32H753: the selected surface

The STM32H753 is learnt for prototype 1's UART and DMA on the
NUCLEO-H753ZI (D560), whose ST-LINK virtual COM port is USART3 on PD8 and
PD9. Its modules are under `generated/stm32h753`, its correspondence and
manifest beside them, and its description in `descriptions/stm32h753`.

| Module | Selected registers | Why |
|---|---|---|
| `rcc` | AHB1ENR, AHB4ENR, APB1LENR, RSR | the clock enables of DMA1, GPIO ports B and D and USART3, and the reset flags the board's boot frame reports |
| `pwr` | CSR1, CR3 | the supply configuration RM0433 requires after reset, and the flag that says the voltage levels are valid |
| `gpiob` | MODER, IDR, BSRR | the board's indicator, LD1 on PB0, driven through the set and reset register and read back; port B is derived from port A |
| `gpiod` | MODER, AFRH | PD8 and PD9 to alternate function 7; port D is derived from port A |
| `usart3` | CR1, CR3, BRR, ISR, ICR, RDR, TDR | enable, DMA transmit, the divisor, status, clears and data; USART3 is derived from USART1 |
| `dma1` | LISR, LIFCR, S0CR, S0NDTR, S0PAR, S0M0AR | stream 0's configuration, count and addresses, its status and clears |
| `dmamux1` | DMAMUX_C0CR | channel 0's request, 46 for usart3_tx_dma |
| `tim2` | CCMR1_Input | the timer's capture view, the selection's alternate register |

Status registers have no writer, the clear registers LIFCR and ICR no
reader and a one-clears writer, BSRR no reader, and RDR one volatile load. DMAMUX1's
single-bit and polarity fields enumerate values named `B_0x0` and so on,
which the policy reads as numbers.

The check compares every selected register and field's address and
layout with ST's `stm32h753xx.h`, through a reviewed table of the header's
structure members and the names it spells differently. Where the two
disagree, RM0433 Rev 9 decides, and where it says the SVD is wrong the
policy corrects it with the section and page (D560): `RCC_AHB1ENR` has no
bit 18 (8.7.41, p. 454), where the SVD puts a `USB2OTGHSULPIEN`; and the
RAMECC diagnostic interrupt is at 145 (Table 147, p. 759), which the SVD
omits and the policy adds as `ECC`, the header's `ECC_IRQn`, the manual
giving that one line three acronyms. Where it says the SVD is right the
check names the header's disagreement instead: DMAMUX1's `DMAREQ_ID` is
bits 6:0 and `SYNC_ID` bits 26:24 (17.6.1, p. 708), where the header's
masks are DMAMUX2's, and `WWDG1_RST` is at 143, which the header lacks.
Reset values and access policies are compared with literals reviewed from
RM0433 Rev 9, each citing its section and page: every selected register
resets to zero but `USART3_ISR`, 0x0000 00C0 in its FIFO-disabled view
(48.8.10, p. 2091); `GPIOD_MODER`, 0xFFFF FFFF, and `GPIOB_MODER`,
0xFFFF FEBF (11.4.1, p. 541), which the SVD gets wrong by deriving both
ports from port A and the policy corrects; `RCC_RSR`, 0x00FE 0000 after a
power-on reset (8.7.39, p. 450), which the SVD gives as 0 and the policy
corrects; `PWR_CSR1`, 0x0000 4000 (6.8.2, p. 305), and `PWR_CR3`,
0x0000 0006 (6.8.4, p. 307); and `GPIOB_IDR`, whose pin levels have no
known reset value (11.4.5, p. 543).
`interrupts.ldn` has 166 slots and says its one correction in a line of
its own (D542).

The [consumer](consumers/stm32h753/main.ldn) enables the clocks, sets
the pins, programs USART3 at 115200 baud from the 64 MHz HSI and transmits
four bytes through DMA1 stream 0. No emulator models the chip, so
[`thumb.py`](thumb.py) reads the linked image's instructions from its reset
vector and lists every store it makes to a device, and the check compares
the list, address, width and value in order, with one reviewed from
RM0433, and requires that nothing enables or maintains the caches (D561).

The description's [`memory.ldn`](descriptions/stm32h753/memory.ldn) is
written by hand and checked against the header's base addresses (D562):
2 MiB of flash from 0x0800_0000, ITCM 64 KiB at 0, DTCM 128 KiB at
0x2000_0000, AXI SRAM 512 KiB at 0x2400_0000, SRAM1, SRAM2 and SRAM3 at
0x3000_0000, 0x3002_0000 and 0x3004_0000, and SRAM4 64 KiB at 0x3800_0000.
It boots from the plain vector table at 0x0800_0000. The profile is
cacheless: startup leaves the M7's caches disabled, as reset leaves them,
and a cached profile is not admitted. DMA1 and DMA2 reach neither TCM, so
data, BSS and the stack are placed in the AXI SRAM. A program selects the
profile by importing `descriptions/stm32h753` with `--root=devices`, and
builds at `--level=armv7e-m`, the M7's level (D543); the consumer does, so
its linked image is at the H753's addresses. The Cortex-M descriptions lane
selects it by its identity and compares its linked regions, its 166-word
vector table at 0x0800_0000, its reserved slots, a handler at USART3's slot
55, a datum placed in the DTCM and its boot kind with
`environments/cortex-m/descriptions.json`, recorded from ST's header.
Every capacity verdict is rerun against its profile as RP2040's is: the
corpus links with the reference's probe map, so its verdicts against the
STM32H753 are a measurement from each limited image's sizes and frames, not
a link against its map.

The literals were reviewed against
[RM0433](https://www.st.com/resource/en/reference_manual/rm0433-stm32h742-stm32h743753-and-stm32h750-value-line-advanced-armbased-32bit-mcus-stmicroelectronics.pdf)
Rev 9, SHA-256
`672a9433d6602da224e5215f571beed2be0e683cb025526f4afe9db61c26b6a0`,
66,378,901 bytes, which `inputs.json` pins. ST's site does not serve it to a
script, so it is marked `"fetch": "by hand"`: download it in a browser and
put it at `~/.cache/landin/inputs/rm0433/RM0433.pdf`, where
`scripts/fetch_inputs.py --all` verifies it, and says where it goes when it
is absent. No test reads it, as no test reads the RP2040 datasheet; the
literals stay in `test.py`, and the hash names the document they were
reviewed against.

## RP2040: the selected surface and its prototype derivation

| Module under `generated/rp2040` | Selected vendor registers | Pressure and limits |
|---|---|---|
| `io_bank0` | GPIO0_CTRL, GPIO1_CTRL, GPIO3_CTRL | Pin function/override images, stride 8; different enumerated domains despite identical field names. No pad/electrical model. |
| `sio` | GPIO_IN, GPIO_OUT, GPIO_OUT_SET, GPIO_OUT_CLR, GPIO_OE_SET | Input/output and separate write commands; 30-bit masks, sparse offsets, no implicit RMW. |
| `timer` | ALARM0–3, TIMERAWL, INTR, INTE | Four explicit alarm registers, stride 4, low counter word and one-clears interrupt image. No timekeeping driver or 64-bit counter protocol. |
| `uart0` | UARTDR, UARTRSR, UARTFR, UARTIBRD, UARTFBRD, UARTLCR_H, UARTCR, UARTRIS, UARTICR, UARTDMACR | FIFO read side effects, divisors, flags, the enables, the raw overrun status, clear commands and DMA enable. No serial timing or full UART driver. |
| `uart1` | UARTFR | Peripheral `derivedFrom="UART0"` with a distinct base. No alias collapse. |
| `dma` | CH0_READ_ADDR, CH0_WRITE_ADDR, CH0_TRANS_COUNT, CH0_CTRL_TRIG, CH1_READ_ADDR, CH1_CTRL_TRIG, CH0_AL1_CTRL, INTR, INTE0, CHAN_ABORT | Channel stride 64, alternate control view, encoded width/request selectors, sparse request values, mixed access bits, one-clears interrupt status and the abort command, which the header calls self-clearing and the SVD one-to-clear. No full channel driver. |
| `resets` | RESET, RESET_DONE | The first board's peripherals taken out of reset and the wait for each. |
| `clocks` | CLK_REF_CTRL, CLK_REF_SELECTED, CLK_SYS_CTRL, CLK_SYS_SELECTED, CLK_PERI_CTRL | The reference and system clocks moved to the crystal, and the peripheral clock enabled; the glitchless switch's selected images. No PLL. |
| `xosc` | CTRL, STATUS, STARTUP | The 12 MHz crystal's enable, its stability and its start-up delay; FREQ_RANGE is read as a number, its SVD names beginning with a digit. |
| `pads_bank0` | GPIO0, GPIO1, GPIO3 | Pad input enable, drive and pulls of the UART and indicator pins; DRIVE is read as a number for the same reason. |
| `vreg_and_chip_reset` | CHIP_RESET | Which reset the chip last had, power-on among them. |
| `watchdog` | TICK | The reference clock's divider to the 1 MHz tick the timer counts. |
| `ppb` | NVIC_ISER, NVIC_ICPR, NVIC_ISPR, VTOR | The core's interrupt enables and pending bits, and the vector table's address, read only. pico-sdk's header for them is `m0plus.h`. |

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
engineering source code. Decisions below apply to the RP2040 selection.

| Feature | Representation, normalization or refusal |
|---|---|
| Property inheritance | Register size/access/reset defaults resolve from register, peripheral, then device. UART1's only admitted peripheral inheritance copies UART0 registers and retains UART1's base. Register/field inheritance and other inheritance shapes are refused. |
| Arrays, dimensions, clusters | This SVD flattens repeated registers; it contains no `dim`, cluster or alternate-register elements. Explicit names/offsets remain explicit; GPIO/alarm/channel strides have independent literal assertions. The helper refuses selected dimension/alternate structures and does not implement cluster expansion or a general array importer. |
| Sparse offsets and holes | Constants preserve actual addresses; no ordinary aggregate fills holes or permits bulk transactions. Size is inherited explicit 32-bit register size, never the sum of field widths. |
| Alternate/overlapping views | CH0_AL1_CTRL remains a distinct raw type/address with unknown reset, and no write convenience. UARTRSR/UARTECR shares a read/error-clear address; the SVD's one-to-clear metadata and prose's write-to-clear semantics are insufficiently consistent for a safe generated write, which is refused. No alias is silently merged. Overlapping fields are refused. |
| Encodings and incomplete lists | GPIO FUNCSEL and DMA DATA_SIZE/TREQ_SEL retain exact named values and holes. Raw images preserve unnamed values; extraction validates membership. RING_SIZE lists only RING_NONE but its description/manual defines numeric 0–15: the policy explicitly normalizes it to `u4`, retaining the original enum in correspondence. Unlisted request values remain invalid. |
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
protocol is offered by these small consumers. The separate
[complete driver](../compiler/tests/driver/DERIVATION.md) uses the unchanged
public accessors under an explicitly different synthetic protocol.

## RP2040: executable evidence and limits

The mandatory [device runner](../environments/cortex-m/devices.py) follows all
inherited lanes in `run.py`. Five consumers run at the inherited six profiles
`none/off`, `size/off`, `size/auto`, `speed/auto`, `none/all`, `speed/all`; the new lane records six QEMU sessions, 24 generated
device runs, one independent C/assembly device control, seven precise source
refusals and 168 fresh-directory ELF/object/assembly/linker/map/source-map
comparisons. Exact accepted results belonged to the verified native bundle of
the retired acceptance, not this interface guide.

The QEMU consumer cold-boots compiler-generated reset/vectors/linker output,
checks initialized data and BSS, immutable flash, RAM-code copying, literal
addresses/strides/layouts, raw reserved/unnamed bits, encoded updates and nested
`platform/cortex_m` mask restoration. Stack paint reports only observed writes. QEMU
executes compiler-generated firmware against `FixturePeripheral` in
`environments/cortex-m/models.py`, served at every access by the harness in
`machine.py`, whose
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
it is not language-startup evidence. The hosted line transport, older backend
harnesses and abstract models retain their separate inherited meanings.

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
JSON provenance is never linked. Complete firmware/stack measurement and source debugging belong to
the freestanding evidence lane, and the driver to its
[derivation](../compiler/tests/driver/DERIVATION.md). Package acquisition, sandboxed generator
orchestration and the broader standard library are open work in
`ROADMAP.md`. This guide creates no additional work owner.
