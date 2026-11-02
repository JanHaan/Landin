# The ESP32-C3 board: an Olimex ESP32-C3-DevKit-Lipo

The prototype-1 board port, `compiler/tests/board/esp32c3`, built by refine
for the ESP32-C3 at `--level=rv32imc` through `devices/descriptions/esp32c3`
as a RAM-only `esp-app-image` (D683, D707), written to flash at offset 0,
and booted from power-on by the chip's ROM with no second stage.
`board.py` builds the image, reads it apart from refine, flashes it, cuts
the board's power and checks what the ROM and then the program write on
UART0 against a physical oracle written from what the host sent, the
ESP32-C3 Technical Reference Manual v1.4 and ESP-IDF v6.1's image format
(D722). It is a developer tool: no compiler feature runs it or needs it,
and the gate does not run it, since no hosted runner has the board. What
it shares with the ESP32-C5's tool is [`../esp.py`](../esp.py) (D723), and
with every board's [`../common.py`](../common.py) (D646).

The console is UART0 and not the board's USB-C, though that is a serial
port too: the USB-C is the chip's own USB-Serial-JTAG, which drops off the
bus whenever the chip resets or loses power, so a port opened on it misses
everything the ROM prints at boot, the account of the image it loaded that
the oracle checks first.

## What it needs

| What | Which | Why |
|---|---|---|
| the board | an Olimex ESP32-C3-DevKit-Lipo, powered from its USB-C, which is the chip's own USB-Serial-JTAG; UART0 on its EXT2 header, pin 4 IO21 (TX) to the console's RX and pin 5 IO20 (RX) to its TX, and GND | the chip, its flash and its ROM |
| a console | a [probehive](https://github.com/JanHaan/probehive) slot's UART, slot 2 by default, `--slot`, whose bridge, `scripts/dap_bridge.py`, serves slot N's UART as TCP port 4461 + N; a bridge already listening is used, and with `--probehive` the tool starts one when none is | UART0, powered apart from the board, so the ROM's log from power-on is read whole |
| probe-rs | one that reaches the board's USB-Serial-JTAG, `--probe 303a:1001:SERIAL`, with `--chip esp32c3` | flashing the image raw at offset 0 with verification, and reading memory |
| power | the board's USB port on a hub with per-port power switching, and `uhubctl` with the right to switch it | a power cycle, so the run starts at power-on |
| the compiler | refine, `riscv64-elf-gcc`, `-nm` and `-objdump` (D532, D695), as `nix develop` gives them | the image and its disassembly |

The tool switches only `--port` on `--hub`, and only after `uhubctl` shows
`--serial` on it and `--guard-device` on `--guard-port` of the same hub, the
J-Link on the maintainer's rig, which is never switched. The port is
switched off and on again, each through `/run/wrappers/bin/sg GROUP -c`,
`--hub-group`, when the session is not in the group that may switch it,
and each switch is paced and followed by a wait for the hub to list the
board again, since every switch re-enumerates the rig's hub cascade (D725);
a switch made while the cascade re-enumerates finds no hub and is made
again. The run holds the rig's lock. The defaults are the maintainer's rig:
hub `7-2.3.4`, port 2 (front port 7), guarded by port 1 (the Renesas
board's J-Link, front port 8), and probehive slot 2's UART, port 4463.

## Running it

```sh
python3 environments/boards/esp32c3/board.py \
    --refine compiler/ada/build/nix-x86_64-linux/debug/bin/refine \
    --probe-rs PATH/TO/probe-rs --image-control --output NEW_DIRECTORY
```

The output holds the ELF, `board.elf.bin` (the image refine wrote), the
build report, the disassembly and every command's log, `rom.log` (what the
ROM wrote before the program's first frame), with `--image-control` the
two controls' ROM logs, `uart.bin` (every byte the board sent) and
`sent.bin` (every byte the host sent), and `result.json`: the image's and
the ELF's hashes, the image as read, its A-extension instructions (none),
each verdict, the counters and cells read over JTAG, the segments read
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
| `b` | once, after the indicator, the timer and the receiver are set up | `r` RTC_CNTL_RESET_CAUSE_PROCPU as read first in `start`, `v` mtvec |
| `t` | after each 0x11 | `h` bytes handled, `c` ring restarts, `i` receive interrupts, `m` timer interrupts, `p` and `q` mcause in the last receive and timer interrupt, `k` timer interrupts in the last threshold window, `l` bytes the receive interrupt dropped, `o` RX FIFO overflows it saw, `e` bytes consumed, `g` the indicator's pad read back, `s` the application's state |
| `a` | after each 0x06 | `b`, `h` and `w`: the byte, half-word and word cells as loaded after their atomic stores |
| `h` | when the application halts | `s` its status |

Four bytes are commands after their echo: 0x06 runs the atomics over the
two bytes received before it, 0x11 asks for a `t` frame, 0x12 stops
reading for 100 ms, and 0x13 raises the line threshold above the receive
line's priority for 100 ms (D721).

## The oracle

| Checked | Against |
|---|---|
| the image, read apart from refine | ESP-IDF v6.1's `esp_app_format.h` and `esp_image_format.h`: magic 0xE9, chip 5, revisions 3 to 199, legacy minimum 0, DIO and 0x20, entry the ELF's and IRAM's origin 0x4038_0000, each segment the ELF's loadable segment, zero padding, the checksum of every segment byte into 0xEF, the SHA-256 of what precedes it, and nothing after; refine's build report says the same |
| the instructions | the linked disassembly holds no AMO, `lr.w` or `sc.w` (D696) |
| the checksum control, with `--image-control` | a copy whose checksum byte is flipped: the ROM says `Checksum failure`, computing the image's own checksum and finding the flipped one, never enters the image and the program writes nothing |
| the SHA-256 control, with `--image-control` | a copy whose hash's last byte is flipped: the ROM says `SHA-256 comparison failed`, computing the image's own hash; without secure boot it boots the image anyway, so the hash it computed is all that is required |
| flash | `probe-rs download --binary-format bin --base-address 0x0 --verify` |
| the ROM's log | `rst:0x1 (POWERON)` (TRM 6.1, Table 6.1-1), a `SPI_FAST_FLASH_BOOT`, one `load:` per segment at its address and length, in order, and `entry` the header's |
| the boot frame | the reset cause 1, the chip reset of a power-on; mtvec 0x4038_0101, the table at its vector address in vectored mode (D680; TRM 1.5.3.2) |
| the shared scenario | `1`, `A` and `0` echoed, with `g` 0x400 after `1` and 0 after `0` |
| the interrupts | receive on line 1, mcause 0x8000_0001; the timer on line 2, 0x8000_0002 |
| the atomics | over two printable operands x and y the host chose: the byte x, the half-word x y and the word x y y x, each loaded back as stored, across a sequentially consistent fence |
| a ring overrun | after 0x12, a 300-byte burst into the 256-byte ring: 44 bytes dropped, one restart, none of the burst echoed |
| a FIFO overflow | after 0x13, a 300-byte burst while the receive line is held off: one RX FIFO overflow, a second restart, none of it echoed, and 99 to 101 timer interrupts in the 100 ms window, since the timer's line is above the threshold |
| the stream | 3000 more bytes in pieces of 64, each sent after the last one's echo, since the C3 runs at its reset clock, 20 MHz (D727), and every byte sent echoed in order but the two bursts, `h` their count, and the timer advancing |
| the counters | `handled`, `recoveries`, `dropped`, `overflows` and `entries`, and the three atomic cells, read over JTAG after the scenario, equal the last frames; and `_landin_firmware_trap_count` reads 0: no trap reached the unhandled entry (D656), whose five cells a failed run's result keeps |
| SRAM | the image's read-only segment, read over JTAG, is OUT.bin's bytes: what the ROM loaded is the image |

What the emulator lane and the boards share is
`compiler/tests/driver/commands` (D593, D645): the echo and the indicator.
