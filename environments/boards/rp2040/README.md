# The first board: a Raspberry Pi Pico

Start with the [board guide](../README.md) for the rig rules, pinned
tools, offline builds and the build-on-epycmicro/run-on-rigpi command.

`compiler/tests/board/rp2040` targets RP2040 through
`devices/descriptions/rp2040`, using `--target=cortex-m0`.
`board.py` defaults to `--mode=ram`: the loader halts the running core,
applies the explicit warm reinitialization contract, writes and verifies
SRAM, sets the stack and vector/trap entry and resumes. This does not
reset through the ROM, write flash or cycle power, and does not prove a
cold reset. The resident flash image stays in place. `--mode=boot` is the
separate flash and cold-start check.

The port uses UART0 on GPIO0/1, DMA channel 0, GPIO3 as its indicator,
TIMER_IRQ_0 and USBCTRL_IRQ. Its physical oracle follows the RP2040
datasheet (D595). The boot check additionally exercises the flash second
stage and its CRC (D594).

## What it needs

| What | Which | Why |
|---|---|---|
| the board | a Raspberry Pi Pico H, its SWD on the 3-pin debug connector, GPIO0 (UART0 TX) to the probe's UART RX and GPIO1 (UART0 RX) to its TX, powered from its USB port | the RP2040 and its 2 MiB W25Q16JV flash, as the description lays them out |
| a probe | a [probehive](https://github.com/JanHaan/probehive) SWD slot, slot 0 by default, `--slot`, and a checkout of it, whose `scripts/dap_bridge.py` serves slot N's UART as TCP port 4461 + N; a bridge already listening on the slot's ports is reused and left running, and otherwise the tool starts one for every slot of the probe, `--bridge-slots`, and leaves it running for the next tool | direct SWD debug and the independent UART trace |
| probe-rs | the pinned fork in the [board guide](../README.md), reaching slot 0 directly as `0000:0002:10.42.0.50/0` by default; `--probe` overrides it | memory access and explicit boot flashing |
| the indicator's wire | optionally, GPIO3 (Pico pin 5) to IO32 on the maintainer's rig, named with `--indicator-pin`; `scripts/gpio.py` runs in `nix develop PROBEHIVE#gpio`, the light LiteX shell available on x86_64 and arm64 Linux | the physical wire level, in addition to pad readback |
| power | the Pico's USB port on a hub with per-port power switching, and `uhubctl` with the right to switch it | power cycling for explicit boot checks |
| the compiler | refine and `arm-eabi-gcc` or `arm-none-eabi-gcc` (D532), as `nix develop` gives them | the image |
| the RAM loader | `landin-ram-run`, named with `--ram-loader`, built from the pinned probe-rs library | one warm halt/load/resume session |

Build tools are needed on the build host; consuming a checked bundle on
rigpi uses its matching tool sources and prepared metadata. Hardware work
holds the common rig lock, `rig.lock` in the rig's shared state,
`/var/lib/landin-rig` on rigpi, after the build and through final
readback/restoration. Preserve the USB guard, protected Arty
and shared pacing state described in the [board guide](../README.md).

Boot power uses hub `.3.3`, port 1 by default. The Arty named by
`--guard-serial` must be present outside `--cascade` before any switch;
its bitstream is held in SRAM. The Pico's indicator wire is GPIO3 to IO32
on the maintainer's rig.

Direct UDP debug completes before the tool opens the UART socket, and
the socket closes before debug readback. The bridge remains available for
UART service between runs; it does not own the native debug session.

## Running it

Run this raw command on the rig host from the matching source snapshot.
Prepare `RAM_BUNDLE` on the build host as the [board guide](../README.md)
describes; the rig host needs no refine or cross-binutils when consuming it.

```sh
python3 environments/boards/rp2040/board.py \
    --mode=ram --bundle=RAM_BUNDLE --ram-loader=PATH/TO/landin-ram-run \
    --probe-rs=PATH/TO/probe-rs \
    --probehive /home/jan/src/probehive \
    --output=NEW_DIRECTORY
```

For a boot check, replace the mode and bundle with `--mode=boot` and
`--bundle=BOOT_BUNDLE`, retain `--ram-loader` for single-core readback, and provide
`--fixed-image=PATH/TO/fixed.elf` if the bundle does not already carry it.
The fixed image is the quiet resident program restored and cold-started
afterward, subject to the USB stop guard. A failed restoration is a failed
check; a USB fault stops further hardware actions and requires the
operator's recovery.

The output retains the ELF, build report, command logs, `uart.bin`,
`sent.bin`, elapsed time and `result.json`, including `mode`, the warm-load
report or the boot/restoration evidence, and the physical oracle verdicts.
Use `mode` and `warm_load` to identify RAM evidence. Keep passed RAM runs in
`ram-record.json` with `--record`; `record.json` remains boot evidence.
ELF hashes depend on the output basename; rebuild a recorded image using
its `image_name` (`board.elf` for the legacy RP2040 record).

## The trace

The firmware writes frames between the echoed bytes: STX, a tag letter, a
field per key, ` k=` and eight lowercase hex digits, then ETX and LF. The
host never sends STX or ETX.

| Tag | When | Fields |
|---|---|---|
| `b` | for each startup ACK, after peripheral initialization | `r` CHIP_RESET as read first in `start`, `v` VTOR then, `k` CLK_REF_SELECTED |
| `r` | after GO and a fresh DMA epoch | no fields; application readiness |
| `t` | after each 0x11 | `h` bytes handled, `c` ring restarts, `d` DMA completions, `m` timer interrupts, `u` USBCTRL_IRQ entries, `p` the exception number it ran in, `n` DMA channel 0's TRANS_COUNT, `e` bytes consumed in this epoch, `g` the indicator's pad read back, `s` the application's state |
| `h` | when the application halts | `s` its status |

Before application traffic, the host sends ACK (0x06), retrying until
it receives `b`, then GO (0x07). The firmware consumes the complete
handshake without echo, restarts its 4096-byte DMA epoch and emits `r`.
Only after `r` does the host send application bytes. `sent.bin` keeps
all ACKs and GO; echo and handled-count checks exclude that prefix.

Three bytes are commands after their echo: 0x05 sets IRQ5 pending in the
NVIC (D596), 0x11 asks for a `t` frame, and 0x12 stops reading for 100 ms.

Ordinary epoch fills and the final stream use pieces of at most 64 bytes,
each sent after the previous piece is echoed. A measured boot run lost
bytes during an ordinary fill at continuous line rate, before the intended
DMA exhaustion. Echo synchronization keeps this traffic within the
application's servicing rate. The deliberate 300-byte ring overflow and
100-byte FIFO overflow remain bursts, with the same exact loss, restart
and DMA completion checks.

## The oracle

| Checked | Against |
|---|---|
| the warm RAM entry | the helper validates SRAM-only load segments, writes and reads them back, establishes the vector/trap base, stack and entry, and reports `flash_written: false`; the physical scenario then checks device behavior |
| the startup frame (RAM mode) | the vector/trap base equals the loaded ELF table and clk_ref selects the crystal; reset-cause bits are observed without a power-on assertion |
| the ELF's `.boot2` (boot artifact) | 256 bytes at 0x1000_0000, not empty, its last word the CRC-32 of the first 252 as the boot ROM computes it (datasheet 2.8.1.3.1) |
| vector word 21 (boot artifact) | the USBCTRL_IRQ handler's address, Thumb bit set |
| flash after flashing (boot only) | its first 256 bytes, read back over SWD, equal to the image's |
| the boot frame (boot mode) | CHIP_RESET is HAD_POR alone, so the run began at power-on; VTOR is 0x1000_0100, which only the second stage writes, so the ROM entered the flashed stage and the stage entered compiler-owned reset; clk_ref is on the crystal |
| the shared scenario | `1`, `A` and `0`, the bytes the emulator lane's application is fed, echoed, with `g` 8 after `1` and 0 after `0`, and with `--indicator-pin` the wire high after `1` and low after `0`; the probe's pin is pulled up when nothing drives it, so low is what shows the Pico driving it |
| IRQ5 | one entry, in exception 21 |
| an overrun | after 0x12, a 300-byte burst into the 256-byte ring is discarded, never echoed, and the ring restarts once |
| an epoch ended by STALL | the 4096-byte epoch filled, its last byte STALL, then 100 bytes while the channel is exhausted and nothing reads: the UART's 32-byte FIFO holds the first 32, it flags the rest lost, the application restarts on that overrun, and only those 32 are echoed |
| an epoch exhausted | the next epoch filled to its 4096 bytes: one DMA completion, one restart, nothing lost, and the byte that waited in the FIFO meanwhile the next epoch's first |
| the stream | every application byte echoed in order but those discarded above, `h` their count, and the timer advancing |
| the line exchange | not run: the console is probehive's bridge, fixed at 115200 8N1; the serial module's `configure` is linked into no image, and only `runtime/library-shared-line`'s arithmetic at 12 MHz and the derived driver's PL011 register images on QEMU stand behind it (D958, D963) |
| the counters | `handled`, `recoveries`, `dma_events`, `usb_events` and TRANS_COUNT, read over SWD without halting the core, equal the last frame's |

What the emulator lane and the board share is
`compiler/tests/driver/commands` (D593): the echo and the indicator, which
the application gives its own indicator and transmitter (D645). The
board's receive protocol is the RP2040's (D594), not the synthetic drain.
What `board.py` shares with the other boards' tools, the framing, the
command log, the ELF reader, probe-rs, the hub, the console and the record,
is [`../common.py`](../common.py) (D646); the oracle is this board's own.
