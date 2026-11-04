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

This tree holds seven devices: Raspberry Pi's RP2040 and RP2350, ST's
STM32H753 and Espressif's ESP32, ESP32-S3, ESP32-C3 and ESP32-C5, and eight descriptions,
RP2350's Hazard3 cores having one of their own. A
description is imported as `descriptions/DEVICE` with `--root=devices`, and
its register modules as `CHIP/PERIPHERAL` with `--root=devices/generated`,
named by the chip alone, so that both of RP2350's descriptions name the same
modules (D831).

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

RP2350's [`memory.ldn`](descriptions/rp2350/memory.ldn) follows pico-sdk
2.2.0's
[`memmap_default.ld`](https://github.com/raspberrypi/pico-sdk/blob/2.2.0/src/rp2_common/pico_crt0/rp2350/memmap_default.ld)
for RP2350 (SHA-256
`2349d98352370fc22d84d482e53313300e8a52ea42529eced235fa99c109234f`): 512 KiB
of RAM from `0x20000000` and the scratch banks at `0x20080000` and
`0x20081000`, the same FLASH template at `0x10000000`, and 4 MiB from the
Pico 2's
[`pico2.h`](https://github.com/raspberrypi/pico-sdk/blob/2.2.0/src/boards/include/boards/pico2.h)
(`6d32916eea833abcef7e7d10321853a5c23eb7366b893aba4d5354d6ddc6b76c`). Its
stack takes SCRATCH_Y, it describes no float unit (D636), and its boot kind
is `rp2350-image-block`: no second stage, the vector table at the start of
flash and, directly after it, the IMAGE_DEF block refine emits and checks
(D637, D638), which the descriptions lane compares with pico-sdk's
`embedded_start_block.inc.S` as the pinned GCC assembles it.


| Path | What it is |
|---|---|
| [`inputs.json`](inputs.json) | the lock: each vendor input's URL and SHA-256 |
| [`policies/`](policies) | one selection policy per device |
| [`generated/`](generated) | the register modules, correspondences and manifests `refine svd` writes |
| [`descriptions/`](descriptions) | each device's description: the generated `interrupts.ldn`, the hand-written `memory.ldn`, RP2040's second stage, `boot2.ldn`, and the stages before reset, the STM32H753's `supply.ldn`, the RISC-V ESP chips' `watchdogs.ldn` and the Xtensa chips' `prepare.ldn` |
| [`notices/`](notices) | the licences the generated files are derived under |
| [`consumers/`](consumers) | firmware that uses the generated modules |
| [`test.py`](test.py) | the offline checks, and with `--refine` the regeneration and the vendor-header oracles |
| [`check_sources.py`](check_sources.py) | the precise source refusals against the generated interface |

## Drafting and reviewing an access policy

Start a policy by selecting the registers the consumer needs, then draft
its `policies` table from the SVD's effective field accesses. A register of
read-only fields gets `write: "refused"`; one of write-only fields gets
`read: "refused"`; an ordinary mixed register starts with normal reads and
writes. The policy is a reviewed interface, so this is only a draft:

1. Resolve the peripheral's `derivedFrom` and the selected register-array
   element before looking at fields. `refine svd` accepts a selected
   concrete element of a `name%s` array with `dim`, `dimIncrement` and an
   optional numeric range or explicit list in `dimIndex`. It does not
   implicitly select the whole array.
   A field may reuse an `enumeratedValues` group named in the same register
   through `derivedFrom`; correspondence records `encoding_derivation` and
   the resolved encodings. Missing or ambiguous groups, inheritance chains,
   cycles, foreign qualified names and local overrides are refused.
2. Read each selected register and field in the independent vendor header
   and the manual. Record the address, bit range, access, reset knowledge,
   enumerated encodings and any side effect. Status/input registers get no
   writer; SET/CLEAR commands get no reader. A FIFO read consumes data even
   when an SVD omits `readAction`, and an interrupt-clear register needs
   `write: "one_clears"` with zero reserved bits. Mixed RO/WO registers need
   an explicit reviewed `write_mask` rather than permission inferred from
   their writable fields alone.
3. Use `reset_mask_overrides` to withhold unknown reset bits and reviewed
   corrections for facts the SVD gets wrong. Cite the independent source
   in every correction. Keep the draft's selection small enough to review
   every field; a field's existence alone does not establish that using it
   is safe.
4. Generate with `refine svd`, review the correspondence beside the policy,
   and add independent header/literal assertions in `test.py`. Regenerate
   again and require byte-for-byte agreement. A successful import does
   not review the policy for its author.

The existing policy and oracle for the closest peripheral family provide
the table format. The Xtensa selections demonstrate both concrete array
elements and policy corrections for missing or incorrect interrupt sources.
The classic DPORT clock/reset writers use `reserved: "preserve"`: the
header declares a whole R/W word above the named bits, and each caller
explicitly transports the read image while changing its selected bits.
The read-only cache-register interfaces deliberately have no generated
writers: these profiles admit only internal SRAM with caches disabled.

## Inputs, fetched by hash

No SVD, header or manual is in this tree (D559). [`inputs.json`](inputs.json)
pins each input by the URL it is fetched from and its SHA-256, and
`python3 scripts/fetch_inputs.py [NAME ...]` fetches each into
`$LANDIN_INPUTS`, or `~/.cache/landin/inputs`, as `CACHE/NAME`, verifies it,
and prints its path. A cached file is verified every time it is used; bytes
of another hash are refused and never cached. `--offline` uses the cache
alone. An input marked `"fetch": "by hand"`, RM0433 or the RP2350
datasheet, is one a person puts in the cache; the fetcher verifies it when
named or with `--all` and never downloads it. The RP2350 datasheet is served
to a script, but its URL serves whatever release is current, so no job may
depend on its hash; it is marked by hand for that reason, and saved as
`CACHE/rp2350-datasheet/rp2350-datasheet.pdf`.

Such a manual stays supplied by hand: www.st.com resets a script's HTTP/2
stream and times out over HTTP/1.1, and its terms do not let the tree carry
the file. A reviewer opens the pinned URL in a browser, saves the PDF as
`CACHE/rm0433/RM0433.pdf` and runs `python3 scripts/fetch_inputs.py
rm0433/RM0433.pdf`, whose refusal names the path and hash wanted. The URL
serves the current revision, so once ST publishes a newer one than the
pinned Rev 9, the copy wanted is the maintainer's, and no job verifies it.

To read a pinned PDF as searchable text, first fetch or supply and verify
it with the command above. Then run `pdftotext -layout` from Poppler. For
example, render the already pinned C3 manual into a local text file:

```sh
nix-shell -p poppler-utils --run 'pdftotext -layout "$HOME/.cache/landin/inputs/esp32c3-trm/esp32-c3_technical_reference_manual_en.pdf" "/tmp/landin-c3-manual-text"'
```

Use `$LANDIN_INPUTS` instead of the default cache path when set. The text
is a local reading aid, not a new authoritative or vendored input. Cite the
PDF's printed section and page, which can differ from the viewer's page
number. Poppler is needed for this optional review step, not to compile a
program or run `refine svd`.

| Input | Source | Licence |
|---|---|---|
| `rp2040/RP2040.svd` | official [pico-sdk 2.2.0](https://github.com/raspberrypi/pico-sdk/tree/2.2.0), commit `a1438dff1d38bd9c65dbd693f0e5db4b9ae91779`; device `RP2040`, version `0.1`, SVD schema `1.1` | BSD-3-Clause, Raspberry Pi Ltd 2024 |
| `rp2040/{clocks,dma,io_bank0,m0plus,pads_bank0,resets,sio,timer,uart,vreg_and_chip_reset,watchdog,xosc}.h` | the same commit's `hardware/regs` headers, used only by the oracle | BSD-3-Clause |
| `rp2040/boot2_generic_03h.S`, `rp2040/exit_from_boot2.S` | the same commit's `boot_stage2/boot2_generic_03h.S` and `boot_stage2/asminclude/boot2_helpers/exit_from_boot2.S`, which `descriptions/rp2040/boot2.ldn` ports and the descriptions lane reads as the stage's oracle | BSD-3-Clause |
| `rp2040/{addressmap,ssi}.h` | the same commit's `hardware/regs` headers, whose macros that oracle evaluates | BSD-3-Clause |
| `rp2350/RP2350.svd` | the same commit's `src/rp2350/hardware_regs/RP2350.svd`; device `RP2350`, version `0.1`, SVD schema `1.1` | BSD-3-Clause, Raspberry Pi Ltd 2024 |
| `rp2350/{addressmap,clocks,dma,intctrl,io_bank0,m33,pads_bank0,powman,resets,sio,ticks,timer,uart,xosc}.h` | the same commit's `hardware/regs` headers for RP2350, used only by the oracle | BSD-3-Clause |
| `rp2350/embedded_start_block.inc.S`, `rp2350/picobin.h` | the same commit's `pico_crt0/embedded_start_block.inc.S` and `boot_picobin_headers/include/boot/picobin.h`, which the descriptions lane assembles as the image block's oracle | BSD-3-Clause |
| `rp2350-datasheet/rp2350-datasheet.pdf` | the [RP2350 datasheet](https://datasheets.raspberrypi.com/rp2350/rp2350-datasheet.pdf), release 8, build date 2026-10-01, build version `80d627281ed5`, 11,094,994 bytes, supplied by hand | CC BY-ND 4.0, not redistributed |
| `stm32h753/STM32H753.svd` | Arm's [STM32H7xx_DFP](https://github.com/Open-CMSIS-Pack/STM32H7xx_DFP) tag `v4.1.3`, commit `4c77d2ffa6e885b6da9d6fe949c2d6070b21fe7d`, the device family pack Keil publishes; device `STM32H753`, version `2.0`, SVD schema `1.1` | Apache-2.0, STMicroelectronics 2024, stated in the file's own header |
| `stm32h753/stm32h753xx.h` | ST's [cmsis-device-h7](https://github.com/STMicroelectronics/cmsis-device-h7), commit `81db1ec63cdc191fae1565b772da3ea5aa29a683`, used only by the oracle | Apache-2.0, per that repository's licence |
| `esp32c3/esp32c3.svd` | Espressif's [svd](https://github.com/espressif/svd) repository, commit `be20aa12560889d6125d144cdb48cf615ac17628`, its newest; device `ESP32-C3`, version `18` | Apache-2.0, Espressif Systems 2024, stated in the file's own header |
| `esp32c5/esp32c5.base.svd` | Espressif's Rust team's [esp-pacs](https://github.com/esp-rs/esp-pacs), commit `a96d437ebad40b00854aa3e78011ad7732713a4d`, `esp32c5/svd/esp32c5.base.svd`; device `ESP32-C5`, version `1` | Apache-2.0, Espressif Systems 2025, stated in the file's own header |
| `esp32c3/*.h`, `esp32c5/*.h` | [ESP-IDF](https://github.com/espressif/esp-idf) v6.1, commit `fff9895c82d744c7237be8847347bdd1b07c6643`: each chip's `reg_base.h`, `soc.h`, `interrupts.h` and the selected peripherals' `*_reg.h`, and the C5's `clic_reg.h`, used only by the oracle | Apache-2.0, or MIT where a file says so |
| `esp32c3-trm/esp32-c3_technical_reference_manual_en.pdf` | the [ESP32-C3 TRM](https://documentation.espressif.com/esp32-c3_technical_reference_manual_en.pdf), version 1.4, created 2026-03-26, 9,623,028 bytes, supplied by hand | Espressif's terms, not redistributed |
| `esp32c5-trm/esp32-c5_technical_reference_manual_en.pdf` | the [ESP32-C5 TRM](https://documentation.espressif.com/esp32-c5_technical_reference_manual_en.pdf), version 1.1, created 2026-04-24, 14,650,675 bytes, supplied by hand | Espressif's terms, not redistributed |

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
| `device`, `svd_version` | the SVD's `device/name` and `version`, which must match; a name with a hyphen, Espressif's, gives its `prefix` and `description` |
| `identity` | the description's `compiler.device`; default the device's name in lowercase (D700) |
| `core` | `hazard3`, `esp-rv32imc`, `esp-rv32imac-clic`, `xtensa-lx6` or `xtensa-lx7`; needed when the SVD cpu omits or misnames the core (D700) |
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
| `field_corrections` | for a `PERIPHERAL.REGISTER.FIELD`, its reviewed `bits` as `[HIGH:LOW]`, or `omit: true`, or, for a field the SVD lacks, `add: true` with its `bits` and its `access` in the SVD's words (D652), and the `source` |
| `interrupt_corrections` | for an interrupt's name, the `value` it is added or moved to, or `omit: true`, and the `source`; `interrupts.ldn` says each in a line (D542) |
| `register_corrections` | for a selected register, its reviewed `offset` and the `source` (D704) |
| `peripheral_additions` | a peripheral the SVD lacks: its `base`, `source` and `registers`, each with its `offset`, `access`, `reset` and `fields` of `bits` and an optional `access`, and an array's `dim` and `increment`; read as if the SVD gave it (D705) |

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
or may not enumerate its values. An element of a register array, `NAME%s`,
is selected by its name with one of the array's indices and generated at its
own offset (D703). Arrays of fields and peripherals, clusters, derived
registers and fields, alternate groups, default enumerated values and widths
other than 32 are refused by name (L0528), and what cannot be generated as
described, such as overlapping fields, is L0529.

On the ESP cores the SVD's interrupts are the interrupt matrix's
sources, not slots: `interrupts.ldn` holds the core's 32 or 48 slots and no
interrupt, and the sources are a module of their own, `PREFIX/sources`, of
`public NAME: u32 = N`, the number of each source's mapping register
(D701).

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
With `--refine` it fetches the inputs, regenerates every policy's files twice
into fresh directories and requires every byte to be the checked-in one, puts
back
a changed output and removes a deselected one, refuses each unsupported form
in a mutated, rehashed SVD with its code, and compares every selected register
and field with the vendor's own C headers, which refine never reads. The
gate's `cortex-m` job runs it with the release compiler. The two vendor
formats may share an upstream database; they are independent of the
projection, not a claim of independent silicon verification.

## ESP32-C3 and ESP32-C5: the selected surface

The two ESP chips are learnt for prototype 1's board application (D702):
UART0's echo with interrupt-driven receive, an indicator, a millisecond
wakeup and every watchdog a flash boot leaves running. Their modules are
under `generated/esp32c3` and `generated/esp32c5`, their descriptions in
`descriptions/esp32c3` and `descriptions/esp32c5`, identities `esp32-c3`
and `esp32-c5`. The C3's SVD is Espressif's own; Espressif's repository
has no C5, whose SVD is the copy in esp-pacs, Espressif's Rust team's,
which corrects it in place and so is the vendor's and not a third party's.

| Module | C3 | C5 | Why |
|---|---|---|---|
| `system` / `pcr` | PERIP_CLK_EN0, PERIP_RST_EN0 | UART0_CONF, UART0_SCLK_CONF, SYSTIMER_CONF, SYSTIMER_FUNC_CLK_CONF | UART0's and the system timer's clocks and resets |
| `io_mux` | GPIO10, GPIO20, GPIO21 | GPIO11, GPIO12, GPIO24 | UART0's pins, IO MUX function 0, and the board port's indicator, a pin free of the strapping pins and the boards' LEDs (D720) |
| `gpio` | OUT_W1TS, OUT_W1TC, ENABLE_W1TS, IN, FUNC10_OUT_SEL_CFG | the same, FUNC24_OUT_SEL_CFG | the indicator through the GPIO matrix and its read-back |
| `uart0` | FIFO, INT_RAW, INT_ST, INT_ENA, INT_CLR, CLKDIV, STATUS, CONF0, CONF1, CLK_CONF, ID | FIFO, INT_RAW, INT_ST, INT_ENA, INT_CLR, CLKDIV_SYNC, STATUS, CONF0_SYNC, CONF1, CLK_CONF, REG_UPDATE | the FIFO, the divisor, the interrupts and their clear, and the register update the core clock domain needs |
| `interrupt_core0` | UART_INTR_MAP, SYSTIMER_TARGET0_INT_MAP, CPU_INT_ENABLE, CPU_INT_TYPE, CPU_INT_CLEAR, CPU_INT_EIP_STATUS, CPU_INT_PRI_1, CPU_INT_PRI_2, CPU_INT_THRESH | UART0_INTR_MAP, SYSTIMER_TARGET0_INTR_MAP | the routing of UART0 and the system timer to a CPU line, on the C3 its lines' enables, types, priorities and threshold |
| `clic` | | MCLICCFG, CLICINFO, CLICINT17, CLICINT18 | the C5's lines are its CLIC's identities 16 to 47, enabled and prioritized there (D705) |
| `systimer` | CONF, UNIT0_OP, UNIT0_VALUE_HI, UNIT0_VALUE_LO, TARGET0_HI, TARGET0_LO, TARGET0_CONF, COMP0_LOAD, INT_ENA, INT_RAW, INT_CLR, INT_ST | the same | a millisecond wakeup from target 0 |
| `timg0`, `timg1` | WDTCONFIG0, WDTFEED, WDTWPROTECT | the same | each group's MWDT |
| `rtc_cntl` / `lp_wdt` | RESET_STATE, WDTCONFIG0, WDTFEED, WDTWPROTECT, SWD_CONF, SWD_WPROTECT | CONFIG0, FEED, WPROTECT, SWD_CONFIG, SWD_WPROTECT | the RTC watchdog, the super watchdog and, on the C3, the last reset's cause |
| `lp_clkrst` | | RESET_CAUSE | the C5's last reset's cause |
| `sources` | the 62 sources | the 84 sources, the policy's thirteen among them | each source's number, to route it by name (D701) |

The check compares every selected register's address and every field's
place, width, reset and access with ESP-IDF v6.1's headers, through a
reviewed table of the names they spell otherwise, and the sources with
`interrupts.h`. Where the SVD and the headers disagree each chip's TRM
decides, and the policy corrects the SVD with section and page: on the C3
the one I2S's clock and reset bits, and each pin's sleep drive, MCU_DRV,
which the SVD omits; on the C5 the interrupt matrix's mapping registers
from MSPI's on, which the SVD puts eight bytes low, UART0's at 0x0BC rather
than 0xB4 (D704), their delegation bit 8, the timer groups' reserved bit 21,
thirteen sources the SVD omits, and the CLIC, which no SVD has and the
policy adds from the manual's 2.8.2 (D705). The literals reviewed from the
manuals, the watchdogs' keys and bits among them, stay in `test.py`.

The descriptions are RAM-only `esp-app-image`s (D707). The C3's SRAM1 is
one memory on two buses; its `memory.ldn` puts code in its first 128 KiB
through the instruction bus and data in the 160 KiB after it through the
data bus, so the two do not alias, and the C5's SRAM is one address space;
each ends below what the ROM uses while it loads the image, as ESP-IDF's
`bootloader.memory.ld.in` gives it. Each holds `watchdogs.ldn`, a stage
before reset (D653, D708) that stops both MWDTs and the RTC watchdog and
sets the super watchdog to feed itself, with registers alone, which the
check evaluates store by store.

## RP2350's Hazard3 cores

`policies/rp2350_hazard3.json` reads RP2350's pinned SVD again for its
Hazard3 cores (D706): the Arm selection without the M33's private bus, with
the core `hazard3` and the identity `rp2350-hazard3`. Its modules are the
chip's, `generated/rp2350`, the Arm side's: a core changes no register, so
both policies write each module they share byte for byte alike, and each
keeps a manifest and a correspondence of its own there, the Hazard3 one's
`outputs-hazard3.json` and `correspondence-hazard3.json`, which name no
`ppb` (D831). Its description, `descriptions/rp2350_hazard3`, has the same
68 slots and the Pico 2's map. Hazard3's interrupt control is its own CSRs,
which no SVD describes.

## RP2350: the selected surface

The RP2350 is learnt for the first board's port on a Pico 2 (D635): what
`compiler/tests/board/rp2040` touches, at the RP2350's own addresses. Its
modules are under `generated/rp2350`, its correspondence and manifest beside
them, and its description in `descriptions/rp2350`. pico-sdk's SVD names its
core `CM33`, which refine reads as `cortex-m33`.

| Module | Selected registers | Why |
|---|---|---|
| `clocks` | CLK_REF_CTRL, CLK_REF_SELECTED, CLK_SYS_CTRL, CLK_SYS_SELECTED, CLK_PERI_CTRL | the reference and system clocks on the crystal, the peripheral clock enabled, and the glitchless switches' selections |
| `xosc` | CTRL, STATUS, STARTUP | the 12 MHz crystal; FREQ_RANGE is read as a number, its SVD names beginning with a digit |
| `resets` | RESET, RESET_DONE | the port's peripherals taken out of reset |
| `io_bank0` | GPIO0_CTRL, GPIO1_CTRL, GPIO3_CTRL | UART0's pins and the indicator |
| `pads_bank0` | GPIO0, GPIO1, GPIO3 | their pads, whose ISO bit resets set and IE clear, so bring-up clears one and sets the other; DRIVE is read as a number |
| `uart0` | UARTDR, UARTFR, UARTIBRD, UARTFBRD, UARTLCR_H, UARTCR, UARTRIS, UARTICR, UARTDMACR | the receive DMA, the divisors, the flags, the overrun and its clear |
| `dma` | CH0_READ_ADDR, CH0_WRITE_ADDR, CH0_TRANS_COUNT, CH0_CTRL_TRIG, INTR, INTE0, CHAN_ABORT | channel 0, its interrupt and the abort; the control writer admits bits 0 to 25, BUSY being bit 26 on this chip |
| `timer0` | ALARM0, TIMERAWL, INTR, INTE | the alarm the port interrupts with |
| `ticks` | TIMER0_CTRL, TIMER0_CYCLES | TIMER0's 1 MHz tick, which the RP2040 took from its watchdog |
| `sio` | GPIO_IN, GPIO_OUT_SET, GPIO_OUT_CLR, GPIO_OE_SET | the indicator and its read-back |
| `powman` | CHIP_RESET | the last reset's cause, HAD_POR at bit 16; no writer, since POWMAN takes a password to write |
| `ppb` | NVIC_ISER0, NVIC_ICPR0, NVIC_ISPR0, VTOR | the M33's interrupt enables and pending bits and the table's address; pico-sdk's header for them is `m33.h` |

The check compares every selected register and field with pico-sdk's
headers for RP2350, each base with `addressmap.h`, DMA's request values with
the datasheet's DREQ table (12.6.4.1, Table 1254), and the access policies,
pad resets and CHIP_RESET with literals reviewed from the datasheet. Where the
SVD and pico-sdk disagree, the datasheet decides: IRQs 40 and 41 are
PROC0_IRQ_CTI and PROC1_IRQ_CTI (3.2, Table 95, p. 81), which the SVD omits
and `intctrl.h` defines, so the policy adds both and `interrupts.ldn` says
each in a line of its own, with 68 slots and all 52 interrupts named. The
datasheet's URL serves whatever release is current, so the copy pinned is
supplied by hand and no job verifies it, as RM0433's is.

## STM32H753: the selected surface

The STM32H753 is learnt for prototype 1's UART and DMA on the
NUCLEO-H753ZI (D560), whose ST-LINK virtual COM port is USART3 on PD8 and
PD9. Its modules are under `generated/stm32h753`, its correspondence and
manifest beside them, and its description in `descriptions/stm32h753`.

| Module | Selected registers | Why |
|---|---|---|
| `rcc` | CR, AHB1ENR, AHB4ENR, APB1LENR, RSR | the D2 domain's clocks-ready flag, the clock enables of DMA1, GPIO ports B and D and USART3, and the reset flags the board's boot frame reports |
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
ports from port A and the policy corrects; `RCC_CR`, 0x0000 0001 (8.7.2,
p. 383), and `RCC_RSR`, 0x00FE 0000 after a power-on reset (8.7.39,
p. 450), which the SVD gives as 0x0000 0083 and 0 and the policy corrects; `PWR_CSR1`, 0x0000 4000 (6.8.2, p. 305), and `PWR_CR3`,
0x0000 0006 (6.8.4, p. 307); and `GPIOB_IDR`, whose pin levels have no
known reset value (11.4.5, p. 543).
`interrupts.ldn` has 166 slots and says its one correction in a line of
its own (D542). The policy also adds a field the SVD lacks:
`DMA_SxCR`'s TRBUFF, bit 20, which a stream serving a USART must set
(15.5.5, p. 662), so both the consumer's transmit stream and the board's
receive stream can set it (D652).

The [consumer](consumers/stm32h753/main.ldn) enables the clocks, sets
the pins, programs USART3 at 115200 baud from the 64 MHz HSI and transmits
four bytes through DMA1 stream 0. No emulator models the chip, and its
device accesses are checked by the board run's oracle (D621), which
replaced an evaluation of the linked image's ARMv6-M instructions when the
description gained its float unit (D561). What `test.py` still checks,
in `the consumer links cacheless`, is that the consumer links where the
description places it, and that no literal word of its flash reaches SCB's
CCR or a cache maintenance operation while one reaches CPACR, so nothing
enables or maintains the caches. [`thumb.py`](thumb.py) remains, for
RP2040's second stage (D588).

The description's [`memory.ldn`](descriptions/stm32h753/memory.ldn) is
written by hand and checked against the header's base addresses (D562):
2 MiB of flash from 0x0800_0000, ITCM 64 KiB at 0, DTCM 128 KiB at
0x2000_0000, AXI SRAM 512 KiB at 0x2400_0000, SRAM1, SRAM2 and SRAM3 at
0x3000_0000, 0x3002_0000 and 0x3004_0000, and SRAM4 64 KiB at 0x3800_0000.
It boots from the plain vector table at 0x0800_0000, whose reset word is
the description's [`supply.ldn`](descriptions/stm32h753/supply.ldn): RM0433
permits no RAM write until the supply is configured (6.4.1, p. 262), so
that stage writes PWR_CR3 for the LDO and waits for PWR_CSR1's ACTVOSRDY,
with registers alone, before it enters compiler-owned reset (D653). It names
its Cortex-M7's float unit, `compiler.float_unit("fpv5-d16")`, which makes
the build hard-float (D615, D621). The profile is
cacheless: startup leaves the M7's caches disabled, as reset leaves them,
and a cached profile is not admitted. DMA1 and DMA2 reach neither TCM, so
data, BSS and the stack are placed in the AXI SRAM. A program selects the
profile by importing `descriptions/stm32h753` with `--root=devices`, and
builds at `--level=armv7e-m`, the level its float unit needs (D615); the
consumer does, so
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

## ESP32 and ESP32-S3: internal SRAM and Xtensa entry

Both descriptions use the pinned Espressif SVD revision
`be20aa12560889d6125d144cdb48cf615ac17628` and independent ESP-IDF v6.1
headers/scripts at `fff9895c82d744c7237be8847347bdd1b07c6643`.
`inputs.json` pins each URL and hash. The ESP32 SVD is version 16, the S3
SVD version 21; both are Apache-2.0 Espressif inputs under the notice already
in this tree. Their selected surfaces cover UART0, indicator GPIO, timer,
interrupt routing, watchdogs, clocks, cache-state observation and CPU1's
hardware stall. Neither selection claims a DMA driver.
The classic UART contract follows the pinned `uart_ll.h`: transmit through
its AHB FIFO alias at `0x60000000`, receive through the APB FIFO, and count
received bytes from `MEM_RX_STATUS` pointers because STATUS's count is not
credible after APB reads. The policy keeps the two pointer fields and
omits the overlapping aggregate status field. The S3 uses its direct FIFO
and STATUS count. Each board program resets UART0 before configuring it,
so the classic FIFO's default 128-byte capacity is an explicit premise.

The ESP32 has 128 KiB IRAM at `0x40080000` and 128 KiB DRAM at
`0x3ffb0000` in this conservative profile. The S3 has 128 KiB IRAM at
`0x40378000` and 160 KiB DRAM at `0x3fca8000`. S3 instruction/data aliases
refer to the same physical SRAM with an offset of `0x6f0000`: DRAM starts
where code's alias ends. Its DRAM ends at `0x3fcd0000`, below the ROM
buffers beginning at `0x3fcd7e00` that `bootloader.memory.ld.in` records.
The scripts and independent address checks in `test.py` establish these
bounds. Both profiles leave cache banks, external RAM and mapped flash
unused. Constants and strings are in byte-accessible DRAM; the instruction
bus permits aligned word accesses only.

The descriptions select `xtensa-lx6` and `xtensa-lx7`, each with 32 CPU
interrupt lines. Their generated `sources` modules name interrupt-matrix
sources, which are distinct from those lines. The classic SVD omits SLC0
and SLC1 and advertises two nonexistent MCPWM sources; the policy corrects
those against `interrupts.h`. The S3 SVD omits AES at 77 and puts SHA there;
the policy adds AES and moves SHA to 78, as both `interrupts.h` and the
matrix register order require. Array elements such as `IO_MUX.GPIO38` are
selected by their concrete names through the ordinary importer.

The ROM-image header uses chip IDs 0 and 9, respectively, with revision
bounds 0–399 and 0–99 from ESP-IDF's support configuration. The ESP32 ROM
loads the image at flash offset `0x1000`, the S3 ROM at zero. The image
contains SRAM load segments and an entry address; no ESP-IDF second stage,
partition table or cached execute-in-place path is implied. A RAM entry
has no flash or ROM-reset operation and requires its own warm-state check.

Each hand-written `prepare.ldn` is a naked stage before compiler reset.
The classic stage requires both cache enables clear and parks at
`_landin_device_cache_refused` before any store otherwise. The S3 takes the
same path without device-stage stack use when both enables are clear. Both paths stop watchdogs
with the vendor's keys, assert CPU1's RTC hardware stall code `0x86`, and
enter compiler reset without device-stage calls or RAM accesses. Warm RAM loading still
requires disabled caches before the helper writes SRAM on either chip.

S3 direct entry from the cold ROM image loader also admits enabled caches.
This path requires CPU0 reset cause 1 (POWERON/CHIP_PU), the pinned ROM cache
entry words, and the unchanged default callback table. A reset cause is
sticky state, not proof of caller provenance: an arbitrary application's
jump to this stage is outside this contract. Other reset causes park at
`_landin_device_cache_refused`; different ROM veneers, implementation
bodies or callback tables park at `_landin_device_rom_refused`. These
checks precede the stage's first MMIO write.

Before entering a device stage, the compiler's Xtensa entry prelude prepares
a 32-byte frame in the declared DRAM stack, VECBASE and window spill vectors,
WINDOWBASE 0, WINDOWSTART 1, INTENABLE 0, and PS with WOE and UM set, EXCM
clear and interrupt level 15. After stopping watchdogs and stalling CPU1,
the S3 cold path calls the windowed ROM
`Cache_WriteBack_All` if DCache is enabled, then `Cache_Disable_ICache` and
`Cache_Disable_DCache`, in the vendor LL's order. The ROM routines suspend
autoload, wait for the cache operation to finish and invalidate tags; raw
cache-enable writes do not implement that contract. The stage verifies
both enables clear and enters compiler reset, which initializes the full
runtime and application. ROM table state at `0x3fceffc4` and its immutable
default table at `0x3ff1e2b4` lie outside the image's DRAM range.

[`esp32s3-rom.json`](esp32s3-rom.json) records the reviewed ROM entry,
implementation and callback facts. `inputs.json` pins Espressif's
[ROM ELF archive](https://github.com/espressif/esp-rom-elfs/releases/tag/20260528),
the [ROM symbol table](https://github.com/espressif/esp-idf/blob/fff9895c82d744c7237be8847347bdd1b07c6643/components/esp_rom/esp32s3/ld/esp32s3.rom.ld)
and [cache API](https://github.com/espressif/esp-idf/blob/fff9895c82d744c7237be8847347bdd1b07c6643/components/esp_rom/esp32s3/include/esp32s3/rom/cache.h).
The offline oracle compares complete implementation hashes, ENTRY/RETW
instructions, public veneers and callback words with that vendor ELF.
The stage compares all aligned words of the eight reviewed routines,
including each final word's adjacent padding, and the sixteen ROM literal
words those routines load, before any device-stage MMIO store or ROM call. It also checks the public veneers and callback table.
The comparisons use ordinary instructions and assembler literal pools in
executable IRAM; no static data initializer or extra description declaration
is needed. Physical ROM revisions must be observed against this evidence
before claiming support. The recorded
whole-ROM hash identifies the corresponding vendor QEMU revision-0 ROM;
no ROM binary is vendored. `test.py` executes the stage's restricted
instruction surface against independent MMIO/ROM values, checks refusal
before stores and preservation of unrelated RTC bits, and models the compiler entry precondition, caller
register clobbering and the ROM call order. Those models establish source
contracts; physical cold boot and dirty-cache behavior require board evidence.

CPU1 must remain stalled across debugger sessions. At probe-rs revision
[`6f9946fe748edd0e55604dc42bc0f7ea3e7485da`](https://github.com/JanHaan/probe-rs/blob/6f9946fe748edd0e55604dc42bc0f7ea3e7485da/probe-rs/src/architecture/xtensa/communication_interface.rs#L366),
Xtensa debug cleanup resumes a halted processor before leaving OCD; a
debug halt alone is insufficient. The stall fields follow ESP-IDF's
`cpu_utility_ll_stall_cpu`: APP C0 is 2, APP C1 is `0x21`, and debugger
cleanup does not clear them. The board sources use CPU line 1 at level 1
for UART reception and line 23 at level 3 for the timer, with cache and
CPU1-state fields in their startup frame. Their physical evidence must
verify those premises rather than inheriting RISC-V vector semantics.

## Metadata decisions

[correspondence.json](generated/correspondence.json) preserves the original
properties and the reviewed output for every selected field. Addresses,
offsets, masks, encodings and access metadata are available without reverse
engineering source code. Decisions below apply to the RP2040 selection.

| Feature | Representation, normalization or refusal |
|---|---|
| Property inheritance | Register size/access/reset defaults resolve from register, peripheral, then device. UART1's only admitted peripheral inheritance copies UART0 registers and retains UART1's base. Register/field inheritance and other inheritance shapes are refused. |
| Arrays, dimensions, clusters | This SVD flattens repeated registers; it contains no `dim`, cluster or alternate-register elements. Explicit names/offsets remain explicit; GPIO/alarm/channel strides have independent literal assertions. The importer expands explicitly selected concrete elements of a `name%s` array; arrays without that name form, clusters and alternate array elements remain refused. |
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
