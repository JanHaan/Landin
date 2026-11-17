# refine's commands: an inventory for R18

*A frozen input of the third roadmap, placed under `roadmap/inputs/` at the
exchange and trimmed to what its items cite. Appendices A and B, the
gathered facts the sections below cite as "appendix A" and "appendix B",
stay in the planning record and are not kept here. It is not edited once the
item that decides it is complete.*

2026-11-16, over `origin/main` 29d4f681f. Read-only: I built nothing. The
sizes are the `.text` of the object files in two existing build trees,
the debug tree at `59969d157` and the release tree at `a5838ccbc`. Both
match `29d4f681f`'s compiler source within eight files. The facts were
gathered by two subagents as appendices A and B,
with file and line evidence. The findings, classification and questions
are mine, and the classification is a proposal, not a decision.

## Five findings

1. **There are thirteen commands, and `build` is reserved.** They are
   `check`, `compile`, `run`, `fmt`, `explain`, `lsp`, `svd`, `bindings`,
   `site`, `version`, `targets`, `completion` and `help`. `check`,
   `compile` and `run` are one body (`Driver.Execute`). `check` also runs
   the backend, for the handler-fit check (D572), so nothing separates
   checking from compiling. The command set is a closed Ada enumeration,
   with no registry (appendix A §1, appendix B §0).
2. **What a command links is decided by a few `with` edges, not by what the
   command does.**
   - `lsp` links every backend and IR pass, because `Server.Analysis`
     uses `Driver.Checking`, whose body withs the backend for the same
     handler-fit check.
   - `fmt`, `explain` and `version` link the whole front end (30 units,
     5.9 MB of release text) only because `Driver.Library`'s body withs
     `Driver.Loading` for one path helper.
   - Cutting that edge alone would bring `explain` from 6.8 MB to 0.5 MB,
     `version` to 0.6 MB and `fmt` to 1.9 MB.
   - Already small and separate: `completion`/`help` (7 units), `targets`
     (11), `site` (9), `svd` (22) and `bindings` (21).
   - `bindings`' and `svd`'s own code is 1.8 MB and 1.0 MB of release
     text.

   Of the 36 MB release binary, the compiler proper (92 units) is
   18.6 MB of text (appendix A §3, §4).
3. **`refine NAME` with an unknown NAME is not an error today: it is the
   legacy bare-source form.** It means `refine check NAME`, with NAME read
   as a source file (`landin-commands.adb:329-336`). Cargo-style dispatch
   cannot be added until that form is retired. It is the one breaking
   change R18 cannot avoid.
4. **Discovery has a precedent, and D275 limits the choice.**
   - The library is found relative to the executable through
     `Landin.Platform` (`Driver.Library.Located`, `Executable_Directory`).
   - D275 refuses environment variables and configuration files as a
     second place to be wrong.
   - The flake already installs helpers in `$out/libexec/landin` and puts
     that directory on PATH by wrapper.
   - The assembler and linker driver are already found by PATH lookup.
   - So a `libexec/landin` directory beside the executable fits D275 and
     the flake, and a PATH lookup of `refine-NAME` fits contributed tools.
     Both together cost only an order rule.
5. **Most of the strict requirements reach an external tool only as
   black-box checks, and two do not reach it at all.** These carry over by
   parameterising existing scripts by command:
   - "destroys nothing it did not create" (`test_compile_publication.py`,
     `test_formatter_write_safety.py`, both taking `--refine`);
   - determinism (`test_determinism.py`, `emit_manifest.py`);
   - mutation in the way `fuzz.py` drives `lsp`;
   - the target manifests.

   These do not reach a separate executable:
   - the `Landin.Platform` rule and its fake filesystem, an Ada seam an
     external process does not have;
   - the closed diagnostic catalogue: `check.py` refuses an `L\d{4}`
     outside it, and no code namespace is reserved for another tool;
   - the warning policy, unless the tool is Ada and withs
     `landin_common.gpr`.

   Today help, completion, `refine explain`, `package.sh` (one binary,
   three namespaces) and the release smoke test each enumerate a fixed
   list (appendix B §1, §2).

The docs also disagree with the tool in seven places. Examples:
`refine targets --identify` is refused, though `docs/capabilities.md`
says it works; L0004 and L0009 send the reader to `refine --identify`
where help says `targets`; README's command table omits `targets`,
`completion` and `help` (appendix A §1.3).

## What "the strict requirements" are for a command today

- Every host effect goes through a `Landin.Platform` interface, and its
  driver cases run on the fake filesystem.
- Black-box native controls against owned roots and injected faults: it
  destroys nothing it did not create, and it reads only declared inputs,
  staged (D907) and in an isolated environment for the tools it runs
  (D821).
- Every diagnostic is a catalogued code, explained in
  `docs/diagnostics.md` with a compiled example.
- Output is deterministic across build directories, environments and the
  three hosts.
- The command runs in the gate's target matrix where its work depends on
  the target.
- Mutation evidence where the roadmap asks for it; today that is the
  `lsp` fuzzer.
- The pinned toolchain and warnings-as-errors policy.

A contributed tool could reasonably be released from all of these except
two, and only when it ships in the release archive: the black-box "destroys
nothing" control and determinism.

## Proposed classification

| Command | Proposal | Reason |
|---|---|---|
| `check`, `compile`, `run` | core | one body; the compiler itself |
| `fmt` | core | named core by the maintainer; small once the `Driver.Loading` edge is cut |
| `explain` | core | the diagnostics' own documentation; must know every shipped code |
| `version`, `help`, `completion`, `targets` | core | small; they describe the installation, and must list split commands too |
| `lsp` | undecided; default core | splitting saves no size (it links the whole compiler either way); it is the one command editors launch by name |
| `svd` | split | a generator with its own 1.0 MB of code, device inputs and its own tests; no front end |
| `bindings` | split | a generator that runs Clang (D821), 1.8 MB of its own code; no front end |
| `site` | split | a debugging aid, beside `dap`; 9 units, reads a map file |
| `dap` (new) | split | a long-lived adapter around GDB and LLDB, the first command written to the split's rules; it links the library for source maps and target facts |

"Split" here means a separate executable `refine-NAME`, shipped in the
same archive, that links the same static Ada library in lockstep. So no
stable interface is needed for the shipped ones. A contributed tool in
another language would need one: the JSON forms `refine` already prints
(diagnostics, `version --json`, the source maps) are the natural start.

## Questions for the maintainer, ranked, with my default

1. **Do shipped split commands link the same Ada library, built and
   released in lockstep?** Default: yes. A stable interface is only for
   contributed tools, and starts from the existing JSON outputs.
2. **Which discovery rule?** Default: `libexec/landin/refine-NAME` beside
   the executable first, found through `Landin.Platform` as the library
   is, then `refine-NAME` on PATH for contributed tools. A built-in always
   wins.
3. **May R18 retire the bare-source form `refine FILE`?** Default: yes.
   It is the one breaking change the split needs.
4. **What is a contributed tool released from?** Default: everything in
   the list above. A tool shipped in the archive keeps the black-box
   "destroys nothing" and determinism controls, run in the gate.
5. **What diagnostics does a split or contributed tool emit?** Default:
   shipped split tools keep `L` codes in the one catalogue. Contributed
   tools use their own prefix and answer `refine-NAME explain`, which
   `refine explain` forwards to.
6. **`lsp`: built in or split?** Default: built in.
7. **How do help and completion list external commands?** Default: help
   lists them under a heading of their own, read from a scan of libexec
   and PATH at run time; completion delegates to `refine-NAME --complete`
   in the shell, as git does.
8. **Cut the `Driver.Library` → `Driver.Loading` edge first?** Default:
   yes, as R18's first mechanical step, because it makes `fmt`, `explain`
   and `version` small regardless of the rest.

---
