# The RP2350 board: a Raspberry Pi Pico 2

Start with the [board guide](../README.md) for the rig rules, pinned
tools, offline builds and the build-on-epycmicro/run-on-rigpi command.

`compiler/tests/board/rp2350` targets RP2350 Arm through
`devices/descriptions/rp2350`, using `--target=cortex-m0` at `--level=armv8-m.main`.
`board.py` defaults to `--mode=ram`: the loader halts the running core,
applies the explicit warm reinitialization contract, writes and verifies
SRAM, sets the stack and vector/trap entry and resumes. This does not
reset through the ROM, write flash or cycle power, and does not prove a
cold reset. The resident flash image stays in place. `--mode=boot` is the
separate flash and cold-start check.

The port runs on Cortex-M33 in Secure state and uses no float. Its
UART0, DMA channel 0, GPIO3 indicator and timer use the RP2350's registers
(D654). The oracle follows the RP2350 datasheet, release 8 (D655).
The boot check additionally exercises the Arm IMAGE_DEF block.

## What it needs

| What | Which | Why |
|---|---|---|
| the board | a Raspberry Pi Pico 2 H, its SWD on the 3-pin debug connector, GPIO0 (UART0 TX) to slot 1's UART RX and GPIO1 (UART0 RX) to its TX, powered from its USB port | the RP2350 and its 4 MiB flash, as the description lays them out |
| a probe | a [probehive](https://github.com/JanHaan/probehive) SWD slot, slot 1 by default, `--slot`, and a checkout of probehive, whose `scripts/dap_bridge.py` serves slot N's UART as TCP port 4461 + N; a bridge already listening on the slot's ports is reused and left running, and otherwise the tool starts one for every slot of the probe, `--bridge-slots`, and leaves it running for the next tool | direct SWD debug and the independent UART trace |
| probe-rs | the pinned fork in the [board guide](../README.md), reaching slot 1 directly as `0000:0002:10.42.0.50/1` by default; `--probe` overrides it | memory access and explicit boot flashing |
| the indicator's wire | optionally, GPIO3 to a probe GPIO, named with `--indicator-pin`; `scripts/gpio.py` runs in `nix develop PROBEHIVE#gpio`, the light LiteX shell available on x86_64 and arm64 Linux | the physical wire level, in addition to pad readback |
| power | the Pico 2's USB port on a hub with per-port power switching, and `uhubctl` with the right to switch it | power cycling for explicit boot checks |
| the compiler | refine and `arm-eabi-gcc` or `arm-none-eabi-gcc` (D532), as `nix develop` gives them | the image |
| the RAM loader | `landin-ram-run`, named with `--ram-loader`, built from the pinned probe-rs library | one warm halt/load/resume session |

Build tools are needed on the build host; consuming a checked bundle on
rigpi uses its matching tool sources and prepared metadata. Hardware work
holds the common rig lock, `~/.cache/landin/rig.lock`, after the build and
through final readback/restoration. Preserve the USB guard, protected Arty
and shared pacing state described in the [board guide](../README.md).

The usual development connection is SWD slot 1 and hub `.3.3`, port 2.
Boot checks require an explicitly named hub outside `--cascade`; the
default development hub is refused for them. See the Arm/Hazard3 target
selection described in [the other port](../rp2350_hazard3/README.md#which-chip-probe-rs-is-told).

Direct UDP debug completes before the tool opens the UART socket, and
the socket closes before debug readback. The bridge remains available for
UART service between runs; it does not own the native debug session.

Never attach a probe while the Pico 2 enumerates as BOOTSEL, `2e8a:000f`.
Install and verify the quiet fixed image by UF2 off the cascade first.
The current probe-based corrupted-image control is refused: it would
require attaching again in BOOTSEL. `--bootsel-attach` cannot bypass the
guard. Boot and any future malformed-image checks stay off the cascade.

## Running it

Run this raw command on the rig host from the matching source snapshot.
Prepare `RAM_BUNDLE` on the build host as the [board guide](../README.md)
describes; the rig host needs no refine or cross-binutils when consuming it.

```sh
python3 environments/boards/rp2350/board.py \
    --mode=ram --bundle=RAM_BUNDLE --ram-loader=PATH/TO/landin-ram-run \
    --probe-rs=PATH/TO/probe-rs \
    --probehive /home/jan/src/probehive \
    --output=NEW_DIRECTORY
```

For a boot check, replace the mode and bundle with `--mode=boot` and
`--bundle=BOOT_BUNDLE`, omit `--ram-loader`, and provide
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

The firmware writes frames between the echoed bytes in the RP2040 board's
form: STX, a tag letter, a field per key, ` k=` and eight lowercase hex
digits, then ETX and LF. The host never sends STX or ETX.

| Tag | When | Fields |
|---|---|---|
| `b` | for each startup ACK, after peripheral initialization | `r` POWMAN's CHIP_RESET as read first in `start`, `v` VTOR then, `k` CLK_REF_SELECTED |
| `r` | after GO and a fresh DMA epoch | no fields; application readiness |
| `t` | after each 0x11 | `h` bytes handled, `c` ring restarts, `d` DMA completions, `m` timer interrupts, `u` USBCTRL_IRQ entries, `p` the exception number it ran in, `n` DMA channel 0's TRANS_COUNT count, `e` bytes consumed in this epoch, `g` the indicator's pad read back, `s` the application's state |
| `h` | when the application halts | `s` its status |

Before application traffic, the host sends ACK (0x06), retrying until
it receives `b`, then GO (0x07). The firmware consumes the complete
handshake without echo, restarts its 4096-byte DMA epoch and emits `r`.
Only after `r` does the host send application bytes. `sent.bin` keeps
all ACKs and GO; echo and handled-count checks exclude that prefix.

Three bytes are commands after their echo: 0x05 sets IRQ14, USBCTRL_IRQ,
pending in the NVIC with USBCTRL held in reset (D596), 0x11 asks for a `t`
frame, and 0x12 stops reading for 100 ms.

## The oracle

| Checked | Against |
|---|---|
| the warm RAM entry | the helper validates SRAM-only load segments, writes and reads them back, establishes the vector/trap base, stack and entry, and reports `flash_written: false`; the physical scenario then checks device behavior |
| the startup frame (RAM mode) | the vector/trap base equals the loaded ELF table and clk_ref selects the crystal; reset-cause bits are observed without a power-on assertion |
| the ELF's vector table (boot artifact) | 68 words at 0x1000_0000, the start of flash, word 30 the USBCTRL_IRQ handler (3.2, Table 95, p. 81) |
| the ELF's block (boot artifact) | directly after the table, the minimum Arm IMAGE_DEF (5.9.5.1, Table 503, p. 390): the start and end markers (5.1.5.1, p. 329), IMAGE_TYPE an Arm executable in Secure state for RP2350, LAST and a link to itself |
| the malformed block (boot-only, currently refused by the tool) | a corrupted IMAGE_DEF must be refused by the ROM; testing it requires off-cascade physical UF2 recovery, because probe attachment in BOOTSEL is forbidden |
| flash after flashing (boot only) | the vector table and the block, read back over SWD, equal to the image's |
| the boot frame (boot mode) | CHIP_RESET is HAD_POR alone (6.4, p. 429), so the run began at power-on; VTOR is 0x1000_0000, so the boot ROM took the block and entered this image; clk_ref is on the crystal |
| the shared scenario | `1`, `A` and `0`, the bytes the emulator lane's application is fed, echoed, with `g` 8 after `1` and 0 after `0`, and with `--indicator-pin` the wire high after `1` and low after `0` |
| IRQ14 | one entry, in exception 30 |
| an overrun | after 0x12, a 300-byte burst into the 256-byte ring is discarded, never echoed, and the ring restarts once |
| an epoch ended by STALL | the 4096-byte epoch filled, its last byte STALL, then 100 bytes while the channel is exhausted and nothing reads: the UART's 32-byte FIFO holds the first 32, it flags the rest lost, the application restarts on that overrun, and only those 32 are echoed |
| an epoch exhausted | the next epoch filled to its 4096 bytes: one DMA completion, one restart, nothing lost |
| the stream | every application byte echoed in order but those discarded above, `h` their count, and the timer advancing |
| the counters | `handled`, `recoveries`, `dma_events`, `usb_events` and TRANS_COUNT's count, read over SWD without halting the core, equal the last frame's |

What the emulator lane and the boards share is
`compiler/tests/driver/commands` (D593, D645): the echo and the indicator.
