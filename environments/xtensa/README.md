# Xtensa execution checks

These runners execute compiler-generated firmware on Espressif's QEMU
`esp32` and `esp32s3` machines. They use the windowed ABI throughout, the
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
On NixOS, use the existing Cortex-M README's FHS recipe with `steam-run`;
QEMU needs the installed runtime libraries described there.

Run selected native controls, including an independent nonzero-status
control and an intentional trap control:

```sh
python3 environments/xtensa/backend.py \
  --refine "$REFINE" --tools "$TOOLS" --output "$OUT/controls" \
  --chip esp32 --control status-control --control trap-control \
  --control window-depth --control window-switch --control scalars \
  --control software-float --control assembly-operands --control feature-level
```

Repeat with `--chip esp32s3` and a new output path. The source wrapper
records `main()`'s result in a separate status cell. QEMU's remote protocol
sets a breakpoint at the compiler's stopped label and reads that cell and
the compiler's trap cells. Neither the emitted assembly nor the executable
is rewritten. Trap controls also check that the recorded PC points to the
emitted illegal instruction. The window controls exercise overflow and
underflow, and round trips between two stacks with live recursive frames.

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
reports `COMPLETE`. Run both chips separately. `result.json` contains the
aggregate verdict; each selected case has `verdict.json` and its build and
execution evidence. Source refusals require the inventory's exact diagnostic
codes and no assembly output. A failed execution stays failed until its
cause is fixed or an explicit, witnessed target disposition establishes a
real boundary. Target overrides live in the shared inventory's `targets`
object and are exposed to other tools by `backend.disposition`.

```sh
python3 environments/xtensa/corpus.py \
  --refine "$REFINE" --tools "$TOOLS" --output "$OUT/corpus-esp32" \
  --chip esp32 --all
```

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

The same boundary command links every compiler-reserved libgcc helper root
and follows actual instruction PCs through all conditional branches and
calls. The audit retains the linked image, map, helper-library hash, root
list and each reachable instruction. It rejects undecodable instructions,
unresolved edges and instructions outside the reviewed state policy. This
checks that an interrupt wrapper preserving the integer windows, SAR,
loop registers and the single-precision bank with FCR/FSR also preserves
all state used by the selected helpers. It does not infer state use from
linear disassembly of literal pools and alignment bytes.
