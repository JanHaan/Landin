# What refine does today

This is the maintained inventory of what Landin's compiler, its library and
its tooling do today. The [README](../README.md#current-compiler-capabilities)
summarises it; `ROADMAP.md` owns what comes next, and `spec.md` decides what
is legal. Derived; never an authority.

Keep it an inventory rather than a log: when a capability changes, edit the
entry that describes it, and put a new one where a reader would look for it.
Evidence belongs to the README that owns it; an entry links there.

`D542` names a decision recorded in `spec.md`, and `[1480]` a numbered
paragraph of `tour.md` or `spec.md`; `refine explain D542` prints either.

## Targets

| target | builds | where the gate runs it | debugger |
| --- | --- | --- | --- |
| `linux-x86-64` | hosted executables | natively | GDB |
| `linux-arm64` | hosted executables | natively | GDB |
| `linux-rv64` | hosted executables, LP64D | QEMU's user emulation | GDB, through QEMU's stub |
| `darwin-arm64` | hosted executables | natively | LLDB with dSYM |
| `freebsd-x86-64` | hosted executables, emitted on Linux | a FreeBSD VM under KVM | LLDB in the VM |
| `freebsd-arm64` | hosted executables, emitted on Linux | an emulated FreeBSD VM | LLDB in the VM |
| `cortex-m0` | Cortex-M firmware, ARMv6-M by default and up to ARMv8-M Mainline by `--level` | the pinned QEMU | GDB, lines and functions |
| `xtensa` | windowed LX6 and LX7 firmware, ILP32; physical ESP32 and ESP32-S3 RAM and boot ports | Espressif QEMU chip controls and complete corpus on exact CPUs with explicitly virtual RAM | lines with `--debug=lines`; no gate debugger session |
| `rv32` | RV32IMC and RV32IMAC firmware, ilp32 | Espressif's QEMU, `sifive_e` and `esp32c3` | lines with `--debug=lines`; no gate session |

- **FreeBSD** runs in [architecture-specific VMs](../environments/freebsd/README.md)
  with separate runtime, C ABI and debugger verdicts in the gate.
- **RV64** runs its whole test program and its GDB sessions under QEMU's
  user emulation, which is evidence about its emitted code and none about
  RV64 hardware. Its [physical RISE lanes](../compiler/tests/rv64/README.md),
  with separate runtime, native GDB, C ABI and ISA-level verdicts, are
  suspended from the gate until they are dependable.
- **macOS** checks a host-dependent large-image loader limitation against a
  native Clang control: the shared-region placement limit observed on some
  hosts.
- **Cortex-M** builds firmware with compiler-owned reset, data and RAM-code
  copying, BSS clearing, typed interrupt and naked functions, vector
  references, placement and fixed assembly. The memory map, the vector slots
  a handler takes and the boot image follow the device description the
  program imports (D542-D545), Landin source of directives such as
  `linker.region`; with none, the reference firmware profile of 32 KiB
  flash, 16 KiB RAM and a 4 KiB stack applies, itself a description in the
  library. [The device descriptions](../devices/README.md) cover RP2040,
  whose second stage, marked `link(boot_stage)`, refine seals with the boot
  ROM's checksum (D587, D588); RP2350's Cortex-M33, whose IMAGE_DEF block
  refine emits after the vector table and reads back (D636-D638); and the
  STM32H753, whose supply stage runs before reset writes any RAM (D653).
  Their registers are checked in as generated device fixtures.
  Prototype 1's application runs on a Raspberry Pi Pico, on a Pico 2 at
  `--level=armv8-m.main`, and on a NUCLEO-H753ZI at `--level=armv7e-m` with
  its float unit and, in the cached firmware profile `stm32h753_cached`, its
  caches maintained through `core/cache`, beside controls that fail when
  the maintenance is left out (D974, D975). Each port is checked against
  its expected output by [the board tools](../environments/boards/README.md),
  which record a RAM run, loaded into SRAM without writing flash, and a
  boot check from power-on separately (D593-D596, D647-D655, D901, D902).
  The gate runs both on the maintainer's rig on every push to `main`,
  weekly and by dispatch, never for a branch, and never reuses physical
  evidence (D904, D905).
  The derived linker script is written as `OUT.ld`, or alone with its
  limits by `--emit=linker-script` (D589), a developer's own is linked with
  `--linker-script=FILE` and held to a contract of five clauses, among
  them every section with content clear of the stack and nothing a program
  declares at address zero (D546, D1323), and
  `link(region: ...)` places a declaration in a named region (D547). A
  generic routine's `section:`, `align:` and `region:` place every instance
  the program makes of it (D1322).
  A flash image keeps `text` and `rodata` where reset need not put them:
  a description that places either in RAM nothing loads is refused with
  L0514 (D1116). The link asserts the stack's reservation against whatever
  shares its region (D1114), the build report's `flash_remaining` leaves
  out a stack reserved in text's region, and nothing a program declares is
  placed at address zero (D1115).
  Cortex-M, RV32 and Xtensa also derive an in-place SRAM layout with
  `--firmware-layout=ram` (D900), checking the linked vectors, sections and
  stack, retaining BSS clearing and omitting ROM packaging.
  Firmware runs on the pinned QEMU
  [emulator](../environments/cortex-m/README.md), with synthetic devices
  served through its debugger stub.
- **RV32** is a firmware target, `--target=rv32`, at `rv32imc` or
  `rv32imac` with the ILP32 soft-float layout (D660). Its programs check,
  configure against a device description or the library's
  `platform/riscv/reference`, QEMU `sifive_e`'s map at the Cortex-M
  reference's capacities (D661), and lower to IR; a description may name
  `hazard3`, `sifive-e31`, `esp-rv32imc` or `esp-rv32imac-clic`, whose
  interrupt model decides which mcause codes take handlers (D662). Its
  backend is RV64's at XLEN 32 (D671): eight-byte integers are register
  pairs, f32 and f64 are libgcc's soft float, and 64-bit division is
  libgcc's, with the language's checks unchanged. An image begins with its
  entry word and its trap table, a `j` per mcause code, which reaches a
  routine beyond its 1 MiB through a stub near the table (D1290):
  vectored mtvec on
  the E31 and the ESP32-C3, a common CLIC entry on the ESP32-C5, beside
  mtvt's table of stubs for an interrupt the program vectors (D830), and
  Hazard3's meinext dispatch, with a stub that saves the caller-saved
  registers, calls an `extern(interrupt)` routine and unwinds to mepc
  (D680, D686). An exception's mcause, mepc, mtval and sp are recorded in
  `_landin_firmware_trap_*` cells any probe reads as memory (D656).
  `rp2350-image-block` carries RISC-V's IMAGE_DEF (D682),
  and `esp-app-image` is built: a description names its chip with
  `compiler.esp_image`, may stop its watchdogs in a stage before reset,
  and refine writes `OUT.bin` beside the executable and reads it back
  (D683-D685), which the ESP32-C3's ROM boots on Espressif's QEMU.
  `platform/riscv` and `platform/riscv/hazard3` hold the core's CPU
  operations (D687). The Pico 2's port on its Hazard3 cores, at
  `rv32imac`, takes its interrupts through Xh3irq and counts its telemetry
  with an `amoadd.w` (D710), and is checked by an oracle of its own,
  [`board.py`](../environments/boards/rp2350_hazard3/README.md) (D711-D713).
  Its cold-boot record enters the cores' RISC-V mode from power-on; its
  repeated RAM records load and resume SRAM without flash programming or
  a ROM reset. Both modes take TIMER0's, DMA's and a forced USBCTRL
  interrupt through the meinext dispatch, number all seven telemetry
  frames with `amoadd.w`, and echo 11,202 bytes in order with the counters read
  over SWD equal to the trace's. Its malformed-block control remains
  disabled. The ESP32-C3's and
  ESP32-C5's ports of the same application receive UART0 by interrupt through each chip's
  interrupt matrix, a vectored line on the C3 and a CLIC identity on the
  C5, hold it off by threshold while a 1 ms timer keeps interrupting, and
  run the level's atomics, stores and loads at `rv32imc` and an AMO and
  compare-exchanges at `rv32imac` (D720, D721). Their tools,
  [`esp32c3`](../environments/boards/esp32c3/README.md) and
  [`esp32c5`](../environments/boards/esp32c5/README.md), read `OUT.bin`
  apart from refine and the ROM's boot log, refuse an image whose checksum
  is wrong on the board, and check counters and cells over JTAG
  (D722-D727). A run of each is recorded, `record.json` beside its tool:
  booted from power-on, the ROM's log matching the image, a refused
  checksum, the echo, the indicator, both interrupts, the atomics, a ring
  overrun, a FIFO overflow under the threshold with the timer still
  running, and the counters and cells over JTAG.
- **A float unit** is a fact of a description: a Cortex-M7's
  `compiler.float_unit("fpv5-d16")`, which the STM32H753's has, builds
  hard-float at `armv7e-m` (D615). f32 and f64 arithmetic, negation,
  comparison and conversion are VFP instructions with no software helper,
  floats travel in s0-s15 under AAPCS32's VFP variant for C and Landin
  alike (D616, D617), reset grants the unit and handlers take its extended
  frames (D618), and a fibre's switch keeps d8-d15 and FPSCR (D620). An
  object built with a unit and one built without declare their float
  attributes as GCC's do, so the linker refuses to mix them in either
  order (D780). The convention's C half is measured against GCC on
  QEMU's `mps2-an500`. The whole runtime corpus also runs there, on a lane
  described in Landin source (D619).
- **C on Cortex-M** follows AAPCS32, `compiler.c_aapcs32`, at every level
  (D920): `layout(c)` records, C function types, `extern(c)` imports and
  `public extern(c)` definitions, in the base PCS without a float unit
  and in the VFP variant with one. `platform/c` gives ILP32 aliases with an
  unsigned plain `char` (D921). A variadic C call is refused, naming a
  fixed-arity C wrapper to import instead (D922). Records pass by value,
  split between registers and the stack, and return in r0 or the float
  registers as GCC's do, and `linker.library` links a C archive into the
  firmware (D923). The Cortex-M corpus executes C on QEMU: ABI fixtures'
  freestanding C peers, built by the pinned GCC with no C library and
  linked with the program, among them a hand-written peer that calls and is
  called with every scalar width, records of 3 to 32 bytes, a callback and
  C data, also linked by refine itself from archives, and the generated
  CMSIS NVIC and SysTick adapters, whose effects are read back from the
  registers (D985). A C peer of the other variant is refused before it
  links. Each fixture that does not run there is a refusal with its codes
  or a restriction its build is held to (D986). RV32's ilp32 and Xtensa's
  windowed C ABI stay disabled.
- **A cache** is a fact of a description too: a Cortex-M7's
  `compiler.cache("armv7-m-l1", 32)` makes a cached profile, whose reset
  invalidates and enables the level 1 caches once memory is written and
  whose entry's return cleans and disables them, `compiler.feature.cache`
  and `compiler.cache_line` reading it (D971, D973). The STM32H753's cached
  profile is the one admitted (D974); on QEMU's `mps2-an500`, which models
  no cache, a lane run shows the order of every cache register write and
  nothing of a cache (D977).
- **Devices** are learnt from their CMSIS-SVD files: `refine svd` reads a
  vendor's SVD, fetched by its hash, and a reviewed selection policy, and
  writes the register modules and the generated half of the device's
  description, its interrupts (D555-D559). It reads peripheral derivation,
  device-level property inheritance, alternate registers, an alternate of
  an array element held to that element's own address, elements of
  register arrays and fields with or without enumerations, and refuses
  clusters, field and peripheral arrays and derived registers by name
  (D703). What an SVD omits, overstates or says twice is refused at its
  element: a missing child, a number that wraps, two elements of a
  selected name, and a source or module name Landin reserves (D1062,
  D1063); a large file is read in time proportional to its size. A policy may name a RISC-V description's core, move a register
  or add a peripheral the SVD lacks, each correction with its source, and
  on the ESP cores the SVD's interrupts become a module of interrupt-matrix
  sources rather than slots (D700, D701, D704, D705). The RP2040 and RP2350
  fixtures are regenerated byte for byte and held to pico-sdk's headers,
  the STM32H753's selection to ST's CMSIS header, and the ESP32-C3's and
  ESP32-C5's to ESP-IDF v6.1's headers and their TRMs (D702); RP2350's
  Hazard3 cores have a description of their own (D706). The two ESP
  descriptions are RAM-only images with a stage that stops the watchdogs
  before reset (D707, D708).
- **Synthetic-32** is a checking-only target, which no backend emits.

### CPU feature levels

A build assumes a level of its target's family, selected with `--level=`,
each defaulting to what the backend always emitted. A level the target's
family does not have is refused with the levels it does have.
`refine targets` lists them, and [the target contracts](targets.md) say
what each selects.

| family | levels |
| --- | --- |
| x86-64 | `x86-64-v1` to `x86-64-v4` |
| arm64 | `armv8-a`, `armv8.1-a` |
| M profile | `armv6-m`, `armv7-m`, `armv7e-m`, `armv8-m.main` |
| RV64 | `rv64gc` baseline; `rv64gc_zba` and `rv64gc_xtheadba` add independent address-generation extensions, and `rv64gc_zba_xtheadba` selects both |
| RV32 | `rv32imc` baseline; `rv32imac` adds A |
| Xtensa | `xtensa-esp32` default; `xtensa-esp32s3` exposes `compiler.feature.salt`; independent chip configurations |

- A level changes instructions and never layout or ABI: BMI2 shifts at
  `x86-64-v3`, LSE atomics at `armv8.1-a` on Linux, macOS and FreeBSD,
  hardware division and multiplication at every Thumb-2 level, `armv7-m`,
  `armv7e-m` and `armv8-m.main`, and acquiring loads and releasing stores
  in one instruction at `armv8-m.main`. Each is executed at its level and at
  the default, the Cortex-M ones on QEMU's Cortex-M3 and Cortex-M33, which
  runs the whole Cortex-M corpus again at `armv8-m.main`, and the linked
  image is read for the instructions its level selects. A description's
  float unit is not a level and does change the ABI; `compiler.feature.fp`
  and `compiler.feature.fp_dp` read it (D615).
- A program reads a level as `compiler.feature.NAME` in `fixed if` or in a
  module value, which a routine body then branches on, and every compiler
  fact reads the same way (D437).
- The assembler holds an assembly block to the level, and a level runs only
  on a processor that confirms it; an unconfirmed level fails as unverified.

## The command line

The README has [the commands in brief](../README.md#refine-in-brief);
`refine help reference` prints the complete interface.

### Commands

- `refine check program.ldn ...` runs the frontend, lowering and
  verification on the named sources as one whole program, without writing
  an artifact. It takes every option that says which program is compiled,
  `--link`, `--firmware-entry` and `--build-report` among them, and with
  `--root` the operand is the entry module's directory or its source files;
  source files named as the entry are not also imported as their
  directory's module, which is L0616 (D1055).
  It stays silent when the program is accepted.
- `refine compile program.ldn -o program` assembles and links an executable.
  `--emit asm` writes assembly, `--emit ir` writes the IR the backend would
  receive, and `refine compile program.s -o program` links an assembly file
  as a compiled program is linked. `--emit ir-annotated` writes the same IR
  with what a later comparison needs: a first line recording the target,
  level, optimization and specialization, each routine's module and, for a
  generic instance, its template and item, and the IR's metadata. The
  compile leaves only the executable; `--keep-asm` keeps the assembly
  beside it.
- **Publishing outputs.** Generated artifacts use one
  loss-preserving publication group (D907): exclusive private staging beside
  each destination, verification before installation, and prior versions kept
  through verification of the whole group, including an ESP image or Darwin
  debug bundle. Unchanged files retain their original inode. Failure or
  cancellation restores prior versions without overwriting a concurrent
  change, or reports the retained recovery paths. A cleanup refusal says
  which state the group ended in: published, with the replaced copy kept;
  not published, with every output back and only this build's private files
  kept; or a rollback that did not finish. It names only the recovery entries
  it holds, and an ESP image as checked only when it was written and read
  back. A build cancelled while it holds outputs reports no output fault;
  refine's last line names the signal. A preparation refused for a resource
  limit, such as the file-size limit, removes the workspace it made when it
  captured nothing, and removing a tool's capture takes no further
  descriptor; refine ignores SIGXFSZ, so that limit is a refusal and
  never the signal's end (D1047).
  An earlier retained publication is diagnosed before retrying; only a
  directory the invoking user owns is read as one, and another user's is
  passed over (D1049). A published file has the mode a fresh build gives it
  under the umask, an unchanged file among them, and a replaced file's own
  mode is not carried over (D1048). An output's directory may not be a
  symbolic link, and an output replaces only a regular file; a refusal says
  so in the rule's words (D1051). A name outside ASCII builds on every
  filesystem, and one holding `~` or `:` only where refine recognises the
  filesystem (D1052). `-o` names
  the file to write: an existing directory there is refused before anything
  is compiled, with a file under it as the example. A path that cannot be
  prepared is refused naming the option that gave it, `-o`,
  `--build-report`, `--stage-report`, `--stack-report` or `--depfile`.
  The group is not an atomic
  snapshot for readers, and ordinary recovery is not power-loss durability.
  Protected inputs include the source closure, response files, policies,
  selected tools, supplied tool inputs and known resolved libraries; bindings
  also records Clang's consumed headers. External dependency filenames do not
  provide identities from the tool's read descriptors, and arbitrary wrappers
  and implicit toolchain internals are outside that protection. Relative or
  indirect file directives in assembly or linker scripts are refused: use
  plain absolute file paths or a standalone assembly input or linker script.
  The directive is found wherever its word stands, so an assembly input that
  defines macros is refused with it (D1060), and each tool text input is
  scanned once, within 4,096 inputs and 64 MiB a build (D1059).
  A relative Clang dependency that escapes its private workspace is also
  refused; use an absolute include path or a declared `--include-dir`.
- **Cancelling a build.** An interrupt, termination or hangup ends a
  command with `refine: cancelled by signal N` and status 128 plus the
  number: at once when it holds nothing to recover, and at the next stage
  boundary, the frontend's stages included, while it holds a tool, staged
  outputs or a run directory (D1046). Holding something, it forwards
  cancellation to its active tool's process group, allows bounded
  shutdown, stops remaining ordinary group members and reaps its direct
  child before recovering outputs.
  Tools that escape their group or change credentials are outside that
  supervision contract. A signal unanswered for ten seconds ends refine by
  that signal, leaving its workspace as SIGKILL would. `refine lsp` begins
  no such command, and a signal ends it by the signal's default action.
  Inherited ignored signals stay ignored.
  Tools are refused before spawning if ignored `SIGCHLD` or `SA_NOCLDWAIT`
  would discard their exit status. Start refine with `SIGCHLD` at its default
  disposition and `SA_NOCLDWAIT` clear; refine preserves the inherited policy.
- `refine run program.ldn -- ARGUMENT ...` compiles into a new private
  directory under `TMPDIR` or `/tmp`, runs the program on this terminal with
  the arguments after `--` exactly, exits with its status, or with 128 and
  the number of the signal that ended it and a line naming it. The program
  shares refine's process group, and while it runs refine ignores SIGINT
  and SIGQUIT, so the terminal's Ctrl-C and Ctrl-\ reach the program and
  refine stays to clean up; an interrupt or quit refine's caller ignored
  stays ignored in the program. A termination or hangup sent to refine is
  passed on to the program, unless refine was started with it ignored. So
  a supervisor that signals refine alone, rather than its process group,
  sends SIGTERM or SIGHUP: an interrupt sent only to refine is ignored. It
  cleans up its directory after every outcome, a closed pipe on refine's
  own output among them. If a changed directory or
  cleanup failure prevents safe removal, it retains the entries and reports
  their recovery location and what to do. It takes `compile`'s
  options except those that say what is written, and runs only the
  compiler's own host. A bare `refine program.ldn` checks and says that it
  wrote nothing, naming the commands that run and build what it checked,
  with the options that chose it, `run` for a hosted target and `compile`
  with a firmware entry for a firmware target, or, for a hosted source with
  no `main`, that it checked a module and what a program needs; `-q`
  silences that line.
- The default target is the compiler's own host; cross-compilation names a
  `--target`. Bare source requests and `--emit=asm|exe` remain
  compatibility spellings, and `build` is reserved for future project
  orchestration.
- `refine fmt source.ldn ...` rewrites each named source, or every `.ldn`
  file under a named directory, in the one layout
  [`docs/format.md`](format.md) shows, changing its space and nothing else.
  `--check` writes nothing and reports every line that is not in it, showing
  the line as the layout writes it and marking where it differs; `--stdout`
  prints one source in the layout. Rewriting retains the original read
  descriptor and updates that inode, preserving metadata and hard links. A
  save renamed over the source is never overwritten; a late name change can
  leave the old inode formatted and the original bytes at a reported recovery
  path. Concurrent writes to the same inode through another descriptor remain
  unsupported. `--check` and `--stdout` acquire no writable lease. Before it
  writes, `fmt` parses its own output and refuses, as a defect, a layout
  that no longer parses. The library
  roots, the examples and the tour's examples are kept in that layout.
- `refine svd --policy=POLICY.json --out-dir=DIR DEVICE.svd` reads a
  vendor's CMSIS-SVD file and a reviewed selection policy, requires the SVD
  to be the file the policy names by SHA-256, and writes a register module
  per selected peripheral, their correspondence and manifest, and the
  device description's generated `interrupts.ldn` (D555-D558). It stages
  every output privately beside its destination and reads it back before
  publishing the group through D907's shared contract, leaves unchanged files
  alone and removes what its old manifest names and it no longer makes with
  the same recovery checks, a stale file only while it is still what that
  manifest hashed: a changed one stops the run with L0531 (D1064). Output
  paths that are equal, or one below another, are refused before anything
  is prepared. [The device guide](../devices/README.md)
  describes the policy.
- `refine bindings --clang=CLANG [--sysroot=DIR] --policy=POLICY.json
  --out-dir=DIR HEADER.h ...` asks the named Clang, in an environment of
  its own, for the headers' declarations and writes the bindings a reviewed
  policy selects: Landin declarations, C adapters for the forms Landin does
  not carry natively, the header that declares them, and metadata (D820,
  D821). It binds for Linux x86-64, Linux arm64, macOS arm64 and
  freestanding Cortex-M, the last under AAPCS32's base procedure call
  standard or its VFP variant as the policy says, with Clang's own headers
  alone and adapters that allocate nothing (D935-D938). It stages its four outputs and compiles the adapters before
  publishing them through the same protected-input and recovery contract as
  `refine svd`. Missing output directories are staged privately and published
  only after validation; refusal preserves any tree created there meanwhile.
  Existing output directories retain unrelated files.
  [The binding guide](../bindings/README.md)
  describes the policy; installed command help points to its generated
  reading copy, `bindings.html`.
- `refine lsp` is a language server over standard input and output: an
  editor started with it gets diagnostics, definitions, hover types,
  formatting and quick fixes from the compiler's own stages, as
  [`docs/server.md`](server.md) describes. A build option the editor
  configures reaches the modules that declare it (D1068); an unsaved buffer
  is the file it names through a symbolic link and in a directory not yet on
  disk (D1069, D1070); watched-file changes cover a directory's removal, an
  import directory that was empty and an earlier root; and a document may
  be as large as a message carries. While a module's publication ends in a
  compiler defect, each of its open documents shows that one report at its
  first line until a publication completes (D1250), and an analysis that
  exhausts the server's stack or memory is that document's defect, with the
  session kept (D1220). The packages under `highlight/`
  start it.
- `refine explain CODE` prints [what a diagnostic code means](diagnostics.md)
  and what to change, from text the compiler carries; where an explanation's
  example is a fixture, it shows the fixture's files and report (D1230). It
  answers the citations a note carries as well:
  `refine explain [1760]` or `D275` names the construct's or decision's title,
  its document and its page on the site, and `--full` adds the construct's
  text or the decision's chosen rule. These it reads from `citations.txt` in
  the library, or under `--library=DIR`; without a readable file it names
  the path it read and what to install (L0003, D1240). A file generated
  beside other compiler sources than the compiler's own, or naming none,
  is still read, with an L0017 warning that names both (D1357).
- `refine site PROGRAM SITE` names the source line of a panic site a
  `panic_handler` received, and the check that failed, and
  `refine site PROGRAM FILE LINE COLUMN` the source position of a caller's
  three coordinates. PROGRAM is what the compilation wrote, an executable,
  a firmware image or the assembly of `--emit=asm`; the table is the
  `PROGRAM.sources.json` that `--panic-map` writes beside it, or
  `--map=FILE`. The table answers only for the build it was written with,
  whose identity the command reads from the program itself, a stripped
  executable's included, and `--dsym=FILE` holds a Darwin dSYM to the
  executable's UUID (D1292).

### Help, options and completion

- `refine --help` lists commands. `refine compile --help`,
  `refine --help compile` and `refine help compile` give the same command
  help. `refine completion bash|zsh|fish` prints shell completion
  definitions from the same option catalogue.
- Shared options work before or after the command. Command-specific options
  follow it, and one written before it is refused naming the command it
  belongs to and where it goes.
- Values accept a space or `=`, repeatable options retain their order, and
  duplicate single-valued options are refused. Use `--` before literal
  operands. `@FILE` expands a bounded response file with single and double
  quotes and backslash escapes, without shell expansion.

### Version and targets

- `refine version` (also `--version`) prints `refine 0.2.9` for an exact
  release checkout, or `refine dev (01234567)` for a development commit. A
  modified checkout adds `dirty`; a modified release also includes its
  commit. The release name comes from an exact numeric `v` tag,
  independently of debug or release optimization. Tracked edits anywhere in
  the checkout and untracked compiler inputs count as dirty; generated build
  outputs do not. Without Git metadata, the banner identifies the source
  digest instead.
- `refine version --json` retains the full revision, compiler-input digest,
  dirty state, build mode and host triplet, with `version` set to the
  release name or `null` for development. The input digest covers compiler
  sources and build policy, so a prose edit changes dirty state without
  changing that digest.
- `refine targets` lists described targets, their CPU feature levels and
  accepted debug modes, and for a firmware target the cores each level is,
  so a Cortex-M4 reads as `cortex-m0`'s `armv7e-m`; `--json` gives
  structured output, with a `cores` list of names and levels, and
  `--identify` retains the older capability summary.

### Reports and diagnostics

- `--verbose` (or `-v`) describes the compilation request and names each
  source read, in load order; repeating it
  also traces the actual native tool argument vectors. `--quiet` retains
  warnings and errors.
- `--color auto|always|never` controls human diagnostic colour; `auto`
  checks standard error's terminal, `NO_COLOR` and `TERM`.
- `--diagnostics human|short|json` selects the source report, which is
  written to standard error in every format: read JSON diagnostics from
  there, as `2>report.jsonl` does, since standard output carries only what
  the command itself prints. JSON diagnostics are schema-versioned newline-delimited objects carrying
  labels, notes and fixes; line and byte-column coordinates are one-based,
  spans retain the compiler's byte offsets, and paths also carry a
  hexadecimal encoding of their original bytes. A failed tool's output is
  shown a line each, and JSON carries it as `tool_output` (D1057).
- A command whose standard output cannot be written exits with status 71,
  the host's fault, as it does when the host's resources are exhausted
  (D1061).
- A refused program gets a report with a span, a caret and a note, one per
  mistake and on the token it is about. What a mistake leaves behind is not
  reported again, and where one change of a token mends a line the report
  says which change and offers it as a fix.
- When a refused form matches a spelling from another language, such as
  `elif`, `fn`, `x as i32`,
  `x++`, `x--`, prefix `!`, C-family comments, braces, semicolons, `*u8`,
  `&&`, `!=` or `..=`, the report names what Landin writes instead,
  and `io.println`, `io.printf`, `io.print` or `io.puts` is shown the
  `io.write_format` call that prints a value, spelt with the program's
  alias for `core/io`.
  A construct the tour describes and the enabled language omits is refused with a note
  naming the paragraph that describes it and whether the form is a recorded
  boundary, withdrawn or transferred to a successor.
  Refused leading-keyword typos point at the misspelled word and offer a
  likely respelling; a returned expression names assignment to the named
  result followed by a bare `return`. A keyword written as a name is one
  report for the file, offering a longer spelling (D1190).

### Warnings

- `check` and `compile` accept `--warnings default|all|none` and repeated
  `--warn CODE|all`, `--allow CODE|all` and `--deny CODE|all`. The baseline
  is applied first; the repeated controls then apply in their written
  order, with the last matching control winning. Only live warning codes are
  accepted. `--deny all --allow L0326` denies every warning except the
  unnecessary-`mut` warning, which it suppresses.
- Denial returns status 1 before producing artifacts; ordinary warnings
  retain status 0 and the same generated bytes. Quiet mode retains selected
  diagnostics.
- Every current warning is recommended, L0016 among them, which says a
  `--root` holds a module the library supplies instead, and L0628, which
  marks a bidirectional control character in a comment or a literal and
  shows it escaped (D1077), L0684, which marks an `else (name)` whose
  block never reads `name`, names the forms that bind nothing and offers
  the exact rewrite to `else begin` (D1261, D1341), and L0692, which marks
  a declaration that takes a predeclared type's name, `u8` or `cstring`
  (D1342), so `default` and `all` currently select the same warnings.
- Unnecessary local declarations produce advisories even when comments or
  layout prevent a safe automatic repair; unused signed numeric literals are
  also covered. A warning can report an observation without an edit; exact
  fixes remain available where their edits preserve meaning and comments.

### Build integration

- `refine compile --dry-run` checks and emits in memory, prints planned
  writes and tool arguments, and performs no writes or tool executions.
- `--depfile PATH` writes Make-format source dependencies after successful
  emission, its rule's target the artifact whatever `--emit` asks for,
  including observed module-search directories so import
  membership changes can cause a rebuild. Keep artifacts and reports outside
  those watched directories: creating them there changes directory
  timestamps and can cause redundant rebuilds. Paths Make cannot carry, a line
  break or one of the characters it reads specially, are refused when a
  depfile is requested (D1058). A consuming build rule must also
  track its compiler and native tool configuration.
- Build mode, optimization, specialization and debug information remain
  independent controls.

## The language

- **Forms.** Functions, aggregates and variants, block-valued control flow,
  lexical `defer` and failure-only `undo`, declared errors, every loop and
  literal family, and `unchecked` regions. A program the grammar derives is
  accepted in every layout: indentation decides nothing in an accepted
  program (D1074). A text literal may hold about a mebibyte.
- **Types and conversions.** Explicit conversion to a written type such as
  `[]u8(text)`, the enabled scalar conversions and range subtypes, checked
  also at a call-site `else` value, a `fixed` formal and a concept entry
  (D1086-D1088). An atom
  union may be written in place as a binding's, parameter's, return's or
  field's type. A distinct type compares wherever its base does, updates
  flags in place with `|=`, `&=` and `^=`, and has its base's zero image; a
  pointer union compares with one of its own atoms. A nearer declaration of
  a predeclared type's name, `u8` or `utf8`, shadows it in type positions as
  any declaration shadows a name (D1260).
- **Measuring.** `lenof` measures a field or element path or a call's
  result, `offsetof t.field` measures where a field begins, and
  `compiler.assert` measures a declared type's size, alignment and field
  offsets. Evaluated slice operands receive origin checks and run once;
  fixed-array paths and array-literal elements remain unevaluated.
- **Failures.** `else (problem)` recovers a call in an `if` arm as anywhere
  else, and `else none` ignores the failure of a call that returns none.
  A callee selected through a type parameter's entry or a function-valued
  field keeps its error set, so `try` and `else` work there (D1091). A
  failure outside a declared error set is refused naming every atom that
  enters there, each with its module (D1200). `compiler.unreachable(where)`
  given its routine's `caller` parameter traps at the call that filled it,
  through any forwarding wrappers, in the hosted report, a selected
  handler and firmware alike (D1262).
- **Matching and places.** A match's `_ (rest):` arm binds the atoms no
  other arm named, and `ptr (sink p):` consumes the matched place.
  Destructured results are local places, and an assignment on every edge
  leaving a loop holds after it. An `inout` payload binding needs a
  writable matched value (D1085), and a loop may replace a variant beside
  the match that reads its payload (D1112). A whole array parameter or
  named array return is assigned to an array field (D1180), and a whole
  array field is passed as an `inout` array argument (D1201).
- **Module values.** Module arrays hold variant-bearing struct images, a
  module array or an array field of a module struct takes a call's array
  result, and a module struct may hold an array field before a slice
  field. A
  module binding of function type may be written on one line,
  `chosen: () -> (v: i32) = seven`, and an immutable module integer sizes an
  array, `[path_max]u8` (D438). An array length, in a routine body too,
  reads an integer compiler fact and `sizeof` or `alignof` of a built-in
  scalar at the selected target's value: `[sizeof usize]u8` is `[4]u8` on
  a 32-bit target and `[8]u8` on a 64-bit one (D1321, D1340). A run in a static image is
  written as one `.zero` or `.fill` where one directive writes it, and as
  repetitions no wider than 256 otherwise, so the assembly and the
  assembler's memory stay the source's size rather than the image's (D536). Before emission every
  target holds a program's images to a budget, refused as L0505: written
  images to the code model's reach, 2 GiB on x86-64, Darwin and RV64 and
  4 GiB on arm64, or to a firmware profile's flash and RAM, and zero images
  to the address space alone (D537).
- **Generics and dispatch.** Generics take fixed parameters by compile-time
  substitution, an untyped literal argument takes its parameter's type, and
  a fixed array is lent to a generic slice parameter. A generic
  signature's array bound may use an immutable module integer (D1101), and
  `t(x)` with `t` a type parameter converts to each instance's actual type,
  with that conversion's checks (D1100). Concepts carry a
  whole-program record of their conformances. Generic calls pass only the evidence
  their checked bodies use; direct and `any C` dispatch share table storage
  only when their layouts and entries match, and an `any C` call no
  conformance of C answers builds as a trap no value reaches. An `any C`
  itself satisfies C and every concept C refines, so a generic routine can
  take it and call each entry through its table (D492).
- **Pointers and slices** get local origin, borrow, `escaping`,
  `escaping into` (D445), `from` and consume checks. A view no name holds
  is in use until what took it is done, a `for` loop's source and a view
  passed as an argument among them (D1084).
- **Modules.** Directory modules have file-local imports, aliases, selected
  imports, typed global options and ordered roots. Option names collide with
  ordinary declarations/imports only in their declaring module; unrelated
  modules may reuse the spelling in the ordinary namespace. Static Linux
  checking includes an available implicit startup module before configuration.
  A `public mut` binding named `module.name` is assigned, updated,
  addressed, matched and given to a `sink` as its plain name is, and
  `offsetof` measures a
  qualified struct's field.
  Your own modules are
  found under the roots given with `--root` [1480]; an import whose first
  directory holds no source while a later root holds the module is refused
  naming both (D563).
- **Hardware.** D227's memory model supplies scalar atomics, volatile
  accesses and barriers, each atomic fenced only as its ordering asks on
  every backend (D499), and D228 packed register images with checked
  encoded fields. Cache maintenance for DMA is `core/cache`'s provider,
  never a builtin (D970).
- **Assembly operands.** A block carries integers at `general` or a named
  integer register on every target with registers, and on x86-64, arm64 and
  RV64, and on a Cortex-M whose description has FPv5-D16, `f32` and `f64`
  at `float` or a named float register, a declared callee-saved float
  register saved by its routine (D630). A Cortex-M with no float unit
  refuses a float operand as its boundary. A block's text is held to its
  rules behind any margin of blanks or tabs, and an ordinary block defines
  neither a label nor a symbol (D1054); on x86-64 the straight-line rule
  reads past instruction prefixes (D1117). An ordinary RV64 or RV32 block's
  text may name `zero`, x0, as a source and as a destination, though no
  operand may be placed there (D1320).
- **Stacks.** D450's stack builtins, `compiler.stack_prepare` and
  `compiler.stack_switch`, run on every target with a native backend. On
  Cortex-M0 a prepared stack runs on the process stack pointer, and an
  interrupt in a fibre runs its handler on the main one (D460, D461).
  Synthetic-32 refuses both builtins, where the program reaches them
  (D564): a module that offers a switch nothing calls is admitted.
- **Stack limits.** In a program that prepares a stack, every routine checks
  its frame against the current stack's limit in its prologue and traps
  D451's fifth panic kind, `stack_exhausted`, at its own site before it
  writes below the stack, at any depth. A switch carries each stack's limit,
  which stands a margin above its base for the handler (D471, D472). A
  selected handler that does not fit that margin, or whose calls the
  compiler cannot measure, is refused when the program is compiled (D474).
  A frame larger than the stack pointer's value is past the limit
  (D1111). On Xtensa a routine's outgoing argument area is part of its
  frame, so the stack pointer moves only in the prologue and the check, the
  build report and the stack report count the area (D1110), and a double
  exception records its PC from DEPC. A program that prepares no stack has
  no check. The limit is the running
  thread's own: ELF thread storage on Linux and FreeBSD, a pthread key's
  slot read directly on Darwin (D497, D506). Off Linux the default report
  claims a latch before it uses the one report stack, so two threads
  failing at once write one line (D498, D507).
- **Thread storage.** `link(thread) mut cell: T` gives every thread its own
  zeroed instance of a module binding: ELF local-exec thread storage on
  Linux and FreeBSD, which a static Linux program's start lays itself and
  `--link=libc` leaves to the C library, Darwin's thread-local variables,
  and ordinary module storage on Cortex-M0 (D496, D504); x86-64 reads and
  writes an instance through one `%fs`-relative operand. `hosted/system`
  keeps each thread's last errno and last signal so, and a handle from
  `system.new()` records into the calling thread's (D503, D509).
  platform/linux lays the block a new thread's `clone` takes (D504).
  An instance's address stored in a module binding without
  `link(thread)` is refused (D772).
- **Fibres on Cortex-M0.** On the retained Cortex-M0 profile a consumer of
  `core/fibre`'s round of turns, two fibres on 1,472-byte stacks cut from
  fixed module storage, fits with its painted peaks and D461's exception
  frame, and the Cortex-M lane reports its flash, static RAM, backing and
  verdict at every profile (D470).
- **Stack reports.** `--stack-report=PATH` writes, for every emitted routine
  on each of those targets, its frame and the deepest stack of the call
  graph it can close, and names each foreign call, recursion, runtime
  helper and stack-moving assembly that opens it (D447, D467, D468). Its
  `frame_bytes` is the build report's `stack_bytes`, the routine's whole
  stack, and not the build report's `frame_bytes`
  ([the compiler guide](../compiler/ada/README.md#the-build-report)). A
  call through `any`, a generic's table or a function value is counted as
  reaching every routine of the program it could call, so a fibre's task
  has a depth to size its stack from wherever nothing foreign is reached
  (D570).

`compiler/tests/constructs.matrix` records every normative construct's
state, targets and evidence, and `check.py` refuses a stale or unexplained
row.

## The library

The standard library comes with `refine`: `core`, `hosted` and `platform`
are found beside the executable. [The library overview](library.md)
introduces each module, and the site's
[library reference](https://www.701.dev/library.html) is generated from it,
the public signatures and their doc comments, with module browsing, search,
source links and examples taken directly from runtime fixtures.

### `core`

The shared `core/*` modules take arena and pool allocators and a failure
injector as arguments, as providers.

- **Memory and containers.** Raw memory, vectors, inline-prefix spill lists,
  maps, trees, and sorting by ordering evidence or by a comparison given a
  context. A pool grows a block within its slot. Containers share
  construction and release names, and vectors, spill lists and maps lend
  writable slots with `at` alongside copying `get`. `vec.append_bytes`,
  `text.append` and `text.format` accept the container's own bytes
  (D1122); `core/mem`'s `reserve_admit_copy` is the growth that copies them
  before the old block is released. An arena is an ordinary
  allocator, not syntax (D212).
- **Comparison.** The comparison concepts are a module of their own,
  `core/cmp`, with library-supplied evidence for integer keys and ordering,
  Boolean and byte slice keys, and UTF-8 keys and ordering.
- **Text.** Byte-oriented and validated text. Positions over `utf8` step
  a whole scalar and keep its byte offset, and searches for text or a
  scalar return where the match begins, so the parts around it are
  zero-copy `utf8` views of the source (D945, D946). A scalar encodes into
  a caller's buffer whole or not at all (D947). A builder over a caller's
  buffer, or one an allocator grows, takes bytes, scalars, text, host
  strings, decimals of every integer width and hexadecimal, aligned in a
  field, and a `utf8_builder` takes only text, scalars and numbers, so it
  always holds UTF-8 and lends it as one `utf8` view with no scan (D948).
  `compiler.utf8_unvalidated` makes such a view of bytes valid by
  construction, admitted only inside `unchecked` (D949).
  `text.format` fills a template's `{}` with any value that has
  `formattable` evidence, checked against its values when it runs, and
  `io.write_format` writes one to a file in a single call, through a
  128-byte store on its own stack that goes out whenever it fills, so a
  value of any length is printed on every target (D527). Every width
  parses back from bytes, and no locale is consulted.
- **Bytes.** Byte slices copy, with overlap allowed either way, fill,
  compare and search with their lengths checked.
- **Failures and panics.** Bulk cleanup, panic dispatch, the
  `any`-dispatched `core/diag.log` and, in `core/failure`, a phrase for a
  person for every library failure atom. A closed set of named values, such
  as a diagnostic's severity, is an atom set.
- **Serial lines.** `core/line` holds a UART line's settings, rate, data
  bits, parity and stop bits, and computes the divisor a PL011, an STM32
  USART or an Espressif UART is set to, refusing an unreachable rate, one
  more than two percent out, or a frame, with shared atoms and nothing
  written; it reads no register and runs on every target (D955, D956).
  The derived driver and every board port's serial module program their
  line through it. The STM32H753, ESP32, ESP32-S3 and ESP32-C5 change line
  during their runs over their tty bridges, a rate change and two frame
  changes each and two refusals, with the payload echoed; the Picos and the
  ESP32-C3 stay at their probehive bridge's fixed 115200 8N1, their line
  code checked by arithmetic and the derived driver's emulator register
  images only (D957-D964).
- **Random numbers.** `core/random` is a deterministic generator,
  xoshiro256**, seeded from a fixed seed or from entropy, which draws the
  same sequence on every target, Cortex-M0 included, with unbiased bounded
  draws and shuffles.
- **Atomic cells.** `core/atomic` holds a `u8`, `u16`, `u32` or `u64` in a
  cell whose operations carry their orderings in their names, with a
  relaxed family and the single writer's `sole_add`, a load and a store,
  on every target. Cortex-M0 refuses a `u64` cell and a read-modify-write
  where the program uses it, naming `sole_add` and the critical section
  (D500, D510, D511); RV32 refuses a `u64` cell at both levels and a
  read-modify-write at `rv32imc`, naming `rv32imac`, which admits it, the
  one checking rule a level decides (D690, D691).

### Providers

An allocator or an I/O provider is reached through a handle passed by
value over state its caller declares, so a program and its logger write
through one handle, and a region allocates beside its parent while both are
live; the checker ties neither up, and any lock is the provider's own
business. Each one has a caller-backed fake; the fakes of a system's
providers are `core/io/fake`'s, each named for what it fakes.

| concept | what it does | its fake |
| --- | --- | --- |
| reader, writer, file | caller-backed I/O; a streaming log needs only a writer; `write_format` writes a template and its values in one call, a buffered writer gathers many writes in a caller's buffer until it is flushed, and a line reader lends each line until the next read | the memory world |
| process | lends standard input beside standard output and error | the memory world |
| directories | lists a directory through a buffer its caller supplies, lending each name until the next read, and makes and removes directories and files | the memory world |
| environment | lends the read-only environment | an environment over data |
| programs | starts a program by its path with the arguments and environment its parent builds, each standard stream inherited, discarded or piped; reads its output and errors together while it runs, and waits for it to exit with a code or be ended by a signal | scripted programs |
| clocks, in `core/time` | a monotonic clock with sleeping and a wall clock, with time in nanoseconds in a `u64` and no floating point; on Linux the clock is read through the vDSO the auxiliary vector names, falling back to the system call | `fake.clock`, a manual clock |
| entropy | the system's entropy | `fake.entropy`, scripted entropy |
| network, in `core/net` | TCP and UDP over IPv4 and IPv6 that listen, accept, connect, send and receive, blocking the thread over `hosted/blocking` and letting other fibres run over `hosted/events`; address values read from and written to their text, an IPv6 address's zone among it, `fe80::1%eth0`, which the hosted providers turn into the interface's number and back (D581); time limits whose passing is an atom, a connection's own among them (D580); a connection read and written as a file, a line reader and a buffered writer among them | `fake.network`, loopback addresses in the caller's buffers, whose calls take turns where they would wait when it is given a `fibre.turns`, beside a `fake.clock` whose sleepers it waits for (D483, D493) |
| file system | opening with options, appending and exclusive creation among them, and a directory opened as a file refused as `io.is_a_directory`; renaming that replaces a taken name in one step; a status of size, kind, modification time and a read-only flag; read-only files, synchronizing, truncation, reading and writing at an offset; temporary files created exclusively under names drawn from entropy; the working directory's path | `fake.volume`, over the caller's nodes |
| terminals | whether a stream is one, and its size | `fake.terminals` |
| signals, in `core/io/signal` | the signals a server cares about, delivered as events: `signals` refines `fibre.turns`, so only a provider whose fibres take turns delivers them, and a fibre waits for the next one as for a receive (D477, D482) | `fake.signals`, those a test raises, on Cortex-M0 too |

The clocks, entropy, network, file system and terminals sit outside
`world`. A write to a peer that has gone is an error atom, since a hosted
process ignores SIGPIPE and gives its children the default back.

### `hosted` and `platform`

- `hosted/thread/lock` is a lock that waits through the system's wait on
  an address, beside the flag that a thread has started, and `hosted/heap`
  keeps its size classes behind it once one has (D501, D502, D513).
- `hosted/heap`, `hosted/system`, `hosted/blocking` and `hosted/events`
  supply the hosted heap, what the system offers that does not wait, the I/O
  provider that blocks the thread while it waits and the one that switches
  fibres, written once over `platform/posix` (D476, D478, D479).
  `hosted/events` is one handle over state its caller declares; it supplies
  every concept the blocking provider does, and `fibre.turns` and
  `signal.signals` beside them, on Linux over epoll and a signalfd and on
  Darwin and FreeBSD over kqueue. On Linux only the process's first thread
  may `signal.watch` (D1126). Its fibres take turns on a round whose
  wait, when every fibre waits, is the loop's wait for events, limited by
  the earliest deadline. A read, a write, a socket's accept, connect, send
  and receive, a child's pipes and end, a sleep and a signal each submit a
  record on the waiting fibre's own stack and are answered by the loop;
  closing or shutting a socket wakes its waiters with `io_failed`, and a
  child's end is a pidfd or kqueue's process filter (D485--D488). A pipe
  left blocking is written at most `PIPE_BUF` bytes a call, so another
  fibre of the same thread reading it does not hold it (D1045). A write to
  any other blocking descriptor except a regular file, such as a terminal,
  a socket or `/dev/null`, is refused with `io_failed`, since it could hold
  the thread (D1278).
- `hosted/thread` starts threads as a group a routine joins, made over a
  `hosted/system` handle, a backing the caller lends and a count, as
  `core/fibre` starts fibres: each task's stack is prepared and checked,
  the group keeps the first failure, a thread begins with every asynchronous
  signal blocked, and creation and join are the only edges it supplies (D494,
  D495). A static Linux program starts a thread with `clone` and waits on
  the word the kernel clears; under `--link=libc`, on Darwin and on
  FreeBSD the C library starts it on the caller's stack area and joins it
  (D517--D520). Each thread checks its frames against its own stack's
  limit, kept in its thread-local storage (D497).
- `platform/posix` gives POSIX in Landin types: files, directories, memory
  mappings, `poll`, non-blocking descriptors, pipes, spawning, waiting and
  sockets, Unix-domain ones
  among them; reading and writing at an offset, renaming, hard and symbolic
  links, permission bits, owners and file times; whole-file and record
  locks; terminals, their raw mode and pseudo-terminals; the user and group
  databases, read from /etc/passwd and /etc/group by a static Linux program
  and through the C library elsewhere; and shared objects loaded with the
  system's own loader, on Darwin, FreeBSD and Linux under `--link=libc`.
  It waits on and wakes an address, through the futex, `_umtx_op` and
  `os_sync_wait_on_address` (D512).
  Every descriptor is closed on exec, with a descriptor handle type and
  errno atoms that keep their numbers and have words for a person,
  `posix.words`, which passes the core library's failures to
  `failure.words` (D582). `duplicate_above` duplicates a descriptor at
  or above a number, clear of the standard streams with 3. `kill` sends a
  signal to a process it names, or to a process group as C's `kill` names
  one, zero for the caller's own and a negated leader's ID for another,
  refusing -1, beside `current_process` and the signal numbers (D1279,
  D1356). It sits over `platform/libc` on
  Darwin and FreeBSD and `platform/linux` on Linux. `platform/libc`
  installs a signal handler with `libc.handling(handler, flags)` and
  `sigaction`, its `signal_action` holding the handler's address, which a
  static Linux program cannot use (D1280, D1344).
- A hosted program started with SIGCHLD ignored gets the signal's default
  back at start, so it can wait for its children (D1125).
- A path, a process argument and a directory entry's name are host strings,
  never converted on the way through, with a checked conversion to UTF-8.
- `platform/linux` supplies Linux's system calls, epoll and signalfd among
  them, and the static process entry, with a raw `system_call` that reaches any call by the number
  `platform/linux/numbers` names, generated from a pinned kernel release.
  `platform/kqueue` supplies kqueue on Darwin and FreeBSD (D481).
  Linux executables link with no C library by default (`--link=libc` keeps
  it), through the first GCC a distribution installs that the host can
  start.
- `linker.library("NAME")` links a C library under `--link=libc` as the C
  driver's `-lNAME`, shared or archive, on every hosted target.
  `linker.directory("DIR")`, relative to its file, and a repeatable `-L DIR`
  on `check`, `compile` and `run` say where, `-L`'s first, and each is also
  the executable's runtime search path. A missing directory is refused
  before any tool runs, and a library a failed link cannot find is L0509,
  naming every directory searched. The static Linux link refuses all
  three. Firmware links each library as a static archive between its
  object and libgcc, with the directories ahead and no runtime path
  (D923), and refuses an image whose archives bring C constructors,
  thread-local storage or a dynamic linkage, with L0587 (D924).
- `platform/c` supplies aliases for the supported C ABIs, the four LP64
  ones and Cortex-M's ILP32 AAPCS32, and
  `platform/cortex_m` supplies M-profile CPU operations; it declares nothing
  on another target, so a program for every target imports it and calls it
  from a `fixed if compiler.arch == cortex_m0` arm (D575).
  `platform/cortex_m/l1` is the Cortex-M7's cache provider on a cached
  profile alone, and a call elsewhere says it is a cached profile's (D972).
- **Cache maintenance.** `core/cache`'s `maintenance` concept cleans,
  invalidates or does both to a range of whole lines, refusing one that is
  not with `cache.misaligned` and never rounding it, and its cacheless
  provider, the barriers alone, serves every target (D970).
- An import outside a module's target scope is refused by name, including
  through a project-root override.
- A failed check in a hosted program with no `panic_handler` writes its kind
  and source site to standard error before its terminal instruction;
  firmware keeps the bare instruction.

## The C boundary

- The C ABI of each hosted target, and `layout(c)`.
- C's byte-packed records as `layout(c, packed)` on every target, whose
  unaligned fields RV64 and Cortex-M0 move a byte at a time, and a
  last-field flexible array member, both passed to C by pointer.
- Callbacks and variadic calls, a C function value made from an address
  a loader found, and the address of a C function value, `usize(f)`
  (D1343).
- `refine bindings` ([`bindings/`](../bindings/README.md)) generates
  bindings, packed and flexible-member records among them and every pointer
  to a generated record typed to it, from an external
  Clang's view of a header, with nothing but refine and that Clang, for
  Linux x86-64, Linux arm64 and macOS arm64 and for Cortex-M's ILP32
  AAPCS32 in both procedure call standards; two committed Cortex-M bindings come from pinned CMSIS headers
  (D939). It binds a pointer to a pointer, a tag declared again after its
  definition, and the functions of the system's own `<string.h>`,
  `<stdlib.h>` and `<stdio.h>`, `strlen`, `malloc` and `printf` among
  them, passing over the attributes Clang itself adds and fifteen written
  kinds that say nothing of the call, and a function that does not return
  binds as `-> noreturn` (D1065, D1252); a C name that is a Landin
  scalar's is written `c_NAME`
  (D1066), and a record is laid out in the target's bytes, past 2 GiB where
  the target has room (D1067). Unsupported C forms are refused by name.
- A hosted entry may spell the linkage it has, `link(symbol: "main")`
  (D1113).
- Only the entry, C imports, public C definitions, link names and Cortex-M
  placements are global symbols. Every other routine and datum, public or
  not, is local to the image, so none meets the C library's names.

## Code generation

- **Determinism.** Target code and the build report are byte-identical
  whatever the build directory, environment or order, on all nine targets, with both Xtensa configurations;
  a hosted linked image without `--debug` is too, on one host's toolchain
  and under one output name (D810).
- **Switches.** D209 to D211 specify compact numeric-array arithmetic,
  explicit `layout(optimal)` field placement and optional evidence-proved
  specialization, which are independent switches. The driver selects
  size/auto by default; `--optimize=none --specialize=off` selects the
  reference, and `--build-report=PATH` requests deterministic off-target
  JSON, [whose fields the compiler guide lists](../compiler/ada/README.md#the-build-report),
  and whose every routine row counts frame, stack, saves, spills,
  registers, instructions, stack traffic and calls the same way on every
  backend (D791). Build mode remains independent.
- **The simplifier.** At size and speed it forwards a slot's value across
  writes that cannot reach it and computes identical operations and checks
  within a block once. Immutable module values fold, a check a dominating
  comparison proves is removed, and a callee reads an aggregate argument
  where its caller keeps it when nothing can change it.
- **Register allocation.** The x86-64 and arm64 allocators give slots
  registers over their live intervals, small routines' among them in
  caller-saved registers, floating-point values included. Both keep each
  routine's traps after its body, compute into a result's own register with
  immediate operands, fuse comparisons with their branches and fold indexed
  accesses into scaled operands.
- **At speed** a direct call to a small routine becomes a copy of its body,
  which the debuggers show as an inlined frame of that routine (D339);
  slices and small structs split into scalars; and a branch whose arms only
  compute becomes a choice (D338).
- **Reachability.** A program with a public `main` lowers, emits and
  assembles only the routines it can reach, so it pays for the library it
  calls rather than everything it imports. A firmware program emits every
  routine of the modules it imports, each in a section of its own, and its
  link drops the ones the image does not reach
  ([Cortex-M firmware images](targets.md)).
- `./scripts/quality.sh` measures the objects a built compiler produces, and
  [the Benchmark Game, measured](benchmarks.md) compares five ports, their
  running and their compile times, with seven other languages.

## Debugging

`refine compile --debug=full program.ldn -o program` requests source
debugging; the default is `--debug=none`, and debugging metadata is
independent of the program's optimization and source build-mode settings.
Add `--target=darwin-arm64` for native macOS output, then open
`lldb ./program`. See
[source debugging and identity](targets.md#native-source-debugging).

- **Per target.** DWARF and GDB on Linux; native LLDB in both FreeBSD VMs
  for source-line stops, frames, local values and unwinding; LLDB with dSYM
  and exact Mach-O identity on Darwin; and line and function debugging on
  Cortex-M0. Under `--debug=lines` a firmware image also names its module
  bindings with their types, so GDB prints one as it is (D1291). FreeBSD's
  LLDB sessions also run against Linux images with the
  development shell's LLDB, `compiler/tests/debugging/lldb_linux.py`, as
  feedback before the VM lanes run them.
- **Optimized code.** At speed a local held in a register is described past
  its last use until the register is written over, and the GDB and LLDB
  sessions read such locals there.
- **Stack switches.** A backtrace through a stack switch names the switch
  and start routines, `landin.stack_switch` and `landin.stack_start` (D469),
  and a scripted session on every target with a native backend steps two
  switches and holds the leaving and resumed fibres' frames at every
  instruction.
- **Names.** An atom set is described as an enumeration, so a debugger
  prints an atom's name, and a generic instance is a symbol named after its
  routine.
- **Library paths.** A library file is recorded as `/landin-library/` and its
  module path, never where the library was installed, which a session maps
  to the directory `refine version` names.
- Debug provenance stays independent of DWARF for a possible future PDB
  emitter; PDB is not implemented.

## Programs that run

- **Derived programs.** Programs derived from prototypes 2, 3 and 4 run as
  the recovering configuration parser, the container client and the log
  filter on every hosted target, with native debugging coverage. The one derived
  from prototype 1 runs as the
  [derived driver](../compiler/tests/driver/DERIVATION.md) on the Cortex-M0
  emulators, opening any line its PL011 can carry, whose register images
  the emulator's model holds to an oracle (D957, D964). Each runs against
  generated expected output. The driver and its
  application run with compiler-owned startup within the recorded 32 KiB
  capacity and source-debugging limits. The server derived from prototype
  5's hosted half runs on every hosted target from one source over both
  I/O providers, in a process of its own, asked by a client in another: over
  `hosted/blocking` it answers one request at a time and SIGTERM ends it,
  and over `hosted/events` two requests are in flight and its signal
  waiter stops it cleanly (D490). It also runs in one process over the
  fake network on a round of turns. Its firmware counterpart, derived in
  [`compiler/tests/counterpart`](../compiler/tests/counterpart/DERIVATION.md),
  takes the same two requests on prototype 1's synthetic serial line on the
  Cortex-M0 emulator, with a taker and an answerer fibre on `core/fibre`'s
  round and SysTick counted by `atomic.sole_add`, and answers them one at
  a time in arrival order; its recorded trace of when each request arrived,
  began and ended being answered is held to an oracle for that single-core
  answer at every profile, with controls that overlap, drop, trap and stall
  (D448, D1034, D1035). It takes about 56 KB of flash at `size`, so it runs
  on a description of the micro:bit's own 256 KiB nRF51822 rather than the
  32 KiB reference (D1036).
- **Example programs.** Every hosted program in
  [`examples.md`](../examples.md)
  runs on every hosted target against its recorded output: everyday tools,
  the printing and failure lessons, the classic exercises from FizzBuzz to
  merge sort, the sensor-polling program, and five Benchmark Game ports at
  correctness scale. Its firmware example builds for Cortex-M0 and is held
  to its serial output on the emulator.

## Where the evidence comes from

The recurring gate runs Linux and macOS programs natively, FreeBSD programs
in accelerated VMs and Cortex-M firmware under QEMU, with separate runtime,
C ABI and debugger verdicts; RV64 Linux runs under QEMU's user emulation, as
above. On a push to `main`, weekly and by dispatch it also runs all eight
board ports on the physical rig, each RAM run followed by its boot check.
The gate's scripts job holds every workflow to the pinned actionlint, which
runs the pinned shellcheck over every `run:` script. The
[gate reference](process.md#the-mechanical-gate) describes every job.
The recorded boundaries stand as measured: the 32 KiB capacity verdicts, linked again against RP2040's,
RP2350's and the STM32H753's derived scripts, the lines-and-functions Cortex-M
debugging contract and the macOS shared-region placement limit observed on
some hosts.

The Cortex-M lanes also run one thing at a time on a developer's Linux
host, under the same locked QEMU and GDB: a program of one's own at the
corpus's profiles, printing what it returned or where it trapped, a single
lane, a firmware case or an evidence control, each marked `FILTERED`; a
stack that overruns its reservation is named with its routine. On NixOS
they run from `nix develop`, re-running themselves inside its `landin-fhs`
FHS environment with the same locked binaries, and refuse outside it
naming that route
([the lane's guide](../environments/cortex-m/README.md#on-nixos)).

The test program lists a suite's cases as selectors with
`./scripts/dev-test.sh --cases=SUITE`, and its fixture comparison names
every differing fixture at once with the one `--record=` command. A
recorded report holds a library line by its text, so a moved library line
re-records nothing (D1306), and a runtime fixture may name the targets that
do not emit it yet with `not_yet_emitted`, which fails once one does
(D1308). The scripts, and every lane that takes `--refine`, warn when that
compiler was not built from the checkout's compiler sources (D1307).
