# The RP2350 board: a Raspberry Pi Pico 2

The prototype-1 board port, `compiler/tests/board/rp2350`, built by refine
for the Pico 2's RP2350 at `--level=armv8-m.main` through
`devices/descriptions/rp2350`, flashed, and booted from power-on with
nothing attached to its core. It runs on the Cortex-M33 in Secure state, as
its image block says, and uses no float. `board.py` builds the image,
flashes it, switches the Pico 2's power and checks what the board writes on
its UART against a physical oracle written from what the host sent and
from the RP2350 datasheet, release 8 (D655). It is a developer tool: no
compiler feature runs it or needs it, and the gate does not run it, since
no hosted runner has the board. What it shares with the other boards'
tools is [`../common.py`](../common.py) (D646); the application is the
RP2040 board's port (D593-D596) on this chip's own registers (D654).

## What it needs

| What | Which | Why |
|---|---|---|
| the board | a Raspberry Pi Pico 2 H, its SWD on the 3-pin debug connector, GPIO0 (UART0 TX) to slot 1's UART RX and GPIO1 (UART0 RX) to its TX, powered from its USB port | the RP2350 and its 4 MiB flash, as the description lays them out |
| a probe | a [probehive](https://github.com/JanHaan/probehive) SWD slot, slot 1 by default, `--slot`, and a checkout of probehive, whose `scripts/dap_bridge.py` serves slot N's UART as TCP port 4461 + N | SWD to flash and read back, and the UART the trace comes over |
| probe-rs | one that reaches the slot as `--probe` names it, `0000:0002:10.42.0.50/1` by default, the CMSIS-DAP UDP transport, with `--chip RP235x` | flashing, verifying and reading memory |
| the indicator's wire | optionally, GPIO3 wired to one of the probe's GPIO, named with `--indicator-pin`; probehive's `scripts/gpio.py` reads it | the indicator's level on the wire, not only as its pad reads it back |
| power | the Pico 2's USB port on a hub with per-port power switching, and `uhubctl` with the right to switch it | a power cycle, so the run starts at power-on |
| the compiler | refine and `arm-eabi-gcc` or `arm-none-eabi-gcc` (D532), as `nix develop` gives them | the image |

The tool switches only `--port` on `--hub`, and only while
the device with `--guard-serial`, the probe's own Arty A7, is present and not on
`--cascade`, the hub cascade the boards are on (`7-2` on the maintainer's
rig), found by its serial wherever it is plugged in: its bitstream is held
only in SRAM and would be lost with its power, and every switch on the
cascade re-enumerates the whole of it (D725), as [the RP2040's tool](../rp2040/README.md) does: this
firmware does not enumerate on USB, so the Pico 2's port shows no device of
its own while it runs. With `--pico-serial`, the port must also show that
serial whenever it shows a device, which a Pico 2 does in BOOTSEL. The
port is switched off and on in one `uhubctl -a cycle`, through
`/run/wrappers/bin/sg GROUP -c`, `--hub-group`, when the session is not in
the group that may switch it. The defaults are the maintainer's rig: hub
`7-2.3.3`, port 2, on the cascade `7-2`.

How the tool switches, paces and waits is [`../pico2.py`](../pico2.py)'s,
which [the Hazard3 tool](../rp2350_hazard3/README.md) shares, since both run
the same board on the same port (D832). The run holds the rig's lock,
`~/.cache/landin/rig.lock`, from its first step on the rig to its last; it
spaces each download and cycle from every other tool's on the host, by
`--spacing` seconds and until the kernel has logged nothing of USB for
`--quiet` seconds, stopping on any USB trouble the kernel logged since the
last such action; and after each it waits up to `--guard-seconds` for the
hub to list again and the Arty to be found off the cascade, and pings
`--probe-host`. Every probe-rs attach as `RP235x` halts both cores, and a
Pico 2 in BOOTSEL halted so keeps its USB pull-up but stops answering,
which on the rig reset the hub tree above it (D712). So the tool refuses
to attach while the port shows BOOTSEL, 2e8a:000f, unless told
`--bootsel-attach`, which `--block-control` needs, since it flashes the
good image again from BOOTSEL; after a flash from BOOTSEL it cycles the
power at once, unpaced, gives the boot ROM `--boot-seconds`, and reads the
head back from the image, never from BOOTSEL.

## Running it

```sh
python3 environments/boards/rp2350/board.py \
    --refine compiler/ada/build/nix-x86_64-linux/debug/bin/refine \
    --probehive ~/src/probehive --probe-rs PATH/TO/probe-rs --slot 1 \
    --hub 7-2.3.3 --port 2 --guard-serial 210319B3E738 \
    --block-control --bootsel-attach --output NEW_DIRECTORY
```

The output holds the image, its build report and every command's log, the
bridge's log, `uart.bin` (every byte the board sent) and `sent.bin` (every
byte the host sent), and `result.json`: the image's hash, its block, the
block control's verdict, each verdict, every frame and the commands with
their status and time. `--record` writes a passed run's record. The linked ELF holds the name of the object refine assembled beside it, so its hash depends on the output's name: a record gives the name as `image_name`, and a reader rebuilding the image to check the hash builds it under that name.

## The trace

The firmware writes frames between the echoed bytes in the RP2040 board's
form: STX, a tag letter, a field per key, ` k=` and eight lowercase hex
digits, then ETX and LF. The host never sends STX or ETX.

| Tag | When | Fields |
|---|---|---|
| `b` | once, after the clocks, the resets, the pads and the receiver are set up | `r` POWMAN's CHIP_RESET as read first in `start`, `v` VTOR then, `k` CLK_REF_SELECTED |
| `t` | after each 0x11 | `h` bytes handled, `c` ring restarts, `d` DMA completions, `m` timer interrupts, `u` USBCTRL_IRQ entries, `p` the exception number it ran in, `n` DMA channel 0's TRANS_COUNT count, `e` bytes consumed in this epoch, `g` the indicator's pad read back, `s` the application's state |
| `h` | when the application halts | `s` its status |

Three bytes are commands after their echo: 0x05 sets IRQ14, USBCTRL_IRQ,
pending in the NVIC with USBCTRL held in reset (D596), 0x11 asks for a `t`
frame, and 0x12 stops reading for 100 ms.

## The oracle

| Checked | Against |
|---|---|
| the ELF's vector table | 68 words at 0x1000_0000, the start of flash, word 30 the USBCTRL_IRQ handler (3.2, Table 95, p. 81) |
| the ELF's block | directly after the table, the minimum Arm IMAGE_DEF (5.9.5.1, Table 503, p. 390): the start and end markers (5.1.5.1, p. 329), IMAGE_TYPE an Arm executable in Secure state for RP2350, LAST and a link to itself |
| the block control, with `--block-control` | a copy whose end marker is flipped, flashed and power-cycled, is refused by the boot ROM, which enumerates as USB BOOTSEL, 2e8a:000f (5.6.1, Table 470, p. 370); the good image is then flashed again, from BOOTSEL, and the power cycled at once |
| flash after flashing | the vector table and the block, read back over SWD, equal to the image's |
| the boot frame | CHIP_RESET is HAD_POR alone (6.4, p. 429), so the run began at power-on; VTOR is 0x1000_0000, so the boot ROM took the block and entered this image; clk_ref is on the crystal |
| the shared scenario | `1`, `A` and `0`, the bytes the emulator lane's application is fed, echoed, with `g` 8 after `1` and 0 after `0`, and with `--indicator-pin` the wire high after `1` and low after `0` |
| IRQ14 | one entry, in exception 30 |
| an overrun | after 0x12, a 300-byte burst into the 256-byte ring is discarded, never echoed, and the ring restarts once |
| an epoch ended by STALL | the 4096-byte epoch filled, its last byte STALL, then 100 bytes while the channel is exhausted and nothing reads: the UART's 32-byte FIFO holds the first 32, it flags the rest lost, the application restarts on that overrun, and only those 32 are echoed |
| an epoch exhausted | the next epoch filled to its 4096 bytes: one DMA completion, one restart, nothing lost |
| the stream | every byte sent echoed in order but those discarded above, `h` their count, and the timer advancing |
| the counters | `handled`, `recoveries`, `dma_events`, `usb_events` and TRANS_COUNT's count, read over SWD without halting the core, equal the last frame's |

What the emulator lane and the boards share is
`compiler/tests/driver/commands` (D593, D645): the echo and the indicator.
