# Xtensa execution checks

These runners execute compiler-generated firmware on Espressif's QEMU.
Chip controls use its `esp32` and `esp32s3` machines; the complete corpus
uses its `sim` machine with the exact selected CPU and explicitly virtual
RAM. They use the windowed ABI throughout, the
chip-specific assembler configuration, and the matching windowed libgcc.
The core names LX6 and LX7 identify configurable processor families; the
selected levels describe the actual ESP32 and ESP32-S3 configurations.

Build `refine` in the [pinned environment](../../docs/process.md#local-agent-feedback)
and install the [shared cross-target tools](../cortex-m/README.md).
`--tools DIRECTORY` names the installation and selects its QEMU and wrappers.
Complete corpus lanes require that argument. The runner verifies the lock,
archive pin, whole installation hashes before and after execution, binary
versions and both configuration multilibs. Focused development runs may
instead pass `--qemu PATH` and use wrappers from `PATH`; they record those
actual tool hashes and versions. Output directories must
be new; every command, assembly image, linker script, helper-library hash,
disassembly, remote-protocol transcript and verdict stays in that directory.
On NixOS, run them from `nix develop`: with `--tools`, a runner on
NixOS's stub loader runs itself again inside the flake's `landin-fhs`, as
the [Cortex-M lanes](../cortex-m/README.md#on-nixos) do, and QEMU loads the
installation's runtime libraries there. A focused run with `--qemu` alone
runs the QEMU it is given as it is.

Run selected native controls, including an independent nonzero-status
control and an intentional trap control:

```sh
python3 environments/xtensa/backend.py \
  --refine "$REFINE" --tools "$TOOLS" --output "$OUT/controls" \
  --chip esp32 --control status-control --control trap-control \
  --control window-depth --control window-switch --control window-arguments \
  --control double-exception-control \
  --control scalars \
  --control software-float --control assembly-operands --control feature-level \
  --control break-control --control early-stop-control --control premature-stop-control
```

Repeat with `--chip esp32s3` and a new output path. The source wrapper
initializes a separate status cell to `-999`, records `main()`'s result,
then enters its own nonreturning completion loop. QEMU's remote protocol
checks the stop PC, that status cell and the compiler's trap cells. Normal
corpus images use the emitted assembly unchanged. Separate negative controls
exercise an illegal instruction, a debug break, an early debugger stop and
a premature firmware stop; the latter two cannot count as completion even
with zero status and no recorded trap. Trap controls also check the recorded
PC against the emitted instruction. The window controls exercise overflow and
underflow, round trips between two stacks with live recursive frames, and a
caller whose window is taken beneath a callee that passes stack arguments.
A double exception control raises an illegal instruction with `PS.EXCM`
set and checks that the recorded PC is that instruction's, which only
`DEPC` holds.

The corpus adapter reads the sole shared
[inventory](../../compiler/tests/cortex-m/corpus.json) and its retained
[counterparts](../../compiler/tests/cortex-m/counterparts.json). It executes
four standard optimization/specialization profiles and the additional
specialization profiles requested by fixture metadata. Exact focused runs
report `FILTERED`:

```sh
python3 environments/xtensa/corpus.py \
  --refine "$REFINE" --tools "$TOOLS" --output "$OUT/focused" \
  --chip esp32 --fixture runtime/calls-return-through-the-abi \
  --fixture runtime/fibre-join-first-failure --profile none-off
```

A complete lane uses `--all` without fixture or profile selectors, and
reports `COMPLETE`. Run both chips separately. Keep CPU headroom while the
complete corpus runs: the oracle has a 20-second wall-clock guard, and the
exhaustive memory-alignment fixture can exceed it when CPU-heavy closing
jobs saturate the host. Preserve default workers; schedule those jobs
separately. A timeout retains its stop/register evidence and remains failed
until investigated; it supplies no source or capacity exemption.
`result.json` contains the
aggregate verdict; each selected case has `verdict.json` and its build and
execution evidence. Source refusals require the inventory's exact diagnostic
codes and no assembly output. A failed execution stays failed until its
cause is fixed or an explicit target disposition establishes a real
boundary. Target overrides live in the shared inventory's `targets`
object, `"targets": {"xtensa": {...}}`, and are exposed to other tools by
`backend.disposition`; the Cortex-M lanes' `lanes` entries are the same
idea per lane. Xtensa's windowed C ABI is disabled (D920), so every row
that runs or is restricted on Cortex-M through its C surface carries an
Xtensa refusal with the codes Xtensa gives, L0346 for its C signatures and
records, or L0015 for the C aliases module. A `restriction` row is built
as D986 has it and must stop where its `stops` says: refine's compilation,
then an ABI fixture's C, compiled by the chip's pinned GCC with the
freestanding contract, then the link and the oracle; a row that refine
refuses here, or that gets past its stop, fails, naming the `targets.xtensa`
entry to write. Each refusal's and restriction's `reason` in the results is
rendered for the selected chip and memory profile and names
`environments/xtensa/abi.py`, this target's own independent C controls.

```sh
python3 environments/xtensa/corpus.py \
  --refine "$REFINE" --tools "$TOOLS" --output "$OUT/corpus-esp32" \
  --chip esp32 --memory-profile=sim --all
```

The SIM profile declares 64 MiB of emulator RAM, separate code/data regions
and an 8 MiB stack. It retains the selected chip's actual ISA configuration;
it supplies no physical SRAM, PSRAM, cache or peripheral claim. Chip-machine
controls and physical runs retain their bounded internal-SRAM maps.
SIM uses QEMU's generic ELF loader with `cpu-num=0`, whose reset callback
selects the ELF entry; the runner independently verifies the initial PC
against that entry before continuing. The unchanged two-GiB static-array
fixture exceeds this virtual map too. Its existing selected-image limit
requires an actual capacity-only link failure corroborated by the retained
link map and object sections, and makes no execution claim. A row with
that limit is also met by a routine whose frame the selected stack cannot
hold: the lane builds with a firmware entry, where refine refuses such a
frame with L0507, and it records the limit when L0507 is the only code and
no assembly was written. That is no `refuse` row: a refusal is compiled
without an entry, where L0507 is not given.

Configuration and compatibility controls run separately:

```sh
python3 environments/xtensa/boundaries.py \
  --refine "$REFINE" --tools "$TOOLS" --output "$OUT/boundaries"
```

They compile real inline assembly blocks and invoke both strict assemblers,
including real compiler invocations with `--level` omitted for the ESP32 default.
Both accept emitted checked integer division and reject the optional `CONST16`; only the
S3 configuration accepts `SALT`, and only the ESP32 configuration accepts
the selected double-precision accelerator register instruction. The feature-level
source returns 6 on ESP32 and 7 on S3 through a `compiler.feature.salt` branch. The common
controls also assemble the same generated source with both configurations,
then link the original ESP32 object against the S3 memory map and matching
S3 libgcc and execute it on S3. The result establishes compatibility for
those emitted scalar operations and selected helpers. It does not establish
compatibility for arbitrary ESP32 assembly or the ESP32 helper library.

Independent vendor-C layout and calling-convention probes run beside them:

```sh
python3 environments/xtensa/abi.py \
  --refine "$REFINE" --tools "$TOOLS" --output "$OUT/abi"
```

Both configurations check C sizes and alignments, integer and floating-point
carriers, aggregate register/stack placement, 12/16/20-byte returns and
sixteen-byte stack alignment. C peers call actual emitted Landin scalar
routines through a source-authored entry thunk. Separate native peers test
C aggregate transport; this does not admit Landin by-value C signatures.
Each chip must return zero and a deliberate nonzero status, with no trap
and an intact stack guard. Both vendor configurations refuse C
`unsigned __int128`; sixteen-byte vector storage alignment is checked
separately and supplies no C integer-mode claim.

The same boundary command links every compiler-reserved libgcc helper root
and follows actual instruction PCs through all conditional branches and
calls. The audit retains the linked image, map, helper-library hash, root
list and each reachable instruction. It rejects undecodable instructions,
unresolved edges and instructions outside the reviewed state policy. This
checks that an interrupt wrapper preserving the integer windows, SAR,
loop registers and the single-precision bank with FCR/FSR also preserves
all state used by the selected helpers. It does not infer state use from
linear disassembly of literal pools and alignment bytes.
