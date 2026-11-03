# The RP2350 board on its Hazard3 cores: a Raspberry Pi Pico 2

The prototype-1 board port on the Pico 2's RISC-V cores,
`compiler/tests/board/rp2350_hazard3`, built by refine for `--target=rv32`
at `--level=rv32imac` through `devices/descriptions/rp2350_hazard3`,
flashed, and booted from power-on with nothing attached to its cores. It
is [the Pico 2's Arm port](../rp2350/README.md) (D654) with its
interrupts through Hazard3's Xh3irq rather than the NVIC, and with a
counter kept by an `amoadd.w`, an A-extension read-modify-write (D710).
The port is its `app` alone: its `bringup`, `report` and `serial` are the
Arm port's, under `compiler/tests/board/rp2350`, which the tool names as a
root after the port's own, over the chip's modules, `rp2350/PERIPHERAL`
(D831). `board.py` builds the image, flashes it, switches the Pico 2's
power and checks what the board writes on its UART against a physical
oracle written from what the host sent and from the RP2350 datasheet,
release 8 (D711). It is a developer tool: no compiler feature runs it or
needs it, and the gate does not run it, since no hosted runner has the
board. What it shares with the other boards' tools is
[`../common.py`](../common.py) (D646).

## What it needs

| What | Which | Why |
|---|---|---|
| the board | a Raspberry Pi Pico 2 H, its SWD on the 3-pin debug connector, GPIO0 (UART0 TX) to slot 1's UART RX and GPIO1 (UART0 RX) to its TX, powered from its USB port | the RP2350 and its 4 MiB flash, as the description lays them out |
| a probe | a [probehive](https://github.com/JanHaan/probehive) SWD slot, slot 1 by default, `--slot`, and a checkout of probehive, whose `scripts/dap_bridge.py` serves slot N's SWD as TCP port 4441 + N and its UART as 4461 + N | SWD to flash and read back, and the UART the trace comes over |
| probe-rs | one with the CMSIS-DAP TCP transport, `0000:0001:127.0.0.1:PORT`, and the `RP235x` and `RP235x_riscv` targets | flashing, verifying and reading memory |
| the indicator's wire | optionally, GPIO3 wired to one of the probe's GPIO, named with `--indicator-pin`; probehive's `scripts/gpio.py` reads it | the indicator's level on the wire, not only as its pad reads it back |
| power | the Pico 2's USB port on a hub with per-port power switching, and `uhubctl` with the right to switch it | a power cycle, so the run starts at power-on |
| the compiler | refine and `riscv64-elf-gcc` or `riscv64-unknown-elf-gcc` (D660), with that toolchain's `nm` and `objdump`, as `nix develop` gives them | the image, and the symbols and the `amoadd.w` it is checked for |

The tool reaches the slot through the bridge alone, so probe-rs and the
console share the slot's one CMSIS-DAP client rather than meeting as two.
A bridge already listening on both of the slot's ports is reused and never
stopped; otherwise the tool starts one serving every slot of the probe,
`--bridge-slots`, and leaves it running when it ends, so that another
board's tool on another slot finds it (D713). `result.json` says which.

The tool switches only `--port` on `--hub`, and only while
the device with `--guard-serial`, the probe's own Arty A7, is present and not on
`--cascade`, the hub cascade the boards are on (`7-2` on the maintainer's
rig), found by its serial wherever it is plugged in: its bitstream is held
only in SRAM and would be lost with its power, and every switch on the
cascade re-enumerates the whole of it (D725), as [the Pico 2's Arm tool](../rp2350/README.md) does. On
the rig such a cycle coincided with a reset of the whole hub tree above it,
the Arty's USB among it, while the kernel was failing to enumerate the
port. So the tool holds the rig's lock, `~/.cache/landin/rig.lock`, from
its first step on the rig to its last, and spaces each download and cycle
from every other tool's on the host, by `--spacing` seconds and until the
kernel has logged nothing of USB for `--quiet` seconds, stopping on any
USB trouble the kernel logged since the last such action (D725). After
the cycle it waits `--guard-seconds` for that device to be present again,
still off the cascade, and pings `--probe-host`, and stops if either is missing. A
listing of the hub that meets the tree re-enumerating is asked again until
`--guard-seconds` have passed.
The defaults are the maintainer's rig: hub `7-2.3.3`, port 2, on the
cascade `7-2`.

## Which chip probe-rs is told

probe-rs names the RP2350 twice, and which one reaches it follows the
architecture its cores run when probe-rs attaches, not the operation
(D712):

| The chip is | `RP235x` | `RP235x_riscv` |
|---|---|---|
| running a RISC-V image, after its boot ROM switched the cores | a FAULT from the Arm access ports | reads, writes and flashes |
| in BOOTSEL, its boot ROM on Arm | reads, writes and flashes | a debug module timeout |
| just flashed as `RP235x` | reads | a debug module timeout |

So the tool reads one word as `RP235x` first, whose refusal is quick, then
as `RP235x_riscv`, and flashes through whichever answered. Every probe-rs
attach as `RP235x` halts both cores. A Pico 2 in BOOTSEL halted that way
keeps its USB pull-up but stops answering, and the host then retries the
port for minutes: on the maintainer's rig the kernel power-cycled the
port itself every two minutes, the whole hub tree above it reset with the
probe's own USB, and every probe-rs start spent 85 s in its USB probe
listing. So the tool refuses to attach while the Pico 2's port shows
BOOTSEL, 2e8a:000f, unless told `--bootsel-attach`; if it ever does, cycle
the port once and wait for it to stop enumerating before anything else.
After flashing through the Arm side the tool cycles the power at once,
gives the boot ROM `--boot-seconds`, and reads the head back from the cores
the new image runs on. The counters are read as `RP235x_riscv` alone, from
the cores the image booted on.

The negative control ends in BOOTSEL and must then flash the image
again, which is that attach, so `--block-control` needs `--bootsel-attach`
and belongs on a hub that does not carry the probe. On the maintainer's
rig it does not run at present.

## Running it

```sh
python3 environments/boards/rp2350_hazard3/board.py \
    --refine compiler/ada/build/nix-x86_64-linux/debug/bin/refine \
    --probehive ~/src/probehive --probe-rs PATH/TO/probe-rs --slot 1 \
    --hub 7-2.3.3 --port 2 --guard-serial 210319B3E738 \
    --output NEW_DIRECTORY
```

The output holds the image, its build report, its disassembly and every
command's log, the bridge's log when it started one, `uart.bin` (every
byte the board sent) and `sent.bin` (every byte the host sent), and
`result.json`: the image's hash, its block, where its `amoadd.w` is, which
chip it was flashed as, whether the bridge was reused, the block control's
verdict, each verdict, every frame and the commands with their status and
time. `--record` writes a passed run's record. The linked ELF holds the
name of the object refine assembled beside it, so its hash depends on the
output's name: a record gives the name as `image_name`.

## The trace

The firmware writes frames between the echoed bytes in the Pico 2's form:
STX, a tag letter, a field per key, ` k=` and eight lowercase hex digits,
then ETX and LF. The host never sends STX or ETX.

| Tag | When | Fields |
|---|---|---|
| `b` | once, after the clocks, the resets, the pads and the receiver are set up | `r` POWMAN's CHIP_RESET as read first in `start`, `v` mtvec then, `a` marchid, `k` CLK_REF_SELECTED |
| `t` | after each 0x11 | `h` bytes handled, `c` ring restarts, `d` DMA completions, `m` timer interrupts, `u` USBCTRL_IRQ entries, `p` the mcause it ran under, `n` DMA channel 0's TRANS_COUNT count, `e` bytes consumed in this epoch, `g` the indicator's pad read back, `s` the application's state, `q` what the `amoadd.w` that counted this frame returned |
| `h` | when the application halts | `s` its status |

Three bytes are commands after their echo: 0x05 forces IRQ14,
USBCTRL_IRQ, pending through meifa with USBCTRL held in reset, and its
handler stops forcing it; 0x11 asks for a `t` frame; and 0x12 stops
reading for 100 ms.

## The oracle

| Checked | Against |
|---|---|
| the ELF | EM_RISCV; its first word, at 0x1000_0000 where the boot ROM enters a RISC-V image, a `jal x0` to `_landin_firmware_reset` |
| the ELF's trap table | 68 words at 0x1000_0200, the build report's `vector_address`, 512-aligned as D662 aligns 272 bytes; slot 11, the machine external interrupt, a jump to the meinext dispatch, slots 16, 26 and 30, TIMER0_IRQ_0, DMA_IRQ_0 and USBCTRL_IRQ (3.2, Table 95, p. 81), jumps to their handlers, and every other slot a jump to the unhandled loop |
| the ELF's block | directly after the table and inside the first 4 KiB, at the report's address, the minimum RISC-V IMAGE_DEF (5.9.5.1, Table 503, p. 390): the start and end markers (5.1.5.1, p. 329), IMAGE_TYPE a RISC-V executable for RP2350, LAST and a link to itself |
| the read-modify-write | an `amoadd.w` in the image's disassembly, on a counter in SRAM, where Hazard3's atomics reach (3.8.9, MCAUSE, Table 403) |
| the block control, with `--block-control` | a copy whose end marker is flipped, flashed and power-cycled, is refused by the boot ROM, which enumerates as USB BOOTSEL, 2e8a:000f (5.6.1, Table 470, p. 370); the good image is then flashed again |
| flash after flashing | the entry word, the table and the block, read back over SWD, equal to the image's |
| the boot frame | CHIP_RESET is HAD_POR alone (6.4, p. 429), so the run began at power-on; marchid is 0x1b, Hazard3 (3.8.9, Table 440), so the boot ROM switched the cores to RISC-V and entered this image; mtvec is the table in vectored mode, 0x1000_0201 (Table 394), so compiler-owned reset ran; clk_ref is on the crystal |
| the shared scenario | `1`, `A` and `0`, the bytes the emulator lane's application is fed, echoed, with `g` 8 after `1` and 0 after `0`, and with `--indicator-pin` the wire high after `1` and low after `0` |
| IRQ14 | one entry, under mcause 0x8000_000b, the machine external interrupt (Table 403), which meinext resolved to slot 30 |
| the `amoadd.w` | frame n's `q` is n, every frame the host asked for counted once, and the counter read over SWD is the number of frames |
| an overrun | after 0x12, a 300-byte burst into the 256-byte ring is discarded, never echoed, and the ring restarts once |
| an epoch ended by STALL | the 4096-byte epoch filled, its last byte STALL, then 100 bytes while the channel is exhausted and nothing reads: the UART's 32-byte FIFO holds the first 32, it flags the rest lost, the application restarts on that overrun, and only those 32 are echoed |
| an epoch exhausted | the next epoch filled to its 4096 bytes: one DMA completion, one restart, nothing lost |
| the stream | every byte sent echoed in order but those discarded above, `h` their count, and the timer advancing |
| the counters | `handled`, `recoveries`, `dma_events`, `usb_events`, `reports` and TRANS_COUNT's count, read over SWD as `RP235x_riscv` once the scenario has ended, equal the last frame's |

What the emulator lane and the boards share is
`compiler/tests/driver/commands` (D593, D645): the echo and the indicator.
