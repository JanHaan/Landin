# Board tools

These tools build and exercise six supported ports: RP2040, RP2350 Arm,
RP2350 Hazard3, STM32H753, ESP32-C3 and ESP32-C5. Both RP2350 ports use the
same physical Pico 2. Other boards on the rig are not selected by these
commands.

Build on epycmicro in Landin's pinned environment. The tools and physical
oracles run on rigpi. A RAM run is a warm debugger entry; it does not
establish power-on or boot-ROM behavior. `refine` retains the default boot
layout; board tools default to `--mode=ram` and select the compiler's
`--firmware-layout=ram` explicitly.

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

The probehive runtime needs its `scripts/dap_bridge.py`, `scripts/dap_udp.py`
and `scripts/gpio.py`, and the loaded bitstream's
`build/slots_ci/generated/rig.json` and `csr.json`. GPIO uses its lightweight
`#gpio` shell, available on arm64 and x86-64, rather than the FPGA shell.
Prepare that environment before holding the rig lock:

```sh
nix develop /home/jan/src/probehive#gpio -c true
```

The matching probehive change is local until separately published. Source
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

The warm helper halts the executing core, retires an active exception,
stops the port's DMA and interrupt sources, parks the other RP core,
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

Every Pico 2 boot check and malformed-image control belongs off the
cascade. A Pico 2 in BOOTSEL must never be attached through probe-rs, even
with an override. Recover corrupt flash by preparing the fixed Arm ELF as
a UF2 with [uf2.py](uf2.py), then copying it to BOOTSEL storage off the
cascade. On the Pi, unplug the cascade before plugging a BOOTSEL Pico 2
into another Pi port. Return it only after verifying its fixed image.

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
