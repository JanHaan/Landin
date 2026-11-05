# The ESP32-C3 board: an Olimex ESP32-C3-DevKit-Lipo

Start with the [board guide](../README.md) for the rig rules, pinned
tools, offline builds and the build-on-epycmicro/run-on-rigpi command.

`compiler/tests/board/esp32c3` targets ESP32-C3 through
`devices/descriptions/esp32c3`, using `--target=rv32` at `--level=rv32imc`.
`board.py` defaults to `--mode=ram`: the loader halts the running core,
applies the explicit warm reinitialization contract, writes and verifies
SRAM, sets the stack and vector/trap entry and resumes. This does not
reset through the ROM, write flash or cycle power, and does not prove a
cold reset. The resident flash image stays in place. `--mode=boot` is the
separate flash and cold-start check.

The port executes from IRAM and DRAM. A boot artifact is an
`esp-app-image` written at flash offset 0 and loaded by the ROM with no
second stage (D683, D707). A RAM artifact is the ELF alone, loaded directly
over the chip's USB-Serial-JTAG. Its physical oracle follows the ESP32-C3
Technical Reference Manual v1.4 and ESP-IDF v6.1's image format (D722).
The tool shares [`../esp.py`](../esp.py) with the ESP32-C5 (D723).

UART0 on GPIO21/20 is the application console, served by probehive slot 2
on TCP port 4463. The board's USB-C supplies power and native debug;
its USB serial endpoint is separate from this UART console. In a boot
check that endpoint disconnects on reset, so the independent UART is
needed to capture the ROM's complete log.

## What it needs

| What | Which | Why |
|---|---|---|
| the board | an Olimex ESP32-C3-DevKit-Lipo, powered from its USB-C, which is the chip's own USB-Serial-JTAG; UART0 on its EXT2 header, pin 4 IO21 (TX) to the console's RX and pin 5 IO20 (RX) to its TX, and GND | the chip, its flash and its ROM |
| a console | a [probehive](https://github.com/JanHaan/probehive) slot's UART, slot 2 by default, `--slot`, whose bridge, `scripts/dap_bridge.py`, serves slot N's UART as TCP port 4461 + N; a bridge already listening is used, and with `--probehive` the tool starts one when none is | UART0, powered apart from the board, so the ROM's log from power-on is read whole |
| probe-rs | one that reaches the board's USB-Serial-JTAG, `--probe 303a:1001:SERIAL`, with `--chip esp32c3` | debug memory access; explicit boot flashing at offset 0 |
| power | the board's USB port on a hub with per-port power switching, and `uhubctl` with the right to switch it | power cycling for explicit boot checks |
| the compiler | refine, `riscv64-elf-gcc`, `-nm` and `-objdump` (D532, D695), as `nix develop` gives them | the image and its disassembly |
| the RAM loader | `landin-ram-run`, named with `--ram-loader`, built from the pinned probe-rs library | one warm halt/load/resume session |

Build tools are needed on the build host; consuming a checked bundle on
rigpi uses its matching tool sources and prepared metadata. Hardware work
holds the common rig lock, `rig.lock` in the rig's shared state,
`/var/lib/landin-rig` on rigpi, after the build and through final
readback/restoration. Preserve the USB guard, protected Arty
and shared pacing state described in the [board guide](../README.md).

Boot power uses hub `.3.4`, port 2 (front port 7), guarded by port 1's
Renesas J-Link (front port 8). `--serial` must match the switched board.
The tool can start the shared UART bridge with `--probehive` or reuse one
already listening. Debug uses the board's native USB-Serial-JTAG.

## Running it

Run this raw command on the rig host from the matching source snapshot.
Prepare `RAM_BUNDLE` on the build host as the [board guide](../README.md)
describes; the rig host needs no refine or cross-binutils when consuming it.

```sh
python3 environments/boards/esp32c3/board.py \
    --mode=ram --bundle=RAM_BUNDLE --ram-loader=PATH/TO/landin-ram-run \
    --probe-rs=PATH/TO/probe-rs \
    --probehive /home/jan/src/probehive \
    --output=NEW_DIRECTORY
```

For a boot check, replace the mode and bundle with `--mode=boot` and
`--bundle=BOOT_BUNDLE`, omit `--ram-loader`, and provide
`--fixed-image=PATH/TO/fixed.elf.bin` if the bundle does not already carry it.
The fixed image is the quiet resident program restored and cold-started
afterward, subject to the USB stop guard. A failed restoration is a failed
check; a USB fault stops further hardware actions and requires the
operator's recovery.

`--image-control` and `--recover` require boot mode. The former checks
malformed checksum/hash copies; the latter enters the ROM download mode
through the native USB-Serial-JTAG reset lines to recover an image that
left JTAG unanswered. Neither belongs to a RAM development run.

The output retains the ELF, build report, command logs, `uart.bin`,
`sent.bin`, elapsed time and `result.json`, including `mode`, the warm-load
report or the boot/restoration evidence, and the physical oracle verdicts.
Use `mode` and `warm_load` to identify RAM evidence. Keep passed RAM runs in
`ram-record.json` with `--record`; `record.json` remains boot evidence.
ELF hashes depend on the output basename; rebuild a recorded image using
its `image_name`.

A boot bundle also contains `board.elf.bin`; its image hash, the ELF hash
and the ESP image's embedded SHA-256 are separate identities. Boot checks
retain `rom.log` and, with `--image-control`, the two control logs.
The record's `image_name` names the `.bin`; its ELF basename omits that suffix.

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
| the warm RAM entry | the helper validates SRAM-only load segments, writes and reads them back, establishes the vector/trap base, stack and entry, and reports `flash_written: false`; the physical scenario then checks device behavior |
| the image, read apart from refine (boot only) | ESP-IDF v6.1's `esp_app_format.h` and `esp_image_format.h`: magic 0xE9, chip 5, revisions 3 to 199, legacy minimum 0, DIO and 0x20, entry the ELF's and IRAM's origin 0x4038_0000, each segment the ELF's loadable segment, zero padding, the checksum of every segment byte into 0xEF, the SHA-256 of what precedes it, and nothing after; refine's build report says the same |
| the instructions | the linked disassembly holds no AMO, `lr.w` or `sc.w` (D696) |
| the checksum control, with `--image-control` (boot only) | a copy whose checksum byte is flipped: the ROM says `Checksum failure`, computing the image's own checksum and finding the flipped one, never enters the image and the program writes nothing |
| the SHA-256 control, with `--image-control` (boot only) | a copy whose hash's last byte is flipped: the ROM says `SHA-256 comparison failed`, computing the image's own hash; without secure boot it boots the image anyway, so the hash it computed is all that is required |
| flash (boot only) | `probe-rs download --binary-format bin --base-address 0x0 --verify` |
| the ROM's log (boot only) | `rst:0x1 (POWERON)` (TRM 6.1, Table 6.1-1), a `SPI_FAST_FLASH_BOOT`, one `load:` per segment at its address and length, in order, and `entry` the header's |
| the startup frame | in boot mode, reset cause 1 proves power-on; in both modes, mtvec 0x4038_0101, the table at its vector address in vectored mode (D680; TRM 1.5.3.2) |
| the shared scenario | `1`, `A` and `0` echoed, with `g` 0x400 after `1` and 0 after `0` |
| the interrupts | receive on line 1, mcause 0x8000_0001; the timer on line 2, 0x8000_0002 |
| the atomics | over two printable operands x and y the host chose: the byte x, the half-word x y and the word x y y x, each loaded back as stored, across a sequentially consistent fence |
| a ring overrun | after 0x12, a 300-byte burst into the 256-byte ring: 44 bytes dropped, one restart, none of the burst echoed |
| a FIFO overflow | after 0x13, a 300-byte burst while the receive line is held off: one RX FIFO overflow, a second restart, none of it echoed, and 99 to 101 timer interrupts in the 100 ms window, since the timer's line is above the threshold |
| the stream | 3000 more bytes in pieces of 64, each sent after the last one's echo, since the C3 runs at its reset clock, 20 MHz (D727), and every byte sent echoed in order but the two bursts, `h` their count, and the timer advancing |
| the counters | `handled`, `recoveries`, `dropped`, `overflows` and `entries`, and the three atomic cells, read over JTAG after the scenario, equal the last frames; and `_landin_firmware_trap_count` reads 0: no trap reached the unhandled entry (D656), whose five cells a failed run's result keeps |
| SRAM | the image's read-only segment, read over JTAG, is the ELF's loaded bytes in RAM mode or OUT.bin's segments in boot mode |

What the emulator lane and the boards share is
`compiler/tests/driver/commands` (D593, D645): the echo and the indicator.
