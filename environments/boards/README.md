# Board tools

These tools build and exercise eight supported ports: RP2040, RP2350 Arm,
RP2350 Hazard3, STM32H753, ESP32-C3, ESP32-C5, ESP32 and ESP32-S3. Both RP2350 ports use the
same physical Pico 2, and the STM32H753's board also runs its cached
profile, `stm32h753_cached`, from SRAM alone
([below](#the-stm32h753s-cached-profile)). Other boards on the rig are not
selected by these commands. The tools serve the maintainer's rig; to load
an image onto a board of your own, the ELF on a Cortex-M or RP2350 board
and `OUT.bin` at the description's flash offset on an ESP chip, see
[the firmware guide](../../docs/targets.md#loading-an-image-onto-your-own-board).

The rig has names of its own. epycmicro is the maintainer's x86-64 Linux
build host. rigpi is the Raspberry Pi the boards hang off. The cascade is
its chain of USB hubs, whose ports `uhubctl` switches to power a board on
and off. The Arty is a Digilent Arty A7 FPGA board on a Pi port outside the
cascade, running probehive, the gateware that makes it a six-slot CMSIS-DAP
probe over Ethernet with a UART and a reset line for each slot. `D973`
names a decision recorded in `spec.md`; `refine explain D973` prints it.

Build on epycmicro in Landin's pinned environment. The board tools and
their physical checks run on rigpi, by hand through `run.py` or in the gate
through [`gate.py`](#the-board-gate-on-the-rig). A RAM run enters an image
loaded into SRAM through the debugger, so it establishes nothing about
power-on or boot-ROM behavior. `refine` defaults to the boot layout; the
board tools default to `--mode=ram` and pass `--firmware-layout=ram`
explicitly.

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

The SRAM helper, the probehive runtime and the record of the loaded
bitstream live in the rig's shared state, `/var/lib/landin-rig` on rigpi
([shared rig rules](#shared-rig-rules)), where the maintainer's manual runs
and the gate's runner user both find them.

The pinned probe-rs source is JanHaan/probe-rs revision
`6f9946fe748edd0e55604dc42bc0f7ea3e7485da`, branch `rig/2026-11-03`.
The Pi reports `v0.32.0-344-g6f9946fe`. The helper uses the same source and
vendor hashes in [package.nix](ram-run/package.nix). Build the helper on
epycmicro, import its closure on the Pi, and root it there in a profile:

```sh
nix build .#board-ram-run-rigpi --out-link /tmp/landin-ram-run
helper=$(readlink -f /tmp/landin-ram-run)
nix-store --export $(nix-store -qR "$helper") > /tmp/landin-ram-run.closure
ssh -i ~/.ssh/epycmicro-2026-09-17 jan@10.42.0.60 \
    'sudo nix-store --import' < /tmp/landin-ram-run.closure
ssh -i ~/.ssh/epycmicro-2026-09-17 jan@10.42.0.60 \
    "sudo nix-env -p /nix/var/nix/profiles/landin-ram-run --set $helper &&
     install -d -m 2770 /var/lib/landin-rig/bin &&
     ln -sfn /nix/var/nix/profiles/landin-ram-run/bin/landin-ram-run \
         /var/lib/landin-rig/bin/landin-ram-run"
```

This explicit import accepts a locally built, unsigned closure; a normal
remote Nix copy rejects it without a trusted signing key. An imported store
path is not a garbage-collection root, and neither is a symlink to it from
a home directory or from the state directory: the Pi's weekly garbage
collection deletes the path and leaves the link dangling. The profile is the
root. Each `--set` adds a generation;
`sudo nix-env -p /nix/var/nix/profiles/landin-ram-run --delete-generations old`
drops the earlier ones. `readlink -f /var/lib/landin-rig/bin/landin-ram-run`
names the store path the profile holds. Do not check roots with
`nix-store --query --roots`: although it is a query, on rigpi it removed
stale automatic root links and temporary-root files as it ran.

The gate runs `/var/lib/landin-rig/bin/landin-ram-run` by default; a manual
run names it with `--ram-loader`.
`nix build .#board-ram-run` builds and tests the host executable.
`landin-ram-run --describe` reports the compiled source hash and probe-rs
revision without opening a probe. The board tool checks these against its
matching source before hardware access and refuses a stale helper as
`rig-tool-mismatch`.

The probehive runtime needs its `flake.nix` and `flake.lock` for the
`#gpio` shell, `scripts/dap_bridge.py`, `scripts/dap_udp.py` and
`scripts/gpio.py`, and the loaded bitstream's
`build/slots_ci/generated/rig.json` and `csr.json`. GPIO uses its lightweight
`#gpio` shell, available on arm64 and x86-64, rather than the FPGA shell.
The gate takes the runtime from `/var/lib/landin-rig/probehive`, and a
manual run names it with `--probehive`. Prepare that environment before
holding the rig lock:

```sh
nix develop /var/lib/landin-rig/probehive#gpio -c true
```

The matching probehive change is published on
[`landin-ram-gpio`](https://github.com/JanHaan/probehive/tree/landin-ram-gpio),
commit `4f69b8269a664cf1e1c47b2b40365b482e9f30ec`.
[rig.json](rig.json) pins that commit and the SHA-256 of each of the seven
runtime files above, and `gate.py` checks them before the lock: a missing
file is `needs-setup`, a different one `rig-tool-mismatch`. A plain copy of
the files serves as well as a checkout, since the hashes are the identity.
Source and runtime files must match the loaded bitstream.

The Arty holds its bitstream in SRAM, and the gateware's LiteX identifier
is the constant `probehive`, so which bitstream is loaded cannot be read
back from it. [`rig.py`](rig.py) keeps the answer instead, in
`probehive-loaded.json` in the shared state: the file's SHA-256, when it
was loaded, the Pi's kernel boot id then and the Arty FTDI's location, bus
and device numbers. With `PATH` the pinned build's
`build/slots_ci/gateware/arty_slots.bit`:

```sh
python3 environments/boards/rig.py load-probehive --bitstream PATH
python3 environments/boards/rig.py record-probehive-load --bitstream PATH --reason TEXT
python3 environments/boards/rig.py verify
```

`load-probehive` takes the rig lock, refuses any bitstream but the one
rig.json pins, loads it with `openFPGALoader -b arty` and records it; it is
the only command here that touches the Arty. `record-probehive-load`
records a bitstream the operator knows is already loaded, with the reason,
and loads nothing. `verify`, which the gate runs before any hardware,
accepts the record only while its hash is the pin, its boot is the current
one and the Arty has not enumerated again since; otherwise the gate stops
with `rig-tool-mismatch` for another hash and `needs-operator` for a reboot
or a re-enumeration, either of which may have cost the Arty its power and
its bitstream. Load or record again after either. Loading a bitstream is an
explicit rig operation; a run never switches the Arty's power.

## Run a prepared candidate

From the Landin checkout on epycmicro:

```sh
python3 environments/boards/run.py --board=rp2040 \
    --refine compiler/ada/build/nix-x86_64-linux/debug/bin/refine \
    --output NEW_DIRECTORY -- \
    --ram-loader /var/lib/landin-rig/bin/landin-ram-run \
    --probehive /var/lib/landin-rig/probehive --indicator-pin IO32
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

[rig.json](rig.json) writes out each port's arguments in both modes, as the
gate passes them. Both RP ports and both Xtensa ports need `--ram-loader`
in boot mode as well as RAM mode, because their tools read a running
core's memory only through the helper's single-core readback: a full
probe-rs session would try to access the RP's reset-held core 1 when it
closes and can leave the executing core halted, and an Xtensa read goes
through the helper's `boot-read` in boot mode and checks CPU1's retained
stall in RAM mode. The STM32H753, ESP32-C3 and ESP32-C5 boot checks read
memory with probe-rs itself, so only their RAM runs name the helper.
`--probehive` names the runtime for the ports whose probe or UART is a
probehive slot's: both RP ports and the ESP32-C3. The Pico 2 also takes
its `--hub`, `--port` and, on the rig, `--power-only`
([below](#the-pico-2-on-a-power-only-cable)).

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
the quiet resident image. With `--power-only` any device there at all stops
the run. RAM mode needs no hub power-control permission.
For a Pico 2 on a data cable with the cascade unplugged, name the
cascade's last root explicitly with `--cascade`
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

### The Pico 2 on a power-only cable

On the rig the Pico 2 hangs from the cascade's hub `.3.3`, port 2, through
a cable that carries VBUS and ground alone; [rig.json](rig.json) names that
location. Its SWD and UART come from probehive and its fixed images are
USB-silent, so it needs no USB data. Without data lines nothing the chip
does reaches a host controller: neither BOOTSEL nor the boot ROM's USB
device, which probe-rs's RP235x download reset leaves connected with its
core halted (D832). Those two are what stopped the xHCI before. Uhubctl
still cuts VBUS for a real cold start. `--power-only` is the maintainer's
word for that cable. With it both Pico 2 tools:

- run boot checks and the change between Arm and Hazard3 on the cascade
  port, unattended;
- permit a probe attach whatever the boot ROM runs, BOOTSEL included;
- require the port to show no device at all before any attach or switch: a
  device there means the cable carries data, and the run stops
  `needs-operator` before anything attaches or switches;
- refuse `--boot-transport=manual-uf2`, since such a cable cannot copy a
  UF2.

A boot check flashes over SWD as the architecture already running, so it
also recovers a bad image without UF2. The gate runs `rp2350_hazard3` RAM
from the resting fixed Hazard3 image, `rp2350` boot, `rp2350` RAM and
`rp2350_hazard3` boot in that order, and ends on the fixed Hazard3 image,
the board's resting state. The
maintainer's NixOS configuration for rigpi also sets `early_stop` on that
hub port, a backstop the tools do not rely on. Malformed-block controls
stay refused in this arrangement too.

### A Pico 2 with a data cable

A Pico 2 whose cable carries USB data, run without `--power-only`, keeps
the earlier rules. Every boot check and malformed-image control belongs off
the cascade. A Pico 2 in BOOTSEL must never be attached through probe-rs,
even with an override. Recover corrupt flash by preparing the fixed Arm ELF
as a UF2 with [uf2.py](uf2.py), then copying it to BOOTSEL storage off the
cascade. On the Pi, unplug the cascade before plugging a BOOTSEL Pico 2
into another Pi port. Return it only after verifying its fixed image, and
on the rig return it on its power-only cable.

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

## The STM32H753's cached profile

[`stm32h753_cached/board.py`](stm32h753_cached/README.md) runs
`compiler/tests/board/stm32h753_cached` on the NUCLEO-H753ZI with its
Cortex-M7's caches on (D974, D975). It is a RAM run alone: `build.py`
prepares its RAM bundle and no boot bundle, it has no fixed image, and the
board's boot check stays the cacheless port's. The helper loads it as it
loads the cacheless image, under the warm contract unchanged, which still
refuses a chip whose caches are on: the image's own reset enables them
after the load (D973), and its entry returns at the end of the run, which
cleans and disables them again. The return then ends, as every firmware
entry's return does, in the compiler-owned `udf` trap, whose handler the
helper cannot step out of, so a RAM run straight after a cached run is
refused with "could not retire active exception; use the boot check". The
leg runs the boot check next, which flashes and restores the fixed image;
after a manual cached run, run that boot check before another RAM run. The
helper and its deployment are unchanged by it.

What is physical and what is not:

| Evidence | Where |
|---|---|
| a read without the invalidate returns the ring's stale lines, and memory holds the bytes sent | the board |
| a maintained ring reads 1024 bytes across its laps as the host sent them | the board |
| an invalidate loses a dirty line, and four ranges that are not whole lines are refused, the line under them kept | the board |
| a transmit without a clean carries memory's stale bytes, and after one the message | the board |
| CCR's IC and DC set during the run, by the image and over SWD, and clear once the entry returned; CCSIDR's 128 sets, four ways and 32-byte line | the board |
| the order of every SCB write of reset, the provider and the return, and the refusals | QEMU's mps2-an500, which models no cache (D977) |
| the image's literals reach only the declared cache registers | `devices/test.py` and the tool's build (D976) |

The oracle refuses a control that does not fail as predicted, so a run on
a core without caches, or with the maintenance in place, cannot pass.

## The board gate on the rig

[`gate.py`](gate.py) runs one port of [rig.json](rig.json) on rigpi from
the bundles `build.py --mode=both` prepared, as the gate's board jobs do:

```sh
python3 environments/boards/gate.py --port=PORT --bundles=BUNDLES \
    --output=NEW_DIRECTORY [--lock-wait=SECONDS]
```

rig.json describes the maintainer's rig: the Arty's serial, the probehive
commit with the SHA-256 of its seven runtime files and of its bitstream,
and the steps of each port, `rp2040`, `pico2`, `stm32h753`, `esp32c3`,
`esp32c5`, `esp32` and `esp32s3`, in order with the arguments that rig
needs. In an argument, `{probehive}` and `{ram_loader}` become the paths
`gate.py` was given as `--probehive` and `--ram-loader`, by default
`probehive/` and `bin/landin-ram-run` in the shared state, and a name from
the port's `location`, such as the Pico 2's `{hub}` and `{port}`, becomes
its value. A null location ends the port `needs-setup` before any hardware,
and the port's `setup` text says what the rig lacks. The gate passes
`--mode`, `--bundle` and `--output` itself, so rig.json may pass none of
them, nor `--record`.

Every port runs its RAM run first, from the verified fixed image the last
run left, then its boot check, which flashes, cold-starts, checks the
physical oracle and restores and verifies the fixed image, so the board
rests on that image rather than on a RAM application left running. A RAM
run leaves an RP chip's other core parked under the warm contract, which
probe-rs's whole-chip download cannot attach to, so the RP boot checks
begin with a cold start of the board's port before they flash. After a
run that did not end on its passed boot check, the board's state is
unknown, so the port begins with the boot check of its resting image as
well. The Pico 2 runs four steps
([above](#the-pico-2-on-a-power-only-cable)), and the STM32H753 three: its
RAM run, its cached profile's RAM run, and its boot check
([below](#the-stm32h753s-cached-profile)). A RAM run's success never
establishes power-on, ROM loading or fixed-image restoration, so no port
runs RAM alone.

Before it takes the lock, and before anything touches a board, a probe or
a hub, `gate.py` reads rig.json, validates every bundle against this
checkout's source, describes the helper, asks probe-rs for its version,
hashes the probehive runtime, finds the cascade with the Arty off it and
verifies the bitstream's load record, each for the ports that use them.
Then it holds the rig lock across all the port's steps, so no other run
comes between its steps. It waits at most `--lock-wait`
seconds for it, 2700 by default and 1200 in the gate's jobs, then ends
`rig-busy`, naming the holder.

Each step runs `python3 environments/boards/BOARD/board.py --mode=MODE
--bundle=BUNDLES/BOARD/MODE --output=NEW_DIRECTORY/BOARD-MODE ARGUMENTS`,
as `run.py` runs it, in a process group of its own, and the sequence stops
at the first step that does not pass. `NEW_DIRECTORY/outcome.json` keeps
each step's outcome, exit status, elapsed time and failure, and the run's
provenance: the commit and GitHub run, the host and its boot id, the state
directory, rig.json's hash, each bundle's manifest, compiler and source
identities, the helper's description, probe-rs's version, the probehive
files' hashes, the topology and the load record. A summary is appended to
`$GITHUB_STEP_SUMMARY` when that is set. The exit status is 0 only for a
passed port.

Before each step `gate.py` writes `runs/PORT.json` in the shared state,
naming the port, the step, the commit and the run, and removes it only
when the sequence ended on its passed boot check, which leaves the board on
its restored and verified fixed image. A run that finds one keeps it in
`outcome.json` as `previous_interrupted` and begins with the boot check of
the resting image, the sequence's last, which flashes over SWD whatever the
board runs. That holds for the Pico 2 too, in either architecture or in its
boot ROM, since its power-only cable keeps that ROM's USB off the bus.

## The line exchange

The boards with a tty console change their serial line during each run
and come back (D962, D963). After the run's other checks, and before the
probe reads the counters back, `common.line_phase` asks for a line by
sending 0x16 and eleven digits. The board answers on the line in use with
an `l` frame:

| key | what it holds |
|---|---|
| `r`, `d`, `p`, `s` | the rate, data bits, parity and stop bits the board read |
| `k` | the clock it computes the line from |
| `o` | 0 when it accepts the line, 1 for `line.unsupported_rate`, 2 for `line.unsupported_format` |
| `b`, `f` | for an accepted line, the divisor and frame register images |
| `x` | on the STM32H753, its CR2 register image |

The host holds each answer to the port's expected one, written from its
manual: `stm32h753/board.py`'s `line_oracle` from RM0433, `esp.py`'s from
the ESP TRMs. After a refusal the board must still answer a 0x11 on the old
line. An accepted line is set on the tty with `TtyConsole.line`. Nothing
may arrive while the two ends change; a 48-byte payload and 0x17 must come
back echoed byte for byte; the board's `e` frame must count the payload and
hash it, FNV-1a, exactly; and once the board and the tty are back at
115,200 8N1 the board must answer a 0x11 there. A board that echoes the
payload and 0x17 but sends no `e` frame has read 0x17 as something else,
as a parity bit left above seven data bits makes it, and the failure says
so (D965).

| Port | Bridge | Accepted | Refused |
|---|---|---|---|
| STM32H753 | ST-LINK V3 VCP | 230400-8N1, 9600-8E1, 57600-7O2 | 300 baud, 6N1 |
| ESP32 | CH340 | 921600-8N1, 9600-8E1, 57600-7O1 | 3,000,000 baud, 8N2 |
| ESP32-S3 | CH340 | 460800-8N1, 19200-8O2, 57600-7E1 | 9600 baud, 9N1 |
| ESP32-C5 | CH340X | 230400-8N1, 38400-8E2, 57600-7O1 | 300 baud, 9N1 |

The settings are within what the bridges' vendors state, which no run here
measures: the CH340 and CH340X carry 5 to 8 data bits, any parity, one or
two stop bits and the standard rates to about 2 Mbaud; the ST-LINK V3's
port carries 7 or 8 data bits with parity and one or two stop bits, at
rates derived from its own clock. A passed exchange shows that the board's
registers and its bridge agree on a line well enough to carry every byte
both ways; it times no bit. The RP2040, both RP2350 ports and the ESP32-C3
answer on probehive's bridge, 8N1 at the one rate it was started at, so
their `line` verdict is `not run: probehive bridge fixed at 115200 8N1`:
their line code has only the shared module's arithmetic and the derived
driver's emulator register images behind it (D958, D961). The exchange
adds two to three seconds to each tty run, RAM and boot alike, most of
it the 0.2 s each end is given to change line.

## Shared rig rules

The rig's state is one directory. It is `LANDIN_RIG_STATE` when that is
set, which must name an absolute existing directory or every lock refuses
`needs-setup`; otherwise `/var/lib/landin-rig` when it exists, as it does on
rigpi; otherwise `~/.cache/landin`, the default on any other host.

| entry | what it holds |
|---|---|
| `rig.lock` | the one lock, naming its holder |
| `rig.pace` | the last action that disconnected a device, and acknowledgements |
| `runs/PORT.json` | `gate.py`'s journal of a port's step under way |
| `probehive-loaded.json` | `rig.py`'s record of the loaded bitstream |
| `probehive/` | the pinned probehive runtime |
| `bin/landin-ram-run` | the SRAM helper's link into its profile |

On rigpi the directory belongs to group `rig`, which the maintainer and
the gate runner's `landin-rig` user share, so manual runs and the gate's
take one lock and see one USB stop. The tools make what they write there
group-shared whatever the user's umask: files 0660, directories setgid
2770, never writable by others. They replace a file by renaming a complete
one beside it, so a reader never sees half of one.

While the state is anywhere but the home's cache, a `~/.cache/landin/rig.lock`
that another process holds stops the run `needs-operator`: a tool from an
older source holds that file, and would not serialize against this one.
Let that run finish, update its source, then retire the old file.

Every hardware phase holds the lock. A board tool waits for it without end,
naming the holder; `gate.py` waits for a bounded time and ends `rig-busy`.
A run started by hand under `flock` on the same file already holds it
through its parent, and goes on. Compilation and environment preparation
happen before that phase. Hub paths are discovered by IDs, relative to the
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

### What a run reports

Every board tool's `result.json` keeps its `status`, `passed` or `failed`
for records and older readers, and adds an `outcome` that says what to do
next:

| outcome | what it means |
|---|---|
| `passed` | the run passed, or a diagnostic completed its observation |
| `failed` | the board, its image or its oracle failed |
| `usb-stopped` | the kernel logged USB trouble and the run stopped; recovery and acknowledgement are the maintainer's |
| `unavailable` | a board, debugger, console, hub or the cascade is absent, or another device holds its place |
| `rig-busy` | the lock stayed held for the whole bounded wait |
| `rig-tool-mismatch` | the helper, probe-rs, the probehive runtime or the loaded bitstream is not the pinned one |
| `needs-setup` | the rig lacks a setup the run requires; nothing was attempted |
| `needs-operator` | the rig's state needs a person's look before any run continues |
| `cancelled` | SIGINT or SIGTERM stopped the run |

`gate.py`'s `outcome.json` adds `incomplete`, for a step that exited
without a readable `result.json`. A run that meets several keeps a
cancellation or a USB stop over anything else, and otherwise its first
specific outcome over a plain failure. A refusal before a tool has written
its result, in its preflight, is still written as a `result.json` under
`--output`; one its argument parser raises is not, and the gate reports
that step `incomplete`.

A probe command whose open is refused with "permission denied (errno 13)"
is asked again for up to 15 seconds, each attempt in a log of its own. A
unit that comes back after a power cycle is listed by its hub before udev
has given its new node the group, and an open in between is refused; a node
still refused after the wait fails the step as the command does.

SIGINT or SIGTERM stops a tool at its next point. A power cycle or a
download under way finishes first, because one cut short leaves a port off
or a chip halted in its boot ROM. A boot check cancelled before its fixed
image is restored records the restoration pending instead of starting it:
GitHub's runner sends SIGTERM 7.5 s after SIGINT and kills the step 2.5 s
later, too soon for a restoration, and one killed half way leaves the board
worse off than one never begun. The port's next boot check restores it.
The tool then closes the probe sessions and consoles it opened, releases
the lock and records `cancelled` with the signal and the phase: the command
running or last run, and the last paced action. Later signals are only
noted. `gate.py` passes each signal to the running step, and between steps
stops itself.
