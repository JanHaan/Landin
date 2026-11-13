# The STM32 board: a NUCLEO-H753ZI

Start with the [board guide](../README.md) for the rig rules, pinned
tools, offline builds and the build-on-epycmicro/run-on-rigpi command.

`compiler/tests/board/stm32h753` targets STM32H753 through
`devices/descriptions/stm32h753`, using `--target=cortex-m0` at `--level=armv7e-m`.
`board.py` defaults to `--mode=ram`: the loader halts the running core,
applies the explicit warm reinitialization contract, writes and verifies
SRAM, sets the stack and vector/trap entry and resumes. This does not
reset through the ROM, write flash or cycle power, and does not prove a
cold reset. The resident flash image stays in place. `--mode=boot` is the
separate flash and cold-start check.

The port uses the board's ST-LINK V3 for debug and its virtual COM
port for USART3 on PD8/PD9; PB0 drives LD1. Its physical oracle follows
RM0433 Rev 9 and IEEE 754 arithmetic computed on the host (D650).
Its receive ring takes `core/cache` maintenance evidence and does D227's
handoff itself; this cacheless profile passes `cache.cacheless(32)`, the
barriers alone, and the [cached profile](../stm32h753_cached/README.md)
passes the Cortex-M7's provider (D978).
The warm contract requires HSI as the system clock and disabled caches;
the helper verifies the supply before loading SRAM. A boot check also
exercises the description's supply stage and the power-on flags.

## What it needs

| What | Which | Why |
|---|---|---|
| the board | a NUCLEO-H753ZI, powered from its ST-LINK's USB port, LD1 on PB0 | the STM32H753, its USART3 on PD8 and PD9 wired to the ST-LINK's virtual COM port |
| probe-rs | one that reaches an ST-LINK V3, named by `--probe`, `0483:374e:SERIAL` by default with `--serial`'s serial | debug memory access and explicit boot flashing with `--chip STM32H753ZITx` |
| the ST-LINK's firmware | one probe-rs supports, a V3 firmware whose JTAG API version is 3 or later, which ST's STLinkUpgrade (STSW-LINK007) installs | probe-rs refuses an older one when it opens the probe, with "The firmware on the probe is outdated"; the maintainer's rig shipped with V3J2M1 and runs V3.J18.M12, installed with STSW-LINK007 3.18.12's `java -jar STLinkUpgrade.jar -sn SERIAL -update`, which needs write access to the probe's bootloader, 0483:374d, as well |
| access | read and write on the ST-LINK's USB device node, which probe-rs opens, and on the tty of its virtual COM port, for example a udev rule for `0483:374e` that gives both to a group the session is in | without it probe-rs cannot open the ST-LINK, whose node a host without a rule leaves `root:root 0664` |
| power | the ST-LINK's USB port on a hub with per-port power switching, and `uhubctl` with the right to switch it | power cycling for explicit boot checks |
| the compiler | refine and `arm-eabi-gcc` or `arm-none-eabi-gcc` (D532) with its `nm`, `objdump` and `readelf`, as `nix develop` gives them | the image and the checks of its instructions |
| the manual | RM0433 Rev 9, as `devices/inputs.json` pins it | where the oracle's expectations are read from; the tool does not read it |
| the RAM loader | `landin-ram-run`, named with `--ram-loader`, built from the pinned probe-rs library | one warm halt/load/resume session |

Build tools are needed on the build host; consuming a checked bundle on
rigpi uses its matching tool sources and prepared metadata. Hardware work
holds the common rig lock, `rig.lock` in the rig's shared state,
`/var/lib/landin-rig` on rigpi, after the build and through final
readback/restoration. Preserve the USB guard, protected Arty
and shared pacing state described in the [board guide](../README.md).

Boot power uses hub `.3`, port 2 and ST-LINK serial
`001900293137511339383538` by default. The same serial locates the probe,
virtual COM tty and guarded power port. `--console PATH` names a tty
explicitly. The Arty named by `--guard-serial` must remain present outside
the switched cascade.

## Running it

Run this raw command on the rig host from the matching source snapshot.
Prepare `RAM_BUNDLE` on the build host as the [board guide](../README.md)
describes; the rig host needs no refine or cross-binutils when consuming it.

```sh
python3 environments/boards/stm32h753/board.py \
    --mode=ram --bundle=RAM_BUNDLE --ram-loader=PATH/TO/landin-ram-run \
    --probe-rs=PATH/TO/probe-rs \
    --output=NEW_DIRECTORY
```

For a boot check, replace the mode and bundle with `--mode=boot` and
`--bundle=BOOT_BUNDLE`, omit `--ram-loader`, and provide
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
its `image_name`.

Float evidence can be `pending` if software helpers remain, startup has
not granted CP10/CP11, or square root has not run. Pending is never passed,
and only a passed run can be recorded.

## The trace

The firmware writes frames between the echoed bytes in the RP2040 board's
form: STX, a tag letter, a field per key, ` k=` and eight lowercase hex
digits, then ETX and LF. The host never sends STX or ETX. A boot check's power cycle
re-enumerates the ST-LINK's virtual COM port. In both modes the firmware
waits for the host's first byte, `S`, before writing its boot frame. The host
validates that first complete frame and its boot readings before counting echoes
from the byte after its LF. Any unframed bytes before it are reported on stderr
and in `result.json` as `pre_boot` (hex bytes, length, and offsets into the raw
capture); their origin is not determined. `uart.bin` and its hash retain the
entire capture. A malformed or unexpected first frame, or another boot frame,
leaves the run failed. If the boundary cannot be established, the result says
so instead of reporting echo gaps from an unanchored capture.

| Tag | When | Fields |
|---|---|---|
| `b` | once, after the first byte | `r` RCC_RSR as read first in `start`, `v` VTOR, `a` CPACR and `c` CCR then, `q` PWR_CR3 and `y` PWR_CSR1 at application entry, configured by the description's supply stage in boot mode and checked before SRAM loading in RAM mode, `w` the bytes that had arrived |
| `t` | after each 0x11 | `h` bytes handled, `c` ring restarts, `d` epochs the stream completed, `w` its laps, `k` DMA_STR0 entries, `m` SysTick interrupts, `u` USART3 entries, `p` the exception number USART3's handler ran in, `n` DMA1_S0NDTR, `e` bytes consumed in this epoch, `g` PB0's input, `s` the application's state |
| `f` | after 0x14 and 16 operand bytes | f32 results as bit patterns: `a` sum, `s` difference, `m` product, `d` quotient, `c` the comparisons, `q` the square root once it is sent |
| `F` | after 0x15 and 32 operand bytes | the same for f64, each result's high word under its key and its low word under the next letter: `a` and `b`, `s` and `t`, `m` and `n`, `d` and `e`, `q` and `r`; `c` the comparisons |
| `l` | after 0x16 and 11 line digits | `r`, `d`, `p` and `s` the line read, `k` USART3's clock, `o` 0 accepted, 1 an unsupported rate, 2 an unsupported frame, and when accepted `b` BRR, `f` CR1's M1, M0, PCE and PS, `x` CR2 (D962) |
| `e` | after 0x17 on a changed line | `n` the bytes that arrived on it, `h` their FNV-1a |
| `h` | when the application halts | `s` its status |

0x12 stops reading for 100 ms. An operand byte is one of `a` to `p`, four
bits, most significant first, so that no operand byte is a command. The
comparisons are one bit each: less 1, less or equal 2, equal 4, unequal 8,
greater or equal 16, greater 32.

## The oracle

| Checked | Against |
|---|---|
| the warm RAM entry | the helper validates SRAM-only load segments, writes and reads them back, establishes the vector/trap base, stack and entry, and reports `flash_written: false`; the physical scenario then checks device behavior |
| the startup frame (RAM mode) | VTOR equals the loaded ELF table; caches are disabled, LDO supply and valid VOS3 are checked as in the boot oracle, and CP10/CP11 must permit the float unit; reset flags are observed without a power-on assertion |
| the ELF's vector table (boot artifact) | 166 words at 0x0800_0000, the boot address (RM0433 2.6, p. 138), word 1 the supply stage entering reset, word 27 the DMA_STR0 handler and word 55 the USART3 handler (Table 147, pp. 754 and 755) |
| the ELF's text (boot artifact) | the text in the ITCM, the 64 KiB at address zero that stm32h753xx.h names D1_ITCMRAM_BASE, with the entry and both handlers in it, and its load image, the supply stage, reset and reset's copy in flash, where reset finds them (D1359) |
| the float routines' instructions | `vadd`, `vsub`, `vmul`, `vdiv` and `vcmp` of both widths and no call to a software float helper; software helpers alone are pending |
| flash after flashing (boot only) | the vector table, read back over SWD, equal to the image's |
| the boot frame (boot mode) | RCC_RSR's named flags are Table 56's power-on line alone (p. 333), so the run began at power-on and no software reset followed; VTOR is the boot address; CCR's IC and DC are clear, the cacheless profile read on the chip; PWR_CR3 holds the LDO supply the description's stage wrote before reset, and PWR_CSR1 reads VOS3 with ACTVOSRDY set, the voltage levels valid (6.4.1, p. 262; 6.8.2, p. 305; 6.8.4, p. 308; D653); one byte, the host's, had arrived; CPACR's CP10 and CP11 granting the float unit, pending until the compiler-owned startup grants them |
| the shared scenario | `1`, `A` and `0`, the bytes the emulator lane's application is fed, echoed, with PB0's input 1 after `1` and 0 after `0` |
| USART3's interrupt | its handler at slot 55 entered in exception 55, raised by the USART's own IDLE flag, and entered again for each later byte; SysTick, every millisecond, advancing |
| an overrun | after 0x12, a 300-byte burst into the 256-byte ring is discarded, never echoed, and the ring restarts once |
| an epoch ended by STALL | the 4096-byte epoch filled, its last byte STALL, then 100 bytes while the stream is exhausted and nothing reads: the receiver holds the first 17, 16 in its RXFIFO and one in the receive data register (48.5.4, p. 2023; Table 402, p. 2018), ORE flags the rest lost (48.5.6, p. 2030), the application restarts on that overrun, and only those 17 are echoed |
| an epoch exhausted | the next epoch filled to its 4096 bytes: one epoch completed, one restart, nothing lost, and the byte that waited in the receiver meanwhile the next epoch's first |
| the stream | every byte sent echoed in order but those discarded above, `h` their count, and the stream lapping the ring |
| the float exercise | f32 and f64 results for special and seeded operands equal IEEE 754's bit for bit, any NaN matching any NaN: f64 from the host's binary64 arithmetic, f32 from the binary64 result of binary32 operands rounded once to binary32, which is correctly rounded for these operations |
| the line exchange | 230400-8N1, 9600-8E1 and 57600-7O2 accepted with BRR, CR1's frame bits and CR2 as RM0433's 48.5.7, 48.8.1 and 48.8.3 give them at 64 MHz, and a payload echoed and counted on each; 300 baud, BRR above 65535, and 6N1, a word M has not, refused with the line unchanged (D959, D962) |
| the counters | `handled`, `recoveries`, `dma_entries`, `usart_entries` and DMA1_S0NDTR, read over SWD without halting the core, equal the last frame's |
| the stream's configuration | DMA1_S0CR over SWD has TRBUFF, which a stream serving a USART must (15.5.5, p. 662) |
| the ITCM (boot mode) | read over SWD once the scenario has run from power-on, byte for byte the text's load image in flash: probe-rs wrote flash alone, so reset's copy put it there (D1359) |

What the emulator lane and the boards share is
`compiler/tests/driver/commands` (D593, D645): the echo and the indicator.
The board's receive protocol is the STM32H753's (D648), not the synthetic
drain or the RP2040's.
