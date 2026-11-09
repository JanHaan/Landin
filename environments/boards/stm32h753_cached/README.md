# The STM32 board's cached profile

Start with the [board guide](../README.md#the-stm32h753s-cached-profile)
and the [cacheless port](../stm32h753/README.md), whose board, ST-LINK,
virtual COM port, access and rig settings this run shares. `D973` names a
decision recorded in `spec.md`; `refine explain D973` prints it.

`compiler/tests/board/stm32h753_cached` targets the STM32H753 through
`devices/descriptions/stm32h753_cached`, the cached profile, at
`--target=cortex-m0 --level=armv7e-m`, built for SRAM. Its reset enables
the Cortex-M7's level 1 caches once memory is written and its entry's
return cleans and disables them (D973). It uses the cacheless board's
`serial`, `bringup`, `report` and `scs` modules: the receive ring through
`serial.open`, `available`, `read`, `stop`, `restart`, `completed` and
`idle`, given `l1.new()`, so the ring cleans and invalidates itself
before it is armed and invalidates itself before each copy (D978), and the
program writes none of its maintenance. The stale-read control gives the
same routines `cache.cacheless(32)`, which leaves those operations out, so
it shows what the cacheless board's own code does on a cached chip.

## Running it

```sh
python3 environments/boards/stm32h753_cached/board.py \
    --bundle=RAM_BUNDLE --ram-loader=PATH/TO/landin-ram-run \
    --probe-rs=PATH/TO/probe-rs --output=NEW_DIRECTORY
```

`--mode=boot` is refused: the board's boot check is the cacheless port's.
In the gate, the STM32H753 leg runs this between its RAM run and its boot
check. `--record=ram-record.json` keeps a passed run's record beside the
tool, which `build.py --records=strict` compares the image with.

## The frames

Each is the cacheless board's form: STX, a tag letter, fields of a key, `=`
and eight hex digits, then ETX and LF. The host sends `S` first.

| Tag | When | Fields |
|---|---|---|
| `b` | after the start byte, read through the maintained ring | `c` CCR at the entry, `g` CCSIDR of the level 1 data cache, `l` the provider's line, `v` VTOR, `s` the byte read |
| `c` | the ring refilled with 0x5A, cleaned and not invalidated, and rearmed | `n` the bytes the control waits for, 64, two lines |
| `C` | the 64 bytes read without an invalidate | `n` read, `s` how many were 0x5A, `k` a bit for each line that was 0x5A throughout, `a` their FNV-1a, `m` the FNV-1a of the ring once invalidated |
| `E` | 1024 bytes read through the maintained ring | `n` read, `x` their FNV-1a, `w` the ring's laps |
| `d` | the CPU's controls | `l` bytes an invalidate lost of a dirty line, `r` ranges refused of four, `k` dirty bytes kept under them, `w` bytes written once the line was cleaned |
| `x`, `X` | around a transmit whose buffer was not cleaned | `n` 64; `t` 1 when the stream ended with its count at zero and no transfer error, `r` its count left, `f` DMA_LISR's stream 0 flags, an underrun's FEIF among them, which stops nothing |
| `y`, `Y` | around the same buffer's transmit after a clean | the same |
| `e` | before the entry returns | `c` CCR, still on |
| `h` | when the application halts | `s` the step that failed |

## What the host checks

| Checked | Against |
|---|---|
| the image | the vector table at the loaded address, the handlers at slots 15, 27 and 55, the build report's `armv7-m-l1` cache, and literals that reach only the cache registers the profile declares (D976) |
| the boot frame | CCR's IC and DC set, CCSIDR a 16 KiB four-way data cache of 32-byte lines, the provider's line 32, VTOR the loaded table, the start byte read through the ring; CCR over SWD while the run goes on, both caches on |
| the stale read | each line the read returned is the ring's cached 0x5A throughout or, evicted in between, the bytes sent, and at least one is stale; memory, once invalidated, hashes as the 64 bytes sent |
| the maintained receive | 1024 bytes hashing as the host's, over at least four laps of the 256-byte ring |
| the lost dirty line | an invalidate after a clean discards all 32 dirty bytes; the four ranges that are not whole lines are refused and the line they cover keeps its 32 dirty bytes, which a clean then writes |
| the transmits' edges | the frames after the CPU's controls are `x`, `X`, `y`, `Y` and `e` in that order, each whole, and each transmit carries all 64 bytes, its first among them: a transmit enables its stream before it sets DMAT, so the request rises once the stream has preloaded its first byte, and ends with the stream's EN clear, DMAT cleared and then USART3's TC, as RM0433 48.5.19 orders it, before the CPU writes its next frame (D979) |
| the stale transmit | each line the transmit without a clean carries is the `o`s memory held or, written back in between, the message's, at least one the `o`s; after the clean it carries the message, `A` to `Z` repeated; nothing else arrives outside the frames |
| the end | CCR over SWD with IC and DC clear once the entry returned |

The host predicts each result from what it sent and what a write-back data
cache does, never from the firmware's report of itself. A cache may evict
a line between a control's setup and its read, so a control is judged line
by line: an evicted line reads or sends what memory holds, never a mix of
the two. A step waits 20 seconds for the host,
which reads CCR over SWD between the boot frame and the control.
