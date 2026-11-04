# The RP2350 board on its Hazard3 cores: a Raspberry Pi Pico 2

Start with the [board guide](../README.md) for the rig rules, pinned
tools, offline builds and the build-on-epycmicro/run-on-rigpi command.

`compiler/tests/board/rp2350_hazard3` targets RP2350 Hazard3 through
`devices/descriptions/rp2350_hazard3`, using `--target=rv32` at `--level=rv32imac`.
`board.py` defaults to `--mode=ram`: the loader halts the running core,
applies the explicit warm reinitialization contract, writes and verifies
SRAM, sets the stack and vector/trap entry and resumes. This does not
reset through the ROM, write flash or cycle power, and does not prove a
cold reset. The resident flash image stays in place. `--mode=boot` is the
separate flash and cold-start check.

The port uses Hazard3's Xh3irq dispatch and an `amoadd.w` counter
(D710, D711). Its `app` shares `bringup`, `report` and `serial` with the
Arm port under `compiler/tests/board/rp2350`, named as a second root over
the chip's generated `rp2350/PERIPHERAL` modules (D831). The oracle follows
the RP2350 datasheet, release 8. The boot check additionally exercises the
RISC-V IMAGE_DEF block.

## What it needs

| What | Which | Why |
|---|---|---|
| the board | a Raspberry Pi Pico 2 H, its SWD on the 3-pin debug connector, GPIO0 (UART0 TX) to slot 1's UART RX and GPIO1 (UART0 RX) to its TX, powered from its USB port | the RP2350 and its 4 MiB flash, as the description lays them out |
| a probe | a [probehive](https://github.com/JanHaan/probehive) SWD slot, slot 1 by default; direct UDP debug and `scripts/dap_bridge.py` for slot N's UART on TCP port 4461 + N | debug access and the UART trace |
| probe-rs | the pinned fork in the [board guide](../README.md), reaching slot 1 directly as `0000:0002:10.42.0.50/1` by default; `--probe` overrides it | memory access and explicit boot flashing |
| the indicator's wire | optionally, GPIO3 to a probe GPIO, named with `--indicator-pin`; `scripts/gpio.py` runs in `nix develop PROBEHIVE#gpio`, the light LiteX shell available on x86_64 and arm64 Linux | the physical wire level, in addition to pad readback |
| power | an off-cascade hub with per-port switching for automatic boot checks, or the board guide's manual UF2 transport and Pico-only unplug/replug steps | cold starts for explicit boot checks |
| the compiler | refine and `riscv64-elf-gcc` or `riscv64-unknown-elf-gcc` (D660), with that toolchain's `nm` and `objdump`, as `nix develop` gives them | the image, and the symbols and the `amoadd.w` it is checked for |
| the RAM loader | `landin-ram-run`, named with `--ram-loader`, built from the pinned probe-rs library | one warm halt/load/resume session |

Build tools are needed on the build host; consuming a checked bundle on
rigpi uses its matching tool sources and prepared metadata. Hardware work
holds the common rig lock, `~/.cache/landin/rig.lock`, after the build and
through final readback/restoration. Preserve the USB guard, protected Arty
and shared pacing state described in the [board guide](../README.md).

The usual development connection is SWD slot 1 and hub `.3.3`, port 2.
Automatic boot checks require an explicitly named hub outside `--cascade`;
the default development hub is refused for them. Manual UF2 boot checks
require the cascade unplugged and an explicit direct hub, port and Pico
serial, as the [board guide](../README.md#boot-checks-and-recovery) describes.

Direct UDP debug completes before the tool opens the UART socket, and
the socket closes before debug readback. The bridge remains available for
UART service between runs; it does not own the native debug session.

Never attach a probe while the Pico 2 enumerates as BOOTSEL, `2e8a:000f`.
Install and verify the quiet fixed image by UF2 off the cascade first.
The current probe-based corrupted-image control is refused: it would
require attaching again in BOOTSEL. `--bootsel-attach` cannot bypass the
guard. Boot and any future malformed-image checks stay off the cascade.

## Which chip probe-rs is told

The target follows the architecture already running on the board (D712):
`RP235x` for Arm and `RP235x_riscv` for Hazard3. A running RISC-V image
can make the Arm access ports fault; the RISC-V debug module does not
answer while the ROM is in Arm BOOTSEL. That state never permits an
attach. Changing between Arm and Hazard3 is an explicit off-cascade
setup/boot operation. Prepare and verify the fixed image for the intended
architecture before repeated RAM runs; warm entry does not switch
architectures through the ROM. Automatic boot flashing selects the architecture that
currently answers, then cold-starts the selected port's image and restores
that port's fixed image. `result.json` records `flashed_as` only for
the automatic boot check. Manual UF2 selects the image's architecture
through its UF2 family and image block, then reads only that architecture
after BOOTSEL disappears. Counters for this port are read as `RP235x_riscv`.

## Running it

Run this raw command on the rig host from the matching source snapshot.
Prepare `RAM_BUNDLE` on the build host as the [board guide](../README.md)
describes; the rig host needs no refine or cross-binutils when consuming it.

```sh
python3 environments/boards/rp2350_hazard3/board.py \
    --mode=ram --bundle=RAM_BUNDLE --ram-loader=PATH/TO/landin-ram-run \
    --probe-rs=PATH/TO/probe-rs \
    --probehive /home/jan/src/probehive \
    --output=NEW_DIRECTORY
```

For a boot check, replace the mode and bundle with `--mode=boot` and
`--bundle=BOOT_BUNDLE`, retain `--ram-loader` for single-core readback, and provide
`--fixed-image=PATH/TO/fixed.elf` if the bundle does not already carry it.
The fixed image is the quiet resident program restored and cold-started
afterward, subject to the USB stop guard. Name the off-cascade `--hub` and its
`--port` explicitly. A failed restoration is a failed check; a USB fault
stops further hardware actions and requires the operator's recovery.

The output retains the ELF, build report, command logs, `uart.bin`,
`sent.bin`, elapsed time and `result.json`, including `mode`, the warm-load
report or the boot/restoration evidence, and the physical oracle verdicts.
Use `mode` and `warm_load` to identify RAM evidence. Keep passed RAM runs in
`ram-record.json` with `--record`; `record.json` remains boot evidence.
ELF hashes depend on the output basename; rebuild a recorded image using
its `image_name`.

## The trace

The firmware writes frames between the echoed bytes in the Pico 2's form:
STX, a tag letter, a field per key, ` k=` and eight lowercase hex digits,
then ETX and LF. The host never sends STX or ETX.

| Tag | When | Fields |
|---|---|---|
| `b` | for each startup ACK, after peripheral initialization | `r` POWMAN's CHIP_RESET as read first in `start`, `v` mtvec then, `a` marchid, `k` CLK_REF_SELECTED |
| `r` | after GO and a fresh DMA epoch | no fields; application readiness |
| `t` | after each 0x11 | `h` bytes handled, `c` ring restarts, `d` DMA completions, `m` timer interrupts, `u` USBCTRL_IRQ entries, `p` the mcause it ran under, `n` DMA channel 0's TRANS_COUNT count, `e` bytes consumed in this epoch, `g` the indicator's pad read back, `s` the application's state, `q` what the `amoadd.w` that counted this frame returned |
| `h` | when the application halts | `s` its status |

Before application traffic, the host sends ACK (0x06), retrying until
it receives `b`, then GO (0x07). The firmware consumes the complete
handshake without echo, restarts its 4096-byte DMA epoch and emits `r`.
Only after `r` does the host send application bytes. `sent.bin` keeps
all ACKs and GO; echo and handled-count checks exclude that prefix.

Three bytes are commands after their echo: 0x05 forces IRQ14,
USBCTRL_IRQ, pending through meifa with USBCTRL held in reset, and its
handler stops forcing it; 0x11 asks for a `t` frame; and 0x12 stops
reading for 100 ms.

## The oracle

| Checked | Against |
|---|---|
| the warm RAM entry | the helper validates SRAM-only load segments, writes and reads them back, establishes the vector/trap base, stack and entry, and reports `flash_written: false`; the physical scenario then checks device behavior |
| the startup frame (RAM mode) | the vector/trap base equals the loaded ELF table and clk_ref selects the crystal; reset-cause bits are observed without a power-on assertion; marchid identifies Hazard3 |
| the ELF (boot artifact) | EM_RISCV; its first word, at 0x1000_0000 where the boot ROM enters a RISC-V image, a `jal x0` to `_landin_firmware_reset` |
| the ELF's trap table (boot artifact) | 68 words at 0x1000_0200, the build report's `vector_address`, 512-aligned as D662 aligns 272 bytes; slot 11, the machine external interrupt, a jump to the meinext dispatch, slots 16, 26 and 30, TIMER0_IRQ_0, DMA_IRQ_0 and USBCTRL_IRQ (3.2, Table 95, p. 81), jumps to their handlers, and every other slot a jump to the unhandled loop |
| the ELF's block (boot artifact) | directly after the table and inside the first 4 KiB, at the report's address, the minimum RISC-V IMAGE_DEF (5.9.5.1, Table 503, p. 390): the start and end markers (5.1.5.1, p. 329), IMAGE_TYPE a RISC-V executable for RP2350, LAST and a link to itself |
| the read-modify-write | an `amoadd.w` in the image's disassembly, on a counter in SRAM, where Hazard3's atomics reach (3.8.9, MCAUSE, Table 403) |
| the malformed block (boot-only, currently refused by the tool) | a corrupted IMAGE_DEF must be refused by the ROM; testing it requires off-cascade physical UF2 recovery, because probe attachment in BOOTSEL is forbidden |
| flash after flashing (boot only) | the entry word, the table and the block, read back over SWD, equal to the image's |
| the boot frame (boot mode) | CHIP_RESET is HAD_POR alone (6.4, p. 429), so the run began at power-on; marchid is 0x1b, Hazard3 (3.8.9, Table 440), so the boot ROM switched the cores to RISC-V and entered this image; mtvec is the table in vectored mode, 0x1000_0201 (Table 394), so compiler-owned reset ran; clk_ref is on the crystal |
| the shared scenario | `1`, `A` and `0`, the bytes the emulator lane's application is fed, echoed, with `g` 8 after `1` and 0 after `0`, and with `--indicator-pin` the wire high after `1` and low after `0` |
| IRQ14 | one entry, under mcause 0x8000_000b, the machine external interrupt (Table 403), which meinext resolved to slot 30 |
| the `amoadd.w` | frame n's `q` is n, every frame the host asked for counted once, and the counter read over SWD is the number of frames |
| an overrun | after 0x12, a 300-byte burst into the 256-byte ring is discarded, never echoed, and the ring restarts once |
| an epoch ended by STALL | the 4096-byte epoch filled, its last byte STALL, then 100 bytes while the channel is exhausted and nothing reads: the UART's 32-byte FIFO holds the first 32, it flags the rest lost, the application restarts on that overrun, and only those 32 are echoed |
| an epoch exhausted | the next epoch filled to its 4096 bytes: one DMA completion, one restart, nothing lost |
| the stream | every application byte echoed in order but those discarded above, `h` their count, and the timer advancing |
| the counters | `handled`, `recoveries`, `dma_events`, `usb_events`, `reports` and TRANS_COUNT's count, read over SWD as `RP235x_riscv` once the scenario has ended, equal the last frame's |

What the emulator lane and the boards share is
`compiler/tests/driver/commands` (D593, D645): the echo and the indicator.
