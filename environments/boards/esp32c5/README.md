# The ESP32-C5 board: an Olimex ESP32-C5-DevKit-Lipo

The prototype-1 board port, `compiler/tests/board/esp32c5`, built by refine
for the ESP32-C5 at `--level=rv32imac` through `devices/descriptions/esp32c5`
as a RAM-only `esp-app-image` (D683, D707), written to flash at offset
0x2000, and booted from power-on by the chip's ROM with no second stage.
`board.py` builds the image, reads it apart from refine, flashes it, cuts
all the board's power, reads over JTAG what the chip recorded of its boot,
then resets it through its enable pin with the console open and checks
what the ROM and then the program write on UART0 against a physical oracle
written from what the host sent, the ESP32-C5 Technical Reference Manual
v1.1 and ESP-IDF v6.1's image format (D722, D724). It is a developer tool: no compiler feature runs it or needs it,
and the gate does not run it, since no hosted runner has the board. What
it shares with the ESP32-C3's tool is [`../esp.py`](../esp.py) (D723), and
with every board's [`../common.py`](../common.py) (D646).

## What it needs

| What | Which | Why |
|---|---|---|
| the board | an Olimex ESP32-C5-DevKit-Lipo with both USB-C ports on the hub: the chip's own USB-Serial-JTAG, and USB-UART1, a CH340X bridge on UART0, GPIO11 (TX) and GPIO12 (RX), whose DTR and RTS drive EN and the GPIO28 boot strap through the board's auto-reset transistors | the chip, its flash and its ROM |
| a console | the CH340X's tty, found by the hub port it is plugged into, `--console-port`, since it has no USB serial of its own, and opened with DTR and RTS inactive | UART0 |
| probe-rs | one that reaches the board's USB-Serial-JTAG, `--probe 303a:1001:SERIAL`, with `--chip esp32c5` | flashing the image raw at 0x2000 with verification, and reading memory |
| power | both ports on a hub with per-port power switching, and `uhubctl` with the right to switch them | a power cycle that cuts all the board's power |
| the compiler | refine, `riscv64-elf-gcc`, `-nm` and `-objdump` (D532, D695), as `nix develop` gives them | the image and its disassembly |

Either USB-C powers the board, so the chip runs before either port has
enumerated and the console cannot be open when the power returns. The
boot from power-on is therefore shown over JTAG, as soon as the
USB-Serial-JTAG enumerates: LP_CLKRST_RESET_CAUSE reads 1, the chip reset
(TRM 9.1.4, Table 9.1-1), the program's own reading of it is 1, the
application is running, and its timer interrupts are advancing. Then, with
the console open, RTS alone pulls EN low for 100 ms with DTR inactive, so
GPIO28 stays high and the ROM boots from flash again, and the console reads
that boot's log and the scenario. The ROM reports a chip-enable reset as a
power-on reset, `rst:0x1`, which the oracle requires (D724).

The tool switches only `--port` and `--console-port` on `--hub`, together,
and only after `uhubctl` shows `--serial` and `--console-device` on them
and `--guard-device` on `--guard-port`, the J-Link on the maintainer's rig,
which is never switched; after every switch and download it waits for the
hub to list the board again (D725). The run holds the rig's lock. The
defaults are the maintainer's rig: hub `7-2.3.4`, the JTAG on port 3,
guarded by port 1.

## Running it

```sh
python3 environments/boards/esp32c5/board.py \
    --refine compiler/ada/build/nix-x86_64-linux/debug/bin/refine \
    --probe-rs PATH/TO/probe-rs --image-control --output NEW_DIRECTORY
```

The output holds the ELF, `board.elf.bin` (the image refine wrote), the
build report, the disassembly and every command's log, `rom.log` (what the
ROM wrote before the program's first frame), with `--image-control` the
two controls' ROM logs, `uart.bin` (every byte the board sent) and
`sent.bin` (every byte the host sent), and `result.json`: the image's and
the ELF's hashes, the image as read, its A-extension instructions,
what JTAG read of the power-on boot, each verdict, the counters and cells
read over JTAG, the segments read
back, every frame and the commands with their status and time.
`--record` writes a passed run's record. An image that leaves JTAG
unanswered, as one whose RAM code the C3 could not fetch did, keeps
probe-rs from flashing the next one; `--recover` first resets the chip into
its ROM's download mode through its own USB-Serial-JTAG, whose DTR and RTS
it turns into a reset with the boot strap held low, as esptool does. The linked ELF holds the name of
the object refine assembled beside it, so its hash depends on the output's
name: a record gives the image's name as `image_name`.

## The trace

The firmware writes frames between the echoed bytes in the RP2040 board's
form: STX, a tag letter, a field per key, ` k=` and eight lowercase hex
digits, then ETX and LF. The host never sends STX or ETX.

| Tag | When | Fields |
|---|---|---|
| `b` | once, after the indicator, the timer and the receiver are set up | `r` LP_CLKRST_RESET_CAUSE's cause as read first in `start`, `v` mtvec, `t` mintthresh as the ROM left it |
| `t` | after each 0x11 | `h` bytes handled, `c` ring restarts, `i` receive interrupts, `m` timer interrupts, `p` and `q` mcause in the last receive and timer interrupt, `k` timer interrupts in the last threshold window, `l` bytes the receive interrupt dropped, `o` RX FIFO overflows it saw, `e` bytes consumed, `g` the indicator's pad read back, `s` the application's state |
| `a` | after each 0x06 | `p` what the word cell's add returned, `q` and `r` what its two compare-exchanges observed, `d` the word cell after them, `e` what the byte cell's add returned, `f` the byte cell after it |
| `h` | when the application halts | `s` its status |

Four bytes are commands after their echo: 0x06 runs the atomics over the
two bytes received before it, 0x11 asks for a `t` frame, 0x12 stops
reading for 100 ms, and 0x13 raises mintthresh to the receive interrupt's
level for 100 ms (D721).

## The oracle

| Checked | Against |
|---|---|
| the image, read apart from refine | ESP-IDF v6.1's `esp_app_format.h` and `esp_image_format.h`: magic 0xE9, chip 23, revisions 100 to 199, legacy minimum 0, DIO and 0x20, entry the ELF's and SRAM's origin 0x4080_0000, each segment the ELF's loadable segment, zero padding, the checksum of every segment byte into 0xEF, the SHA-256 of what precedes it, and nothing after; refine's build report says the same |
| the instructions | the linked disassembly holds an AMO and an LR/SC pair, the A extension the level has |
| the checksum control, with `--image-control` | a copy whose checksum byte is flipped: the ROM says `Checksum failure`, computing the image's own checksum and finding the flipped one, never enters the image and the program writes nothing |
| the SHA-256 control, with `--image-control` | a copy whose hash's last byte is flipped: the ROM says `SHA-256 comparison failed`, computing the image's own hash, and without secure boot boots the image anyway |
| flash | `probe-rs download --binary-format bin --base-address 0x2000 --verify` |
| the power-on boot, over JTAG | LP_CLKRST_RESET_CAUSE's cause 1, the program's `boot_reason` 1, `app_state` 2 and `timer_events` advancing |
| the ROM's log, after the chip-enable reset | `rst:0x1 (POWERON)`, a `SPI_FAST_FLASH_BOOT`, one `load:` per segment at its address and length, in order, and `entry` the header's |
| the boot frame | the reset cause 1; mtvec compiler-owned trap entry's address with mode 3, CLIC (D680; TRM 2.8.2) |
| the shared scenario | `1`, `A` and `0` echoed, with `g` 0x0100_0000 after `1` and 0 after `0` |
| the interrupts | receive on CLIC identity 17, mcause's code 0x11 with its interrupt bit; the timer on 18, 0x12 |
| the atomics | over two printable operands x and y the host chose: the add returns x, the first compare-exchange observes x + y and stores x ^ y, the second observes x ^ y and stores nothing, the cell holds x ^ y; the byte cell's add returns x and leaves x + y, wrapped to eight bits |
| a ring overrun | after 0x12, a 300-byte burst into the 256-byte ring: 44 bytes dropped, one restart, none of the burst echoed |
| a FIFO overflow | after 0x13, a 300-byte burst while mintthresh holds the receive interrupt off: one RX FIFO overflow, a second restart, none of it echoed, and 99 to 101 timer interrupts in the 100 ms window, since the timer's level is above the threshold |
| the stream | 3000 more bytes, and every byte sent echoed in order but the two bursts, `h` their count, and the timer advancing |
| the counters | `handled`, `recoveries`, `dropped`, `overflows`, `entries` and `boot_reason`, and the two atomic cells, read over JTAG after the scenario, equal the last frames |
| SRAM | the image's read-only segments, read over JTAG, are OUT.bin's bytes: what the ROM loaded is the image |

What the emulator lane and the boards share is
`compiler/tests/driver/commands` (D593, D645): the echo and the indicator.
