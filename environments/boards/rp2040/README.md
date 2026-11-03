# The first board: a Raspberry Pi Pico

The prototype-1 board port, `compiler/tests/board/rp2040`, built by refine
for the Pico's RP2040 through `devices/descriptions/rp2040`, flashed, and
booted from power-on with nothing attached to its core. `board.py` builds
the image, flashes it, switches the Pico's power and checks what the board
writes on its UART against a physical oracle written from what the host
sent and from the RP2040 datasheet (D595). It is a developer tool: no
compiler feature runs it or needs it, and the gate does not run it, since
no hosted runner has the board.

## What it needs

| What | Which | Why |
|---|---|---|
| the board | a Raspberry Pi Pico H, its SWD on the 3-pin debug connector, GPIO0 (UART0 TX) to the probe's UART RX and GPIO1 (UART0 RX) to its TX, powered from its USB port | the RP2040 and its 2 MiB W25Q16JV flash, as the description lays them out |
| a probe | a [probehive](https://github.com/JanHaan/probehive) SWD slot, slot 0 by default, `--slot`, and a checkout of it, whose `scripts/dap_bridge.py` serves slot N's UART as TCP port 4461 + N; a bridge already listening on the slot's ports is reused and left running, and otherwise the tool starts one for every slot of the probe, `--bridge-slots`, and leaves it running for the next tool | SWD to flash and read back, and the UART the trace comes over |
| probe-rs | one that reaches the slot as `--probe` names it: the CMSIS-DAP UDP transport the default `0000:0002:10.42.0.50/0` asks for is a pull request to probe-rs, and upstream's TCP transport reaches a bridge as `0000:0001:HOST:PORT` | flashing, verifying and reading memory |
| the indicator's wire | optionally, GPIO3 (the Pico's pin 5) wired to one of the probe's GPIO, named with `--indicator-pin`; IO32 on the maintainer's rig. probehive's `scripts/gpio.py` reads it, with the LiteX its `nix develop` carries | the indicator's level on the wire, not only as its pad reads it back |
| power | the Pico's USB port on a hub with per-port power switching, and `uhubctl` with the right to switch it | a power cycle, so the run starts at power-on |
| the compiler | refine and `arm-eabi-gcc` or `arm-none-eabi-gcc` (D532), as `nix develop` gives them | the image |

`uhubctl` needs write access to the hub's port `disable` files; on a host
where those belong to a group, `--hub-group`, `dialout` by default, the tool
runs `uhubctl` through `/run/wrappers/bin/sg GROUP -c` when the session is
not in that group, as a session started before its user joined it is not.
The tool switches only `--port` on `--hub`, and only while
the device with `--guard-serial`, the probe's own Arty A7, is present and not on
`--cascade`, the hub cascade the boards are on (by default the one `0bda:5411`
hub whose parent is not one, wherever it is attached, D833), found by its serial wherever it is plugged in: its bitstream is held
only in SRAM and would be lost with its power, and on the cascade's earlier
port a switch re-enumerated the whole of it (D725). The port is switched off and on in one
`uhubctl -a cycle`: on that port switching it off re-enumerated the hub's inner hubs, and
a second call could meet their new device nodes before udev had given them
the group allowed to switch them. The run holds the rig's lock,
`~/.cache/landin/rig.lock`, from its build to its last read; its download
and its cycle each stop on any USB trouble the kernel logged since the last
such action by any tool on the host, since on that port even a download to
the Pico, which enumerates nothing, was followed by the whole cascade
disconnecting; and after the download and after the cycle the tool waits,
up to `--hub-seconds`, for the hub to list again (D725, D832).
No action waits for a fixed time: on the cascade's present port a switch
drops only the device on the port switched, back within seconds, and
`--spacing` and `--quiet`, a time between two actions and one the kernel
must have logged nothing of USB for, are options, none by default. `--hub`
is named as `uhubctl -l` names
it, or relative to the cascade's root; the default is the maintainer's rig:
hub `.3.3`, port 1.

## Running it

```sh
python3 environments/boards/rp2040/board.py \
    --refine compiler/ada/build/nix-x86_64-linux/debug/bin/refine \
    --probehive ~/src/probehive --probe-rs PATH/TO/probe-rs --probe 0000:0002:10.42.0.50/0 \
    --hub .3.3 --port 1 --guard-serial 210319B3E738 \
    --indicator-pin IO32 \
    --output NEW_DIRECTORY
```

The output holds the image, its build report and every command's log, the
bridge's log when it started one, `uart.bin` (every byte the board sent) and `sent.bin` (every
byte the host sent), and `result.json`: the image's and the second stage's
hashes, the stage's CRC, whether the bridge was reused, each verdict, every frame and the commands with
their status and time. The run the item recorded is
[`record.json`](record.json), whose image was built as `board.elf`; it
predates the record's `image_name`. The linked ELF holds the name of the object refine assembled beside it, so its hash depends on the output's name: a record gives the name as `image_name`, and a reader rebuilding the image to check the hash builds it under that name.

## The trace

The firmware writes frames between the echoed bytes: STX, a tag letter, a
field per key, ` k=` and eight lowercase hex digits, then ETX and LF. The
host never sends STX or ETX.

| Tag | When | Fields |
|---|---|---|
| `b` | once, after the clocks, the resets and the receiver are set up | `r` CHIP_RESET as read first in `start`, `v` VTOR then, `k` CLK_REF_SELECTED |
| `t` | after each 0x11 | `h` bytes handled, `c` ring restarts, `d` DMA completions, `m` timer interrupts, `u` USBCTRL_IRQ entries, `p` the exception number it ran in, `n` DMA channel 0's TRANS_COUNT, `e` bytes consumed in this epoch, `g` the indicator's pad read back, `s` the application's state |
| `h` | when the application halts | `s` its status |

Three bytes are commands after their echo: 0x05 sets IRQ5 pending in the
NVIC (D596), 0x11 asks for a `t` frame, and 0x12 stops reading for 100 ms.

## The oracle

| Checked | Against |
|---|---|
| the ELF's `.boot2` | 256 bytes at 0x1000_0000, not empty, its last word the CRC-32 of the first 252 as the boot ROM computes it (datasheet 2.8.1.3.1) |
| vector word 21 | the USBCTRL_IRQ handler's address, Thumb bit set |
| flash after flashing | its first 256 bytes, read back over SWD, equal to the image's |
| the boot frame | CHIP_RESET is HAD_POR alone, so the run began at power-on; VTOR is 0x1000_0100, which only the second stage writes, so the ROM entered the flashed stage and the stage entered compiler-owned reset; clk_ref is on the crystal |
| the shared scenario | `1`, `A` and `0`, the bytes the emulator lane's application is fed, echoed, with `g` 8 after `1` and 0 after `0`, and with `--indicator-pin` the wire high after `1` and low after `0`; the probe's pin is pulled up when nothing drives it, so low is what shows the Pico driving it |
| IRQ5 | one entry, in exception 21 |
| an overrun | after 0x12, a 300-byte burst into the 256-byte ring is discarded, never echoed, and the ring restarts once |
| an epoch ended by STALL | the 4096-byte epoch filled, its last byte STALL, then 100 bytes while the channel is exhausted and nothing reads: the UART's 32-byte FIFO holds the first 32, it flags the rest lost, the application restarts on that overrun, and only those 32 are echoed |
| an epoch exhausted | the next epoch filled to its 4096 bytes: one DMA completion, one restart, nothing lost, and the byte that waited in the FIFO meanwhile the next epoch's first |
| the stream | every byte sent echoed in order but those discarded above, `h` their count, and the timer advancing |
| the counters | `handled`, `recoveries`, `dma_events`, `usb_events` and TRANS_COUNT, read over SWD without halting the core, equal the last frame's |

What the emulator lane and the board share is
`compiler/tests/driver/commands` (D593): the echo and the indicator, which
the application gives its own indicator and transmitter (D645). The
board's receive protocol is the RP2040's (D594), not the synthetic drain.
What `board.py` shares with the other boards' tools, the framing, the
command log, the ELF reader, probe-rs, the hub, the console and the record,
is [`../common.py`](../common.py) (D646); the oracle is this board's own.
