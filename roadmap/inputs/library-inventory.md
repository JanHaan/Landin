# The standard library: an inventory for R20

*A frozen input of the third roadmap, placed under `roadmap/inputs/` at the
exchange and trimmed to what its items cite. Of the gathered facts the
sections below cite as appendices A and B, only appendix B §5, where each
addition would live, is kept, since R22 cites it; the rest stay in the
planning record. It is not edited once the item that decides it is
complete.*

2026-11-16, over `origin/main` 29d4f681f. Read-only. Observations, not a
redesign: R20 designs. The facts were gathered by two subagents as
appendices A and B, with file and line evidence. The
findings and the questions above them are mine. The library is 107 `.ldn`
files in 48 modules: 26 under `core/`, 6 under `hosted/`, 16 under
`platform/`.

## Five findings

1. **The layers are clean, but two edges run against them.** There are no
   import cycles, and every module respects its namespace's availability
   class. But `core/failure` imports eight modules only to name their
   atoms in `failure.reason`. Three modules import it (`core/fibre`,
   `hosted/thread`, `platform/posix`), and importing `core/fibre` pulls in
   nearly the whole of `core`. And `platform/posix` sits above the
   protocol layer: it imports `core/io`, `core/net`, `core/text` and
   `core/failure`, so the system layer depends on the abstractions built
   over it. `hosted/events` bypasses posix for epoll and kqueue
   (appendix A §2, §4.7 item 9).
2. **Several concepts say one idea twice.**
   - `fibre.task` and `thread.job` have the identical entry and each has
     its own `launch` bridge.
   - `fibre.group_value` keeps both `any scheduler` and `any turns` with a
     flag, because `any turns` does not convert to `any scheduler`.
   - `io.writer.write` and `text.outlet.take` both consume bytes, with
     different receivers and failures.
   - The file operations are split over `files`, `file_system` and
     `directories`.
   - `io.world` has no entries, and needs `io.lent`/`writer_of` because
     `any world` does not convert to `any writer`.

   No library concept takes more than one type input. Three concepts have
   exactly one conformance, each a bridge an application never writes.
   `diag.log` and `io.world` are never required by a library routine and
   are used almost only erased, in the examples (appendix A §3.2).
3. **The same kind of capability is received in different shapes, and no
   rule says which.**
   - An allocator is a generic `provider: type is mem.allocator` in 44
     routines, but `any mem.allocator` in the text builder, which stores
     it.
   - A byte sink comes in four shapes: `any io.writer`, a generic writer,
     `any text.outlet`, and `any io.world` plus `lent_writer`.
   - Entropy comes in three.
   - Callbacks are a function value with a context in `sort.sort_by` and
     in `admit`, each hidden behind its own `launch`.
   - The examples erase with `any` what the library keeps generic
     (`any io.world` 30 times, `any net.network` 13).

   When to take `type is C` and when `any C` is the unwritten rule at the
   bottom of most of these (appendix A §4).
4. **The conventions are written down, and parameter order is not.**
   R13.11's conventions (D268-D271), R13.13's review (D274) and R13.17's
   services as handles (D288) are collected in `core/README.md:93-337` as
   twenty conventions. The later modules follow them closely. Departures
   are in parameter names (`caches`, `parent`, `runs`, `names`,
   `inner_provider` against the fixed `memory`, `host`, `state`, `self`)
   and in `X_of` conversions in `hosted/system`. `last_errno`/`last_signal`
   are written three times. Parameter order is stated nowhere: "subject
   first" appears only in D945, and D269 does not say it. The naming is
   uneven:
   - "absent" has seven atom names;
   - a count or length has about ten names;
   - giving storage back has about fifteen;
   - the end of an iteration is signalled five ways;
   - `used`, `new`, `at`, `host`, `space`, `cursor` and `entry` each mean
     two or more things, and `not_found` is two atoms (appendix B §2, §3).
5. **R22's additions fit the structure, and four of them need generated
   tables.**
   - Math and regex are pure freestanding modules (`core/math`,
     `core/regex`).
   - Float text belongs in `core/text` beside `numbers.ldn`.
   - Unicode, encodings and locale need generated data: UCD, the
     WHATWG/IANA code pages and CLDR.
   - The repository's way to generate data is a program run outside
     compilation, with its output checked in and held current by a check:
     `refine svd`, `refine bindings` and `scripts/linux_syscalls.py`. That
     is consistent with RP3, and D296 already drops unreachable table
     entries from an image.
   - Missing today: floats have no `cmp` evidence and are not
     `formattable`; `utf16` has no library at all; nothing in `core`
     carries a locale.

   Six Broader standard library rows (SR-96, 97, 98, 100, 285, 995)
   already describe these additions (appendix B §4, §5).

## Questions the review has to answer, ranked

1. **When does a routine take `type is C`, and when `any C`?** This one
   rule would settle finding 3 and most of finding 2's conversions. My
   default: generic in `core`, `any` only where a value stores the
   provider, written into `core/README.md`'s conventions.
2. **Should fibres and threads share one task concept, and one erased
   scheduler?** Default: one task concept in `core`. The group keeps one
   erased provider, and the language question of `any` conversion along
   parents is filed for R19 if R20 needs it.
3. **Should `core/failure` stop importing the modules whose atoms it
   names?** Default: keep the one registry, but measure what importing
   `core/fibre` costs a firmware image before deciding.
4. **Should `platform/posix` sit below the protocol concepts, not above
   them?** Default: yes, as far as its types allow: posix speaks
   descriptors and errno, and `hosted/system` adapts to `core/io`.
5. **How should the I/O concepts be grouped?** Default: keep them narrow
   (D268's firmware reason), and fix `world` so that `any world` gives each
   part without `lent`.
6. **One name per idea:** absent, out of room, end of iteration, length,
   giving back. Default: yes, as one breaking rename list taken in R20.
7. **Write parameter order down.** Default: subject first, then
   capabilities, then inputs, as most modules already do.
8. **How R22 gets its generated tables.** Default: one generator script
   per data source, with a pinned input hash as `devices/inputs.json`
   does, the output checked in and held by a check. No compile-time
   execution.
9. **Is a locale an explicit value passed like a capability?** Default:
   yes, as SR-98 says. No global locale.
10. **Do `core/random`, `hosted/thread` and `core/io/fake`, imported only by
    fixtures, have the consumers D1033 asks for?** Default: keep them, and
    give `core/random` and `hosted/thread` an example program.

---

## Appendix B §5. Where the additions would live and what they need

What exists today (survey):
- Floats: language arithmetic only (spec.md:3292-3309; `f32/f64.nan/infinity`, spec.md:1198); no `core/math`, no float text. Float square root is reachable only by assembler (tour.md:4971 `sqrtsd`); float bits by address
  (docs/from-c.md:1260). Firmware floats: Cortex-M0/RV32 soft float via libgcc (docs/capabilities.md:85-93); a float unit is a description fact (D615, spec.md:32414). `core/time` and `core/line` avoid floats (core/time/time.ldn:4, core/line/line.ldn:8).
  Floats have no `equatable`/`hashable`/`ordered` evidence (docs/library.md:380,431) and are "not formattable yet" (core/text/format.ldn:13).
- Text: `core/text/{text,builder,format,numbers}.ldn`; UTF-8 validation, byte/scalar positions, `find`, `encode`, builders, integer parse; `utf16` is a language type with no conversion and no library module (tour.md:2576-2600; no `utf16` in core/hosted/platform). No case mapping, normalization, grapheme/word segmentation, properties, collation, or encodings other than UTF-8/host-bytes: "It never normalizes" (tour.md:2637, docs/library.md:555). No Unicode data table anywhere under core/hosted/platform. No locale: "no locale is consulted anywhere" (core/README.md:309; docs/library.md:832, D388 "in every locale"). Calendars/time zones listed as missing (docs/library.md:259).
- Regex: nothing (SR-100). The only pattern-like code is `text.find` (Two-Way, D946) and `mem.find`.
- Generated sources already in repo: `refine svd` writes Landin register modules and `interrupts.ldn` from a hash-pinned SVD fetched by `scripts/fetch_inputs.py` per devices/inputs.json (devices/README.md:1-30; 13,271 lines under devices/generated; docs/capabilities.md:172); `refine bindings` generates C bindings (bindings/README.md:1; docs/capabilities.md:910); `scripts/linux_syscalls.py` writes `platform/linux/numbers/numbers.ldn` (2,108 lines) and `platform/linux/wrapped.ldn` from a hash-pinned kernel tarball, `--check` compares, and `scripts/tests/test_linux_syscalls.py` holds checked-in files to the generator (D294, spec.md:34115; scripts/linux_syscalls.py:1-60; gate job `scripts/tests` at .github/workflows/gate.yml:147). `docs/diagnostics.md` is built into Ada by `check.py --catalogue` (AGENTS.md table). RP3 (ROADMAP.md:4848) holds: no compile-time execution or macros; each generated file checked in and held current by a check; a general source-generator stage would be reviewed against RP3. Tour [1540] (tour.md:4426): "write a program that writes the source, and have the build run it."
- A generated table counts as one facility, not a name each, for the consumer rule: `LIBRARY_TABLES` in check.py:11136-11140. Unreachable module bindings and routines are not emitted (D296, spec.md:33654), which is what lets a program use part of a large table; the Linux numbers module is a module of its own so a thousand declarations do not enter every program (D294).
- Module-level constant tables exist only in small form (core/io/fake/signals.ldn:14, core/text/builder.ldn:515); the largest generated library module is `platform/linux/numbers` (2,108 lines).

Adding a module touches four places (core/README.md:473-499: `MODULES` in environments/cortex-m/freestanding.py, a `runtime/library-shared-NAME` fixture, its row in compiler/tests/cortex-m/corpus.json via scripts/add_fixture.py, a `## core/NAME` section in docs/library.md); a new public name needs a consumer (core/README.md:501-513); new module names avoid device nouns (D1316).

Per addition (module name is a suggestion that fits D274/D1316; nothing is decided):
- Math: `core/math` (SR-96), freestanding, written in Landin so results are target-identical; functions are plain `f32/f64 -> f64` with no allocator, handle or capability, like `core/random`'s pure draws; `sqrt`/`fma` need compiler support or `assembler.block` per target (as tour.md:4971). No data tables beyond small coefficient arrays. Firmware size check on Cortex-M0 libgcc soft float. If it needs bit access it needs `usize(addr x)` view trick or a builtin (docs/from-c.md:1260). Depends on nothing else.
- Float text (shortest round trip print, correctly rounded parse): belongs in `core/text` beside `numbers.ldn` and `builder.ldn`, not a new module: `text.formattable` evidence for `f32`/`f64` (entry `append(self: ptr item, inout into: builder) -> none ! no_space`, format.ldn:20-22), builder `append_f64`-style routines with the `no_space` failure, and `text.parse_f64` failing `invalid_number | number_overflow` (numbers.ldn:56 pattern). Needs 64-bit integer arithmetic only (D286 widths), possibly a table of powers (Ryu-style) or big integer scratch in the caller's buffer; no allocator needed if scratch is caller-supplied or on stack. Size on Cortex-M0 measured (SR-97). Hex float literals are a language item (SC-29). `docs/from-c.md` and `docs/library.md:48,758,799` currently teach the integer-scaling workaround and would change. SR-285 (template width/precision) is the formatting side.
- Text and Unicode (properties, normalisation, case): `core/text/unicode` submodule or `core/unicode` (SR-98 phase 1), written against `utf8` and `text.position` (D945), results into a caller `builder`/utf8_builder (D948, whole scalars) for case/normalization, no allocator unless a growing builder is passed (`text.growing`, erased `any mem.allocator`). Needs generated tables: Unicode Character Database (pinned release) via a checked generator, stored as checked-in `.ldn` (arrays of ranges/offsets), fetched by hash like `scripts/fetch_inputs.py` / `devices/inputs.json`, with a `--check` and a script test as `linux_syscalls.py` has, and a `LIBRARY_TABLES` entry (check.py:11136). Reachability (D296) lets a program use part of it. Needs a decision on table format (no tuple-of-arrays idiom beyond `[N]u8 = [...]` module values; large constant arrays have not been exercised) and on flash cost on Cortex-M0; the freestanding probe fixture will expose it.
- Character encodings: `core/encoding` (name fits a noun), conversions between `utf8`, `utf16` (language type with no library conversion yet, tour.md:2576) and legacy code pages; same pattern as `text.encode` (D947: whole scalar or nothing, writes into caller buffer, `no_space`/`invalid_scalar`). Legacy tables would be generated (WHATWG/IANA) the same way as Unicode data.
- Locale formatting of numbers: `core/locale` or `core/text/locale`; a locale is an explicit value from a BCP 47 identifier, never global state (SR-98; core/README.md:323 "no locale is consulted anywhere"); would sit beside `text.formattable` as evidence over a `distinct` wrapper or as `append_*_in(locale, ...)`. Needs generated CLDR data modules a program uses in part (SR-98 cites ICU4X), host-supplied locale name from `hosted/system` (new `io.environment`-like or `platform/posix` lookup). Phase 2 in SR-98; depends on Unicode and float text.
- Regex: `core/regex` (SR-100), freestanding, linear-time (Thompson/Pike or DFA), no backreferences; compile at run time with the allocator passed as `memory` (convention 8), results as positions (`text.position`) of matches so the text around is a range of the source (D946 style), failures via an atom set in `failure.reason` with words (D388). No data tables except Unicode classes if `\p{..}` is supported (then depends on the Unicode tables). Pin linear time on adversarial patterns on hosted and Cortex-M0 (SR-100 evidence).

Every new failure atom is added to `failure.reason` and `failure.words` (D388, core/failure/failure.ldn:20-80); evidence for new key types goes in their own module (core/README.md:331-334).
