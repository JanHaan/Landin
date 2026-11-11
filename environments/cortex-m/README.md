# Cortex-M emulator evidence

This directory is the emulator harness for the Cortex-M and RV32 firmware
targets: the gate's evidence that firmware runs, and not a guide to
writing it. To write firmware, start from
[the firmware example](../../examples.md#firmware-for-a-microcontroller), a
complete program with its build and run commands;
[the targets guide](../../docs/targets.md#running-a-firmware-image-under-qemu)
says how to run an image under a QEMU you install yourself. The harness
installs locked QEMU, GDB and cross tools, and its lanes run
independent C and assembly controls, compiler-generated firmware with
compiler-owned reset, vectors and linking, and the backend corpus, against
QEMU machines and synthetic peripherals. `setup.py` installs the tools and
`run.py` runs every lane:

```sh
python3 environments/cortex-m/setup.py
python3 environments/cortex-m/run.py --refine PATH_TO_REFINE --output NEW_DIRECTORY
```

[Reproduction and evidence](#reproduction-and-evidence) gives the whole
sequence and the lane and part selectors. `D619` names a decision recorded
in `spec.md`, and `[1990]` a numbered paragraph of `tour.md` or `spec.md`;
`refine explain D619` prints either.

## Selected lanes and pins

| Component | Exact selection |
|---|---|
| Probe host | native Linux x86-64 with glibc 2.38 or later, `dpkg-deb`, `tar` and `xz`; the gate runs it on GitHub's `ubuntu-24.04` |
| CPU/startup lane | QEMU 10.0.13, Debian `1:10.0.13+ds-0+deb13u1`, `-M microbit -accel tcg,thread=single` |
| Armv7-M corpus lane | the same QEMU binary, `-M mps2-an385`: a Cortex-M3, for corpus fixtures whose `levels:` name `armv7-m` (D255) |
| Armv8-M corpus lane | the same QEMU binary, `-M mps2-an505`: a Cortex-M33 r0p3 in Secure state, for the whole corpus at `armv8-m.main` in `run.py`'s `mps2-an505` lane and for fixtures whose `levels:` name it, on the lane description `lanes/descriptions/mps2_an505` (D607, D619); libgcc from `thumb/v8-m.main/nofp` |
| M7 corpus lane | the same QEMU binary, `-M mps2-an500`: a Cortex-M7 r1p2 with the double-precision FPv5-D16, for the whole corpus at `armv7e-m` hard-float in `run.py`'s `mps2-an500` lane, on the lane description `lanes/descriptions/mps2_an500` (D619), and for the VFP ABI control and the firmware lane's `float-unit` and `cache-sequence` cases, the latter on `lanes/descriptions/mps2_an500_cached` (D977); libgcc from `thumb/v7e-m+dp/hard` |
| Core | nRF51822 Cortex-M0, ARMv6-M, Thumb, little endian, 16 MHz model clock; no FPU, caches or exclusive-access instruction requirement |
| Peripheral lane | the same QEMU, with `machine.py` serving `models.py`'s synthetic devices through its debugger stub; `-icount shift=0` |
| EABI compiler | `arm-eabi-gcc` 16.1.0, GNAT's arm-elf archive `16.1.0-1` from the host GNAT's release, pinned in `environments/pins.sh` |
| Assembler/linker | GNU Binutils 2.46.1, from the same archive |
| Debugger | `gdb-multiarch` 16.3, Debian `16.3-1`, loopback QEMU remote stub |
| Probe options | `-mcpu=cortex-m0 -mthumb -mfloat-abi=soft -mabi=aapcs -fno-short-enums -ffreestanding -fno-builtin -fno-omit-frame-pointer -g3 -O1 -nostdlib`; warnings are errors |
| RV32 emulator | Espressif's QEMU `esp-develop-9.2.2-20260417`, the release's Linux x86-64 `qemu-system-riscv32` archive, unpacked into the tool root's `qemu-espressif` (D695) |
| rv32imc corpus lane | `-M esp32c3 -cpu espressif,a=false,zawrs=false,f=false,d=false,zfa=false`: the ESP32-C3 machine with its core's A, F and D removed, which the C3 has not (D696), for the whole corpus at `rv32imc` in `run.py`'s `esp32c3` lane, on the lane description `lanes/descriptions/esp32c3` |
| rv32imac corpus lane | `-M sifive_e`: a SiFive E31, rv32imac, for the whole corpus at `rv32imac` in `run.py`'s `sifive-e` lane, on the RV32 reference's map, 32 KiB of flash at `0x2040_0000` and the 16 KiB DTIM at `0x8000_0000` |
| RV32 compiler | `riscv64-elf-gcc` 16.1.0 with Binutils 2.46.1, GNAT's riscv64-elf archive `16.1.0-1`, pinned in `environments/pins.sh`; libgcc from `rv32im/ilp32` at rv32imc and `rv32imac/ilp32` at rv32imac |
| RV32 options | `-march=rv32imc_zicsr_zifencei` or `-march=rv32imac_zicsr_zifencei`, then `-mabi=ilp32 -ffreestanding -fno-builtin -fno-omit-frame-pointer -g3 -O1 -nostdlib`; warnings are errors |

`tools.lock.json` pins URLs and SHA-256 for every downloaded package: QEMU
and GDB, and the whole Debian 13 runtime closure they load, down to
the libraries and embedded Python 3.13 a Debian 13 base image would have
supplied, and Espressif's QEMU release archive with the Debian libraries it
loads: SDL2 and the sound, X11 and Wayland libraries SDL2 links, and
libgcrypt, 36 packages chosen by following each binary's `NEEDED` entries
rather than the packages' dependencies, which would add Mesa and LLVM that
nothing loads. Debian's libpulse finds its common library through a
`RUNPATH` under `/usr`, so the lanes put the tool root's
`lib/x86_64-linux-gnu/pulseaudio` on `LD_LIBRARY_PATH` beside the library
directory itself. GCC and binutils come from the arm-elf and riscv64-elf
archives whose version and checksums `environments/pins.sh` holds beside
the host GNAT's; the arm-elf GDB is
built without the Python the debugger sessions run, so GDB stays Debian's.
The installer verifies archives before extraction. Each probe verifies the
installation inventory and versions before execution, checks it again afterward,
and retains that inventory. The host supplies only the C and C++ runtimes
and the Python that drives the probes, so any glibc 2.38 host runs the same
locked binaries; the newest of them asks for exactly that glibc. This is a
supported host profile, not a hermetic operating-system image.

These C probe flags select base AAPCS soft-float transport and ELF32 EABI;
the internal Landin transport is selected separately, as the
[target guide](../../docs/targets.md#cortex-m-layout-and-abi-planning) describes.
The compiler-generated assembly lane keeps external startup and linking; the
firmware lane uses compiler-owned reset, vectors and linking. Landin's C
boundary on Cortex-M is AAPCS32 signatures and records, in the base and VFP
variants (D920), which [C peers on Cortex-M](#c-peers-on-cortex-m) runs;
variadic C calls are not enabled (D922).

## Memory and device map

| Region | QEMU CPU lane | Synthetic peripheral lane |
|---|---|---|
| Vectors | address 0, 48 words / 192 bytes, initial MSP `0x20004000`; Thumb reset address in word 1 | identical probe image convention |
| Flash | machine provides 256 KiB at 0; linker limits probes to 32 KiB | identical |
| RAM | 16 KiB at `0x20000000` | identical |
| Probe stack | top `0x20004000`; linker reserves upper 4 KiB | identical; this is a reservation, not a measured stack bound |
| NVIC / SysTick | `0xe000e000`; 32 external IRQ entries | the same NVIC; the prototype device raises IRQ0 through its set-pending register (the driver's device also IRQ1) |
| GPIO | Nordic registers at `0x50000000` | prototype GPIO A at `0x40020000`; mode, speed, alternate-function and image storage, input injection, output set/reset |
| UART | Nordic UART at `0x40002000`, transmitted bytes captured to a file | synthetic divisor at `0x40021000`, received data at `0x40021004` |
| DMA | no prototype DMA | controller status/clear at `0x40026000/04`; stream 5 config/count/peripheral/memory at `0x40026058/5c/60/64` |

The prototype is a sketch combining M0 CPU pressure with vendor-like registers;
it does not identify a real part matching that whole map. The model is
deliberately named `PrototypePeripheral`, not micro:bit or STM32, and lives in
QEMU's unimplemented `0x40000000` window, above every Nordic device the lane
touches. GPIO B, unused streams and unspecified UART registers are absent.
Unknown modeled registers, invalid access directions and unsupported bus widths
raise `Refused`, which fails the runner. Explicit halfword support covers the 16-bit
count and GPIO data, without automatic read/modify/write translation.
The linker refuses initialized data (this probe startup only clears BSS), a
wrong vector extent, flash overflow and BSS entering the reserved stack area.

## Why one QEMU

Current official [QEMU documentation](https://www.qemu.org/docs/master/system/arm/nrf.html)
identifies the micro:bit's M0 and Nordic devices. Selection also inspects the
[pinned SoC implementation](https://github.com/qemu/qemu/blob/98f88efe8f07067667b8d9b1a5ce9551d34036c1/hw/arm/nrf51_soc.c)
and runs the controls below. Device presence does not prove the prototype's
behavior: Nordic GPIO/UART addresses differ, clock registers include stubs,
and this is not a prototype DMA model. QEMU retains the mandatory CPU/startup
role and the derived driver's QEMU obligation is unchanged.

The synthetic devices run on that same QEMU. The pinned SoC leaves
`0x40000000..0x5fffffff` to an unimplemented-device region, and QEMU's Arm
target stops *before* an access a watchpoint covers. `machine.py` sets an
access watchpoint on each model's window, and at every stop decodes the
Thumb load or store at PC, performs it against the Python model in
`models.py`, writes a load's destination register and moves PC past the
instruction. `decode` accepts only the register- and immediate-offset single
loads and stores; PC- and SP-relative forms and every multiple transfer are
refused, so no access reaches a model unexamined. Its decoding is checked
against the pinned `objdump` over every load and store in every image the
lanes build. A DMA transfer writes RAM while the CPU is stopped, and an
interrupt line is level-sensitive, as ARMv6-M and Renode's NVIC both treat
it: while asserted and not the active exception, the harness keeps it
pending through the NVIC's set-pending register.

Nothing here extends QEMU: the lane needs no emulator build of its own, and
the CPU that executes the peripheral lanes is the one the CPU lanes execute.
The harness is single-threaded and owns the only stream it reads. It replaced
Renode 1.17.0, whose own threads twice put text on the console a lane's
result was read from, and whose CPU descends from QEMU as this one does.

One QEMU binary still means one emulator, but not one machine. QEMU's
micro:bit is a Cortex-M0 whatever `-cpu` says, so a corpus fixture executed
at `armv7-m` (D255) runs on the MPS2 AN385's Cortex-M3 from the same locked
binary. Its memory puts writable SSRAM at 0 and RAM at `0x20000000`, so the
external harness's 32 KiB/16 KiB map, vectors and stack reservation hold
unchanged; the probe stub assembles under `-march=armv7-m`, the image must
carry `Tag_CPU_arch: v7` with Thumb-2, and libgcc comes from
`thumb/v7-m/nofp`. Only the corpus runs there. The AN385 has real devices
at `0x40020000`, where `PrototypePeripheral` lives, and its flash is RAM,
so no peripheral, firmware or flash-protection lane moves to it. Each image
run at a Thumb-2 level is disassembled and required to ask libgcc for no
product and no 32-bit quotient, and a fixture whose corpus row `selects`
instructions is held to them, so the level is shown to have reached the
bytes that ran. The six fixtures whose `levels:` name `armv7-m` add 24 QEMU
sessions to the default run, and the three that name `armv8-m.main` 12.

The `mps2-an505` and `mps2-an500` corpus lanes run on an emulator's memory
map rather than the reference's, each stated by a Landin description under
[`lanes/descriptions/`](lanes/descriptions). The program itself is
unchanged: one more entry-module file, `lanes/lane-NAME.ldn`, imports the
lane's description. A rooted program then names its entry module by its
files, since a rooted request names its directory or its files and not both
(D619). The corpus derives each lane's firmware profile, links with the
script refine derives from it (D545, D589), and holds its facts to the
`lanes` record of `descriptions.json`, kept apart from the devices.
`backend_corpus.py --lane NAME` runs every
inventory row alone on lane NAME, and `run.py`'s lane of the same name is
that run.

`mps2-an505` runs `armv8-m.main` on the MPS2 AN505's Cortex-M33, from the
same binary, for the whole corpus and for fixtures whose `levels:` name
that level. It boots in Secure state and takes its stack pointer and reset
from `0x10000000`, so an image linked at zero locks up, and the reference's
map does not fit it. Its description,
[`lanes/descriptions/mps2_an505`](lanes/descriptions/mps2_an505), has the
reference's capacities where the board has memory: 32 KiB of flash at
`0x10000000` and 16 KiB of RAM at `0x38000000`, the Secure aliases of its
two SSRAMs, the upper 4 KiB the stack (D607), so a program fits there
exactly when it fits the reference. The image must carry `Tag_CPU_arch:
v8-M.mainline`, and libgcc comes from `thumb/v8-m.main/nofp`.

`mps2-an500` runs `armv7e-m` on the MPS2 AN500's Cortex-M7, from the same
binary, whose float unit, FPv5-D16, is a description's (D615), so the
lane's description gives it:
[`lanes/descriptions/mps2_an500`](lanes/descriptions/mps2_an500/description.ldn),
4 MiB of code memory at 0, VTOR's address, and 4 MiB of RAM at
`0x20000000` with a 64 KiB stack at its top. Unmapped space there reads
zero and ignores writes with no fault, so a program that runs away hangs to
the session's deadline rather than faulting. Every corpus session, on any
lane, therefore interrupts a program still running at its 20-second limit
and fails it with its last pc, the caller in the link register and sp: a
pc outside the image, which `info symbol` cannot name, is a stray jump,
and one inside it is a loop that did not end. The harness start grants CP10
and CP11 before anything else, paints d8-d15 before `main` and checks them
after, the image must carry `Tag_FP_arch: FPv5/FP-D16 for ARMv8` and
`Tag_ABI_VFP_args: VFP registers`, libgcc comes from `thumb/v7e-m+dp/hard`,
and each image is required to call no float helper;
`runtime/float-operations-by-arguments` must also hold its own VFP
operation in each of its routines at none/off and no software float
routine at all. At `LANDIN_CORTEX_JOBS=4` the lane is 3,278 verdicts,
3,022 of them executions, in five to five and a half minutes on a
32-thread host, beside the reference's four and a half.

## Executable routes and limits

| Prototype pressure | Route and current evidence | Limit / where the language covers it |
|---|---|---|
| Reset, zeroed static storage, vector table and kept handlers | `start.S`, `memory.ld`, QEMU GDB initial MSP/PC/vector assertions, step, reset and second boot | handwritten environment startup; Landin sections/keep/entry are compiler-owned firmware |
| Traps, exceptions, timer and wait-for-interrupt | `cpu.c`: SVC, PendSV, SysTick/WFI, IRQ0; `fault_probe` UDF reaches HardFault with IPSR 3 | no cycle timing, every fault class or general priority/nesting proof; generated code and firmware lanes |
| Debugger control | QEMU GDB breakpoint, step, memory/register inspection, resume, reset, rerun; exact log assertions | C/assembly debug only; Landin source debug/stack evidence under Freestanding evidence |
| GPIO whole images, indexed packed fields, AF selection, reserved bits | `peripheral.c`: explicit mask/shift RMW, retained high bits, AF image, set/reset; model input injection | stored image behavior, not electrical pins/pull/speed/alternate routing; packed-language legality is D228's |
| UART configuration and bytes | QEMU exact TX bytes; synthetic `feed` writes its DR and transfers one supplied byte | synthetic divisor is storage only; no serial line, baud accuracy, FIFO overrun or framing/parity model |
| DMA descriptor, escaping static buffer, enable handoff | `peripheral.c` supplies a static ordinary byte array and descriptor; feed while disabled leaves it untouched | C pointer handoff only; Landin origin refusals and the complete derived driver |
| DMA count, increment, circular wrap and CPU visibility | five ordered feeds into four bytes, checked halfword count 4/2/4/3, wrap replaces first byte, CPU reads the transferred bytes | model serializes byte copy before count/status; no asynchronous bus races or cache-coherence proof |
| Completion, half-transfer and transfer error | model status `0x20/40/80`, enables in config bits 1/2/3, NVIC IRQ0, firmware records three IRQs and clears status | synthetic status convention follows sketch stream 5; not stock STM32 status layout |
| Critical section and event collection | PRIMASK masks delivery while DMA updates RAM/count; restoring it permits pending completion handler | proves this model's mask/delivery behavior, not Landin happens-before; D227 |
| One-clears and access modes | firmware clears pending bits; `Run.peripheral`'s model controls prove writing zero preserves error, one clears it, read-only/write-only/unknown accesses refuse | other access modes are absent; normative register rules are D228's and the generated device fixtures' |
| Bad descriptor, bounds, unsupported direction | model controls reject bad destination, count above 65535 and unsupported direction; no transfer occurs | no physical bus fault/overrun timing; driver `buffer_empty`, `buffer_too_big`, `line.unsupported_rate`, `line.unsupported_format` and recovery execute in the derived driver over this lane |
| Ordinary-slice read, head/tail and short output | current lane exposes count and circular RAM for the complete derived driver | the derived driver executes its `available`/`read` cases and failure oracles; this environment is not that driver |
| SVD-derived types, encoded values, named refusals | checked-in model and map are explicit device inputs; malformed access controls already execute | D228 packed encodings; D231 `noreturn`; generated `.ldn` device modules, which `refine svd` writes from a vendor SVD ([device guide](../../devices/README.md)) |

Feeds happen while the CPU is stopped. The firmware then runs until it is
idle -- at a WFI with nothing to take, at a branch to itself, or in a polling
loop whose registers, RAM and model state repeat exactly -- or until a
named stage word changes, and the lane checks it there. No host sleep and no
interval decides firmware success; QEMU counts instructions for its clock,
and only the debugger socket startup uses a bounded readiness poll. Stopped
time is execution scheduling, not physical bus timing. The model's transfer order
is an explicit harness assumption. The ordinary C buffer is reloaded across
opaque memory-clobber barriers; that is no definition of Landin DMA visibility.
D227 defines races, tearing, atomics, compiler/hardware barriers and cache
maintenance, with models for behaviors this cacheless M0 profile cannot expose.
Supplemental hardware can test actual bus/interrupt timing, electrical behavior
and a real device's DMA visibility; it cannot replace the emulator gates or
by itself establish language concurrency semantics.

## Reproduction and evidence

On the documented native Linux host, with Python 3, `dpkg-deb` and `tar`:

```sh
python3 environments/cortex-m/setup.py
python3 environments/cortex-m/test.py
./scripts/build.sh
python3 environments/cortex-m/run.py \
  --refine compiler/ada/build/linux-amd64/debug/bin/refine \
  --output /absolute/new/evidence-directory
```

`run.py` runs every lane, in the order the sections below describe them,
and reports each one's verdict whether or not an earlier one failed: a
transient debugger error in one lane no longer hides the others, and the
run fails afterwards, naming each lane that did not pass. `--lane NAME`,
repeated, runs only those lanes, and the lanes they need: `evidence`
compares its images with the `driver` lane's, so `--lane evidence` runs
both, and a lane whose prerequisite failed is reported as not run. The
lanes are `cpu`, `peripheral`, `abi`, `memory`, `packed`, `rv32-controls`,
`packed-native`, `backend`, `mps2-an505`, `mps2-an500`, `esp32c3`,
`sifive-e`, `firmware`, `freestanding`, `devices`, `descriptions`, `driver`
and `evidence`; `mps2-an505`, `mps2-an500`, `esp32c3` and `sifive-e` are the
corpus again on those lanes, and the two RV32 ones need `rv32-controls`
(see [RV32 lanes](#rv32-lanes)). A run that selects lanes says `FILTERED` in its last line
and its `result.json`, and is not the gate's run.

A run records the SHA-256 of its inputs before its lanes and compares them
after: when one changed meanwhile it fails with "probe inputs changed while
the lanes ran", naming each, because no verdict then holds for one tree.
The inputs are every file under `environments/cortex-m` except its
Markdown, so this guide may be edited while lanes run and a probe, a
script, a description or a recorded validation may not.

The gate runs every lane in three jobs, one for each of `run.py`'s
parts, because one job running all of them risked its hour on a four-CPU
runner, and two more whole corpora would put `corpus` at that risk again.
`--part=NAME` runs one part:

| part | lanes | gate job |
|---|---|---|
| `programs` | `cpu`, `peripheral`, `abi`, `memory`, `packed`, `packed-native`, `firmware`, `freestanding`, `devices`, `descriptions`, `driver`, `counterpart`, `evidence` | `cortex-m-programs` |
| `corpus` | `backend`, `mps2-an505`, `mps2-an500` | `cortex-m-corpus` |
| `rv32` | `rv32-controls`, `esp32c3`, `sifive-e` | `cortex-m-rv32` |

The parts together are every lane, each exactly once, and each part holds
the lanes its lanes need, so a part is not `FILTERED`: its `result.json`
records `part` and a scope naming the part and its lanes. `test.py` holds
`run.py`'s parts to that, and the gate's `cortex-m` matrix to running
exactly those parts. Each lane's verdict in `result.json` gives the seconds
it took, which is what to rebalance the parts by.

### Debugger sessions share a GDB per worker

Every lane's debugger sessions go through `Run.debug`, which serves them
from one `gdb-multiarch` per worker thread (`gdb_server.py`) rather than
one batch GDB each, since starting GDB is most of what a session costs. A
session therefore runs after whatever the sessions before it on that
thread debugged, in any lane and for either architecture, which a lane run
alone with `--lane` never meets. Before each session the server restores
the Python namespace, deletes every breakpoint and watchpoint the last
session made, the internal ones a script makes from Python among them,
disconnects, unsets the target description the last target reported, sets
the architecture back to `auto` and loads the session's executable. A
failure that names an architecture the session's own executable does not
have, or a stop the session's script never asked for, is one session
seeing another's state: run the lanes that preceded it on the same worker
to reproduce it. The `rv32-controls` lane's `shared-debugger` control
serves an Arm session, an RV32 one and an Arm one again through one GDB,
the first leaving an internal breakpoint and watchpoint, and requires each
later session to see none.

A session reads a program's module binding by its symbol,
`v("*(unsigned*)&refused")`. A binding whose name an imported routine
also has is linked under its module-qualified spelling, `main.geometry`
beside `l1.geometry`, and the bare name is then the routine's or no
symbol at all; the [target guide](../../docs/targets.md#cortex-source-debugging)
says how GDB answers that and how to find and read the binding's spelling.

### On NixOS

The locked QEMU and GDB are Debian binaries, and NixOS's own
`/lib64/ld-linux-x86-64.so.2` is a stub that refuses them, so on NixOS a
lane runs inside an FHS environment such as steam-run's. That environment
gives `/tmp` a private namespace: a `TMPDIR` the outer shell set there does
not exist inside it, so refine cannot write its files, and an `--output`
under `/tmp` vanishes when the lane ends. Keep both under `$HOME`:

```sh
mkdir -p $HOME/.cache/landin/tmp
NIXPKGS_ALLOW_UNFREE=1 nix-shell -p steam-run python3 --run \
  "TMPDIR=$HOME/.cache/landin/tmp steam-run python3 environments/cortex-m/run.py \
   --tools $HOME/.cache/landin/cortex-m --refine $PWD/compiler/ada/build/nix-x86_64-linux/debug/bin/refine \
   --output $HOME/.cache/landin/NEW-DIRECTORY"
```

Setup runs the same way, with `dpkg-deb` and `xz`, which NixOS does not put
on the path, added to the shell steam-run inherits its path from:

```sh
NIXPKGS_ALLOW_UNFREE=1 nix-shell -p steam-run python3 dpkg xz --run \
  "TMPDIR=$HOME/.cache/landin/tmp steam-run python3 environments/cortex-m/setup.py \
   --tools $HOME/.cache/landin/NEW-TOOL-ROOT"
```

`dpkg` supplies the Debian archive unpacker; `xz` decompresses the release
archives. `setup.py` checks these unpackers and `tar` before creating its
tool directory, and names this recipe if one is missing.

Both emulators run there, QEMU's `qemu-system-arm` and, for the RV32
lanes, Espressif's `qemu-system-riscv32`, with `gdb-multiarch` for both;
`--part=rv32` or `--lane rv32-controls` takes the same route.

To run an emulator or GDB by hand, to try a machine, give it the tool
root's libraries as the lanes do: they are found only through
`LD_LIBRARY_PATH`, and Debian's libpulse, which Espressif's QEMU loads
through SDL2, looks for its own common library in a `pulseaudio`
directory beside them:

```sh
T=$HOME/.cache/landin/TOOL-ROOT L=$T/root/usr/lib/x86_64-linux-gnu
NIXPKGS_ALLOW_UNFREE=1 nix-shell -p steam-run --run \
  "LD_LIBRARY_PATH=$L:$L/pulseaudio steam-run \
   $T/qemu-espressif/bin/qemu-system-riscv32 -M help"
```

Every lane refuses these three hosts before it builds anything and prints
this route: NixOS's stub loader, a `TMPDIR` that does not exist inside the
environment, and an `--output` under its `/tmp`. The firmware link driver
is not among the Debian binaries: `nix develop` carries the pinned
`arm-eabi-gcc` (D532), so `refine compile --target=cortex-m0
--firmware-entry=NAME` links in the shell itself, and the locked
installation keeps its own copy for the lanes.

The default private tool root is `~/work/.cortex-m`; `--tools` selects another
installation. Every lane refuses a root holding no installation before it
builds anything, naming the directory it looked in and `--tools`. Setup
refuses an existing root; install deliberately into a new
root to change tools. No sudo, host package replacement, Linux container on
the Mac, Nix job or compiler dependency is introduced. Missing tools, wrong
pins/host, subprocess failures, deadline expiration, model refusals, unexpected
QEMU diagnostics and absent assertions all fail. A peripheral lane's result is
the lane's own assertions in the process that ran the model; there is no
console to scan. QEMU's log may hold only its instruction-count notice and
the harness's own termination of it.

Each subprocess has a 30-second deadline, GDB 20 seconds, and QEMU startup
three seconds; timeout cleanup terminates the owned process group, escalating
after two seconds. A failed command's line names the command, how it ended,
the limit it reached and the log it left, and the firmware lane names its
case and profile ahead of it. A corpus program whose debugger session ran
out says how long the program had run under QEMU and that it, not the
debugger, took too long; an emulator that exited first says that instead.
Each run needs a new output directory and retains failure
logs as well as successes. Evidence includes exact commands, version replies,
installed file hashes, input hashes, linker maps, ELF headers/attributes, sizes,
ELFs, generated GDB scripts, logs, UART bytes, model traces and `result.json`.

The retired Linux acceptance's documents job executed both the failure
controls and these live probes from the same committed archive as every native
job, and `job.py` copied its `cortex-m` evidence into the exported,
hash-verified bundle. Thus the annotated dual-native approval bound the
environment's actual run, not only this document or a development transcript.
Darwin retains native compiler/workload/LLDB evidence and does not impersonate
this probe host. The environment's debugger control checks ran at routine
scope with debugger coverage, which is not the full milestone matrix.

The retained development result is indexed by [validation.json](validation.json).
Its successful probe images contain 643 and 836 text bytes respectively, no
initialized data and 24 BSS bytes each. These are environment-control sizes,
not measurements of the future Landin driver or a stack-usage guarantee.

## Layout and ABI evidence

The same mandatory `run.py` also builds `probes/abi.c` and `abi.S` with
the original pinned flags, startup and memory limits, then executes them in
QEMU. The peripheral lane is separate; its result is never counted as ABI
evidence. No library or tool pin changes. The additional ELF, disassembly,
macro dump, GDB script/log, measured JSON and both layout contract inputs are
retained in the `run.py` output directory.

Three independent comparisons meet:

1. The Ada `cortex ABI` suite computes scalar, aggregate, variant, evidence,
   any and multiple-result layouts and physical call plans from compiler
   packages, comparing with `compiler/tests/cortex-m.contract`. It also checks
   eight existing source fixtures through lowering and entry/direct/indirect
   planning under Cortex-M0 and synthetic-32, comparing detailed neutral IR.
   These are compiler-host tests, not target execution.
2. `abi.py` compares the contract with **every original synthetic-32 row** in
   `layout.targets`, without regenerating that golden. GCC independently lays
   out C control structures, unions and tables. QEMU/GDB reads their emitted
   measurements and compares them with the contract. Static assertions also
   cover data/code pointers, slices, ILP32, plain-char policy and 64-bit
   alignment. The C union is a representation control, not C semantics for
   a Landin variant.
3. Independently written assembly captures actual GCC-produced r0–r3,
   incoming sp and stack argument words. Assertions compare meaningful words
   with the compiler plan for double-word gaps, split 12-byte records, narrow
   stack arguments, soft floats, float-only records, promoted varargs and
   result-pointer displacement. Separate hand callers check GCC callees, and
   C callers check hand returns/callbacks, including 3/4/5-byte records and
   integer/double 64-bit results. Padding and skipped registers are unspecified
   and are not asserted as values.

The Landin convention has a separate handwritten witness: hidden aggregate
result and direct/parent evidence addresses, an address-passed value, a stacked
u64, successful and failing r12 outcomes, r0/r1 scalar results, multiple-result
storage, and erased data/table dispatch through Thumb code pointers. GDB checks
the nested r11 frame records, saved lr, chain termination and aligned sp;
firmware checks callee-save registers and restoration. These execute the
selected contract with real M0 instructions; they are not compiler-generated
Landin calls or Landin source-debugging evidence.

Compiler refusal/boundary controls cover wrong targets, unavailable C and
emission capabilities, narrow extension, the four-byte C result threshold,
empty C carriers, unpromoted varargs, declared C errors, stack-budget rounding
and a target-overflowing argument without materializing it. Source checks
cover pointer-sized integer/address overflow and the array byte-extent boundary.
The Python controls refuse duplicate/missing/invalid contract rows, synthetic
mismatches, missing markers, subprocess errors and timeouts.

Every subprocess retains the original deadlines (GDB 20 seconds, build/tools
30, debugger readiness three) and owned process-group cleanup. In the retired
exact-archive acceptance, the Linux documents job repeated all lanes and
retained tool/input hashes alongside the ABI artifacts. Its dual-native
approval bound those results to the same revision as the hosted checks. The
current `cortex-m` gate job runs these controls through `run.py`.
Development results are indexed separately in `abi-validation.json`;
`validation.json` keeps its historical meaning as the CPU and peripheral
environment's record.

The VFP variant (D616) is measured apart, on the M7 lane: `abi.py` builds
`probes/abi-vfp.c` with GCC at `-mcpu=cortex-m7 -mfloat-abi=hard
-mfpu=fpv5-d16`, with `probes/an500-start.S`, which grants the unit, and
`probes/an500.ld`, and runs it on `mps2-an500` against the hand-written
endpoints of `probes/abi-vfp.S`, which record r0-r3, s0-s15, six stack
words and sp. Every recorded argument word is held to the contract's
`vfp.` rows: back-filled singles, aggregates of floats and of doubles, the
stack fallback that leaves s1 unused, a variadic call and a five-float
composite; each endpoint's result is returned where the convention says
and checked by GCC's caller. GCC must save exactly d8-d15 around a body
that clobbers every VFP register, and sentinels in d8-d15 must survive it,
which is the contract's `vfp.preserved` row; the image must carry
`Tag_ABI_VFP_args: VFP registers`.

The generated bindings' layouts are compared with both compilers there
too (D987). Each Cortex-M binding fixture's `adapters.c` carries the
generator's static assertions of every native record's size, alignment and
field offsets and of each enum's size, and `abi.py` compiles it with
`-fsyntax-only` by the pinned GCC at `-mcpu=cortex-m0 -mfloat-abi=soft`
and `-mcpu=cortex-m7 -mfpu=fpv5-d16 -mfloat-abi=hard`, and by Clang, `$CLANG`
or `clang-19`, at `thumbv6m-none-eabi` and `thumbv7em-none-eabihf`, each with
its freestanding headers alone. A record's layout is the same under both
variants, so the VFP fixture's `vfp_sample`, padded in two places, and
`vfp_pair` must hold at both rows under both compilers; the CMSIS fixture
must hold at the base row and be refused at the VFP row by its RP2040
header's own `#error`. Built with short enums, its adapters must be refused
by their assertion of `IRQn_Type`'s size. `binding-layouts.json` records
every verdict. Where no Clang is on PATH, as in the gate's `cortex-m` job,
its half is recorded and printed as SKIPPED; the gate's `bindings` job
compiles each fixture's C with Clang at its own row.

These bounded probes establish neither floating arithmetic helpers, general
unwind support, a complete C language ABI surface, firmware stack bounds,
physical hardware behavior nor a Cortex-M compiler backend. The backend
consumes the plans with native selection and frame code, compiler-owned
firmware implements image placement and startup, and the freestanding evidence
below establishes the bounded Landin debugging and stack evidence. D227 and
D228 cover concurrency and invalid packed encodings.

## Memory evidence

The mandatory `run.py` path additionally executes `memory.py`, without changing
the CPU, peripheral or independent ABI obligations above.
`probes/memory.c` executes GCC's scalar 8/16/32-bit atomic loads/stores, DMB,
DSB and ISB, nested PRIMASK save/restore, pending interrupt exclusion and
ordinary RAM publication in both directions across handler delivery. QEMU/GDB
requires result `0x630` and no fault. These are independent C/assembly controls,
not compiler-generated Cortex-M code. GCC separately compiles an atomic RMW
control to an object whose unresolved `__atomic_fetch_add_4` is asserted; no
helper is linked or inferred as a Landin capability.

`memory_model.py` explores a finite FIFO store-buffer machine and compares its
fenced outcomes with an independently enumerated SC permutation oracle and
a separate reads-from/SC-fence constraint oracle. It checks twelve
release-sequence source cases, including plain-store interruption. It
also enumerates payload/notification propagation with and without the device
ordering premise, split-byte tearing, DMA progress while IRQ delivery is
masked, and a write-back cache-line model. The cache controls require stale
reads without invalidation, visible bytes after invalidation, destructive
post-receive cleaning, and loss of an unrelated dirty byte on a shared line.
These assertions test the stated abstractions, not the complete Arm model or
cache instructions. No absence of a weak emulator outcome counts as proof.

The prototype peripheral lane remains the executable DMA witness: static
ordinary byte storage, circular overwrite, count/status updates and delayed IRQ
while masked. Feeds are serialized while the CPU is stopped. D227 supplies
the language contract; the model supplies only its explicit device premise.
A cached profile needs platform-specific maintenance, cache levels/aliases and
visibility-point evidence before it can be admitted. M0 has no cache and supplies
none of that evidence; the STM32H753's cached profile has it from its board
run (D974, D975). Hardware testing stays supplemental.

Each new subprocess uses the existing 30-second tool and 20-second debugger
limits, three-second readiness deadline and owned process-group cleanup.
Commands, logs, ELF/map/disassembly, generated controls and GDB input, tool/input
hashes and `memory-model.json` are retained under the same `run.py` output
directory. Native Linux and Darwin separately execute the Landin scalar and
pthread ABI fixtures over their selected optimization profiles. Those results
are compiler-generated hosted execution, not embedded or model evidence.

## Image and access controls in development

The mandatory `run.py` path executes `packed.py` and `packed_native.py`. It preserves every
earlier lane. `EncodingPeripheral` in `models.py` is a separate, synthetic
peripheral at `0x40030000`:

| offset | access | explicit device contract |
|---|---|---|
| 0 | normal 32-bit read/write | initial `0xa50000f0`; bits 8..31 must retain `0xa50000` |
| 4 | destructive 32-bit read | returns initial `0x9b`, then zero; writing refuses |
| 8 | write-only 32-bit command | bits 8..31 must be zero; reading refuses |
| 12 | 32-bit status and one-clears command | initial `0xf3`; ones clear, zeros preserve; written bits 8..31 must be zero |
| 16 | normal 16-bit count | initial `0xffff`; word accesses and other widths refuse |
| 20 | normal 32-bit read/write | initial `0xffffff00`; written bits 8..31 must be one |

Pinned GCC compiles `probes/packed.c` to real M0 instructions. Its ordinary
unsigned images enumerate all byte inputs, four two-bit indexed elements and
every three-bit encoding of the independently tabulated named set 0/1/4.
Firmware then performs the device accesses. `packed.py` asserts a literal
16-event oracle, including each direction, width, address and value; that
oracle is neither generated from the C code nor derived from the model.
Reading the model's final properties does not access its registers.
Eight invalid direction/width/reserved operations must raise without adding
an event. A destructive read is consumed once locally; a second explicit read
returns zero. Write-only and one-clears commands issue no preparatory read.
The count is never widened to the neighboring halfword.

The runner retains the ELF/map/disassembly, trace, tool identities, exact
commands and hashes under the same `run.py` output directory. The existing
subprocess limits and process-group cleanup apply. The new
initial firmware had 660 text bytes, zero data and 16 BSS bytes before the
write-one reserved-bit register was added; current sizes are retained in
`size-packed.log`. These are control sizes,
not Landin firmware or stack bounds. `packed-validation.json` indexes the
successful development run and its independent local copy.

The C firmware is one independent control. `packed_native.py` separately
compiles `probes/packed-native.ldn` using the actual native Linux compiler at
six optimization/specialization profiles. Its C peer only transports explicit
width/address/value commands and replies; it performs no field arithmetic,
encoding validation or expected-image calculation. The native Landin program
computes packed indexed updates and images, and the runner performs each
transaction the peer writes against the same device model; no CPU sits
between them. Every run must match the literal
16-event oracle and final register values. This is compiler-generated hosted
execution against an actual peripheral harness, not compiler-generated M0
firmware. The Ada algebra suite and abstract oracle remain distinct evidence.

At each of the same six profiles, `probes/packed-native-hole.ldn` starts a
fresh peripheral, reads the destructive register once, and extracts its
unnamed mode inside `unchecked`. The independently specified reply is `0x9b`
and the complete trace is `r32:4:0000009b`. The native process must terminate
with SIGILL, without a second access or
the normal completion reply, after writing one line to stderr: the hosted
trap report naming the probe's source by its file name, line
16, column 13, and `bad_conversion`. Discarding the extracted value cannot remove
validation. The transport disables core dumps; it still contains no encoding
logic. This negative compiler-generated lane complements the positive raw
copy of the same invalid image and the independent C membership control.

The runner requires `--refine`, retains its SHA256 and `--identify` output,
the native GCC identity, Landin/C input hashes, assembly, executable, transport
commands, device trace and assertions. Compilation is bounded to 60 seconds;
the native peer has a 10-second bound and a 17-command positive limit; the
negative case permits exactly one command, and anything the peer writes to
stderr other than the negative case's one trap report fails the lane. Tool inventories are checked before and after
execution. The retired exact-revision acceptance built the committed debug
compiler in its documents job and retained this lane in its verified `cortex-m`
export. The current gate runs the lane through `run.py` with its built compiler.
The hosted transport remains distinct from the Cortex-M emitter and generated
vendor fixture lanes below.
The original DMA lane continues to test ordinary externally written buffer
storage under D227's explicit serialized-device premise.

The current official
[CMSIS-SVD register description](https://open-cmsis-pack.github.io/svd-spec/main/elem_registers.html)
distinguishes access permission, modified writes, read actions and reset
metadata. Its
[format guide](https://open-cmsis-pack.github.io/svd-spec/main/svd_Format_pg.html)
identifies omitted fields as reserved, without supplying one universal
reserved-bit write policy. The
[Arm Cortex-M0 user guide](https://documentation-service.arm.com/static/5ea6ce5e9931941038def8c1)
requires aligned accesses for this core. These documents were consulted on
2026-09-16; they inform the explicit control contracts, not an assertion that
this synthetic map describes vendor hardware. The device modules `refine svd`
generates keep their own provenance in the [device guide](../../devices/README.md).


## Compiler-generated execution

`run.py` preserves every earlier lane, then requires `backend_acceptance.py`.
The same installed tool inventory is verified before and after all lanes.
`backend/corpus` retains the complete shared runtime/ABI inventory from
`compiler/tests/cortex-m/corpus.json`. Every ordinary runtime case uses the
four inherited profiles; specialization cases add none/all and speed/all.
Fourteen explicit 32-bit/architecture counterparts retain the original hosted
sources and independent numeric expectations. `counterparts.json` records
exact reviewed textual differences, checked before execution. Missing/new
fixtures or counterpart drift fail the supervisor. Compiler-verdict and
neutral-IR golden fixtures retain their native compiler-host checks; they have
no independent execution oracle.

The UTF-8 ordinal trap counterpart uses 4294967295, the largest Cortex-M0
`usize`, to trap outside a three-scalar view. The hosted original keeps its
4294967296 ordinal, which tests type-checking and lowering beyond `u32`.

The corpus keeps source refusals, restrictions and physical image limits
distinct from executed programs. Every whitelisted image-limit
profile is still compiled and attempted within the materialization guard;
when it fits, it must execute successfully. Only a demonstrated oversized
frame/static extent or the selected linker's flash/RAM overflow can produce a
limit record. Missing helpers, bad instructions, wrong results and timeouts
cannot. The original multi-gigabyte image and oversized hosted stress programs
retain their original oracles and recorded image-limit dispositions. Their
unchanged hosted execution does not become a Cortex execution claim.

### The corpus inventory

`compiler/tests/cortex-m/corpus.json` has one row for every shared
`runtime/` and `abi/` fixture, hosted-only ones included, keyed by the
fixture's directory under `compiler/tests/fixtures`. A fixture with no row,
or a row with no fixture, stops the corpus before it builds anything, and
the refusal names each one and the row to write. A row's `mode` is one of:

| `mode` | Meaning | Also required |
|---|---|---|
| `execute` | built and run at every profile, and at each M-profile level its `levels:` names | nothing; a fixture that names `cortex-m0` in its `targets:` needs this row, and one with a `trap_report:` may not name it |
| `execute` with `"selects"` | the same, and at each level the row names, its `routine`, or the whole image without one, must hold every instruction in `has` and none in `lacks`: a mnemonic, or `bl NAME` for a call of NAME | the levels it names are M-profile ones |
| `execute` with `"profile_limit": "selected-image"` | every profile is still built and attempted; a profile whose image fits runs and must pass, and one that does not is recorded with its sizes. A routine whose stack is past the profile's reservation is such a limit too: the Cortex-M and RV32 lanes read it from the build report, and the Xtensa lane, which builds with a firmware entry, from refine's L0507; `scripts/add_fixture.py` writes the row for one, given `--reason` | a `reason`; the fixture does *not* name `cortex-m0` in its `targets:`, since an image that overflows is no execution, and `check.py` refuses the claim |
| `refuse` | compiled for `cortex-m0` and required to fail with exactly these diagnostic codes | `codes`, and a `reason` unless the only code is L0015 |
| `restriction` | built as an `execute` row is, at none/off, and required to stop where `stops` says (D986) | `stops`, one of `defect`, `c-options`, `c-headers`, `c-source`, `link` or `oracle`, and a `reason` |

An `execute` row may also carry `"lanes": {"mps2-an500": {"mode":
"restriction", "reason": ...}}`, a corpus lane's own disposition of it
(D619), which may name either lane. The lane still runs the program and
requires it to fail, so a restriction that no longer holds fails the lane,
naming the row. No row has one now: the three 64-bit-sized `r420-` fixtures
that had one run as 32-bit counterparts instead. A `refuse` row may carry `"lanes":
{"mps2-an505": {"mode": "refuse", "codes": [...], "reason": ...}}`, the
codes that lane's level and map refuse it with where they differ from the
reference's. It may instead carry `"lanes": {"mps2-an500": {"mode":
"execute", "reason": ...}}` where the lane's description gives the program
what the reference lacks: the lane then builds and runs it at every
profile and holds it to its oracle, as it does an `execute` row.
A `lanes` entry may also give an `execute` or `restriction` row `"mode":
"refuse"` and the codes that lane's target refuses it with: the RV32 lanes
refuse every row that reaches the C surface, since RV32's ilp32 C ABI is
not enabled (D920), with L0346, or L0015 for the C aliases module.
`runtime/assembly-float-square-root` has one: its float operands are L0304
on the reference and the AN505's map, which have no float unit, and the
M7's FPv5-D16 holds them (D630). A lane run whose refusal differs names the
entry to write.

An `execute` row may instead carry `"lanes": {"sifive-e": {"mode":
"limit", "reason": ...}}`, a lane's own capacity limit (D698): on that
lane a profile whose image overflows the map is recorded with its sizes,
as `profile_limit` records one on the reference, and so is one whose stack
the harness's watchpoint stopped past the reservation, with the routine
that overran it; every other profile runs and must pass, and a lane run in
which every profile fits fails, naming the stale entry. The RV32 lanes
carry these where RV32's text or frames outgrow the reference's 32 KiB and
4 KiB and Thumb's do not, each reason giving the measured overflow.

A `restriction` row is a fixture the corpus cannot run for a reason no
diagnostic names, and the corpus shows that reason is still the one
(D986). It builds the fixture as it would execute it and stops at the
first stage that fails, in this order:

| `stops` | The stage that stopped it, and what the corpus records |
|---|---|
| `defect` | refine itself fails with an internal compiler defect; its line |
| `c-options` | the pinned GCC refuses an option of the fixture's `c-args`, such as `-pthread`; the options |
| `c-headers` | a C source includes a header no freestanding C has, the C library's: every header `-M -MG` lists that no include directory holds |
| `c-source` | a C source does not compile for the target, an `#error` or another architecture's assembly; its first error |
| `link` | the harness link names a routine or datum nothing defines, a C library's or one the fixture defines for other targets only; the symbols |
| `oracle` | it builds and links, and its oracle needs what firmware cannot give: `stdin:`, `run_args:`, `run_files:` or `run_expect:` |

The stage reached must be the row's `stops`, and the failure says which
one it reached and what to write. One that refine refuses is no
restriction: the failure names its codes and the `refuse` row to write.
One that builds, links and needs nothing hosted is a stale restriction,
and the failure says to make it `execute`. What stopped it is printed on
its corpus line and kept in its `result.json` as `stopped_by`, read from
the build rather than written in the row, so the reason says why rather
than which header or symbol. `stops: defect` is the one stop a fixed
compiler clears, and no row holds it now: the two `abi/c-function-from-*`
rows held it until refine's Cortex-M emission could make a C function
value from an address, and they execute.

Firmware gives a program no standard input, arguments, files beside it or
output, so a fixture whose metadata names `stdin:`, `run_args:`,
`run_files:` or `run_expect:` cannot be `execute`. The inventory refuses
every such row while it is read, before anything builds, naming what each
fixture asks for and the two ways out: give the fixture a status oracle,
or write a `refuse` or `restriction` row. A counterpart cannot help, since
the original's metadata is what is read.

A refusal whose only code is L0015, an import outside the target's
namespace scope (D267), explains itself: the corpus reads the refused
modules from the diagnostics, records them as `refused_imports` and prints
them on the fixture's line, and the reason it records names them. The
row's `reason`, if it has one, says only why firmware has no such thing or
what runs instead, and may not name a refused module, which the corpus
refuses, so renaming or splitting a module leaves no reason stale.
A refusal its row does not record names refine's first diagnostic and the
codes the row would need, and a compilation that fails, the profile
derivation's among them, names its first diagnostic, so a compiler with no
library beside it says so rather than that every refusal changed.
`python3 scripts/add_fixture.py CLASS/NAME` writes a new fixture's row
from its Cortex-M0 compilation, and `check.py` names a fixture with no row
and that command.

A fixture with a `trap_report:` keeps an `execute` row and does
not name `cortex-m0`: firmware keeps D232's bare trap and writes no report
(D361), so the corpus runs it to its trap and checks no line, which is less
than the fixture's oracle; `runtime/computed-array-index-traps` is one.
`check.py` refuses such a fixture that names `cortex-m0`, naming this rule.

Every program links with the constrained reference's own derived linker
script (D545), the one refine writes for a firmware build of a program that
imports no description, and its limits are that build's report: `FLASH used
of 32768`, the text region, and `RAM used of 12288`, the data region less
the 4 KiB stack it holds. The corpus derives each described profile once,
under `profiles/DEVICE` in its output, from a firmware build of a program
that selects it and places nothing, and holds the facts to
[`descriptions.json`](descriptions.json). Every program's line gives its
verdict, its image against those limits with the sections inside each, and
its three largest routines, `largest routines every_kind 2940, ...`. For an
image that overflowed it also says how far over the region the image is,
which the corpus measures by relinking the same objects, never run, against
a copy of the script with enlarged text and data regions and no assertions.
Each program's `result.json` under the output gives every
routine's size, `image.routines`, read with the pinned `nm` from the image
that ran or from the measured one, so where an overflowing image's bytes go
is read from the corpus rather than from tools run by hand. A
profile limit no profile meets any more fails an unfiltered run, naming the
fixture, its largest image, and the row to change: remove `profile_limit`
and `reason`, and add `cortex-m0` to the fixture's `targets:`. An overflow
in a row with no limit fails naming its sizes and the same row.

Each limited verdict is then linked again for every other described
Cortex-M device, RP2040, RP2350 and the STM32H753, with that device's
derived script and a harness start assembled for its vector table and boot
prefix, under `DEVICE/` in the program's output, and held to its build
report's limits and stack; nothing runs there, since QEMU has no such chip. The corpus
prints, for each device, how many limited verdicts still exceed it, and
records each program's verdict under `profiles` in its result. A program
that fits the reference fits every described device, whose flash past its
vector table and boot prefix, static RAM and stack are each no smaller,
which the corpus checks rather than assumes; an image past the harness's
8 MiB materialization guard is past every region of each.

`--profile` takes `none-off` or `none/off`, as the corpus line prints it.
A filtered run judges no limit stale, because the profile that still
overflows may be one it did not run, and says `FILTERED` last.

`--lane mps2-an505` or `--lane mps2-an500` runs every row alone on that
lane, at its level and on its map: each `execute` row at every profile,
each `refuse` row compiled there to its codes and each `restriction`
built there to its stop, so no fixture is left without a verdict. It judges no limit
stale, which is the default run's to judge, and links no limited verdict
again for a device. Every image a Thumb-2 level ran, on a lane or for a
fixture's `levels:`, is required to call neither `__aeabi_lmul` nor a
32-bit divide helper.

`--program PATH` runs a program of your own, a `.ldn` file or a module
directory, with `--root DIR` for the roots it imports from, at the corpus's
four profiles, or the `--profile`s named, on the constrained reference,
and prints what each returned, or where it trapped, with its image against
the map and the stack its run was seen to use; no oracle is held, so a
measured value comes back as a value:

```sh
python3 environments/cortex-m/backend_corpus.py --refine PATH_TO_REFINE \
  --output NEW_DIRECTORY --profile none-off \
  --program compiler/tests/fixtures/runtime/add-exits-with-its-sum/main.ldn
cortex program: main.ldn none/off returned 42 (r12 0): FLASH 668 of 32768 (.isr_vector 192, .text 476); RAM 20 of 12288 (.bss 20); stack 40 of 4096 observed; largest routines main 286
```

`stack N of M observed` is the distance from the stack top to the lowest
word of the M-byte reservation the run changed, read from the session's
paint, and each executed corpus image's line and result carry it too. It
is what this run used, not a bound, and a stack the program made for
itself, a fibre's, is not the painted one. Repeat `--program` to run
several programs in one invocation; two that share a file name are told
apart by their directories. `--c-source FILE`, repeated, gives one
program's C peers, built by the corpus's C contract (D985) with the
program's directory on the include path and linked with it, so a C peer
can be tried without a fixture or an inventory row. `--level` takes the
corpus's names, which say a lane's float unit: `armv7e-m+fpv5-d16` here is
`refine compile --level=armv7e-m`, and the others are refine's own.

A program that traps says `trapped: HardFault at` the faulting routine and
line, and whether it was the UDF #1 a check emits; one that does not fit
says by how much, as a corpus line does; a compile failure gives the
compiler's first diagnostic; and a stack overrun names its routine. Each
profile's `observed.json` holds the status, r12 and the stop. The run
fails only when a profile could not be built or run.

A corpus fixture or a `--program` starts where a hosted program does, at
`public main: () -> (code: i32)`, the result's name included: the harness
start, `probes/backend-start.S` here and `probes/rv32-start.S` on the RV32
lanes, calls `main` and reads `code`. The corpus compiles with
`--emit=asm` and no `--firmware-entry`, and refine then exports a
`public main` of exactly that signature as the global `main` and says
nothing of any other: `public main: () -> (status: i32)` is emitted as a
routine local to the file, and a program with no `main` at all compiles
too. Either is met at the harness link, as ``undefined reference to
`main'``, rather than as the L0502 a hosted target gives (`a hosted
program needs public main: () -> (code: i32)`), or the one `--emit=exe`
gives on firmware, which asks for `--firmware-entry=NAME`. When that link
names `main`, compare the program's `main` with the signature above. The
Xtensa runner calls `main()` from a Landin source wrapper instead, so
there a missing `main` is refine's refusal of the wrapper.

`backend-start.S` is small external test support: the vector table,
bytewise initialized-data and RAM-code copying, BSS clearing, a stack
watermark and result/fault observation. It supplies what the derived
script places and reads, assembled with the profile's table length and
boot prefix: `.boot2` for RP2040's second stage, `.isr_vector`, its entry
`_landin_firmware_reset`, and the `_landin_firmware_*` symbols the script
defines. Its fault and unexpected entries are `_landin_harness_hardfault`
and `_landin_harness_unexpected`, in the `_landin` prefix the compiler
keeps for its own symbols, so a program's own public `reset` links beside
them. The compiler emits ordinary routines, not reset or interrupt
entries. A single routine requiring more than the stack reservation is
recorded as a profile limit. Returned SP, terminated r11 chain,
callee-saved sentinels and a bottom watermark are asserted. Once the stack
is painted, a write watchpoint covers its reservation's lowest 16 bytes,
so a stack that overruns its reservation stops at the instruction that
reached the guard, and the failure names that routine, its caller, the
stack pointer and how many bytes of which stack, main or process, were in
use. The lowest changed watermark word is retained as an observation,
explicitly not a proved stack bound.
Freestanding evidence below records measured stack/firmware and source debugging.

QEMU uses exactly `microbit`, or a level's MPS2 machine, single-threaded TCG and a loopback-only GDB port.
Each program has a bounded startup wait and a 20-second debugger deadline;
process groups are stopped on failure. Expected traps require HardFault at
the emitted UDF #1, not merely any fault. Normal results use the shared fixture's
exit-byte oracle and require r12 zero. Build reports, sources, compiler identity,
requested runtime helpers, the exact v6-M/nofp archive hash, empty unresolved
symbol set, ELF attributes, map, disassembly and commands are retained.
Assembly expansion is bounded before invoking GNU as, including nested compact
repetitions, so a multi-gigabyte source image cannot materialize in the harness.

Independent controls are kept separate:

| Evidence | What actually executes |
|---|---|
| `backend-abi.ldn` with `backend-abi.S` | Generated entries called by literal assembly ABI oracles: double-word register gap/stack tail, caller-owned multiple and aggregate results, aliased value/inout transport, separate failure status, indirect Thumb address and runtime helpers |
| Frame stepping | GDB observes the old r11 until both record words exist, then the published record; checks nested and leaf links, return addresses and aligned SP |
| `backend-veneer.ld` | The generated leaf is copied to SRAM by the external harness, forcing a real GNU Thumb call veneer over the flash/RAM gap; frame and result assertions remain identical |
| `backend-boundaries.ldn` | Generated accesses across frame/immediate boundaries through a 2304-byte array, nontrivial literals and a long conditional transfer |
| `backend-instructions.S` | Independent maximum literal/branch/conditional encodings execute; separate one-past-limit and forbidden high-register/Thumb-2/FPU/exclusive forms must be rejected by GNU as |
| `backend-words.ldn`, signed/unsigned multiply trap controls | Literal multiword product/division/remainder boundaries, including signed minimum and maximum unsigned product, plus checked overflow reaching UDF #1 |
| `backend-symbols.ldn` | Source helper-name collisions, assembly register-like names and direct/indirect code-pointer identity |
| `backend-byte.ldn` | Five exact byte transactions, independently expected as `r8:18:a5;r8:18:00;w8:19:41;w8:1a:02;r8:1a:f1`; no widened/destructive extra read or hidden write-only read |
| `backend-memory.ldn` | Generated D227 8/16/32-bit atomic loads/stores, volatile operations and barriers, with literal values independent of selection |
| `packed-cortex.ldn` and `packed-cortex-hole.ldn` | Actual generated M0 instructions drive the EncodingPeripheral model. The unchanged literal 16-event trace pins halfword/word widths, counts, destructive reads, one-clears and reserved policies. The hole path performs exactly one destructive read before trapping. |
| `backend-dma.ldn` | Generated packed config/count/status operations publish an ordinary slice to PrototypePeripheral; four externally supplied bytes precede completion. A half-complete observation does not permit return. After completion and a device barrier, ordinary reads sum the bytes to 174. Count accesses are exactly one halfword write and one halfword read, with no word count access. |

ABI, memory, frame/boundary and all four peripheral controls run all six
profiles. The standalone encoding control remains independent assembly.
PrototypePeripheral's count-width telemetry leaves its earlier C control and
interrupt behavior intact. The hosted Landin packed-image transport remains
separately identified and required.

For focused development on the supported native Linux host:

```sh
python3 environments/cortex-m/backend_corpus.py --refine PATH_TO_REFINE --output NEW_DIRECTORY --case runtime/r640-packed-hole --profile speed-all
python3 environments/cortex-m/backend_controls.py --refine PATH_TO_REFINE --output NEW_DIRECTORY
python3 environments/cortex-m/backend_peripheral.py --refine PATH_TO_REFINE --output NEW_DIRECTORY --all-profiles
```

Filtered commands are development feedback. The current `cortex-m-corpus` gate job
runs `run.py --part=corpus` with the built compiler. Its mandatory `backend_acceptance.py`
lane executes the complete compiler-generated corpus and controls under the
pinned tools and records their results in `backend/result.json`. The
[target guide](../../docs/targets.md#cortex-m-assembly-implementation) records instruction, allocation, ABI, runtime-helper and memory decisions.
Language startup/linking/sections/interrupt/naked/inline-assembly surfaces,
the freestanding core and `noreturn`, the checked-in device fixtures and the
complete driver each have their own lane below; `refine svd` writes the
device modules, and package acquisition stays with the companion tool. No
scheduler, interrupt-masking abstraction, C source expansion or new DMA
ownership model is introduced.

### C peers on Cortex-M

An `abi/` fixture whose row says `execute` runs in the corpus as a runtime
fixture does, with its C (D985). Each `c-sources` entry is compiled by the
pinned `arm-eabi-gcc` with the level's flags, those the harness start is
assembled with: `-mcpu=cortex-m0` on the micro:bit, `-march=armv7-m` on
the AN385 and `-march=armv8-m.main` on the AN505, all `-mfloat-abi=soft`,
and `-mcpu=cortex-m7 -mfloat-abi=hard -mfpu=fpv5-d16` on the AN500, with
`-mthumb -mabi=aapcs -ffreestanding -fno-builtin -nostdlib -O1 -Wall
-Wextra -Werror`, then `-std=c11 -nostdinc -fno-short-enums`, GCC's own
include directory for its freestanding headers, the fixture's directory,
each `c-inputs` directory and the fixture's `c-args`. GCC's bare-metal
default is short enums, Clang's and Cortex-M's C boundaries int-sized
ones, so the corpus passes `-fno-short-enums` itself and a fixture need
not; `abi.py` shows that a short-enum build of the generated CMSIS
adapters is refused by their own assertion of `IRQn_Type`'s size. No
newlib header is reachable and no C library is linked: a peer that needs
one stops at its headers or its link, and its row is a restriction that
says so. The four routines GCC requires of any freestanding program,
`memcpy`, `memmove`, `memset` and `memcmp`, are `probes/c-runtime.c`,
compiled the same way, each in its own section, and linked only where
called. `c-inputs` names pinned input directories, `rp2040-cmsis` for
example, whose headers the corpus fetches by hash with
`scripts/fetch_inputs.py` before compiling.

Before linking, every object's `readelf -A` is read and each must pass
floats as the lane does, `Tag_ABI_VFP_args: VFP registers` on the AN500 and
not on the others, apart from GNU ld's own check, and none may declare
`Tag_ABI_enum_size: small`, which the linker only warns of. Every other
Arm C compilation of the lanes, the probes', `firmware.py`'s and
`memory.py`'s, passes `-fno-short-enums` too. `abi/cortex-c-peer` is
also the wrong-convention control, at none/off on every lane: its C is
compiled for the other variant, an M4F's hard float on a soft lane and the
M7's `-mfloat-abi=softfp` on the AN500, and that assertion must refuse it,
and GNU ld must refuse the link with `uses VFP register arguments` with
the peer before the program and after it; built for the lane's own variant
with `-fshort-enums`, the assertion must refuse it too. Each result records
all three under `convention_control`.

A fixture takes one of two routes to its image. The harness route, every
`execute` ABI row's at every profile: refine writes assembly and the
harness links it with its start, the C objects and libgcc, and the status
comes back through `backend_done`. The route a user takes, refine's own
firmware link (D923), is taken by `abi/cortex-c-peer` at none/off on every
lane as well: its C objects are archived as `libpeer.a` and the C runtime's
as `libcruntime.a`, the program is compiled with one more entry-module file
that names both with `linker.library` and has a firmware entry storing what
the program's checks return, and `refine compile --emit=exe -L DIR` links
it; compiler-owned startup runs it, the map must show `libpeer.a`'s member,
and GDB holds the stored status to the fixture's at
`_landin_firmware_returned`. Its result records the route as `refine_link`.

The consumers that execute:

| Fixture | What it holds | Lanes |
|---|---|---|
| `abi/cortex-c-peer` | a hand-written peer and the program call each other with every scalar width, 64-bit values in r2:r3 with r1 skipped and on the stack at eight, floats in core registers or the VFP bank, records of 3, 4, 16 and 32 bytes by value both ways, split between r2-r3 and the stack, and by address, a C function pointer to a program routine, the program's datum by its link name and a C global cleared and one initialised by start-up, an unsigned plain `char`, a 32-bit `long` and an int-sized enum; every value is checked where it arrives, each check its own status | every lane, both routes |
| `abi/cortex-cmsis-bindings` | the generated RP2040 CMSIS adapters: NVIC enable, disable, pending and priority and `SysTick_Config`, each read back from the NVIC and SysTick registers with interrupts masked, since the harness's table has no handler: a pending interrupt stays pending, ARMv6-M's two priority bits keep 6 as 2 and read 0xff as 0xc0, a disabled interrupt keeps its priority, and a reload past 24 bits is refused with nothing written | the micro:bit; the AN505's M33 keeps more priority bits and the AN500's unit meets the header's `#error`, each a lane restriction |
| `abi/cortex-vfp-bindings` | the generated STM32H753 adapters and its own `landin-vfp.h`: floats and doubles both ways, back-filled singles, a seventeenth single slot on the stack, a homogeneous aggregate of doubles by value and returned, a record by address both ways through pointers typed to it, `SCB_GetFPUType` 2 and an NVIC interrupt QEMU's AN500 implements | the AN500 only; the reference refuses it with L0324 (D936) |
| `abi/c-packed-records`, `abi/link-symbol-exports`, `abi/public-routine-is-local`, `abi/r440-native-dollar-link`, `abi/r490-distinct-c-roundtrip`, `abi/c-function-from-address`, `abi/c-function-from-zero-address-traps` | shared ABI fixtures whose peers need nothing hosted | every lane |

Of the 65 rows that were restrictions before D986, 8 execute, the five
above, the two `abi/c-function-from-*` rows and
`runtime/rv64-indexed-address`; 36 are refusals with their codes, 27 of
them L0015 for hosted imports, 5 L0346 for variadic C calls, and L0300,
L0324, L0344 and L0347 once each; and 21 stay restrictions, each with its
stop: 16 `c-headers`, peers that print their oracle through stdio, assert,
or fork a child, 2 `c-options`, POSIX threads, 2 `c-source`, an RV64 or
x86-64 observer, and 1 `oracle`, an empty `run_expect`. The 8 `link` restrictions are runtime fixtures that call the C
library. Measured at none/off on the micro:bit's
32 KiB/16 KiB reference, `abi/cortex-c-peer`'s image is 15,204 bytes of
flash, 13,772 at the other profiles, with 48 bytes of static RAM and at
most 1,128 bytes of its 4 KiB stack touched, of which its C is 1,248 bytes
and the C runtime 26, `memcpy` alone; linked by refine it is 13,684 bytes.
`abi/cortex-cmsis-bindings` is 7,656 bytes, 6,368 optimized, 20 of RAM and
452 of stack at most, and its nine generated adapters 460 bytes.

## RV32 lanes

Two lanes run the whole corpus on Espressif's QEMU, one machine for each
RV32 level (D695): `esp32c3` at `rv32imc`, the ESP32-C3's level, and
`sifive-e` at `rv32imac` on QEMU's SiFive E31. `backend_corpus.py --lane
esp32c3` or `--lane sifive-e` runs the inventory there as it does on the
Arm lanes, every row with its own disposition and a row's `lanes` entry
where its verdict differs on that lane; `run.py`'s lanes of the same names
are those runs, followed by the lane's atomics probes.

| lane | machine and core | map | level |
|---|---|---|---|
| `esp32c3` | `esp32c3`, its `espressif` core with `a=false,zawrs=false,f=false,d=false,zfa=false` | `lanes/descriptions/esp32c3`: 32 KiB of SRAM1 as instruction memory at `0x4038_0000`, 16 KiB of its data alias at `0x3FC8_8000` with the stack in the top 4 KiB, a 32-slot table at `0x4038_0100`, the C3's 256-byte mtvec alignment | `rv32imc` |
| `sifive-e` | `sifive_e`, an E31, rv32imac | the RV32 reference, `platform/riscv/reference`, which a program reaching no description is given: 32 KiB of flash at `0x2040_0000` and the 16 KiB DTIM at `0x8000_0000` | `rv32imac` |

Each image is loaded with `-kernel`. On `sifive_e` the mask ROM jumps to
`0x2040_0000`; on `esp32c3` QEMU starts the ELF at its entry without the
ROM, so booting through the ROM from refine's `OUT.bin` is the firmware
programs', not the corpus's. Both machines take the same harness:
`probes/rv32-start.S` supplies what refine's RV32 firmware script places,
the entry word `_landin_firmware_entry` first at the text origin jumping
to `_landin_firmware_reset`, and the vectored trap table in `.isr_vector`
at the profile's vector address, which the build report gives. The reset
clears `mstatus.MIE`, points `mtvec` at the table in vectored mode, copies
data, clears BSS, paints the stack, and paints s1-s11, gp and tp before it
calls `main`; s0 is zero, the end of a frame chain. Slot 0 records an
exception's mcause, mepc, mtval and sp, and any interrupt reaching its own
slot loops there. The GDB session is the Arm one's: a hardware write
watchpoint on the stack's lowest 16 bytes, then `backend_done` with the
status byte, sp at the top and every painted register as it was, or
`backend_fault_done` with mcause 2 at an `unimp`, compressed or not, for a
trap.

Every RV32 image is held to its level before it runs: an ilp32 soft-float
ELF whose `Tag_RISCV_arch` names no extension beyond the level's, and at
`rv32imc` no AMO and no LR/SC anywhere in the linked disassembly, libgcc's
included, assembled with `-march=rv32imc_zicsr_zifencei`. The `esp32c3`
machine's own core has A, F and D, so the lane removes them with `-cpu`:
an A instruction there is an illegal instruction, as on the C3 (D696).

`rv32-controls` needs no compiler. It links hand-written mains,
`probes/rv32-controls.S`, with the harness by a script written from each
lane's recorded profile, and runs them on both machines: a return through a
frame, a trap at `unimp`, a stack overrun the watchpoint must stop, on
`sifive-e` an executed `amoadd.w`, `amoswap.w` and LR/SC loop, and on
`esp32c3` the same A program, which the image check must refuse and the
core must trap at its first AMO. Before them its `shared-debugger` control
debugs the `cpu` probe, the `return` control and the `cpu` probe again
through one GDB (see [Debugger sessions share a GDB per
worker](#debugger-sessions-share-a-gdb-per-worker)). The two corpus lanes need it, so a
harness that cannot tell these apart stops them before any corpus program.

The atomics probes follow each corpus (D697). On `sifive-e`,
`probes/rv32-read-modify-write.ldn`, the exchanges, adds and
compare-exchanges of `runtime/atomic-read-modify-write` without its u64
cell, executes and returns 42, and its image must hold an AMO and an LR/SC
pair. On `esp32c3` refine must refuse that probe with L0344 alone at every
exchange, add and compare-exchange; on both, `probes/rv32-wide-atomic.ldn`'s
u64 cell is refused where it is declared, since no RV32 level has an
eight-byte atomic access.

The directory is still named `cortex-m` and holds the RV32 lanes beside
the Arm ones; the register records that rather than a rename.

## Compiler-owned firmware

`firmware.py` is mandatory in `run.py`. It writes records under the run's
`firmware` output directory, separate from every earlier lane. Its
`float-unit` case builds compiler-owned firmware for the M7 lane's
description and runs it on `mps2-an500`: reset has granted CP10 and CP11
before `start`, a SysTick pended in the middle of an f64 computation is
taken with `0xffffffe9` and the extended frame reserved lazily, the
handler's float instruction fills it, the return restores the interrupted
d0, and the computation ends with its IEEE value (D618); a soft-float C
object linked into the image is refused for its VFP arguments (D617). Its
`float-debug` case is a debugger's view of the same unit by unwinding: on
an image built with `--debug=lines`, GDB reads a routine's arguments at
its first instruction where AAPCS-VFP banks them, r0, d0, s2 and d2;
reads d8-d15 in the caller's frame as the session set them, through the
CFI of a framed routine whose assembly block has by then written d8 and
d15 (D617); and, at a SysTick taken with the extended frame, selects the
interrupted context above its 26 words and unwinds the three routines and
reset from there, reading the caller's d8-d15 again. Ordinary unwinding
still stops at interrupt entry, as it does for the `leaf` control. Its
`cache-sequence` case links a program through `platform/cortex_m/l1` on the
lane description `lanes/descriptions/mps2_an500_cached`, the an500's map
with `compiler.cache`, and runs it under QEMU's trace of the System Control
Space's writes: the linked reset's steps are D973's, each by-address
operation's stores lie between two DSBs with ISB after them, every SCB
write of reset, the program and the return arrives in that order with each
maintenance write the line address its range says, a refused range writes
none, and GDB reads the three refusals and CCR clear at the return (D977).
QEMU keeps neither enable bit and reads CCSIDR as zero, so this is the
operations' sequence alone; what a cache does is the STM32H753 board's
(D975). Its `example` case is the firmware program
[the examples page](../../examples.md#firmware-for-a-microcontroller)
publishes, the fixture `end-to-end/example-firmware-serial`: it builds the
program with the page's command, runs it on `microbit` with the serial
port sent to a file, and holds the bytes to the fixture's `serial.txt`,
the line the page says the program prints. It invokes the
compiler with
`--target=cortex-m0 --firmware-entry=start --emit=exe` and the pinned Arm GCC
path. The compiler generates reset, vectors and the linker script; `backend-start.S`
supplies none of these semantics. The older
533-fixture corpus, 72 generated controls and independent controls remain
mandatory and retain their own startup and applicability records.

The fixed image remains 32 KiB flash, 16 KiB RAM and a 4 KiB stack reservation.
D229/[1990] specify the source/request, convention, section and assembly
contracts. Initialized data and `.ramtext.*` have separate flash load and RAM
execution addresses; compiler reset copies both and clears BSS. Immutable
images stay in flash. The compiler retains `.s`, `.o`, `.ld`, `.map` and ELF;
the probe also retains readelf sections/program headers/relocations/attributes,
disassembly, symbols, independently decoded load extents, tool identities,
commands, timeouts, debugger assertions and device traces. Empty undefined
symbols and explicit runtime-archive identity supplement map-based closure
checks. The archive must be the pinned `thumb/v6-m/nofp/libgcc.a`.

The six optimization/specialization profiles each exercise:

- Two fresh builds, each cold-booted and reset again after poisoning RAM.
  Assertions observe initial SP/reset Thumb identity, zero reserved vectors,
  copied data, cleared BSS, source entry and the entry-return HardFault trap.
- Generated SVC, ordinary helper and higher-priority nested IRQ0, checking
  hardware frames, EXC_RETURN, every preserved register, flags, r11 records,
  eight-byte stack alignment and source results. A painted 4 KiB stack retains
  an untouched lower guard; its observed write extent is evidence for this
  small execution, never a whole-program bound.
- A fibre on a prepared stack (D450, D460) taking IRQ0. The handler's first
  instruction sees EXC_RETURN `0xfffffffd` and MSP exactly where `start`
  left it when it switched away, the eight-word hardware frame at PSP inside
  the fibre's backing with the fibre's pc, and the painted backing below that
  frame untouched through the handler and a call it makes, whose frames
  stand below on MSP (D461). The fibre resumes on PSP with every stacked
  register, switches back, and `start` returns on MSP with CONTROL's SPSEL
  clear. A second build with line information is stepped through both
  switches an instruction at a time: GDB's walk names the leaving context's
  frames until CONTROL selects the resumed stack and the resumed one's
  after, and a prepared stack's walk ends at its start routine.
- Naked source entry selecting PSP, naked SVC returning through EXC_RETURN,
  and a specialized generic opaque-assembly memory write with live values.
  A separate naked-fallthrough image reaches its appended trap without a frame.
- Copied RAM code and RAM handler, flash/RAM veneers, integer libgcc helpers
  and private success/failure transport through checked ordinary calls.
- Four synthetic-device runs: DMA IRQ0 half/completion notifications, packed register
  images, invalid-encoding HardFault and byte transactions. The latter three
  execute ordinary generated programs inside a generated SVC handler. Expected
  values and exact access traces remain independent device-side observations.
  DMA continues with PRIMASK set; half notification is not completion; only
  observed completion plus the explicit boundary precedes ordinary slice reads.

This adds 49 QEMU sessions (48 generated, one independent C/assembly control)
and 24 generated device runs. The independent control establishes PSP/MSP,
four-byte interrupted SP with hardware alignment padding, nested exception
returns and C callee saves independently of Landin emission. Twelve retained
failure programs cover flash overflow, stack overlap, the image budget's
giant image, flash and RAM (D537), missing symbol, invalid instruction
encoding, later-core instruction, wrong vector placement, owned reset slot,
invalid entry and reserved symbol. The flash overflow is an image the budget
admits and the linker refuses once the vectors and reset code are added, so
the linker stays the map's authority. A `compact-images` case runs
`scripts/image_bounds.py` with this lane's assembler: compact shapes at two
sizes keep the assembly and the assembler's memory to the source's size and
the object to the image (D536), and the giant image is refused before any tool
runs.
Source unit controls additionally refuse incompatible conventions/calls,
invalid naked bodies, duplicate directives, unavailable slots and hosted use.

Equivalent inputs in fresh directories must produce byte-identical ELF,
object, assembly, script and map for every generated scenario/profile. ELF
identity includes sections and relocations. Log paths, TCP debugger ports,
command durations and host/compiler identity records intentionally vary and
are retained as execution metadata, not image bytes.
`run.py` writes these records under its `firmware` output directory.

For a focused development run on the supported Linux host:

```sh
python3 environments/cortex-m/firmware.py --refine PATH_TO_REFINE --output NEW_DIRECTORY --all-profiles
python3 environments/cortex-m/firmware.py --refine PATH_TO_REFINE --output NEW_DIRECTORY --all-profiles --case fibre
```

`--case`, repeated, runs only the cases named: `cpu-levels`, `refusals`,
`independent-c-assembly`, `compact-images`, `float-unit`, `float-debug`,
`cache-sequence` and `example` once, and `boot`, the
cold-booted image built twice, `interrupts`, `fibre`, `dma`, `machine`,
`veneers`, `fallthrough`, `images`, `hole` and `byte` at each profile. A
selection is marked `FILTERED` in its last line and its `result.json`.

The contract was checked against Arm's [ARMv6-M Architecture Reference Manual DDI0419E](https://documentation-service.arm.com/static/5f8ff05ef86e16515cdbf826),
[Cortex-M0 Devices Generic User Guide](https://documentation-service.arm.com/static/5ea6ce5e9931941038def8c1),
[AAPCS32 and AAELF32 2025Q4](https://github.com/ARM-software/abi-aa/releases/tag/2025Q4),
the selected-device [nRF51 reference manual](https://docs-be.nordicsemi.com/bundle/nRF51-Series/raw/resource/enus/nRF51_RM_v3.0.1.pdf),
and GNU binutils' [section flags](https://sourceware.org/binutils/docs/as/Section.html),
[retention](https://sourceware.org/binutils/docs/ld/Input-Section-Keep.html),
[load addresses](https://sourceware.org/binutils/docs/ld/Output-Section-LMA.html)
and [Arm veneers](https://sourceware.org/binutils/docs/ld/ARM.html).
Executable controls establish behavior on the pinned microbit/ARMv6-M profile;
they do not generalize to another core, board, real peripheral or timing model.
Core/CPU-library packaging and `noreturn`, the generated fixtures, the complete
driver, source debugging and complete measured stack/firmware evidence have
their own lanes below.

## Freestanding library consumers

`freestanding.py` compiles rooted ordinary modules through the same generated
reset/vector/linker path. It is mandatory after `firmware.py` in `run.py`, with
its own `freestanding` output directory. The old 533-fixture
backend corpus and the firmware lane's 49 QEMU/24 device sessions and 300 comparisons are
unchanged. The shared inventory adds two explicitly restricted hosted C peers
for D231/D232; neither replaces an inherited case. The declared additional lane
has eleven consumers at six profiles: 198 QEMU sessions, six device runs and 336
fresh-directory comparisons. Panic consumers additionally compare optional
source-map bytes. A focused run is development feedback, not a complete gate run.

| Consumer | Independent observation |
|---|---|
| `core-cpu.ldn` | Poisoned initialized data/BSS are repaired by compiler reset; `platform/cortex_m` runs on D248's `general` operands; scalar assembly preserves live values, generic/discarded operations execute; a multi-output block destructures, a block holding every one of r0-r7 stores them all, `general` passes over a register the text writes and a signed byte input is extended; PRIMASK restoration handles enabled/disabled entry, nesting and deferred early return. Masked pending IRQ wakes WFI before handler entry; exception return restores volatile/callee registers, flags, stack alignment, r11 and private status. |
| Default panic derivative | The same source with the hook removed traps on arithmetic, violated nonreturning return and firmware entry return. It retains neither a panic latch nor a source map; the independent hardware exception frame points at UDF. |
| `core-panic.ldn` | Seventeen independently expected kind/site paths per profile, including conversion/bounds/arithmetic, alignment, packed membership, nonnull pointer construction, reserved bits, UTF-8 decoding, recursive panic, forced nonreturning-callee return, normal firmware-entry return and a real NVIC handler. Poisoned data/BSS, no later actions, stack bounds and off-target source lookup are checked. |
| `core-noreturn.ldn` | Six cold boots select direct, generic, static/erased evidence, deferred and recovery paths; independent memory assertions check completed stores, skipped later actions/cleanup and retained kept data. The expected frame-chain depth and each previous-r11/incoming-LR record are checked at every selected nonreturning path. Nonreturning entry and 200–376-byte observed stack writes execute in the fixed profile. |
| `core-pool.ldn` | Misaligned caller backing yields aligned slots; zero-size allocation consumes one slot, an oversize request preserves state, exact free permits address reuse, exhaustion preserves live values and valid frees restore zero live slots. Raw writes initialize bytes before reading them. |
| `core-zero.ldn` | Zero-sized vector elements retain maximum u32 `usize` capacity, one logical element and zero arena byte consumption; release follows the existing provider contract. |
| `core-vec.ldn` | Successful reserve/push followed by injected exhaustion preserves capacity, length and values. Byte-count overflow refuses before allocation and release remains idempotent. |
| Inherited `core-mem-allocators`, `core-mem-arena-boundaries`, `core-mem-raw-storage` | Original status-42 oracles run from compiler startup; only the already-reviewed Cortex raw-storage counterpart supplies its 32-bit expected pointer extent. The complete original corpus inventory is checked before using these sources. |
| Library-derived DMA | The unchanged firmware-lane peripheral oracle checks independent register state, exact halfword count accesses, handler delivery, half/completion states, externally written ordinary storage and subsequent ordinary reads. Only CPU/barrier calls are replaced with the new library surface. |

The runner copies only its declared `core/mem`, `core/vec`, `core/pool` and
`platform/cortex_m`/`core/panic` import closure. Maps must list the generated object and pinned
`thumb/v6-m/nofp/libgcc.a`, with optional GNU linker stubs and no other LOAD
input. Closure records include source hashes, selected archive members, all
symbols and decoded image extents. Undefined symbols and hosted runtime names
fail. This permits private compiler/toolchain helpers, not general C source.
Per-command timeouts, process cleanup and independent failure markers use the
existing supervisor unchanged. Standalone failures retain
their logs, artifacts and failed result record.

For development on the supported Linux host:

```sh
python3 environments/cortex-m/freestanding.py --refine PATH_TO_REFINE --output NEW_DIRECTORY --case cpu
python3 environments/cortex-m/freestanding.py --refine PATH_TO_REFINE --output NEW_DIRECTORY --all-profiles
```

`--case` repeats and names a probe: `cpu`, `pool`, `zero`, `vec`,
`noreturn`, `panic`, `panic-default` and `dma`, the inherited
`core-mem-allocators`, `core-mem-arena-boundaries` and
`core-mem-raw-storage`, or a shared module's consumer, `library-shared-NAME` for each `NAME` in its `MODULES`, such as
`library-shared-text`. An unknown case is refused, naming the cases there
are.

PRIMASK/WFI premises follow the official Arm architecture and M0 guides cited
above; argument/result and linker-stub obligations retain the cited AAPCS32,
AAELF32 and GNU contracts. Actual controls run on ARMv6-M. WFI is not a
completion proof and masking does not stop DMA. The selected profile remains
32 KiB flash/16 KiB RAM/4 KiB reserved stack. Stack paint measures observed
writes only. [The core guide](../../core/README.md) documents the public surface;
`ROADMAP.md` owns the successor measurement gates.

## Checked-in generated devices

[The device guide](../../devices/README.md) records pinned RP2040 provenance,
manual corrections, regeneration, public interfaces and unsupported metadata.
`devices.py` follows all inherited probes in `run.py`, retaining its own
`devices` output directory. Five firmware consumers at the six
inherited profiles supply six QEMU sessions, 24 generated device runs and 168
deterministic artifact comparisons; a separate C/assembly control adds one
device run. Seven precise source refusals and independent vendor-header/literal
oracles run without network or companion tooling. The 55 selected registers
are vendor data, not a faithful RP2040 model or a larger execution board.

```sh
python3 environments/cortex-m/devices.py --refine PATH_TO_REFINE --output NEW_DIRECTORY --case images
python3 environments/cortex-m/devices.py --refine PATH_TO_REFINE --output NEW_DIRECTORY --all-profiles
```

Compiler-owned reset/vectors/linker scripts remain distinct from the independent
C/assembly startup. The new synthetic model asserts exact word transaction
traces, FIFO reads, commands and bounded interrupt/DMA handoff. Its feeds and
half notification are explicit premises; no circular-buffer or physical timing
claim follows. Linker closure, stack paint and optional panic maps are retained
with the fixed map and runtime contract. The runner uses unchanged process
cleanup. The complete derived driver, source debugging and full
measurements have their own lanes below.

## Device descriptions

`descriptions.py` follows `devices.py` in `run.py`, in its own
`descriptions` output directory, and runs nothing: RP2040 and RP2350 are
chips, and emulators cover cores. It builds RP2040's description,
`devices/descriptions/rp2040` imported under `--root=devices`, RP2350's at
`--level=armv8-m.main`, the STM32H753's at `--level=armv7e-m`, and the
constrained reference, which a program importing no description is given
(D543), and compares every fact of each linked image and its build report
with [`descriptions.json`](descriptions.json): the device, core, boot kind,
regions and placements, the vector address and length, the stack top, every
reserved vector word, the handler's word, and a datum placed in its
`SCRATCH_X`. Those expectations are recorded from pico-sdk 2.2.0's
`memmap_default.ld`, its flash-region template, its Pico board header, its
`intctrl.h` and its `boot_stage2.ld`, each by URL and SHA-256, and from
[1990]; none is read from the descriptions or the compiler, so a wrong or
absent fact fails. Every record, under `devices` and under `lanes`, names
the `target` it is built for, `cortex-m0` or `rv32`, and each reader selects
its records by that name: the Cortex-M harness and its lanes take the
`cortex-m0` ones, and the RV32 lanes and checks the `rv32` ones, so a record
without a target is refused rather than read as an Arm device. RP2040's
slot 21, `USBCTRL_IRQ`, holds its handler, and
the reference refuses slot 21 as L0347 and links zero there. RP2350's are
recorded from pico-sdk's `memmap_default.ld` for RP2350, `pico2.h` and
`intctrl.h` the same way; its slot 56, PROC0_IRQ_CTI, holds its handler.

RP2350's image block (D637, D638) is the 20 bytes directly after its
68-word vector table at `0x10000000`: the lane requires them inside the
first 4 KiB of flash and equal to the bytes the pinned GCC assembles from
pico-sdk's fetched `embedded_start_block.inc.S` and `picobin.h` with the
end block off, finds no relocation in the object's `.embedded_block`, and
holds the build report's `image_block` to them. It links RP2350's program
with a copy of the derived script, and refuses as L0519, naming clause 1,
a script that moves the block past the first 4 KiB and one that writes
other words in its place.

RP2040's second stage (D587, D588) is the 256 bytes at the start of flash:
the lane recomputes their checksum as pico-sdk's `pad_checksum` does, finds
no relocation in the linked `.boot2` or reaching it in the object refine
wrote, and holds the build report's `boot_stage` to the slot. It then
follows the stage with [`devices/thumb.py`](../../devices/thumb.py) from its
first instruction in the copy the boot ROM makes at `0x20041f00`, entered
with lr zero and again with lr nonzero, and requires its device stores, its
MSP and its branch, VTOR pointed at `0x10000100` and reset entered, or the
return to its caller, to be what pico-sdk's `boot2_generic_03h.S` and
`exit_from_boot2.S` do. Those are read from the fetched files, their
operands evaluated from their own and `ssi.h`'s, `addressmap.h`'s and
`m0plus.h`'s macros, so a wrong constant in the port fails. The lane needs
those inputs fetched (`python3 scripts/fetch_inputs.py`), as the gate's
Cortex-M job does first.

An ESP description's watchdog stage (D684) is followed the same way by
[`devices/rv32.py`](../../devices/rv32.py), the RV32 reading beside
`thumb.py`: from the linked image's entry word to reset, over no memory but
the image's own bytes, with no RAM and no stack, the stage must make
exactly the device accesses its record lists from the chip's manual, the
one word it reads back answered as the record's `reads` gives it. An
instruction outside RV32I, M and the integer part of C, a CSR access among
them, or a load or store outside the 4 KiB blocks the record's own
accesses lie in, is refused.

It then links RP2040's program with a copy of the derived script and with
four scripts each breaking one clause of D546's contract, and a fifth whose
`.boot2` holds what the script writes rather than the sealed stage, each
refused as L0519 naming its clause, and refuses `link(region: "NOWHERE")`
as L0517. A stage padded past its 252 bytes and one loading a symbol's
address are each refused as L0538, naming the size or the relocation,
before anything is linked. Last, a 100,000-byte static image links for
RP2040, inside its 256 KiB RAM, and overflows the reference's: the image
budget (D537) is the selected profile's.

```sh
python3 environments/cortex-m/descriptions.py --refine PATH_TO_REFINE --output NEW_DIRECTORY
```

The lanes that stage their own library, `devices.py`, `driver.py` and
`freestanding.py`, stage `platform/cortex_m/reference` beside the modules
their programs import, since the reference is part of every program that
imports no description. The corpus links every program with the
reference's derived script and links each limited verdict again with RP2040's,
RP2350's and the STM32H753's, reading every limit from the build report of
`refine compile --target=cortex-m0 --emit=linker-script` over a module that
imports the device's description (D589), which writes the script and its
limits with no program to link ([the corpus inventory](#the-corpus-inventory)),
so its capacity verdicts against those three devices are links against
their maps, not measurements from sizes; none runs there. The harness start
supplies, as zeros, the bytes the build report's `boot_prefix` and
`boot_suffix` say each boot kind puts before and after the table, 256
before RP2040's and 20 after RP2350's, since those images are linked and
never booted; `descriptions.json` records the same two figures for each
profile apart from the compiler.

## Complete derived driver

[`compiler/tests/driver/DERIVATION.md`](../../compiler/tests/driver/DERIVATION.md)
is the subordinate declaration/finding map and public driver contract.
`driver.py` runs the complete application and a public-API client through the
compiler-owned firmware path, across the six inherited profiles. QEMU executes
two poisoned resets per linked program, checking data/BSS, vectors, immutable
flash and application RAM-code copying. `DriverPeripheral` in `models.py`,
served by `machine.py` on the same QEMU, executes GPIO, timer, UART, interrupts and ordinary-slice
DMA consumption, loss detection, stop and recovery. Existing models and
C/assembly/hosted transport controls retain their separate identities.

The model uses unchanged generated RP2040 images/accessors at explicit synthetic
bases. Its finite, non-reloading count and EN-clear/BUSY-clear drain protocol
are not RP2040 hardware claims. Masked/coalesced notifications cannot hide
producer progress. More-than-capacity unread data fails with sticky `overrun`
and explicit discard/restart. Device faults require external maintenance; an
eight-poll stop timeout preserves the storage lifetime obligation. The
application executes echo/GPIO commands, periodic partial-data polling, overrun
recovery and observable terminal policy. Detailed premises and limitations are
in the derivation.

The UART's line registers are images (D964). The model refuses an LCR_H
write that latches IBRD 0, or FBRD above 0 at IBRD 65535, or sets BRK or
SPS, and records what the latched images mean at the declared 48 MHz:
rate, data bits, parity and stop bits. `driver.py`'s `pl011`, written from
the RP2040 datasheet's 4.2.7.1 apart from `core/line`, is their oracle.
The protocol client opens eight lines through the public driver, from 46
to 3,000,000 baud with every data width, parity and stop count, each
image and latched line required to be `pl011`'s, and on each reads back
three characters it was fed, a parity frame's with the parity bit above
the data as an STM32's RDR keeps it, 0x17 among them (D965); the refusals of rates 0,
45 and 3,100,000 and of 4 and 9 data bits leave every UART register
unwritten and nothing latched; and the application's exact trace still
writes 26, 3 and 0x70. No bit is sent at any of these rates: this shows
the images the driver writes, never a line's timing, which only the tty
boards' exchange shows (D963).

Evidence under the `run.py` output's `driver` directory retains compiler/tool
identities, source roots, assertions, timeouts, QEMU/GDB scripts, device traces,
startup/linker inputs, ELF/map/assembly/object/disassembly/relocations, private runtime closure
and fresh-build comparisons. NOLOAD BSS has a RAM LMA, checked independently
from ELF headers; the original memory map is unchanged. Stack paint is an
observation, not a worst-case bound. A model refusal or unexpected QEMU
diagnostic fails the lane.

For focused development on the supported Linux host:

```sh
python3 environments/cortex-m/driver.py --refine PATH/TO/refine \
  --output /ABSOLUTE/NEW/EVIDENCE --profile size-auto --case protocol
```

Use `--all-profiles` for this complete lane. The current `cortex-m` gate job
invokes it through `run.py`, preserving every earlier mandatory lane. Source
refusal checks are also safe compiler-host feedback via
`compiler/tests/driver/check_sources.py`.

## Prototype 5's firmware counterpart

[`compiler/tests/counterpart/DERIVATION.md`](../../compiler/tests/counterpart/DERIVATION.md)
maps prototype 5's `firmware/tick`, `firmware/board` and `firmware/app` to
their complete sources. `counterpart.py`, the `counterpart` lane of the
`programs` part, builds the program at every profile against
`lanes/descriptions/microbit`, the nRF51822's 256 KiB of flash and the
reference's 16 KiB of RAM and 4 KiB stack (D1036), since at `size` it takes
about 56 KB, and holds each image's derived profile to `descriptions.json`.
It runs on `machine.py`'s micro:bit with prototype 1's `DriverPeripheral`
as its serial line, the same QEMU the driver lane uses: SysTick's interrupt
is the emulator's own, and every access to the synthetic device stops it for
the harness.

Each scenario boots the image, paints the fibres' backing and the main
stack at `start`, and feeds lines as the run reaches the points the
scenario names: `two-in-flight` feeds `WAIT 200 a` and then `NOW b` once
`a` has begun being answered; `queue-full` five more at once, so the fifth
is refused `busy`; `refusals` a request with no tag, one longer than the
queue keeps and one ended by `\r\n`. The model takes a byte only while the
driver's DMA channel is enabled, so a line is fed between the driver's
reads. A run ends once every line has been answered and 50 ticks pass
with nothing more written, or 3,000 ticks after the first line; a fault
reaching `_landin_firmware_unhandled` is a trap, and no stop within five
seconds of execution a timeout. `judge` then reads the trace
`firmware/trace` recorded and what the device wrote, and fails the run for
any departure from D448's answer that D1035 lists. Each run writes
`trace.json` and `trace.txt`, and `counterpart/traces.txt` gathers them,
which the gate's `cortex-m-programs` job keeps as the
`cortex-m-counterpart-traces` artifact beside `result.json`, with each
image's flash and static RAM and each fibre's painted peak.

A tick is a millisecond of the emulator's clock, and under `machine.py`'s
`-icount shift=0,align=off,sleep=off` that clock reaches the next tick
across each stop the harness makes: in one measured run 205 of 247
consecutive stops were one tick apart and 41 two. An answer that writes
seven bytes, each a status read and a data write, so lasts about fourteen
ticks. The ticks order a trace's events and bound each wait from below;
they do not measure the firmware's own time.

The controls `overlap`, `missing`, `trap` and `timeout` build the same
source with one exact replacement each, which must match it once, and run
`two-in-flight` at the first profile: a second answerer, `b`'s answer
dropped, a take past the queue and SysTick never started. Each passes only
when the run fails for that reason. `test.py`'s `CounterpartOracle` gives
`judge` traces with each failure and one with none.

```sh
python3 environments/cortex-m/counterpart.py --refine PATH_TO_REFINE \
  --output NEW_DIRECTORY --profile size-auto --scenario two-in-flight
```

`--all-profiles` runs every scenario at the six profiles with every
control; `--scenario` and `--control` repeat, and a run that selects any is
`FILTERED`. On NixOS run it under steam-run as [On NixOS](#on-nixos) says.

## Freestanding evidence

The mandatory `run.py` entry invokes `evidence.py` after every inherited lane.
It builds the complete application, protocol client and layout control with
`--target=cortex-m0 --firmware-entry=start --emit=exe --debug=lines` in all six
optimization/specialization profiles. The [Cortex debugging contract](../../docs/targets.md#cortex-source-debugging)
is line/function debugging with ordinary-frame CFI; full variable/type debug
remains refused. QEMU runs source breakpoints, stepping and call-stack
assertions, including imported core/device code, copied RAM code, veneers,
interrupts, generic/specialized allocation, noreturn and panic paths; the
application's session runs GDB through the harness's relay, so the driver's
device serves it and `monitor feed`, `tick` and `delay_stop` drive it. Separate
symbol selection refuses stale executable, assembly, table and source inputs.

`scripts/cortex_debug.py` reads ELF32 headers directly. Flash is the highest
physical end of a nonempty PT_LOAD payload, measured from flash address zero,
including vectors, gaps, immutable data, private helpers, veneers, initialized
RAM and RAM-code load images. Static RAM is the highest RAM PT_LOAD memory end
minus `0x20000000`, including alignment and zero-fill. Segment payload sums and
section/symbol extents are retained separately, so neither ELF file size nor a
sum that omits alignment substitutes for the occupied extents. Linker maps
retain the exact compiler object, pinned private archive members and linker
stubs. Section flags and file ranges establish that debug metadata is not
loaded. Debug and nondebug LOAD contents/addresses/zero-fill extents must match.

`resources.py` executes the unchanged complete application through cold boot,
partial and wrapped reads, coalesced half/full notifications, delayed drain,
overrun/discard/restart, later successful echo, timeout, open failure, external
repair-required failure and a complete finite 65535-byte epoch. The epoch
services each 256-byte batch before the next, checks every cumulative count,
echoes the final short read and then observes exhaustion/restart. The separate
protocol client preserves its independent exact transaction and unsafe-source
oracles; these application scenarios do not replace it.

Stack paint reports the lowest changed byte, not a worst-case bound. A retained
disassembly-derived site list observes every emitted SP-changing instruction's
successor, every function entry, including private helpers and veneers, and
every exception handler's entry. `StackObserver` in `resources.py` reads SP,
frame/LR and IPSR on the host at a breakpoint on each site; it adds no
firmware instructions, storage or device reads. Its minimum retains the actual ordinary
frame records and stops following an EXC_RETURN record. Guards, written extent,
reserved extent, scenario and sample counts are retained. Hardware exception
stacking is observed at handler entry. The independent `stack-control.S` uses
external startup, deliberately reserves 256 unwritten bytes, then exercises
36-byte aligned exception entry, 8 software-save bytes and 32-byte nested
entry. QEMU register assertions and the observer independently distinguish
256 reserved bytes from 80 painted bytes. Application measurements do not
claim every possible interrupt arrival, nesting, future input or stack bound.

The observer's breakpoints are debugger breakpoints: QEMU checks them in
translated code, so a site in copied RAM code is observed without patching
its bytes, and a breakpoint's instruction is executed by a single step. Each
sample is a debugger round trip, so the exhaustion scenario -- 65,535 bytes
through the ring, about four million samples -- is measured by paint alone;
every other scenario, the helper and veneer controls and the independent
calibration run under the observer. The fixed Cortex profile and firmware
bytes are unchanged. Every process has a bounded timeout and failure record.

Two controls at every profile serve the stack switch. `switch` builds
`runtime/stack-switch-frames` as firmware, its `main` entered from a
`start`, and runs the session every target runs
(`compiler/tests/debugging/switch_frames.py`, D469): stopped in a fibre the
backtrace ends at `landin.stack_start`, and stepping two switches an
instruction at a time the frames above `landin.stack_switch` are the
leaving context's until MSP, PSP or CONTROL is written and the resumed one's
after. `capacity` measures `probes/fibre-capacity.ldn`, a taker and an
answerer fibre admitted to a group over `core/fibre`'s round of turns, whose
idler waits for an interrupt, exchanging six requests through a ring while
SysTick counts ticks, their stacks cut from one fixed 2,992-byte module
buffer (D470). `accounting()` identifies that buffer and the round's state
in static RAM from `nm -S`, the main stack below the reset pointer and the
whole buffer are painted at `start`, and each fibre's peak is read below its
stack's top when the firmware returns. The control writes `capacity.json`
and `capacity.txt` beside it and fails unless the consumer fits; the
evidence directory's `capacity.json` and `capacity.txt` hold every
profile's, and the gate's `cortex-m-programs` job keeps them. Its tick is
`core/atomic`'s `sole_add` in SysTick's handler (D511). The numbers move
with the compiler, so they are each run's, in that run's `capacity.txt`;
the ones below are one run's, of revision 8a03d5343's compiler with
`evidence.py --control capacity --all-profiles`. At none/off the consumer
used 22,832 bytes of flash and 3,072 of static RAM, of which the fibre
buffer is 2,992; with the 4,096-byte main-stack reservation, painted to
1,644, that is 7,168 bytes of reserved RAM, counted once. Each fibre's
backing is 1,472 bytes, a 32-byte record and a 1,440-byte stack whose limit
stands 384 bytes above its base (D472), painted to 784, 820 with D461's
exception frame; both are live at once, 2,944 bytes. The size and speed
profiles used 20,096 to 20,124 bytes of flash and painted at most 720 in a
fibre and 1,340 on the main stack. When the wrapper was introduced (D511),
the compiler of that revision used 22,492 and 19,916 to 19,944 bytes of
flash with the tick written over the builtins directly, and painted the
main stack to 1,472 and 1,248, against its own 23,268 and 20,632 to 20,660
with the wrapper: a firmware image keeps every scalar's cell entries, since
a program without a public `main` keeps everything (D296), and the
handler's two calls deepen the main stack. Every profile fits the 32 KiB
flash, 16 KiB RAM profile; the control fails a profile that does not. Paint
is a run's deepest write, not a bound.

`evidence.py` runs on its own with the programs and controls named and the
profiles to run them at, so the consumer is re-measured alone:

```sh
python3 environments/cortex-m/evidence.py --refine PATH_TO_REFINE \
  --output NEW_DIRECTORY --control capacity --profile none-off --profile size-auto
```

`--control` takes `pool`, `vec`, `cpu`, `noreturn`, `panic`, `veneer`,
`irq`, `machine`, `leaf`, `switch` or `capacity`, and `--program` `app`,
`protocol` or `layout`, which builds the driver lane's image of the same
program first, since the debug image is compared with it. Each repeats;
`--all-profiles` runs all six. The run is `FILTERED`; `capacity.json` and
`capacity.txt` under its `evidence` directory hold each profile's report.

Artifacts under the `run.py` output's `evidence` directory retain sources,
identities, commands/assertions/timeouts,
ELF/object/assembly/linker/map/disassembly/debug records, closure and resource
JSON, source-selection failures, measured SP/frame
snapshots and repeat-emission comparisons. Debug CUs retain their compilation
directory, so deterministic debug comparisons repeat within that directory;
relocation does not imply identical source identity. The current `cortex-m`
gate job runs this lane through `run.py` with the compiler built from its
checkout. Physical board testing remains supplemental and is not claimed by
these emulator lanes.
