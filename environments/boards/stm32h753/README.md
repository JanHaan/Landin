# The STM32 board: a NUCLEO-H753ZI

The prototype-1 board port, `compiler/tests/board/stm32h753`, built by
refine for the NUCLEO-H753ZI's STM32H753 at `--level=armv7e-m` through
`devices/descriptions/stm32h753`, flashed, and booted from power-on.
`board.py` builds the image, flashes it through the board's own ST-LINK
V3, switches the board's power and checks what the board writes on USART3,
the ST-LINK's virtual COM port, against a physical oracle written from what
the host sent, from RM0433 Rev 9 and from IEEE 754 as the host computes it
(D650). It is a developer tool: no compiler feature runs it or needs it,
and the gate does not run it, since no hosted runner has the board. What it
shares with the RP2040's tool is [`../common.py`](../common.py) (D646).

## What it needs

| What | Which | Why |
|---|---|---|
| the board | a NUCLEO-H753ZI, powered from its ST-LINK's USB port, LD1 on PB0 | the STM32H753, its USART3 on PD8 and PD9 wired to the ST-LINK's virtual COM port |
| probe-rs | one that reaches an ST-LINK V3, named by `--probe`, `0483:374e:SERIAL` by default with `--serial`'s serial | flashing, verifying and reading memory with `--chip STM32H753ZITx` |
| the ST-LINK's firmware | one probe-rs supports, a V3 firmware whose JTAG API version is 3 or later, which ST's STLinkUpgrade (STSW-LINK007) installs | probe-rs refuses an older one when it opens the probe, with "The firmware on the probe is outdated"; the maintainer's rig shipped with V3J2M1 and runs V3.J18.M12, installed with STSW-LINK007 3.18.12's `java -jar STLinkUpgrade.jar -sn SERIAL -update`, which needs write access to the probe's bootloader, 0483:374d, as well |
| access | read and write on the ST-LINK's USB device node, which probe-rs opens, and on the tty of its virtual COM port, for example a udev rule for `0483:374e` that gives both to a group the session is in | without it probe-rs cannot open the ST-LINK, whose node a host without a rule leaves `root:root 0664` |
| power | the ST-LINK's USB port on a hub with per-port power switching, and `uhubctl` with the right to switch it | a power cycle, so the run starts at power-on |
| the compiler | refine and `arm-eabi-gcc` or `arm-none-eabi-gcc` (D532) with its `nm`, `objdump` and `readelf`, as `nix develop` gives them | the image and the checks of its instructions |
| the manual | RM0433 Rev 9, as `devices/inputs.json` pins it | where the oracle's expectations are read from; the tool does not read it |

The ST-LINK's USB serial names three things: the probe probe-rs opens, the
tty of its virtual COM port, found under `/sys/class/tty` by the serial of
the USB device it belongs to, and the hub port that is switched. The tool
switches only `--port` on `--hub`, and only after `uhubctl` shows that serial
on that port; the port is switched off and on in one `uhubctl -a cycle`,
run through `/run/wrappers/bin/sg GROUP -c`, `--hub-group`, `dialout` by
default, when the session is not in that group. The defaults are the
maintainer's rig: hub `7-2.3`, port 2, serial `001900293137511339383538`.
`--console PATH` names the tty instead, for a host that gives it a name of
its own; finding it by the serial needs nothing of the host's.

## Running it

```sh
python3 environments/boards/stm32h753/board.py \
    --refine compiler/ada/build/nix-x86_64-linux/debug/bin/refine \
    --probe-rs PATH/TO/probe-rs \
    --hub 7-2.3 --port 2 --serial 001900293137511339383538 \
    --output NEW_DIRECTORY
```

The output holds the image, its build report, its disassembly and every
command's log, `uart.bin` (every byte the board sent) and `sent.bin` (every
byte the host sent), and `result.json`: the image's hash, what its float
routines were found to use, each verdict, every frame and the commands
with their status and time. Its status is `passed`, `failed` with the first
refusal, or `pending`, naming what the float unit still lacks: the image's
float routines calling software helpers, the compiler-owned startup not
granting CP10 and CP11, or the square root not yet sent. A pending run is
never a passed one, and `--record` writes only a passed run's record. The linked ELF holds the name of the object refine assembled beside it, so its hash depends on the output's name: a record gives the name as `image_name`, and a reader rebuilding the image to check the hash builds it under that name.

## The trace

The firmware writes frames between the echoed bytes in the RP2040 board's
form: STX, a tag letter, a field per key, ` k=` and eight lowercase hex
digits, then ETX and LF. The host never sends STX or ETX. The ST-LINK's
virtual COM port re-enumerates after the power cycle, so the firmware
writes nothing until a byte has arrived: the host sends `S` first.

| Tag | When | Fields |
|---|---|---|
| `b` | once, after the first byte | `r` RCC_RSR as read first in `start`, `v` VTOR, `a` CPACR and `c` CCR then, `q` PWR_CR3 and `y` PWR_CSR1, as the description's stage left them before reset, `w` the bytes that had arrived |
| `t` | after each 0x11 | `h` bytes handled, `c` ring restarts, `d` epochs the stream completed, `w` its laps, `k` DMA_STR0 entries, `u` USART3 entries, `p` the exception number USART3's handler ran in, `n` DMA1_S0NDTR, `e` bytes consumed in this epoch, `g` PB0's input, `s` the application's state |
| `f` | after 0x14 and 16 operand bytes | f32 results as bit patterns: `a` sum, `s` difference, `m` product, `d` quotient, `c` the comparisons, `q` the square root once it is sent |
| `F` | after 0x15 and 32 operand bytes | the same for f64, each result's high word under its key and its low word under the next letter: `a` and `b`, `s` and `t`, `m` and `n`, `d` and `e`, `q` and `r`; `c` the comparisons |
| `h` | when the application halts | `s` its status |

0x12 stops reading for 100 ms. An operand byte is one of `a` to `p`, four
bits, most significant first, so that no operand byte is a command. The
comparisons are one bit each: less 1, less or equal 2, equal 4, unequal 8,
greater or equal 16, greater 32.

## The oracle

| Checked | Against |
|---|---|
| the ELF's vector table | 166 words at 0x0800_0000, the boot address (RM0433 2.6, p. 138), word 1 reset, word 27 the DMA_STR0 handler and word 55 the USART3 handler (Table 147, pp. 754 and 755) |
| the float routines' instructions | `vadd`, `vsub`, `vmul`, `vdiv` and `vcmp` of both widths and no call to a software float helper; software helpers alone are pending |
| flash after flashing | the vector table, read back over SWD, equal to the image's |
| the boot frame | RCC_RSR's named flags are Table 56's power-on line alone (p. 333), so the run began at power-on and no software reset followed; VTOR is the boot address; CCR's IC and DC are clear, the cacheless profile read on the chip; PWR_CR3 holds the LDO supply the description's stage wrote before reset, and PWR_CSR1 reads VOS3 with ACTVOSRDY set, the voltage levels valid (6.4.1, p. 262; 6.8.2, p. 305; 6.8.4, p. 308; D653); one byte, the host's, had arrived; CPACR's CP10 and CP11 granting the float unit, pending until the compiler-owned startup grants them |
| the shared scenario | `1`, `A` and `0`, the bytes the emulator lane's application is fed, echoed, with PB0's input 1 after `1` and 0 after `0` |
| USART3's interrupt | its handler at slot 55 entered in exception 55, raised by the USART's own IDLE flag, and entered again for each later byte |
| an overrun | after 0x12, a 300-byte burst into the 256-byte ring is discarded, never echoed, and the ring restarts once |
| an epoch ended by STALL | the 4096-byte epoch filled, its last byte STALL, then 100 bytes while the stream is exhausted and nothing reads: the receive data register holds the first, ORE flags the rest lost (48.5.6, p. 2030), the application restarts on that overrun, and only that byte is echoed |
| an epoch exhausted | the next epoch filled to its 4096 bytes: one epoch completed, one restart, nothing lost, and the byte that waited in the receive register meanwhile the next epoch's first |
| the stream | every byte sent echoed in order but those discarded above, `h` their count, and the stream lapping the ring |
| the float exercise | f32 and f64 results for special and seeded operands equal IEEE 754's bit for bit, any NaN matching any NaN: f64 from the host's binary64 arithmetic, f32 from the binary64 result of binary32 operands rounded once to binary32, which is correctly rounded for these operations |
| the counters | `handled`, `recoveries`, `dma_entries`, `usart_entries` and DMA1_S0NDTR, read over SWD without halting the core, equal the last frame's |
| the stream's configuration | DMA1_S0CR over SWD has TRBUFF, which a stream serving a USART must (15.5.5, p. 662) |

What the emulator lane and the boards share is
`compiler/tests/driver/commands` (D593, D645): the echo and the indicator.
The board's receive protocol is the STM32H753's (D648), not the synthetic
drain or the RP2040's.
