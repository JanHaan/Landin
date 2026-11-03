# The ESP32-C5 board: an Olimex ESP32-C5-DevKit-Lipo

Start with the [board guide](../README.md) for the rig rules, pinned
tools, offline builds and the build-on-epycmicro/run-on-rigpi command.

`compiler/tests/board/esp32c5` targets ESP32-C5 through
`devices/descriptions/esp32c5`, using `--target=rv32` at `--level=rv32imac`.
`board.py` defaults to `--mode=ram`: the loader halts the running core,
applies the explicit warm reinitialization contract, writes and verifies
SRAM, sets the stack and vector/trap entry and resumes. This does not
reset through the ROM, write flash or cycle power, and does not prove a
cold reset. The resident flash image stays in place. `--mode=boot` is the
separate flash and cold-start check.

The port executes from SRAM. A boot artifact is an `esp-app-image`
written at flash offset 0x2000 and loaded by the ROM with no second stage
(D683, D707). A RAM artifact is the ELF alone, loaded directly over the
chip's USB-Serial-JTAG. Its physical oracle follows the ESP32-C5 Technical
Reference Manual v1.1 and ESP-IDF v6.1's image format (D722, D724).
The tool shares [`../esp.py`](../esp.py) with the ESP32-C3 (D723).

UART0 is on GPIO11/12 through the board's CH340X USB-UART1. The bridge
has no serial number and is located by its hub port; the tool opens it
with DTR and RTS inactive. Those lines otherwise drive EN and GPIO28
through the board's auto-reset transistors.

## What it needs

| What | Which | Why |
|---|---|---|
| the board | an Olimex ESP32-C5-DevKit-Lipo with both USB-C ports on the hub: the chip's own USB-Serial-JTAG, and USB-UART1, a CH340X bridge on UART0, GPIO11 (TX) and GPIO12 (RX), whose DTR and RTS drive EN and the GPIO28 boot strap through the board's auto-reset transistors | the chip, its flash and its ROM |
| a console | the CH340X's tty, found by the hub port it is plugged into, `--console-port`, since it has no USB serial of its own, and opened with DTR and RTS inactive; the tty belongs to `--hub-group`, and the tool runs itself through `/run/wrappers/bin/sg GROUP -c` when the session is not in it (D836) | UART0 |
| probe-rs | one that reaches the board's USB-Serial-JTAG, `--probe 303a:1001:SERIAL`, with `--chip esp32c5` | debug memory access; explicit boot flashing at 0x2000 |
| power | both ports on a hub with per-port power switching, and `uhubctl` with the right to switch them | cutting both supplies during explicit boot checks |
| the compiler | refine, `riscv64-elf-gcc`, `-nm` and `-objdump` (D532, D695), as `nix develop` gives them | the image and its disassembly |
| the RAM loader | `landin-ram-run`, named with `--ram-loader`, built from the pinned probe-rs library | one warm halt/load/resume session |

Build tools are needed on the build host; consuming a checked bundle on
rigpi uses its matching tool sources and prepared metadata. Hardware work
holds the common rig lock, `~/.cache/landin/rig.lock`, after the build and
through final readback/restoration. Preserve the USB guard, protected Arty
and shared pacing state described in the [board guide](../README.md).

Either USB-C port powers the board. Boot checks therefore switch both:
native JTAG on `.3.4`, port 3 (front port 6), guarded by the Renesas
J-Link on port 1; CH340X on `.4`, port 3 (front port 12), guarded by the
S3's native USB-JTAG on port 4. The S3's CH340 and classic ESP32's bridge
have the same `1a86:7523` identity, so the C5 console is distinguished by
its port. Its confirmed ROM banner is `ESP-ROM:esp32c5-eco2-20250121`.

In a boot check, the tool reads the power-on state over JTAG because the
CH340X has not enumerated when power returns. With the console open it
then pulses EN through RTS, leaving DTR inactive and GPIO28 high, and
captures the ROM's next flash boot. That chip-enable reset is reported
as `rst:0x1 (POWERON)` by the ROM (D724). RAM runs use neither operation.

## Running it

Run this raw command on the rig host from the matching source snapshot.
Prepare `RAM_BUNDLE` on the build host as the [board guide](../README.md)
describes; the rig host needs no refine or cross-binutils when consuming it.

```sh
python3 environments/boards/esp32c5/board.py \
    --mode=ram --bundle=RAM_BUNDLE --ram-loader=PATH/TO/landin-ram-run \
    --probe-rs=PATH/TO/probe-rs \
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
| `b` | once, after the indicator, the timer and the receiver are set up | `r` LP_CLKRST_RESET_CAUSE's cause as read first in `start`, `v` mtvec, `w` mtvt, `t` mintthresh at application entry, `x` CLICINT18 and `y` CLICINT17 |
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
| the warm RAM entry | the helper validates SRAM-only load segments, writes and reads them back, establishes the vector/trap base, stack and entry, and reports `flash_written: false`; the physical scenario then checks device behavior |
| the image, read apart from refine (boot only) | ESP-IDF v6.1's `esp_app_format.h` and `esp_image_format.h`: magic 0xE9, chip 23, revisions 100 to 199, legacy minimum 0, DIO and 0x20, entry the ELF's and SRAM's origin 0x4080_0000, each segment the ELF's loadable segment, zero padding, the checksum of every segment byte into 0xEF, the SHA-256 of what precedes it, and nothing after; refine's build report says the same |
| the instructions | the linked disassembly holds an AMO and an LR/SC pair, the A extension the level has |
| the table of handler addresses | `_landin_firmware_vector_addresses`, 64-byte aligned (Register 2.10), 48 words: identities 17 and 18 their stubs, `_landin_firmware_slot_17` and `_18`, every other the unhandled entry (D830) |
| the checksum control, with `--image-control` (boot only) | a copy whose checksum byte is flipped: the ROM says `Checksum failure`, computing the image's own checksum and finding the flipped one, never enters the image and the program writes nothing |
| the SHA-256 control, with `--image-control` (boot only) | a copy whose hash's last byte is flipped: the ROM says `SHA-256 comparison failed`, computing the image's own hash, and without secure boot boots the image anyway |
| flash (boot only) | `probe-rs download --binary-format bin --base-address 0x2000 --verify` |
| the power-on boot, over JTAG (boot only) | LP_CLKRST_RESET_CAUSE's cause 1, the program's `boot_reason` 1, `app_state` 2 and `timer_events` advancing; no trap recorded |
| the ROM's log, after the chip-enable reset (boot only) | `rst:0x1 (POWERON)`, a `SPI_FAST_FLASH_BOOT`, one `load:` per segment at its address and length, in order, and `entry` the header's |
| the startup frame | in boot mode, reset cause 1; in both modes, mtvec compiler-owned trap entry's address with mode 3, CLIC (D680; TRM 2.8.2); mtvt, `w`, the table of handler addresses (D830); CLICINT18, `x`, as the core reads it back, with SHV, bit 16, set, so the timer is entered through mtvt's table, and CLICINT17, `y`, with it clear, so UART0's takes the common entry (Register 2.66). The CLIC is on the core's own bus, which probe-rs's system bus access does not reach: a read of 0x2080_1048 over JTAG fails |
| the shared scenario | `1`, `A` and `0` echoed, with `g` 0x0100_0000 after `1` and 0 after `0` |
| the interrupts | receive on CLIC identity 17, through the common entry, mcause's code 0x11 with its interrupt bit; the timer on 18, hardware vectored, 0x12 |
| the atomics | over two printable operands x and y the host chose: the add returns x, the first compare-exchange observes x + y and stores x ^ y, the second observes x ^ y and stores nothing, the cell holds x ^ y; the byte cell's add returns x and leaves x + y, wrapped to eight bits |
| a ring overrun | after 0x12, a 300-byte burst into the 256-byte ring: 44 bytes dropped, one restart, none of the burst echoed |
| a FIFO overflow | after 0x13, a 300-byte burst while mintthresh holds the receive interrupt off: one RX FIFO overflow, a second restart, none of it echoed, and 99 to 101 timer interrupts in the 100 ms window, since the timer's level is above the threshold |
| the stream | 3000 more bytes, and every byte sent echoed in order but the two bursts, `h` their count, and the timer advancing |
| the counters | `handled`, `recoveries`, `dropped`, `overflows`, `entries` and `boot_reason`, and the two atomic cells, read over JTAG after the scenario, equal the last frames; and `_landin_firmware_trap_count` reads 0: no trap reached the unhandled entry (D656), whose five cells a failed run's result keeps |
| SRAM | the image's read-only segments, read over JTAG, are the ELF's loaded bytes in RAM mode or OUT.bin's segments in boot mode |

What the emulator lane and the boards share is
`compiler/tests/driver/commands` (D593, D645): the echo and the indicator.
