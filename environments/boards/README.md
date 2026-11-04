# Board tools

These tools build and exercise eight supported ports: RP2040, RP2350 Arm,
RP2350 Hazard3, STM32H753, ESP32-C3, ESP32-C5, ESP32 and ESP32-S3. Both RP2350 ports use the
same physical Pico 2. Other boards on the rig are not selected by these
commands.

Build on epycmicro in Landin's pinned environment. The tools and physical
oracles run on rigpi. A RAM run is a warm debugger entry; it does not
establish power-on or boot-ROM behavior. `refine` retains the default boot
layout; board tools default to `--mode=ram` and select the compiler's
`--firmware-layout=ram` explicitly.

On NixOS the foreign cross-toolchain archives need an FHS environment, as
the [emulator recipe](../cortex-m/README.md#on-nixos) explains.
After entering Landin's pinned environment, prepare this shell once, then
run the Python commands below inside it:

```sh
mkdir -p ~/.cache/landin/tmp
NIXPKGS_ALLOW_UNFREE=1 nix-shell -p steam-run python3 --run \
    'TMPDIR=$HOME/.cache/landin/tmp steam-run bash'
```

The Pi consumes prepared bundles and needs no cross-toolchain or FHS shell.

## Build without hardware

```sh
python3 environments/boards/build.py \
    --refine compiler/ada/build/nix-x86_64-linux/debug/bin/refine \
    --mode=both --output NEW_DIRECTORY
```

This builds every port, checks its image, and names every failed build or
record mismatch. It never opens a probe, discovers USB, takes the rig lock
or connects to another host. `--records=report` reports drift while failing
only builds, as the software gate does. The default strict comparison fails
on either. Record drift identifies old hardware evidence; a successful
build does not refresh it.

The native helper can check a prepared RAM plan without hardware:
`landin-ram-run --validate --plan PLAN.json --output VALIDATION.json`.
This uses the same ELF and address checks as loading, and never creates a
probe session. The plan has `format_version: 1`, `mode: "ram"`, `board`,
`probe` and an absolute `elf` path; `probe` is unused during validation.

Boot images compare with each port's `record.json`; RAM images compare
with `ram-record.json`. The records name their image filenames because ELF
identity depends on the output name. ESP image and ELF hashes are separate.
Each prepared bundle retains ELF, applicable ROM image, build report,
symbols, checksums, compiler content identity, source content identity and
the fixed image a boot check restores.

## Prepare the Pi once

The rig is reached with
`ssh -i ~/.ssh/epycmicro-2026-09-17 jan@10.42.0.60`. It provides Python,
uhubctl and probe-rs. Debug reaches probehive directly by UDP, for example
`--probe 0000:0002:10.42.0.50/0`; the UART service remains a separate
runtime dependency of the RP and ESP32-C3 tools.

The pinned probe-rs source is JanHaan/probe-rs revision
`6f9946fe748edd0e55604dc42bc0f7ea3e7485da`, branch `rig/2026-11-03`.
The Pi reports `v0.32.0-344-g6f9946fe`. The helper uses the same source and
vendor hashes in [package.nix](ram-run/package.nix). Build the helper on
epycmicro and import its closure on the Pi:

```sh
nix build .#board-ram-run-rigpi --out-link /tmp/landin-ram-run
nix-store --export $(nix-store -qR /tmp/landin-ram-run) > /tmp/landin-ram-run.closure
ssh -i ~/.ssh/epycmicro-2026-09-17 jan@10.42.0.60 \
    'sudo nix-store --import' < /tmp/landin-ram-run.closure
```

This explicit import accepts a locally built, unsigned closure; a normal
remote Nix copy rejects it without a trusted signing key. On the Pi, point
`~/.local/bin/landin-ram-run` at the imported store path's
`bin/landin-ram-run`, or pass that path directly with `--ram-loader`.
`nix build .#board-ram-run` builds and tests the host executable.
`landin-ram-run --describe` reports the compiled source hash and probe-rs
revision without opening a probe. The board tool checks these against its
matching source before hardware access and refuses a stale helper.

The probehive runtime needs its `flake.nix` and `flake.lock` for the
`#gpio` shell, `scripts/dap_bridge.py`, `scripts/dap_udp.py` and
`scripts/gpio.py`, and the loaded bitstream's
`build/slots_ci/generated/rig.json` and `csr.json`. GPIO uses its lightweight
`#gpio` shell, available on arm64 and x86-64, rather than the FPGA shell.
Prepare that environment before holding the rig lock:

```sh
nix develop /home/jan/src/probehive#gpio -c true
```

The matching probehive change is published on
[`landin-ram-gpio`](https://github.com/JanHaan/probehive/tree/landin-ram-gpio),
commit `4f69b8269a664cf1e1c47b2b40365b482e9f30ec`. Use a checkout containing
that commit. Source
and runtime files must match the loaded bitstream. Loading a bitstream is
an explicit rig operation; a run never switches the Arty's power.

## Run a prepared candidate

From the Landin checkout on epycmicro:

```sh
python3 environments/boards/run.py --board=rp2040 \
    --refine compiler/ada/build/nix-x86_64-linux/debug/bin/refine \
    --output NEW_DIRECTORY -- \
    --ram-loader /home/jan/.local/bin/landin-ram-run \
    --probehive /home/jan/src/probehive --indicator-pin IO32
```

This one command builds the current source, copies its checked bundle and
matching tool source to a private directory on rigpi, runs the board tool,
and retrieves its complete output, including a failed run. `--host` and
`--identity` override the defaults above. The Pi checks artifact and source
identities before hardware access and needs no compiler or cross tools to
consume the bundle. `transfer.json` retains the remote paths and status.
Each board tool records elapsed time, helper operations and oracle results.
Add `--record NEW_LOCAL_PATH` before `--` to retrieve a successful tool's
record without replacing an existing file. Use `ram-record.json` for RAM
evidence; a build never produces hardware records.

The warm helper halts the executing core, retires Arm and C5 handlers,
resets Hazard3 interrupt state, stops the port's DMA and interrupt sources,
parks the other RP core,
validates the supported clock/cache baseline, loads SRAM and checks its
readback, prepares vectors, stack and entry, and resumes compiler startup.
It has no flash-programming or system-reset operation. STM32 supply is
configured and checked before SRAM writes. RISC-V instruction visibility is
established before entering the new image. Startup clears BSS and the full
port scenario still checks interrupts, DMA, counters and the physical I/O.
Unsupported prior device state is refused with the boot check named.
RP loading and readback expose only the executing core to probe-rs; the
parked core is excluded from session cleanup. RP2040 attachment uses the
generic Arm sequence so a failed connection cannot fall back to a rescue
reset. Readback retains probe-rs's brief debug housekeeping halts.
Hazard3 loads and readbacks use core 0's program buffer for every transfer
width. RP2350's system-bus debug access shares core 1's load/store port;
the program buffer keeps memory access on the executing core.
See the [RP2350 datasheet, section 3.8.5 and erratum E4](https://pip-assets.raspberrypi.com/categories/1214-rp2350/documents/RP-008373-DS-2-rp2350-datasheet.pdf?disposition=inline).
Hazard3 requires both processors already in RISC-V mode and debug-halts
hart 1 before peripheral cleanup or SRAM writes. It avoids the PSM power-off
operation that stalled the debug link during validation. Normal session
teardown leaves that halt in place: the chip's
[per-core debug state](https://github.com/Wren6991/Hazard3/blob/86fc4e3f/hdl/hazard3_csr.v)
changes on reset or resume, while
[disabling its debug module](https://github.com/Wren6991/Hazard3/blob/86fc4e3f/hdl/debug/dm/hazard3_dm.v)
issues neither. Each independent RAM readback checks that hart 1 is still
halted without halting it again. Boot and fixed-image setup reads do not
require this warm-entry state.
Hazard3 also rejects `fence.i` in Debug mode. The helper uses the legal
data fence there; debug resume flushes its instruction frontend before
fetching the SRAM entry, and compiler startup executes the normal-mode
fences. The [decoder](https://github.com/Wren6991/Hazard3/blob/86fc4e3f/hdl/hazard3_decode.v)
and [frontend](https://github.com/Wren6991/Hazard3/blob/86fc4e3f/hdl/hazard3_frontend.v)
define that chip-specific boundary. The ESP32-C3 and ESP32-C5 helper fences are unchanged.
The Hazard3 port also releases TIMER0 from reset and configures its debug
pause to follow core 0 alone. Otherwise the parked hart 1 freezes the
shared timer, and the application's alarm cannot wake its event loop.
DMA and UART remain in reset until startup. This contract covers the
port's TIMER0; future TIMER1 or SIO MTIME users must establish their own
core 1 debug-pause policy. The watchdog is disabled during cleanup.

The ESP scenario's historical `receive_mcause` and `timer_mcause` result
keys name RISC-V `mcause` only on C3/C5. In ESP32 and ESP32-S3 records they
contain snapshots of Xtensa's `INTERRUPT` pending bits: the receive check
requires line 1 and the timer check requires line 23. Other pending bits
may also be set. The inherited keys and refusal wording remain misleading;
interpret them using the port's architecture rather than as RISC-V causes.

The windowed Xtensa ports use their own bounded warm contract. CPU1 is
hardware-stalled with code `0x86` before memory changes; each independent
readback verifies that stall without applying it again. Only CPU0 is
exposed to session cleanup. Both caches must already be disabled. The
helper accepts the XTAL clock with divider zero or one, stops the port's
timer, UART interrupt sources and watchdogs, then normalizes the divider
to zero for 40 MHz. Other clock/cache states are refused before SRAM
writes. Internal instruction SRAM receives word accesses; byte-addressed
constants and mutable storage remain in data SRAM. External flash, PSRAM,
cache maintenance and DMA are outside these profiles.

The S3 cold ROM-entry stage has a separate cache contract. After checking
its reset cause and pinned ROM instruction/constant fingerprints, it stops
watchdogs, stalls CPU1 and uses the ROM's windowed writeback and cache-disable
APIs. Compiler entry supplies windows, vectors and a spill stack before this
stage; static storage is initialized afterward. The cache-off path calls no
ROM routines. Classic cold entry separately guards its revision-3 ROM's
complete disable/flush routines and literals, then disables and flushes
both read-only flash caches after watchdog shutdown and CPU1 stall. That
contract excludes initialized PSRAM and dirty external data. Neither cold
path relaxes the warm loader's precondition.

Before resuming the new entry, the helper checks and single-steps the
compiler's exact normal-mode `memw`/`isync` pair with interrupts masked,
recording both PCs and debug causes. Startup then establishes window and
FPU controls, VECBASE, stack and static storage. The scenario uses UART
receive at level one and a timer at level three, with GPIO22 on ESP32 and
the active-low GPIO38 LED on ESP32-S3. Ordinary compiler-owned handlers
admit only levels one through three, which EXCM masks while their shared
context is saved; higher priority, debug and NMI vectors stop.

Use the same wrapper for these ports:

```sh
python3 environments/boards/run.py --board=esp32 --refine REFINE \
    --output NEW_DIRECTORY -- --ram-loader PI_HELPER
python3 environments/boards/run.py --board=esp32s3 --refine REFINE \
    --mode=boot --output NEW_DIRECTORY -- --ram-loader PI_HELPER
```

S3's boot check observes power-on and application progress over JTAG before
opening the board-powered UART bridge, then captures a separate EN reset's
full ROM trace. Classic ESP32's external JTAG remains powered during USB
cycling, so that cycle alone does not establish power-rail discharge. Its
check follows USB cycling with one explicit CHIP_PU reset, with GPIO0
released, and captures fresh ROM startup before the independent JTAG
readiness checks. Its record identifies that EN cold-reset contract and
unmeasured rail discharge. Both ports drive the scenario and repeat their
readiness proof for the fixed image. ESP32's ROM prints decimal
segment lengths and `POWERON_RESET`; S3 prints hexadecimal lengths and
`POWERON`. These are separate chip-specific log oracles. Xtensa corruption
and download-mode recovery controls are not admitted by these tools.

For a failed cold-start observation, append `--inspect-boot` to the explicit
boot invocation. This reads actual cache, reset, CPU1 and selected ROM state
without flashing, resetting or writing a passed record. Its helper uses
`boot-read`; ordinary warm readbacks still require CPU1's retained stall.
Classic ESP32 also accepts `--diagnose-reset` in boot mode: it confirms the
ROM download message through the selected CH340, then retains one traced
probe reset command. This diagnostic performs no flash write and produces
an observation rather than a board pass. Both paths use the common rig lock,
topology guards, kernel USB checks and timing.
Classic `--trace-rom` instead applies one normal 100 ms EN pulse with GPIO0
released and retains 2.5 seconds of UART output. It performs no JTAG access,
flash write or power switching, and cannot write a passed board record.

For Pico 2 RAM entry, the BOOTSEL guard reads the selected hub and physical
port through Linux sysfs. It validates the hub, port and any device
identity, failing on unreadable metadata; an absent device is normal for
the quiet resident image. RAM mode needs no hub power-control permission.
With the cascade unplugged, name its last root explicitly with `--cascade`
and give the Pico's absolute `--hub` and `--port`. After the direct-Pi
recovery at hub `1-1`, port `2`, the RAM arguments were
`--hub=1-1 --port=2 --cascade=1-1.2`. Check live topology before reusing
those locations. The Pi's built-in hub has ganged power and carries the
Arty; these direct-Pi arguments are for RAM mode, never automatic boot
power cycling.

The RP ports use ACK `0x06`, boot frame, GO `0x07`, readiness frame before
the scenario. This lets native UDP loading finish before the UART service
opens, without losing a boot frame or including handshake bytes in DMA
epochs. ESP and STM32 already wait for input before their first frame.

## Boot checks and recovery

Use `--mode=boot` for image-format or startup changes, at item closure and
in the physical board gate. It flashes the ordinary boot image and
cold-starts it, exercises its physical oracle, then restores and verifies
the fixed image. The fixed application starts no USB service and parks;
the ESP hardware USB-JTAG and external debuggers remain available. Boot
checks retain evidence a RAM run cannot provide: ROM image parsing, second
stage, image block, ESP header and load segments, data/RAM-code copies,
execution from flash where supported, and flash-sized programs.
ESP boot images still load into SRAM; their boot mode checks the ROM
header and loading, and does not raise the SRAM limit.

Every Pico 2 boot check and malformed-image control belongs off the
cascade. A Pico 2 in BOOTSEL must never be attached through probe-rs, even
with an override. Recover corrupt flash by preparing the fixed Arm ELF as
a UF2 with [uf2.py](uf2.py), then copying it to BOOTSEL storage off the
cascade. On the Pi, unplug the cascade before plugging a BOOTSEL Pico 2
into another Pi port. Return it only after verifying its fixed image.

Changing a Pico 2 between Arm and Hazard3 is an explicit setup/boot
operation, also off the cascade. After UF2 recovery into Arm, use the
intended port's boot check with an explicitly named off-cascade switching
hub and port. Its flash step attaches as the architecture already running,
cold-starts the selected image and finally restores that port's fixed
image and verifies its startup marker. Only then run that port repeatedly
in RAM mode. A RAM run does not change architectures or fall back to a
ROM reset. Keep the board off the cascade through recovery, setup and boot
validation; the physical setup must be checked before returning it.

When no independent switching hub is available, both Pico 2 ports accept
`--mode=boot --boot-transport=manual-uf2`. Keep the cascade unplugged and
give the direct `--hub`, `--port` and known `--pico-serial`. For the recovered
board these are `--hub=1-1 --port=2 --pico-serial=5ED092AAACF4A000`.
The tool validates the normal and fixed UF2s against their ELFs, binds the
BOOTSEL volume to that USB location and serial, and copies through a
normally running boot ROM. It never uses probe flashing or hub switching
in this mode. The Pi needs passwordless `sudo -n mount` and `umount` for
the private VFAT mount; the copy runs as the invoking user.

Use the same build-host wrapper with `--mode=boot` before `--` and the
manual transport arguments afterward. It prints progress and a status
command before starting the physical phase, and retains that command in
`transfer.json`. Each flushed `MANUAL` request names a run, phase, token
and physical instruction. From the matching source snapshot on the Pi,
the operator commands are:

```sh
python3 environments/boards/manual.py status --output=RESULT
python3 environments/boards/manual.py ack --output=RESULT --run=RUN --phase=PHASE --token=TOKEN
python3 environments/boards/manual.py cancel --output=RESULT --run=RUN --phase=PHASE --token=TOKEN
```

Acknowledge only after completing the displayed instruction. The sequence
installs the ordinary image through BOOTSEL, checks its flash bytes, then
requests separate unplugged and replugged confirmations for a cold start.
UART is ready before reconnect, and the existing exact power-on oracle
still decides the run. Restoration repeats the process for that port's
fixed image and checks its flash bytes and startup marker. The recorded
off interval is measured between human confirmations; it does not measure
the power rail. Wrong or stale tokens, timeout, cancellation and USB
trouble cannot advance a step or resume a stopped run. A USB stop leaves
recovery to the operator, without further prompts or hardware actions.
The rig lock spans the whole physical sequence. Recovery records establish
installation and readiness; only the complete scenario and fixed-image
restoration produce a passed boot record.

## Shared rig rules

Every hardware phase holds the same host lock,
`~/.cache/landin/rig.lock`. Compilation and environment preparation happen
before that phase. Hub paths are discovered by IDs, relative to the
cascade; verify live board and debugger identities rather than copying an
old absolute USB path. The Arty must be present and outside the cascade
before a port can be switched, and its own port is never switched.

There is no fixed inter-action wait by default: wait for the affected hub
and device. Stop on kernel USB trouble, including controller death, retain
the kernel lines and leave recovery to the maintainer. Ordinary Wi-Fi
firmware errors are not USB errors. After the cause is understood, the
explicit `python3 environments/boards/common.py acknowledge REASON`
records that recovery under the same lock; it is not an automatic retry.
The Pi's cascade and Arty share its VL805 controller, so separate ports do
not establish separate controller failure domains.
