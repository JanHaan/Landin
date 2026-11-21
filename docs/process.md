# Development and validation

The loop below is the one that runs now, and the
[gate reference](#the-mechanical-gate) describes its jobs and reuse rules;
`ROADMAP.md` owns the work left on this process. The gate is a safety net
rather than a verdict: green says a tree passed there, and nothing accepts a
revision. `D586` names a decision recorded in `spec.md`, and
`refine explain D586` prints its title.

Each `##` section has a byte budget that `python3 check.py` holds
(`PROCESS_SECTION_BUDGETS`). This file says what is done now and why;
an account of how a rule came about goes in its commit message, a figure
measured once goes in the commit or the measurement it belongs to, and a
section that would pass its budget sends its detail to the script's
`--help` or the subsystem's own reference.

## The loop that runs now

| stage | command | what it says |
|---|---|---|
| starting a roadmap item | `python3 scripts/item.py start ITEM` from the clone's main checkout | the item's worktree and branch from `origin/main`, its reserved identities, its status made active and the brief; [running an item](#running-an-item) says the rest |
| edit/test loop | `./scripts/dev-test.sh` with the affected exact `--suite`, `--case` and `--fixture` selectors in one invocation | checksum-safe feedback; the transcript says `FILTERED` |
| Mac compiler host | `./scripts/dev-test.sh --host --target=linux-x86-64` | compiler checks only; every selected case passes, and no Linux workload is emitted or run |
| another Linux architecture from this host | `./scripts/dev-test.sh --target=linux-arm64 --runner=qemu-aarch64` with the affected selectors, inside `nix develop` | a cross lane under QEMU: the emitted code's evidence, not the pinned toolchain's. The development shell has the cross driver under the name `refine` asks for; elsewhere `--toolchain=` names it, as [the lanes](../compiler/tests/README.md#lanes) say |
| before pushing a candidate | affected exact developer cases/suites and script controls; `python3 check.py` after documentation changes; `./highlight/test.sh --integration` when the grammar, `highlight/tree-sitter/`, a positive, runtime or ABI fixture or `core/` changed | focused feedback; the complete matrix runs once in CI |
| before pushing explanatory-only prose | `python3 check.py` and review the prose against what it describes | every document invariant and the accuracy of the explanation |
| after touching the harness | `./scripts/parallel-equivalence.sh --suite='fixture execution'` | a wider run reaches the same verdicts, byte for byte |
| before pushing a Darwin change | focused native Mac checks, with LLDB in an appropriate security audit session when affected | native developer feedback; full host/parity/debugger coverage runs in CI |
| candidate push or pull request | `.github/workflows/gate.yml` | every target, unless identical-tree reuse or an explanatory edit applies; the [job table](#the-mechanical-gate) says what each job runs |
| physical boards for a candidate | `item.py boards ITEM`, or `gh workflow run gate.yml --ref BRANCH -f scope=boards`, by the maintainer or an item's agent, once `main` is an ancestor of the head | each port's RAM run, then its boot check, on the rig through `environments/boards/gate.py`, with `inputs`, documents and scripts, and the timing jobs unless a dispatch on the branch already timed the same key (D1649); never a software pass. A run that failed in timing alone [re-runs its failed jobs](#a-timing-failure-is-not-a-boards-failure) |
| promotion to main | the [promotion rule](#physical-boards-and-promotion): the candidate's complete software gate, a passed boards dispatch on the same tree, or before only explanatory commits, then main's own push gate followed to its end; an item's agent promotes without asking again unless the item says `Promotion: maintainer` (`ROADMAP.md`'s Mechanics), in [the promotion queue's](#the-promotion-queue) order | the push reuses the full candidate software pass and takes the boards of the passed dispatch on the same tree, or before only explanatory commits (D1647); documents and script controls still run |
| closing an item | `python3 scripts/activations.py`, then the steps in [closing an item](#closing-an-item) | the register rows whose activation the item's changes met, and the passes only the gate runs that the changes reach |

Linux, Darwin and Cortex-M runtime and debugger evidence comes from the
gate, or from a host you run yourself; the
[gate reference](#the-mechanical-gate) says where each lane runs.

On a Mac, run `./scripts/dev-test.sh --host --target=linux-x86-64` with the
affected exact cases or suites, and expect every selected case to pass. The
host selector takes a suite or a case, not a fixture. The unfiltered
harness emits and runs Linux workloads and fails without their toolchain,
so a Mac runs no Linux containers, no Linux workload emission and no
repeated complete suites. With the default `darwin-arm64` build tag:

```sh
./scripts/dev-build.sh
LANDIN_TEST_JOBS=1 ./scripts/dev-test.sh --host --target=linux-x86-64 --suite=checking
```

A Darwin change receives focused checks on a Mac before it is pushed, and,
when a Mac is available, so does a change to the harness or to fixtures
the Darwin lanes run: `darwin-parity` and `darwin-host` are the lanes such
changes most often fail. The full Darwin suites run in the candidate's
gate. LLDB must inherit a graphical or terminal security audit session; an
arbitrary background session may not launch a debugged process, whatever
its debugger rights, while the hosted macOS image's runner session may.

For debugger changes, run an affected native workload/profile with
`scripts/debug.sh` after building this checkout's compiler. A second run
replaces its own earlier output; an `--output` naming any other nonempty
directory is refused. Full native parity and debugger matrices belong to
the candidate's gate, rather than every local editing loop.

Choose the smallest test that can expose the changed behavior first, broaden
only for another affected subsystem, and let the gate validate the final
candidate once. Run a complete local suite when an investigation needs it,
never as a mandatory step before pushing, and never as a substitute for the
multi-host gate. After any documentation change run the full
`python3 check.py`, then review the prose against what it describes: its
checks are mechanical and do not establish accuracy. There is no separate
lint or typecheck step: the pinned build treats every warning as an error
and enforces GNAT style checks. Do not silence a warning without a recorded
reason (`compiler/ada/TOOLCHAIN.md` holds the policy).

When a push is authorized, push the final candidate to a branch and let its
complete gate finish. A failed gate reports itself only when its last lane
ends, so follow it with `python3 scripts/gate_watch.py`, which returns at
the first failed job with its step and log command, and investigate the
log rather than rerunning the matrix; a pushed fix cancels the superseded
run. Promotion follows the [promotion rule](#physical-boards-and-promotion):
the candidate's complete software gate, a passed boards dispatch on its
tree, or before only explanatory commits, unless the edit is itself
explanatory, and `main`'s own gate followed to its end. A changed merge tree needs
new evidence; neither reuse condition ever takes local filtered transcripts
or build caches as evidence.

An item may close in the candidate itself or after its gate. A closing
commit made after the branch's full gate reuses that gate, on the branch and
again when `main` is promoted to it, only when it is an
[explanatory edit](#reusing-a-pass): confined to the files that rule
lists and declared `Gate: explanatory`. `docs/capabilities.md` and this
file are among them; `docs/commands.md`, `docs/library.md`,
`docs/format.md` and `docs/from-c.md` are not, since lanes read them, and a
close that changes one of those is a new tree with its own full gate.

The parallel-equivalence wrapper builds once under the standard mode lock,
then holds the same binaries across both runs. Its printed evidence directory,
or a new directory selected with `--output=DIR`, retains build output, both
raw stdout/stderr streams, exact commands, exit statuses and full diffs.
Verdict text is compared byte for byte; only the exact elapsed field of a
progress line is normalized. Matching case failures establish equivalence
but are printed explicitly and still need investigation.

Run the test program through `scripts/test.sh`, `scripts/dev-test.sh` or
`scripts/parallel-equivalence.sh` rather than as its binary directly: on Linux
they disable glibc's per-thread allocation cache in the fresh test process,
preserving other allocator tunables, so that the memory controls tell live
small allocations from freed cached blocks. Each measurement first checks
that a held 512-byte block is counted and that freeing it restores the
baseline exactly, and a direct invocation whose meter fails that check
refuses and names the launcher route. The initial build keeps its
inherited allocator settings; test subprocesses inherit the prepared test
setting. Ordinary `refine` invocations keep their defaults. The worker
comparison records the effective setting alongside each command.

## Running an item

`scripts/item.py` takes a roadmap item through the steps that need no
agent, and keeps its state where a reopened session finds it: under the
clone's common Git directory, `landin-items/ITEM/`, shared by every worktree
of the clone. The [landin-change skill](../.agents/skills/landin-change/SKILL.md)
puts the steps in order:

| step | command | what it does |
|---|---|---|
| start | `item.py start ITEM` | refuses a complete item or one with an incomplete dependency; makes `../Landin-ITEM` and its branch from `origin/main`; reserves blocks of decision, row and question numbers no other running item of the clone holds, which `register_next.py` then gives out first; marks the item active, moves a pointer naming it, commits that as `Gate: explanatory`; writes the item's brief |
| after a reopen | `item.py resume [ITEM]` | the worktree, every recorded run as running, finished or lost, the gate runs, the journal's last lines and the next step |
| along the way | `item.py note ITEM TEXT`, `item.py run ITEM NAME --limit S [--cwd DIR] -- COMMAND` | a dated journal line; a detached `run_logged.py` run kept in the state, in the item's worktree or DIR |
| push | `item.py push ITEM [--watch]` | refuses a stale `citations.txt`, which names the compiler sources' digest and so goes stale over a merge, and says how to regenerate it; pushes the head and records its gate runs as `gate` does |
| gate | `item.py gate ITEM [--main] [--watch]` | records the pushed head's runs, or main's after promotion, and follows them with `gate_watch.py --all` in a detached run; a failed boards run is named a timing failure when only timing jobs failed |
| boards | `item.py boards ITEM [--watch] [--unmerged] [--rerun-failed]` | dispatches `scope=boards` on the pushed head, records the run and with `--watch` follows it in a detached run; refuses while `main` is not an ancestor of the head, since promotion would refuse that tree (`--unmerged` dispatches anyway, for board feedback before the final merge); `--rerun-failed` re-runs only the failed jobs of a boards run that [failed in timing alone](#a-timing-failure-is-not-a-boards-failure) |
| merging main | `item.py merge-main ITEM [--no-queue]` | takes the [promotion token](#the-promotion-queue) and merges `origin/main`; when every commit it brings says `Gate: explanatory` and the merged tree has the candidate's gate key, the merge says it too, so the gate reuses the candidate's pass and its boards still count; otherwise it names the commits and paths that make the tree new. Conflicts stop it with the token held. `--no-queue` is for a merge mid-work |
| promotion | `item.py promote ITEM [--dry-run] [--partial]` | pushes the head to main only as the [promotion rule](#physical-boards-and-promotion) allows: a passed push gate on it with its whole job listing, boards on its tree or before only explanatory commits, main its ancestor, the item complete, the promotion token its own or free; refuses an item that says `Promotion: maintainer` |
| finish | `item.py finish ITEM` | once main's gate on the promoted commit passed: removes the worktree and the local and remote branch, gives up the promotion token, keeps the state under `landin-items/done/`; run from the item's own worktree it works from the clone's main checkout |
| watching items | `item.py status`, `item.py stalled`, `item.py queue [--wait ITEM \| --release ITEM]` | every running item and the token's holder and line; those nothing has moved for an hour, exit 1; the token's holder and line, waiting until ITEM holds it (exit 124 at `--timeout`, 270 seconds by default), or giving up ITEM's token or place |
| report | `item.py report ITEM` | a draft of [the report](../.agents/skills/landin-change/report.md), ending with the open questions the item asked and their defaults |

## Closing an item

Before an item closes:

1. Run `python3 scripts/activations.py --base REV`, with REV the commit the
   item started from (`main` by default). It lists every `open` or
   `scheduled` row under `roadmap/register/`, other than a `limit` or a
   `watch`, whose activation names a path
   the item changed since REV, uncommitted changes included. It also lists
   the passes only the gate runs that those paths reach: the editor
   grammar's corpus, `./highlight/test.sh --integration`, when the grammar,
   a positive, runtime or ABI fixture or `core/` changed; the flake's
   build when `flake.nix`, `flake.lock` or `environments/pins.sh` did; and
   `python3 scripts/actionlint.py` when anything under `.github/`, that
   script or the pins did. Take
   each listed row into the item, or restate its activation; run each listed
   pass inside `nix develop`, or add `--run` to have it run them. A row
   counts only the changes made after the commit that added it or last
   changed its Activation, when that commit is since REV: a change its
   writer had already seen is what the row was written about. Each listed
   row names the commits that met it, the rows left out for that reason are
   named, and `--whole-window` counts every change since REV for every row.
   A commit marked `[beside the row's statement]` was made on a parallel
   branch and merged, by the merge it names: it counts, but it may be the
   very change the row records, so read it before taking the row.

   It is a heuristic and says so: it matches paths an activation writes,
   in backticks or bare, base names of tracked files, Ada unit names and a
   few names of an area that always mean one file. A row that names an area
   in words is counted and not matched; `--unmatched` lists those rows, to
   be read against the item's changes by hand. A base name several tracked
   files share, such as `run.py`, matches none of them and is reported with
   the files it could mean, so write the path in the row. A directory
   written as an owner, "`core/io`'s `make_temporary`", is matched by every
   change under it; a row only such a directory matched is listed apart,
   to be read rather than taken.
2. When the item changed the compiler's lowering, emission or backends,
   added a target or added positive fixtures, run the three checks only the
   gate otherwise runs on them, each of which has found defects after a
   merge: the build-modes comparison, which needs the debug and the release
   compiler of the same tree (`./scripts/dev-build.sh`, then
   `LANDIN_BUILD_MODE=release ./scripts/dev-build.sh`); this host's
   manifest, which every positive fixture must emit or refuse as expected
   on every target, and which the gate's `determinism` job compares across
   hosts;

   ```sh
   python3 scripts/emit_manifest.py modes \
       "compiler/ada/build/$LANDIN_BUILD_TAG/debug/bin/refine" \
       "compiler/ada/build/$LANDIN_BUILD_TAG/release/bin/refine" .
   python3 scripts/emit_manifest.py emit \
       "compiler/ada/build/$LANDIN_BUILD_TAG/debug/bin/refine" . \
       "$(mktemp -d)/manifest.json"
   ```

   and `./scripts/scaling.sh`, alone on its host, since it measures time.
   When the item's exit evidence is that firmware images are unchanged, or
   changed only where it says, run the lanes once with the item's starting
   compiler and once with its own, and compare the two output trees with
   `scripts/compare_images.py`, as
   [comparing the images two compilers link](#comparing-the-images-two-compilers-link)
   shows.
3. Write the `Done:` paragraph, naming in it and in the commit message the
   findings the item fixed rather than filing them. Delete the file of each
   register row the item settled, saying why in the commit message, and file
   only what outlives the item, as `ROADMAP.md`'s mechanics ask: `python3
   scripts/register_next.py --file` writes a new row under the next free
   SR number, with its keys to fill in. Then run
   `python3 check.py --register` for the generated `roadmap/register.md`.

   `python3 check.py` refuses a register over its cap of 60 open rows, so
   an item that would close over it first schedules, settles or puts to the
   maintainer enough rows. It also refuses an open row that has stood
   through more than ten completed items since it was filed or last kept:
   schedule it on an item whose text names it, put its retirement to the
   maintainer as a question under `roadmap/questions/` (`python3
   scripts/register_next.py --question --file --asked-by ITEM` writes
   one with the parts to fill in), or keep it with a
   body line `Kept: ` and one sentence saying why, which restarts its
   count. The age is read from Git's history and is not checked in a
   shallow clone; the gate's `documents` job fetches the whole history
   for it, and a local check needs a full checkout.

   Update the pointer in `README.md` and `handoff.md` too. It names the
   serial lane's item alone, the first in execution order that is active
   or planned with its dependencies complete, even while other items are
   active beside it, as `ROADMAP.md`'s Mechanics say. Substitute the item
   identity and title in these exact forms. Use the current form when that
   item is active, the next form when it is planned, and the endpoint form
   only when all roadmap work is complete:

   ```text
   **Current roadmap work: ITEM — TITLE.**
   **Next roadmap item: ITEM — TITLE (planned).**
   **Roadmap endpoint: ITEM — TITLE (complete).**
   ```

## Local agent feedback

Gather independent searches and reads in one tool response before deciding
what to change. Run dependent steps in order, and keep checks that share
mutable build outputs within the existing lock and worker limits. Preserve
the same model, reasoning effort, required checks and review depth when
reducing orchestration overhead.

Several exact suites or cases can be selected in one developer invocation.
The wrapper performs the build check once, then the harness runs the union
of the selections. Do not replace that union with a narrower selection to
make feedback faster. `--fixture` repeats as well, and may join them: each
named fixture executes in turn within one case.
For example, on the appropriate Linux development host:

```sh
feedback_parent=$(mktemp -d)
nix develop -c python3 scripts/run_logged.py \
    --output "$feedback_parent/checking-and-lowering" -- \
    env LANDIN_TEST_JOBS=1 ./scripts/dev-test.sh \
        --suite=checking --suite=lowering
```

Choose the selectors for the change. `dev-test.sh` checks its own build;
a preceding `dev-build.sh` is useful when compilation feedback is needed,
rather than a mandatory separate step before each suite. Leave its worker
count at the project's `-j0`, every core, and add no `taskset`: a build of
the whole compiler at `-j4` takes 2.6 times as long as at the default on a
32-core host, and the kernel shares the cores between concurrent builds
better than a `-j` or a `taskset` chosen for each one. When several related commands are necessary, enter
`nix develop` once and run them inside it. Use `sh -eu -c` for dependent
commands, so an earlier failure stops the sequence.

A `refine` from a sibling checkout or an older build is easy to pick up,
and its refusals look like the current compiler's. After a developer
build, `dev-build.sh` and `dev-test.sh` ask the binary what it was built
from, and so does every lane that takes `--refine`, as it reads the
argument: each takes it from `scripts/lane_refine.py`, which a new lane
uses too. `python3 scripts/refine_revision.py --refine PATH` asks for any
other.
`refine version --json` names the revision, whether that tree was dirty
and the digest of the compiler sources the binary was built from, and the
digest decides: a binary built from the checkout's compiler sources is
current, whatever its revision says. Any other gets one `landin:
warning:` line on standard error saying how it parts from the checkout:
older, when it was built from an ancestor of HEAD, or from HEAD with the
tree's uncommitted edits made since; newer, from a descendant of HEAD;
and from another line of history, or from a revision the checkout lacks,
which is neither (D1307). A split command, `refine-NAME`, is asked
`--describe` and judged by the digest it names; its revision is the one
of the `refine` installed beside it, when that has the same digest. The
warning changes no status, and `refine` itself never reads git.

A lane that runs `svd`, `bindings` or `site` takes either binary as its
`--refine`: given `refine` it runs `refine svd ...`, given the split
command's own `refine-svd` it runs that directly, and a case that needs a
built-in command uses the `refine` installed beside the split
(`lane_refine.command` and `lane_refine.dispatcher`).

The test program's workers are another matter, and a brief names them.
`LANDIN_TEST_JOBS` splits the corpus fixtures across workers, which is most
of what the suite costs. It is one by default and reaches only the two
corpus-wide cases of `fixture execution`; a run that selects that suite, or
runs the complete one, sets `LANDIN_TEST_JOBS=8`, since at one worker it
runs for hours on a loaded host. `scripts/parallel-equivalence.sh` is what
holds a wider run to the same verdicts. The `checking-and-lowering`
example selects two suites it does not reach, so the count there changes
nothing.

`./scripts/dev-test.sh --cases=SUITE` lists a suite's cases as `--case=`
takes them, so a brief's exact selectors are read from the test program
and not from a suite's source.

An agent harness runs every command in a fresh shell, and `nix develop -c`
evaluates the flake before each one, about two seconds a command.
`scripts/agent_env.sh` evaluates it once per `flake.nix`, `flake.lock` and
`environments/pins.sh`, writes what the shell exports to a file under
`~/.cache/landin/agent-env/`, and prints that file's path; sourcing it takes a
few milliseconds and leaves `TMPDIR` alone. Where there is no nix, or the
toolchain on `PATH` is this checkout's shell or no flake's, it prints
`/dev/null`, so `. "$(./scripts/agent_env.sh)"` holds in either shell. The
flake's shell exports `LANDIN_ENV_KEY`, the key the helper computes; when
the toolchain on `PATH` is another checkout's shell, whose flake or pins
differ, the helper says so on standard error and prints this checkout's
file, whose tools then come first on `PATH`. Claude Code takes the file
through a SessionStart hook in its settings, which then
reaches every Bash command of the session and of its subagents:

```json
{"hooks": {"SessionStart": [{"matcher": "", "hooks": [{"type": "command",
  "timeout": 180,
  "command": "s=\"$CLAUDE_PROJECT_DIR/scripts/agent_env.sh\"; e=\"$CLAUDE_ENV_FILE\"; [ -x \"$s\" ] && [ -n \"$e\" ] && f=$(\"$s\") && [ -n \"$f\" ] || exit 0; m=\"# landin agent_env\"; for o in \"${e%/*}\"/*-hook-[0-9]*.sh; do [ \"$o\" = \"$e\" ] || ! grep -q -e \"^$m\" -e \"^export LANDIN_ENV_KEY=\" \"$o\" 2>/dev/null || : > \"$o\"; done; : > \"$e\"; n=$(cat \"${e%/*}\"/*-hook-[0-9]*.sh \"$f\" 2>/dev/null | wc -c); if [ \"$n\" -lt 65536 ]; then { echo \"$m $(cksum < \"$f\")\"; cat \"$f\"; } > \"$e\"; else echo \"landin: the pinned environment is not loaded: with it this session's hook scripts would hold $n bytes, past the 64 KiB that leaves a command room in Linux's 128 KiB for one argument; start a fresh session\" >&2; fi; exit 0"}]}]}}
```

Claude Code keeps the file a hook writes, one per hook position in the
session's directory under `~/.claude/session-env/`, across a resume, which
runs the hook again and appends to it, and writes another under a new
number when the hook's position moves. Before every Bash command it puts every one of those
files, verbatim, into the single `bash -c` argument that runs the command,
and Linux refuses one argument over 128 KiB with E2BIG, "Argument list too
long". So the hook replaces its own file with the one environment of the
checkout the session started in, empties any other of the session's files
that holds a Landin environment, and writes nothing when the session's
files with it would pass 64 KiB, saying so: an environment is about 23 KB,
and the rest of the argument is Claude Code's own preamble, under 1 KB, and
the command. A session's files therefore hold one environment, whatever the
number of resumes. `scripts/tests/test_agent_env.py` runs the command above
as written here, and `python3 scripts/agent_hook.py --install` writes it
into `~/.claude/settings.json`, where one copy serves every checkout and
worktree and does nothing in a project without `scripts/agent_env.sh`;
`--check` names a copy older than this one, which can break every command
of a session, so run it after this command changes.
The file is the environment of the checkout the session started in; in a
worktree whose flake or pins differ, `. "$(./scripts/agent_env.sh)"` run
there adds that worktree's. The hook is
local to Claude Code and is not installed by cloning the repository. In
Codex, whose commands may each start a fresh shell, source the helper's
cached exports before commands that need the pinned tools:

```sh
landin_agent_env=$(./scripts/agent_env.sh)
if [ -n "$landin_agent_env" ]; then
    . "$landin_agent_env"
fi
```

With nothing to add the helper prints `/dev/null`, which sources as
nothing; the snippet's `-n` test only guards against a helper that failed
and printed nothing. Re-run it after changing the flake or pins.

In Claude Code, launch the long command through Bash's `run_in_background`
facility and use its completion notification. For a remote handoff, request
the host tool's completion notification. Continue independent work while it
runs; do not launch shell loops that sleep and probe logs. In Codex, keep
the session id returned by a yielded shell call and use its native process
continuation tool until completion; a running command alone is not evidence
that the agent will resume after ending its turn. When notifications and
native continuation are unavailable, block on the logged run itself:

```sh
python3 scripts/run_logged.py --wait "$feedback_parent/checking-and-lowering"
```

It returns the run's summary and exit status once `result.json` exists. After
270 seconds by default it exits 124 and prints the log's last line instead,
so the same call is made again. The default is under five minutes because
that is how long a subagent's prompt cache lives: a wait that returns inside
it costs a cached read of the conversation, and one that outlasts it costs
the whole conversation again at full price, which
`scripts/session_report.py` counts. Give the tool call that makes the wait a
limit above the wait's own: Claude Code's Bash tool stops a call after 120
seconds unless told otherwise, so the default wait needs its `timeout` set
to 300 seconds or so. Choose a shorter wait where the calling tool's limit
is shorter: a tool limited to 60 seconds can use `--timeout 45`. A tool that yields a process session can
resume that session instead of opening another wait. Exit 124 means the
logged command is still running, not that it failed.

A session that is reopened ends its background commands: a restart, a
resume and a change of account each do it, and a suite an hour in is lost
with nothing in the conversation saying so. Start a run that must outlive
that with `--detach --limit SECONDS`:

```sh
python3 scripts/run_logged.py --output "$feedback_parent/full-suite" \
  --detach --limit 7200 -- ./scripts/dev-test.sh
python3 scripts/run_logged.py --wait "$feedback_parent/full-suite"
```

It returns at once and the run goes on in a session of its own, which
`--wait` attaches to from the old session or a new one. Nothing ends such a
run by accident, so the limit is required: past it the wrapper ends the
command and `result.json` says `limit_reached`. `--stop DIRECTORY` ends it
early. A detached run sends no completion notification; in a main session,
put the `--wait` itself in the background to get one. A run whose wrapper
died without a result exits 125 at once. Those two statuses are the wait's
own: a finished run whose command itself exited 124 or 125, as `timeout`
does, makes the wait exit 1 and say so, and the first line it prints is
`state=finished`, `state=running` or `state=lost`. Do not wait with `sleep`
loops over the log, nor with `pgrep -f`, whose pattern also matches the
waiting shell's own command line, so the wait never ends. A live progress
inspection is appropriate when diagnosing a stall, rather than as a timer.

A harness limits how long a background command may run, two hours in
Claude Code, and stops it there. `./scripts/parallel-equivalence.sh
--suite='fixture execution'` runs the suite twice, the first time on one
worker, and takes about two hours on a loaded host. Start such a run in a
session of its own, so that it outlives the command that started it, and
wait on its directory:

```sh
setsid nohup python3 scripts/run_logged.py \
    --output "$feedback_parent/equivalence" -- \
    ./scripts/parallel-equivalence.sh --suite='fixture execution' \
    > /dev/null 2>&1 &
python3 scripts/run_logged.py --wait "$feedback_parent/equivalence"
```

The wait is the repeated call above. A detached run sends no completion
notification, so a turn that needs its result stays open on the wait.

Independent work beside a running build may edit and commit any tracked
file the compiler is not built from: a document, a fixture, a library
module, a script that is not the build's own. The build then ends
verified as of the tree it began from, saying `the checkout changed while
this build ran, in nothing the compiler is built from`. An edit to what
the build reads fails it at its end, exit 1, with `sources changed while
this build ran` and the files it found changed: a source or project file
under `compiler/ada`, or one of the build scripts `scripts/build_identity.py`
lists as `BUILD_SCRIPTS`. Running it again recompiles only what changed,
so such an edit either waits for the build or accepts the rerun.

A commit or a document edit also changes the next build's manifest, since
`refine --version` reports the revision and whether the checkout is clean.
That build says `the checkout changed since the last build, in nothing
the compiler is built from`, names what moved, and recompiles the
provenance unit alone; `source content changed` now means a file the
compiler is built from, and is followed by its name.

`scripts/run_logged.py` requires a new output directory and writes complete
combined stdout/stderr to `command.log`. It prints paths, elapsed time, CPU
time, peak child RSS and the exit status; on failure it also prints a bounded
log tail. `result.json` records the argument vector, working directory,
timestamps, resource measurements and status. Cancellation forwards SIGINT
or SIGTERM to the command's process group and records the resulting status.
It executes arguments directly, without interpreting them as shell text.
A shell explicitly passed to it still owns its pipeline semantics: avoid
filtering a check through a pipeline that loses the check's exit status.

The log remains the source for warnings, failures and selected scope. Inspect
those after completion, retrieving detailed sections as needed, and report
`FILTERED` or `HOST-ONLY` when applicable; the
wrapper does not turn a focused check into complete-suite evidence. Retain
full diagnostics even when returning only a concise summary to the main
agent. CPU time includes reaped children; peak child RSS is a process peak,
not the simultaneous memory of all workers. These measurements can identify
expensive commands, but do not establish a CPU or SSD bottleneck alone.

`scripts/test.sh` builds and runs the complete Linux test program.
Staleness is decided by source checksums, not timestamps: `build.sh` rebuilds
from clean when the manifest disagrees, because an edited-and-reverted file
keeps a newer mtime than the object built from it and gprbuild would serve the
stale object. The developer wrappers instead pass the pinned GPRbuild's `-m2`
checksum mode; source inventory or project-file changes still force a clean
tree, and a failed developer build is resumed rather than cleaned. A clean
tree keeps `bin/` and `libexec/`: executables are linked into `link/` and
published into `bin/` by a rename, only while no corpus lane or manifest run
holds the build's readers lock (`scripts/build_lock.py`). Each split command
`compiler/ada/split-commands.json` lists is built with `refine`, with or
without `--compiler-only`, and published as `libexec/landin/refine-NAME`,
the directory there even when the list is empty, as in a release archive
([split commands](../compiler/ada/README.md#split-commands)). A compiler-only build records `refine` as current without claiming that
`landin_tests` is current; the next full build still builds the test program.

`check.py` uses only the Python standard library and changes to its own
directory, so it can also be invoked by absolute path from elsewhere. It is
a heuristic invariant checker, not a parser, compiler, formatter, or
semantic test suite. Checking a single file, `tour.md` by absolute path for
instance, does not run every citation check, so a documentation change
runs the full command.

## Parallel sessions and shared resources

Name one integrator for each candidate and one owner for each resource the
work shares. Independent tasks may have separate integrators; coordinate
their final promotion when both target main. These are task assignments,
not a new authority for work: language decisions and unfinished work still
belong in the specification and roadmap.

### Worktrees and branches

Give every writer its own worktree and branch from an explicit starting
commit. Paseo's `create_agent` defaults to the caller's workspace on this
host, so a new chat alone gives no source isolation. Prepare the worktree
before handing it to a local child and pass its `cwd` explicitly. For
example, after fetching and choosing the intended base:

```sh
base=$(git rev-parse origin/main)
git worktree add -b task-parser ../Landin-task-parser "$base"
```

On another host, discover the actual checkout and available provider;
paths and installed tools differ. Establish an isolated worktree or
throwaway clone there before edits, rather than borrowing an active
checkout. Read-only investigation may share a checkout when its source
snapshot is clear; a run that changes build outputs must respect the
existing build locks and its checkout's ownership.

A harness may cut a child's worktree from another commit than the one its
brief names, an agent's isolated worktree from `origin/main` for one, so
the brief names the base commit and tells the
child to check it before reading anything:

```sh
git merge-base HEAD BASE
```

When that prints the named base, the worktree holds it. When it prints
another commit and the branch has no work yet, the child runs
`git reset --hard BASE` in its own worktree and checks `git rev-parse
HEAD`. A child that cannot move its branch stops and reports the commit
it started from, so that the integrator takes its diff against that
commit and not against the named base.

Assign owned paths, branch, base commit and nonoverlapping decision,
diagnostic and register ranges in the brief. Check the integration branch
and active streams before allocating identities. Announce overlaps before
editing shared documents. Separate worktrees still share Git refs, so do
not check out, reset, rebase, clean or remove another session's branch or
worktree. Retain unrelated working-tree edits. Report a commit as an
immutable handoff; further changes get a new commit and an updated handoff.

### Integration, publication and CI

Say who may commit, push stream branches, update the integration branch and
promote main. Carry existing user authorization into each brief; do not
ask for it again at every handoff. A stream can finish with a local commit
when its integrator owns publication. Merge each stream's branch with Git, so
staged additions and removals survive, and reconcile semantics and
fixtures as well as textual conflicts. When a stream's work is passed as a
patch instead, make it with `git add -N . && git diff HEAD --binary`:
`git diff --binary` alone compares the working tree with the index, so a
change already staged, a file removed with `git rm` among them, is silently
missing from the patch.

A generated file is never merged by hand. `python3 check.py --help` lists
them. Every stream that adds a decision to `spec.md` rewrites one,
`citations.txt`, the data `refine explain` reads a construct or a decision
from (D1240), and so does every stream that changes a compiler source,
whose digest the file's second line names (D1357); it is no compiler
source, and `.gitattributes` merges it by union, so two such streams
neither conflict there nor rebuild. Each stream
regenerates in its own worktree, since its own `check.py` needs the files
current. The integrator regenerates for the merged tree: resolve the
documents, then run `python3 check.py --generate`, which writes every
generated file from them whatever state a merge or a conflict left it in,
and add the result. A union merge can leave `citations.txt` out of order,
or with two source lines, which the full `python3 check.py` reports as
stale until that run. The
compiler is rebuilt only when a generated compiler source changed, which a
diagnostic's explanation in `docs/diagnostics.md` still does through
`landin-diagnostics-explanations.adb`; `--suite=catalogue
--suite=diagnostics --suite=commands` are the suites that read it, and
`--case='driver/explain answers citations'` reads `citations.txt`.

The integrator owns the candidate and its gate watcher. Push once the
affected checks pass; further local lanes run beside that gate. A stream
does not need its own full CI matrix merely because it has a branch. Use a
separate stream gate when it supplies evidence the work actually needs.
Track the exact candidate commit and full run, and use
`scripts/gate_watch.py --all` rather than starting a watcher per child or
dispatching a duplicate run. A newer push to the same branch cancels its
superseded gate.

Rebasing a private branch before handoff can update its base. Coordinate a
rewrite once another session depends on its commits; never silently change
what a reported commit denotes. Fetch main again before promotion. If it
advanced, integrate its changes and obtain the gate evidence for the
resulting tree under the [reuse rules](#reusing-a-pass). A green gate
on a stream's old tree does not cover a changed merge. Promote the tested
tree with a normal fast-forward push; a rejected race calls for another
fetch and integration, not a force push. Remove only the task's refs and
worktrees after their owner has released them, comparing GitHub and the
mirror first, as the next paragraph says.

GitHub is canonical and takes pushes directly; git.sr.ht is a mirror, kept
in step by a second push URL on the same remote rather than by a job. The mirror therefore holds only what a
push through that remote sent it: a branch or tag made on GitHub itself —
the release tags, a branch opened from the web — is not on it, and a ref
deleted on GitHub alone stays on it. A deletion reaches it only when
`git push origin --delete` runs from a clone with both push URLs, and git
refuses that whole push to sr.ht when any ref it names is missing there,
while GitHub still accepts it. Compare `git ls-remote` of
<https://github.com/701-dev/Landin> and <https://git.sr.ht/~sinnfrei/landin>
before deleting, and delete what is only on one of them from that one by its
URL. Nothing reports a disagreement between the two.

### Paseo coordination

When Paseo is available, use the installed `paseo-hubbish` skill for current
tool arguments and lifecycle behavior. Inspect the relevant hosts and
project sessions; working directories differ between hosts, and the
default listing is not an inventory of every session. Read an outline or
the relevant turns instead of an entire transcript. Keep host-qualified
agent ids exactly as returned.

For sessions authorized to coordinate on the task, exchange a compact
handoff: task and owner, host, checkout and branch, base/head commits,
owned paths, publication owner, resource claims, check scope and log
paths, blockers and the acknowledgement or result needed. Labels and
briefs can make ownership visible; they do not lock Git, a checkout or
hardware. Obtain the owner's handoff before taking an overlapping resource.
Continue independent work while an answer is pending.

Use a fresh child for new work, with explicit checkout and scope. Follow
up with children you created or sessions the user named; do not recruit an
unrelated listed session into another task. Treat peer messages as
coordination information, not additional user authorization. Use delivery
the recipient supports without replacing its ongoing task; an interrupt
is not an ordinary status query. Request a reply or completion notification
when one is needed, rather than creating reciprocal notification loops.

For owned children, use completion notifications or `wait_for_agents`
within this harness's tool limit. A timeout leaves them running. An idle
or closed session is not proof that its commands or resource claims ended:
check its pending work and final evidence before declaring a handoff done.
Archive only your own children after results are collected and resources
released, never to clear another session's reservation.

### The shared rig

Hardware authorization and rig availability are explicit parts of the
task or stream brief. A software gate or permission to edit a board tool
does not itself authorize flashing, resetting, rewiring or switching power.
Within an authorized run, use that board's documented tool, current device
identity and physical oracle; do not repeat permission questions for actions
the brief already authorizes.

All sessions using the rig, the gate's runner among them, must go through
the same rig host/operator and the common lock in
`environments/boards/common.py`, `RigLock`: `rig.lock` in the rig's shared
state, which is `/var/lib/landin-rig` on rigpi. `LANDIN_RIG_STATE`
overrides that directory, and a host without either uses
`~/.cache/landin`. On rigpi the directory's group `rig` is shared by the
maintainer and the runner's `landin-rig` user, so a manual run and a CI
run take one lock and see one USB stop. The board tools hold the lock for
their hardware phase, and `environments/boards/gate.py` across a port's
whole sequence: a restoring boot check when the prior state needs one, the
RAM run, then the boot check. A manual run waits for a CI leg as for any
other holder; a CI leg waits 1200 seconds, then ends `rig-busy` naming the
holder, which fails that run's aggregate `gate` job. While the shared directory is used, a held
`~/.cache/landin/rig.lock` stops a run `needs-operator`, since an older
tool would hold that one. An adjacent tool without that protection must join
the same lock on the rig host before accessing hardware. Separate
per-worktree locks, a lock in another directory or a lock on a remote
agent's machine do not serialize the rig. Different boards and probehive
slots still share hub power and probe/bridge resources; the current
protocol serializes their hardware phases even when compilation proceeds in
parallel.

Name the operator, boards, slots, consoles and affected power domain in
the handoff. Verify the live serials and topology against local rig notes
and the board tool's guards. Retain protected-port guards, the tool's
pacing and its USB-error stops; do not bypass them with manual retries or
cycle the probe's own control board. Do not restart a shared bridge, load
another probe bitstream or kill a lock holder to make a run proceed without
the owner's coordinated handoff. Waiting for hardware does not prevent
independent source work or CI.

Close run-scoped connections and processes and release the lock on
completion or cancellation. A board tool cancelled by SIGINT or SIGTERM,
which is how GitHub cancels a job, does this itself: it stops at its next
point, lets a power cycle or download under way finish, skips a fixed-image
restoration it has not begun and records it pending for the port's next
boot check,
releases the lock and records the outcome `cancelled` with the signal and
the phase. The [boards guide](../environments/boards/README.md#what-a-run-reports)
lists every outcome a run reports. Preserve shared services that the board
recipe leaves running, and hand off their owner and state. Report the rig's
resulting state; a waiting session's silence is not a release. Retain the
compiler/source/image identities, logs, oracle verdict
and board record; evidence from one stream must match the inputs being
claimed after integration. The lock enforces exclusion, not authorization
or a distributed reservation, and Paseo status is not a hardware lock.

### Briefs and handoffs

When parallel work is authorized, put the current constraints in each
stream's brief. A local memory, another agent's context or a skill being
present on the coordinator's host does not deliver them to the child. A
useful brief names:

- the task, owned files, checkout and starting commit, plus any allocated
  decision, diagnostic or register identities;
- the source documents and decisions needed for that task;
- the authorized actions and restrictions, including host availability and
  hardware access when relevant;
- the exact affected test selectors, the default build workers, the
  environment setup and the wait method supported by that harness;
- the returned commit or patch, selected scope and status, retained log
  paths, findings and any work still running.

Keep task-specific choices in the brief. Keep reusable repository rules in
`AGENTS.md`, recipes here, and host access details in local guidance. A
reusable skill should point to the maintained recipe instead of copying its
gate matrix or introducing another authority for work. Check that the skill
is available to the actual provider on the actual host before relying on it.
For a resumed session, verify the checkout, current diff and outstanding
work against live state before acting on a remembered status.

The repository's [landin-change skill](../.agents/skills/landin-change/SKILL.md)
connects these recipes for implementation and candidate preparation. Its
source lives in `.agents/skills/landin-change`; the Claude project alias in
`.claude/skills/landin-change` resolves to that source. The
[landin-docs-rewrite skill](../.agents/skills/landin-docs-rewrite/SKILL.md)
rewrites a document for its reader and keeps every piece of its meaning;
its Claude alias is `.claude/skills/landin-docs-rewrite`, made the same
way. Check discovery from
the checkout where the provider will work. Skill discovery does not replace
the root guide, and a changed skill may require a fresh session or catalog
reload before it appears.

## Command reference

```sh
# Run every available mechanical check over the live documents and fixtures
python3 check.py

# Build the release compiler and hold it to its scaling bound: the median
# frontend and emission times, and peak compiler memory, may each grow at
# most 2.5 times per doubling of the program.  Then scripts/image_bounds.py
# assembles compact static images and holds the assembler to the source's size.
./scripts/scaling.sh

# Every scripts/tests module at once, check.py's controls in shards, as the
# gate's scripts job runs them; about two minutes on sixteen workers.
# Name modules, by path or by name, to run only those in one invocation.
# A subprocess timeout in a script test is a hang guard of at least 60
# seconds, which scripts/tests/test_hang_guards.py states and holds.
python3 scripts/script_tests.py
python3 scripts/script_tests.py test_fuzz_close test_scaling
# The gate's jobs run them on a runner, outside the development shell.
# This runs them with only the tools and variables a runner has, so a test
# leaning on one the shell alone carries, lldb for instance, fails here
# first; script_tests.py's GATE_TOOLS names what a test may assume.
python3 scripts/script_tests.py --gate-environment
# The gate's documents and scripts jobs run the runner image's Python 3.12,
# and the development shell gives a newer one, under which an argparse form
# or a library call 3.12 lacks passes.  This runs the modules, or check.py,
# under 3.12 from the flake's locked nixpkgs.
nix shell --inputs-from . nixpkgs#python312 -c \
    python3 scripts/script_tests.py --gate-environment test_fuzz_close
nix shell --inputs-from . nixpkgs#python312 -c python3 check.py

# Every workflow through the actionlint environments/pins.sh pins, with
# .github/actionlint.yaml's runner labels and the pinned shellcheck's pass
# over every run: script, as the gate's scripts job runs it.  nix develop
# provides both; elsewhere --install DIR fetches and verifies them first.  scripts/activations.py names it when a change
# reaches .github/.
python3 scripts/actionlint.py
python3 scripts/actionlint.py --install "$(mktemp -d)"

# Follow HEAD's gate run and return at its first failed job, rather than
# when its last lane ends; with --all, follow it to its end and name every
# failed job, when a round's fixes should go in one push.  Its first line
# names the run it follows with its event and branch.  A commit can have
# several runs, so after a promotion name main's: without --event and
# --branch the newest listed run is followed, which for the first seconds
# is the branch's finished one.
python3 scripts/gate_watch.py
python3 scripts/gate_watch.py --all
python3 scripts/gate_watch.py --all --commit HEAD --event push --branch main

# Regenerate every generated file: the matrices, catalogue, token dump and
# editor files.  A stale one is named by the full run above.
python3 check.py --generate

# Check one specification/prototype file (the narrowest supported test scope)
python3 check.py prototype-2-parser.md

# Build the bootstrap compiler and run its own test program.  Both need the
# pinned toolchain reachable; see compiler/ada/TOOLCHAIN.md.
./scripts/build.sh
./scripts/test.sh

# Build only refine for a consumer that does not run the Ada test program.
./scripts/build.sh --compiler-only

# Fast checksum-safe developer feedback.  The selectors are exact names;
# these runs are visibly FILTERED and do not replace the complete suite.
./scripts/dev-test.sh --suite='fixture execution'
./scripts/dev-test.sh --case='harness/filters select exact cases'
./scripts/dev-test.sh --fixture=negative/variant-match-duplicate

# The options and every suite name, without a build or Python.
./scripts/dev-test.sh --help

# An experiment in a build tree of its own, which nix develop leaves alone.
LANDIN_BUILD_VARIANT=inliner ./scripts/dev-build.sh

# Remove this host's build artefacts (--all removes every host's).
./scripts/clean.sh

# Mac compiler-host feedback.  The unfiltered suite needs Linux, and a Mac's
# own compiler defaults to darwin-arm64, so the shared verdicts' lane is named.
./scripts/dev-test.sh --host --target=linux-x86-64 --suite=checking

# Another Linux target's corpus from this host: a cross lane, under QEMU's
# user emulation and a cross driver, both of which `nix develop` provides.
# Evidence about the emitted code, never about the pinned toolchain on its
# own host.  The emulator's own failures are compiler/tests/cross-lanes.json's.
./scripts/dev-test.sh --target=linux-arm64 --runner=qemu-aarch64 \
    --suite='fixture execution'
QEMU_CPU=max,xtheadba=true ./scripts/dev-test.sh --target=linux-rv64 \
    --runner=qemu-riscv64 --suite='fixture execution'

# Whether a backend change's emission still assembles for the targets this
# host cannot run: emit the positive fixtures for every target but the
# host's, Darwin and FreeBSD among them, and assemble each with the
# shell's assembler for that target.  No VM, Mac, sysroot or emulator, and
# nothing is linked or run, so it says the text is accepted by an assembler
# of the target's kind and no more; the gate's lanes say the rest.  Name
# targets, --corpus= or --fixture=KIND/NAME for less; --keep=DIR keeps each
# refused assembly.
python3 scripts/assemble_targets.py \
    "compiler/ada/build/$LANDIN_BUILD_TAG/debug/bin/refine" .
python3 scripts/assemble_targets.py \
    "compiler/ada/build/$LANDIN_BUILD_TAG/debug/bin/refine" . \
    darwin-arm64,freebsd-arm64 --corpus=runtime --keep=/tmp/refused

# Render the documents selected in docs/site/render_html.py as HTML,
# verify their text was not dropped, and package them. It does not publish:
# .github/workflows/pages.yml is the only publisher; see docs/site/README.md.
./scripts/site.sh

# On a nix machine, a shell holding the pinned toolchain and python3.  It
# reads environments/pins.sh and tags its objects `nix-${system}`, so it does not
# collide with the other environments; see docs/environments.md.
nix develop

# Build the compiler through the flake.  .#refine builds this checkout from
# source -- about 140s on a fast Linux host, and the same cold, because the
# 478MB of pinned toolchain fetches alongside the compile.  .#refine-bin, the
# default package and what `nix run .` runs (D1707), fetches the published
# release asset instead, in about 5s, and ignores the working tree: it
# answers "give me the compiler", not "build what I have".
nix build .#refine
nix build .#refine-bin
nix run . -- version

# What the gate's flake job checks of the README's nix commands: the
# default installs the release archive, `nix run` runs the first program,
# and .#refine is the source build.
python3 scripts/nix_route.py --work /tmp/nix-route

# The release's container images on a host with docker (--engine podman
# for another): the user image from a packaged compiler, run as the README
# says; the contributor image, checked by building this checkout's
# compiler inside it.  Nothing is published; see "Releasing a version".
./scripts/package.sh compiler/ada/build/linux-amd64/release/bin/refine landin.tar.gz
python3 scripts/container_image.py build user landin.tar.gz --tag landin-user
python3 scripts/container_image.py check user landin-user
python3 scripts/container_image.py build contributor --tag landin-contributor
python3 scripts/container_image.py check contributor landin-contributor

# The release workflow with nothing to publish, on a pushed ref.
gh workflow run release.yml --repo 701-dev/Landin --ref BRANCH -f rehearse=true

# A Linux release build is static, glibc linked into each executable
# (compiler/ada/TOOLCHAIN.md), and its tests run as any build's do.  Packaged
# on Debian or Ubuntu, whose libc6-dev names the glibc for the archive's
# notice, it runs where no glibc is: alone in an empty root and on Alpine,
# with install.sh and the --link=libc fixtures (scripts/static_check.py;
# bubblewrap, and the network for Alpine's packages).
LANDIN_BUILD_MODE=release ./scripts/test.sh
./scripts/package.sh compiler/ada/build/linux-amd64/release/bin/refine landin.tar.gz
(. environments/pins.sh && landin_fetch_alpine /tmp/alpine x86_64-linux)
python3 scripts/static_check.py --archive landin.tar.gz \
  --alpine /tmp/alpine/alpine-3.24.4 --work /tmp/static
```

## The mechanical gate

`.github/workflows/gate.yml` is the mechanical gate, and it runs on every
push and pull request, weekly on `main` and on a manual dispatch. A new
candidate runs every target the compiler has,
in jobs that report separate verdicts. RV64 runs under QEMU's user
emulation on an x86-64 runner, which is evidence about its emitted code and
none about RV64 hardware; its jobs on RISE's physical runners stay skipped
until they are dependable. Two reuse conditions, identical-tree reuse and
an explanatory edit, let a push reuse a full pass instead, as
[reusing a pass](#reusing-a-pass) says. Each host's compiler builds hand
checked executables to that host's consumers, the debug compilers for cross-host determinism among
them. The final `gate` job, the aggregate job, requires every build and
verification job, cross-host determinism included, to succeed or to be
skipped under verified reuse or the event's scope; document and script
checks must always succeed, and on a board-scope event so must every
physical board leg.

Read a gate run's verdict with `python3 scripts/gate_watch.py`, or from
the run's complete job listing, every page of it, with each job name
judged by its newest attempt:

```sh
gh api --paginate 'repos/{owner}/{repo}/actions/runs/RUN/jobs?filter=all&per_page=30'
```

Keep the pages at thirty jobs: GitHub answers hundred-job pages of a large
run with 502. The `filter=latest` listing is not that reading: after a
rerun of failed jobs it holds only the jobs the last attempt ran, without
those that had succeeded and were not rerun, so it cannot show that every
required job passed.

Read a job's evidence from its attempt's log archive, a zip holding each
step's own file:

```sh
gh api 'repos/{owner}/{repo}/actions/runs/RUN/attempts/N/logs' > logs.zip
```

`gh run view RUN --job JOB --log` and the jobs API's log can end early,
labelled `UNKNOWN STEP`, where the archive holds the job whole. A job that a
rerun carried over has no log in the later attempt; its log is in the
archive of the attempt that ran it, the job's `run_attempt` in the
`filter=all` listing.

Linux x86-64, Linux arm64 and Darwin host checks run the production C
publication, private-directory and cancellation controls alongside formatter write
safety, with cancellation also exercised through actual `compile` and
`run` commands. Each FreeBSD architecture's first runtime shard compiles
and executes the same C adapters inside its guest, the attached-program
runner's signal-forwarding controls among them. That is native system
call evidence, separate from the Linux-hosted compiler and the generated
program corpus; it is not a FreeBSD-hosted Ada compiler claim.

| job | runner | runs |
|---|---|---|
| `inputs` | `ubuntu-24.04-arm` | verify a recent full pass for an identical candidate, or a full push pass of main or a branch for a declared explanatory edit; on a push to `main`, a passed board run of the same tree or an explanatory base whose boards the push takes (D1647); on a dispatch, a timed dispatch of the same key on the branch whose timing it takes (D1649) |
| `documents` | `ubuntu-24.04` | under the image's own Python 3.12, `check.py` over a checkout with the whole history, which the register's age rule reads, about ninety seconds, needing neither the toolchain nor a built compiler |
| `scripts` | `ubuntu-24.04` | under the image's own Python 3.12, every `scripts/tests` module at once through `scripts/script_tests.py`, `check.py`'s controls among them in shards, every workflow through the pinned actionlint and its `run:` scripts through the pinned shellcheck, which `scripts/actionlint.py --install` fetches and verifies, and the determinism, quality and debugging controls |
| `linux-debug-build` | `ubuntu-24.04` | build the debug executables once for the `compiler` shards, `compiler-checks`, `build-modes` and the Linux x86-64 determinism manifest |
| `compiler` matrix | `ubuntu-24.04` | the debug compiler's complete suite in three `--shard` jobs, `compiler-1` to `compiler-3`, at `LANDIN_TEST_JOBS=8` |
| `compiler-checks` | `ubuntu-24.04` | with the same debug compiler: the default target, a required Emacs-to-`refine lsp` diagnostic smoke, the determinism closures, native report identity, the scripted server sessions through `refine lsp`, and the server under one round of mutated corpus sources |
| `linux-release-build` | `ubuntu-24.04` | build the release executables over the object tree an earlier run left in the cache, for the `build-modes`, Cortex-M, Xtensa, `scaling`, FreeBSD and RV64 jobs |
| `linux-release-clean` | `ubuntu-24.04` | build the release executables from clean, for the `release` and `outside-user-stock` jobs |
| `linux-release-compare` | `ubuntu-24.04` | require the two release builds' `refine` and `landin_tests` to be the same files, byte for byte, and their manifests to record the same inputs (`scripts/compare_builds.py`) |
| `linux-release-cache` | `ubuntu-24.04` | on a push, once `linux-release-compare` has passed, save `linux-release-build`'s object tree to the cache for the next run; `gate` does not need it |
| `release` | `ubuntu-24.04` | with the clean release compiler: the whole test program, the determinism closures, native report identity and the scripted server sessions, the compiler packaged and used outside the checkout, then object quality, the GDB sessions and the DAP session through `refine dap` over the same GDB |
| `outside-user-stock` | `ubuntu-24.04` | the clean release compiler packaged and used outside the checkout on a stock Ubuntu with only its own GCC, installed by `scripts/apt_install.sh`, whose every attempt is bounded and which falls back from the image's mirrors to the official archive, refusing to run if the pinned driver is reachable: the first program, every `examples.md` program, the distribution's driver and a trap's report; then the user image built from the same archive, `scripts/container_image.py`, and the first program compiled and run inside it as the README says (D1667) |
| `build-modes` matrix | `ubuntu-24.04` | the debug and the release compiler of one tree emit the positive and runtime corpora, the firmware corpus and the Cortex-M counterparts at the four standard profiles and must agree byte for byte, and a request both refuse must be one the emission manifest's refusal list or the firmware inventory records as refused there, with status 1, over Linux x86-64, Linux arm64, Cortex-M, RV32 and both Xtensa configurations; the requests are dealt to `build-modes-1` to `build-modes-3` by their keys' digests, `emit_manifest.py modes --shard=I/3`, so each job is a third of the work whatever target grows (D1365, D1374) |
| `bindings` | `ubuntu-24.04` | `refine bindings`, with the debug compiler `linux-debug-build` made, against its pinned Clang |
| `editor-grammar` | `ubuntu-24.04` | the structural grammar's integration pass with the pinned tree-sitter CLI, then the Neovim LSP preference smoke under the distribution's Neovim |
| `flake` matrix | `ubuntu-24.04` | on every run that does not reuse a pass, a full-scope dispatch included (D585), in three jobs: `flake-compiler` runs `nix build .#refine .#refine-bin`, evaluates every flake output of every system, enters the development shell and runs `scripts/nix_route.py` (D1707), `flake-ram-run` builds the native board RAM helper with its Rust controls and `flake-ram-run-rigpi` the Pi's |
| `cortex-m` matrix | `ubuntu-24.04` | every Cortex-M and RV32 lane on the locked QEMU and GDB, at `LANDIN_CORTEX_JOBS=4`, as `run.py`'s three parts, which together are every lane once: the probes, firmware, device programs and debug evidence in `cortex-m-programs`, which also builds all eight board ports in boot and RAM layouts without hardware and keeps their build/drift evidence, the stack-switch consumer's capacity report (D470) and prototype 5's firmware counterpart's traces (D1035), and every firmware workload's instructions counted on each M-profile machine at all nine profiles and compared with the base commit's baselines (`docs/measurement.md`); the whole corpus on the M0, the M33 and the M7 in `cortex-m-corpus`; and the RV32 controls and corpora on Espressif's QEMU in `cortex-m-rv32` |
| `xtensa` matrix | `ubuntu-24.04` | three jobs a chip, `xtensa-esp32-1` to `-3` and `xtensa-esp32s3-1` to `-3`: the first of each runs bounded chip-machine window, scalar, floating, assembly and completion-oracle controls, independent vendor-C layout/carrier probes, strict configured-assembler and baseline compatibility controls, and each runs its `corpus.py --shard` third of the complete freestanding inventory, the three together every run once, on the pinned Espressif QEMU's `sim` machine with the exact selected CPU and explicitly virtual RAM; logs and per-fixture verdicts are retained |
| `measure-size` | `ubuntu-24.04` | with the checked release compiler, inside the pinned environment: every measured workload at every level and all nine profiles for Linux x86-64, arm64 and RV64, Cortex-M, RV32 and both Xtensa chips, each image's allocated sections compared with the base commit's baselines by `scripts/measure.py` (`docs/measurement.md`), then every hosted workload's instructions counted under the pinned `qemu-riscv64` at every RV64 level and profile and compared the same way; the figures kept 30 days as `measure-size-linux`, which `measure.py record --from-run` reads; Darwin's are measured in `darwin-host-release-2` and FreeBSD's in `freebsd-amd64-size` and `freebsd-arm64-size`, which link with the lane's cross driver and boot no guest |
| `measure-time` matrix | `ubuntu-24.04`, `ubuntu-24.04-arm`, `macos-26` | on the weekly schedule and a dispatch alone, whatever its scope (`gate_inputs.py scope`'s `timing`): each builds the candidate's debug compiler and its base's, then `measure.py time` runs every timed configuration's two images interleaved, fresh copies each run, and judges the ratio against the class's noise study; left out of a dispatch whose key a passed dispatch on the branch already timed (D1649) |
| `scaling` | `ubuntu-24.04` | `scripts/scaling.sh`, failing when frontend time, emission time or peak memory grows more than 2.5 times per doubling, or when a compact static image's assembly, object or assembler memory outgrows its bound |
| `darwin-debug-build` | `macos-26` | build the debug executables once for the `darwin-host` job and the Darwin determinism manifest |
| `darwin-release-build` | `macos-26` | build the release executables over the object tree an earlier run left in the cache, with `ZERO_AR_DATE=1`, for the `darwin-host-release` and `darwin-parity` jobs |
| `darwin-release-clean` | `macos-26` | build the release executables from clean, with `ZERO_AR_DATE=1`, for `darwin-release-compare` alone |
| `darwin-release-compare` | `ubuntu-24.04` | require the two Darwin release builds' `refine` and `landin_tests` to be the same files, byte for byte, and their manifests to record the same inputs (`scripts/compare_builds.py`) |
| `darwin-release-cache` | `ubuntu-24.04` | on a push, once `darwin-release-compare` has passed, save `darwin-release-build`'s object tree to the cache for the next run; `gate` does not need it |
| `darwin-release-main-cache` | `macos-26` | on a push to `main` only, unless `main`'s entry for the tree's gate key already exists: build the release executables from clean, with `ZERO_AR_DATE=1`, and save the tree as `main`'s cache entry, which a branch's first run restores; `gate` does not need it |
| `darwin-host` matrix | `macos-26` | the debug compiler host suite in two `--host --shard` jobs, `darwin-host-1` and `darwin-host-2`, which together are the complete host run; the first also runs the verifier observations, the determinism closures, report identity and the native C controls, the second compile publication, tool cancellation and the scripted server sessions |
| `darwin-host-release` matrix | `macos-26` | the release compiler host suite in two shards, `darwin-host-release-1` and `darwin-host-release-2`, with the same follow-on checks divided the same way; the first also uses the installed toolchain outside the checkout, the second runs the LLDB sessions and the DAP session through `refine dap` over Xcode's `lldb-dap` |
| `darwin-parity` matrix | `macos-26` | the hosted corpus executed natively with the release compiler, its fixtures dealt round `darwin-parity-1` to `darwin-parity-3` by `compiler/tests/darwin/check.py --parity --shard=I/3`, so the three are every case once; the parity harness's own tests (`test_darwin_assembly`) and every Darwin source verdict in the first, the bindings in the second |
| `arm64-debug-build` | `ubuntu-24.04-arm` | build the debug executables once for the `arm64-compiler` shards, `arm64-compiler-checks` and the Linux arm64 determinism manifest |
| `arm64-compiler` matrix | `ubuntu-24.04-arm` | the debug compiler's whole test program on the Linux arm64 lane in two `--shard` jobs, `arm64-compiler-1` and `arm64-compiler-2` |
| `arm64-compiler-checks` | `ubuntu-24.04-arm` | with the same debug compiler: representative verifier resources, the default target, the determinism closures, native report identity and the scripted server sessions |
| `arm64-release` | `ubuntu-24.04-arm` | the same corpus with the release compiler, the default target, the server sessions, the GDB sessions with the pinned aarch64 GDB, the DAP session over the same GDB and the generated bindings for the standard AAPCS64; the compiler packaged, used outside the checkout and built into the arm64 user image, which runs the first program (D1667) |
| `freebsd-amd64-runtime`, `freebsd-arm64-runtime-1`, `freebsd-arm64-runtime-2` | `ubuntu-24.04` | emit with the checked Linux release compiler and locked sysroot, check source verdicts, assembler boundaries and linked instructions, then execute the applicable runtime corpus in a fresh FreeBSD 14.4 VM, amd64 under KVM and arm64 emulated, including guest CPU confirmation; the emulated arm64 lane runs as two shards of whole fixtures |
| `freebsd-amd64-debugger`, `freebsd-arm64-debugger` | `ubuntu-24.04` | the same emission, then native FreeBSD LLDB source stops, frames, local values and unwinding in the VM, and the DAP session through `refine dap` on the runner, Ubuntu's `lldb-dap-19` attached to `lldb-server` in the guest |
| `freebsd-amd64-abi`, `freebsd-arm64-abi` | `ubuntu-24.04` | the same emission, then nonempty C ABI fixture sets against independently compiled FreeBSD C peers in the VM |
| `rv64-qemu` matrix | `ubuntu-24.04` | the release compiler's whole test program on the Linux RV64 lane in two `--shard` jobs, `rv64-qemu-1` and `rv64-qemu-2`, linked by Ubuntu's riscv64 cross driver and run under the flake's pinned `qemu-riscv64`, its CPU's every level confirmed, with that emulator registered as the riscv64 binfmt_misc handler so a program that starts itself again runs (D1037); the emulator's own failures listed in `compiler/tests/cross-lanes.json` are reported and not counted; the first shard also runs the RV64 GDB sessions, the stack switch's among them, and the DAP session through `refine dap`, under the same emulator's GDB stub |
| `rv64-emit` matrix | `ubuntu-24.04` | suspended since 2026-10-13 and not required by `gate`; when running, cross-emit checked RV64 runtime, GDB, C ABI and ISA payloads for RISE; source/hash checks, invalid IR register regression and instruction inspection |
| `rv64-runtime`, `rv64-debugger`, `rv64-abi`, `rv64-isa` | ubuntu-24.04-riscv | suspended since 2026-10-13 and not required by `gate`; when running, separate corpus, native GDB, nonempty independent C peers and hardware-confirmed baseline/extended ISA execution on physical RISE runners |
| `board-bundles` | `ubuntu-24.04` | on a board-scope event only, whatever the software lanes reuse: the release compiler built from the commit, every board's boot and RAM bundles by `environments/boards/build.py --mode=both --records=strict`, so drift from a hardware record fails before a board runs, on an event that times the boards also the timing runs' images, every firmware workload at every profile on each port by `environments/boards/timing.py build`, in `timing/`, bound to the same compiler and source, and one 14-day artifact with `provenance.json` and `files.sha256`; skipped on a push to `main` that takes its boards from a passed run (D1647) |
| `linux-release-main-cache` | `ubuntu-24.04` | on a push to `main` only, unless `main`'s entry for the tree's gate key already exists: build the release executables from clean and save the tree as `main`'s cache entry, which `linux-release-build` restores on a branch's first run; `gate` does not need it |
| `board` matrix | `[landin-rig]`, the rig's self-hosted runner | `board-rp2040`, `board-pico2`, `board-stm32h753`, `board-esp32c3`, `board-esp32c5`, `board-esp32` and `board-esp32s3`, one at a time on the rig's one runner: a sparse checkout of the exact commit, the bundles downloaded by artifact id against their digest, their file list and provenance checked, then `environments/boards/gate.py --lock-wait=1200`, each port's RAM run and then its boot check, and on an event that times the boards, with `--timing`, rig.json's time steps before the boot check, each image three times through the SRAM helper's timing plan: measured at 20 s to 6 minutes a leg, about 13 minutes over the seven; 50 minutes a leg, 70 for the Pico 2's six steps; each leg's evidence, `board-evidence-PORT-ATTEMPT`, one per run attempt, kept 90 days, also after a failure or a cancellation, and the aggregate judges each port by its latest attempt and, when the event times the boards and every leg passed, holds the legs' timing runs to the base commit's baselines, `compiler/tests/measure/baselines/BOARD.cycles.json`, within each port's tolerance from `compiler/tests/measure/noise/cycles.json`, by `timing.py figures --evidence` and `timing.py compare`, from a full-history checkout, and keeps the figures as `measure-cycles`; never reused |
| `determinism` | `ubuntu-24.04`, `ubuntu-24.04-arm`, `macos-26` | the called workflow emits the fixture manifest for all nine targets on each host, including both Xtensa levels, in `emit --shard` shards that deal its requests by their keys' digests, three on Linux x86-64 and two on each other host, joins each host's shards and compares the three, starting once the three debug builds succeed rather than after their suites |

Linux and Darwin lanes run on GitHub-hosted images for every event, as do
the called determinism workflow and the links, Pages and release workflows;
the board legs alone run on the self-hosted rig runner described below,
and only for a push to `main`, the weekly schedule or a manual dispatch. The
FreeBSD lanes boot their VMs inside the hosted job, arm64 under emulation
because GitHub's arm64 images offer no KVM. See [the runner environment requirements](environments.md#github-actions-runners).

Every verdict the gate counts was made with executables a clean build of
the tree produced: built from clean, or the same files, byte for byte, as
the clean build's. Linux x86-64's and Darwin's release executables use the
second form. `linux-release-clean` builds them
from clean, as every other build job does. `linux-release-build` builds
them with `scripts/dev-build.sh` over the object tree an earlier run left in
the cache, recompiling by checksum what changed, so the jobs waiting for a
compiler start sooner. The jobs that use `refine` as a tool to make their
evidence take that build: `build-modes`, `cortex-m`, `xtensa`, `scaling`,
`freebsd` and `rv64-qemu`. The jobs whose claim is about the built
executable itself take the clean one: `release`, whose test program run is
the release evidence and which packages the compiler, and
`outside-user-stock`, which packages it for a stock system.
`linux-release-compare` requires the two builds' `refine` and
`landin_tests` to be the same files, debugging information included, and
their manifests to record the same inputs, and `gate` needs it. A stale,
damaged or planted cache entry can make the cached build fail or differ;
either fails the gate, so no lane's verdict counts on executables the clean
build did not also produce. With no usable entry the cached build is a
clean build and takes as long as one.

The comparison can be of whole files because the build records no compiler
switches in its debugging information (`-gno-record-gcc-switches` in
`compiler/ada/landin_common.gpr`, whose reason `compiler/ada/TOOLCHAIN.md`
gives). The cache entry is the build tree
without `bin/` and `link/`, about 120 MB compressed. Its key names what
the objects were compiled against that the build's manifest does not
record, the C library headers the C adapters read and the C compiler's
version (`scripts/release_cache_key.py`), and the digest of
`environments/pins.sh`, and not the runner image's version, since GitHub
serves one run two image versions while it rolls an image out and a key
naming it misses the saved entry. A run restores the newest entry of its own branch
or, failing that, of `main`, and `build.sh` still rebuilds from clean when
the source inventory, a project file, the switches or the toolchain differ
from what the restored tree records. A push saves its tree once the
comparison has passed, so no entry is the tree of a build that differed,
and `board-bundles` saves its clean build's on `main`, so a new branch's
first run starts from `main`; a pull request saves nothing, since no other
ref could restore its entry. GitHub evicts an entry unused for seven days, and
the least recently used once the repository's entries pass 10 GB. If the
cached build fails where the clean one passes, the entry it restored, named
in its log, can be removed with `gh cache delete KEY`; the next run then
restores an older entry or builds from clean.
Linux arm64's release executables are built from clean only.

Darwin's release executables are built the same two ways, by
`darwin-release-build` over the cache and `darwin-release-clean` from
clean, and `darwin-release-compare` holds the first to the second, byte
for byte; `darwin-host-release` and `darwin-parity` take the cached build,
and only the comparison takes the clean one. Apple's `ar` writes each
member's modification time into the library archive and Apple's linker
writes each object's time, or that archive date, into the executable's
debug map, the `N_OSO` entries LLDB reads to find the DWARF that stays in
the object files; the ad hoc signature hashes those pages. Those times
and hashes are the only differences between two builds of one tree, so
both build jobs set `ZERO_AR_DATE=1`, which has `ar` and the linker write
0, and the builds are then the same files. LLDB still finds the source lines of `refine` through such a debug map, and the
Darwin LLDB sessions pass with a compiler built so; a time of 0 only
stops LLDB refusing an object rebuilt since the link, which on a runner,
where no object outlives its job, cannot happen. The cache is keyed and
saved as Linux x86-64's is, by `darwin-release-cache` on a Linux runner so
as to hold no macOS one. `main`'s runs reuse the candidate's pass and
build nothing, so `darwin-release-main-cache` builds `main` from clean on
each push to it and saves that tree, as `board-bundles` does Linux
x86-64's, and a new branch's first run restores it; `gate` does not need
it, and on `main` it takes a macOS runner no other job wants. Its entry is
named by the tree's gate key (`gate_inputs.py key`), which leaves out only
the content of the explanatory files, so a push whose entry already exists,
an explanatory promotion among them, asks the cache and builds nothing:
a clean build of the same inputs would save the same objects.

Both caches carry the sources' modification times with the objects
(`scripts/source_times.py`). GPRbuild's checksum mode spares the units
that depend on an unchanged source but recompiles every unit whose own
source's time stamp differs from the one its ALI file recorded, and goes
by time stamps alone for C; a checkout gives every file the time of the
checkout, so without the carried times a build over a restored tree
recompiles all of it and takes as long as a clean build. The build job gives each source whose SHA-256 is the one recorded the recorded
time, and leaves every other file newer than its objects.

The Darwin lanes are divided so that no macOS job
holds the longest path alone: `darwin-host` runs in two shards,
`darwin-host-release` in two and `darwin-parity` in three, each division
holding every case once, and `darwin-host-release` and the parity shards
start at the cached build's end. The organisation `701-dev` may run fifteen
macOS jobs and sixty jobs in all at once (GitHub raises the sixty to 120 on
request), enough for every macOS job of one run at once. The cap is the
account's, not a run's: two items' gates running at once share its macOS
and Linux runners, and each takes longer.

A compile error surfaces in its host's debug or release build job; Linux
arm64's release lane still builds its own.

The gate keeps artifacts, never an acceptance record: among them a failed
Cortex-M job's diagnostic output, when there is any, and a failed LLDB
session's transcripts, images and dSYMs from `darwin-host-release-2`, in
one archive as `darwin-lldb-evidence`, for 14 days, the determinism
workflow's assembly manifests, and each board leg's evidence for 90 days.
Same-run build archives are only inputs to later jobs.

The gate calls `determinism.yml`, which requires every host in its matrix
to emit the same bytes; it emits and hashes but never assembles, links or
runs. It also supports manual dispatch. `pages.yml` publishes
<https://www.701.dev> when a site input changes on `main`, or when
dispatched manually; it fetches the licensed code face from object storage
because it is not in this repository, renders and verifies, and runs no
compiler test. `scripts/site.sh` renders and packages and does not publish.
`links.yml` checks changed documents on a push and every document weekly or
manually; a change to the link checker's configuration, or an unknown
changed range, checks every document. `release.yml` is tag-driven and
[releasing a version](#releasing-a-version) describes it. The repository
submits no build manifests, and Nix CI is the gate's `flake` job alone,
which builds the flake on every run that does not reuse a pass (D585): no
derivation is cached, and `rv64-qemu` takes only its emulator from the
flake.

### Reusing a pass

Identical-tree reuse: a branch push or same-repository pull request by an
author with write access may reuse a complete successful push run from this repository from the
preceding seven days when the entire tracked tree is identical. This key
includes every byte, path and mode, the workflows and tool pins, and all
documents. A pull request compares its merge checkout, not just its head.
The complete GitHub job listing must contain every required matrix leg with
success; filtered local runs, cache entries, incomplete listings and runs
that themselves reused evidence cannot supply this pass. Main promotion
therefore does not repeat a candidate's full matrix when its tree is unchanged.
A manual dispatch of scope `full`, the default, runs the full matrix and the
boards. Superseded pushes to a branch and updates to a pull request are
cancelled. A manual dispatch, a push to `main` and the schedule each have a
concurrency group of their own, so none of them cancels another: a shared
group would still cancel its pending run when a third arrived, whatever
`cancel-in-progress` says. Unrelated forks' pull requests cannot cancel
each other.

An explanatory edit: a declared edit confined to the content of `README.md`,
`ROADMAP.md`, `handoff.md`, `AGENTS.md` and the guides under `docs/` that
`gate_inputs.py`'s `DOCUMENTS` names, and to anything under `roadmap/` and
`docs/site/` and the boards' `*.cycles.json` baselines, files added and
deleted there included (D1373, D1648, D1650), may reuse a
complete successful push run of this repository from the preceding seven
days, of `main` or of any other branch, whose commit is an ancestor of the
edit (D586). So a
documents-only commit that closes an item after its branch's full gate
reuses that gate on the branch and again when main is promoted to it. A
branch's run is as trustworthy a base as main's: only someone with write
access can push to a branch, and the tree key covers the workflow that run
executed and every tool pin.
Every intervening commit must carry the exact line `Gate: explanatory`;
the event must be a push to a branch of this repository, `main` or another,
or a same-repository pull request whose author has write access. Declare
only changes to explanation, with no
change to language rules, targets, scope or acceptance claims: an
explanatory edit never covers generated Ada or catalogues, executable
examples or fixtures, or the grammar and semantic rules in `spec.md`, and
a guide the key does not leave out, `docs/commands.md`, `docs/library.md`,
`docs/format.md` and `docs/from-c.md` among them, is read by lanes and is
not explanatory. The source
tree key preserves all other bytes, paths and modes. Missing, partial,
expired or mismatching evidence runs everything. Documents and script
checks always run, and a reused run can never itself supply the full pass.
The aggregate gate covers each build, test and determinism host separately.

For a successful reuse, the `inputs` log names the source commit and links
the full run being reused. Target and build jobs, including `determinism`,
appear as skipped; `inputs`, `documents`, `scripts` and the final `gate`
still succeed. The linked full run contains the target-test results.

### The controls that hold the job inventory

A change to a gate job's name, matrix, condition or needs is held by
controls in several files. Read this list before the change, and run them
together afterwards: `python3 scripts/script_tests.py test_gate_inputs
test_rv64_lanes test_build_inventory test_compare_builds
test_host_determinism test_rig_runner_hook test_release`, and `python3
environments/cortex-m/test.py`, which `check.py` runs.

| file | what it holds of `gate.yml` |
|---|---|
| `scripts/tests/test_gate_inputs.py` | `Workflow`: the reuse list is exactly the jobs the aggregate needs, every matrix leg by its rendered name. `Physical`: every job's condition follows the event's scope, a software lane skipping for a reused pass and a boards-only event and a board job running by the boards scope alone, the boards' timing images built, run and compared by the timing scope alone and compared only once every leg passed, the board matrix is every port once, and the aggregate keeps documents and scripts always. `BoardsReuse` and `TimingReuse`: main's push takes boards, and a dispatch its timing, only from a run D1647 and D1649 allow; `BoardVerdict` accepts their skip only on those events. `DocumentReaders`: every tracked file naming a guide, the site or the cycles baselines that the key leaves out says why no lane reads it, the scripts tests a lane runs included. `Inventory`: this list names every test file that names the workflow. Its matrix reader takes axis lines or one `include:` list, never both. |
| `scripts/tests/test_rv64_lanes.py` | the RV64 jobs: the two hardware jobs are suspended, by a `false` conjunct in their condition, and absent from the aggregate and the reuse list; the emulated job is not suspended, has both shards and its packages, and its evidence is packaged. It compares conditions by that conjunct alone, so a scope change does not concern it. |
| `scripts/tests/test_build_inventory.py` | `BuildArchives`: the archives the build jobs hand to their consumers hold the executables and both stamps. |
| `scripts/tests/test_compare_builds.py` | the comparison over ELF and Mach-O files written by the test, a Mach-O debug map alone still failing. `Workflow`: `release` and `outside-user-stock` take Linux x86-64's clean release build and no other, the clean build never touches the cache, `linux-release-compare` compares both builds' `refine` and `landin_tests` and is among the jobs `gate` needs, and only `linux-release-cache`, after the comparison, and `board-bundles` save a release object tree; the key names the C headers and compiler, not the image, and every saved tree carries the sources' times, which the cached build gives back before it builds. `DarwinWorkflow`: only `darwin-release-compare` takes Darwin's clean build, both Darwin builds set `ZERO_AR_DATE=1`, only the cached one restores the cache and only `darwin-release-cache`, after the comparison, which `gate` needs, and `darwin-release-main-cache`, a clean build on a push to `main`, save it, with the same key and times, and `darwin-host-release` starts at the cached build's end. |
| `scripts/tests/test_host_determinism.py` | `Workflows`: the `build-modes` matrix's jobs are every shard of every mode target, numbered from one and dividing by their own count, and `determinism.yml`'s legs are shards 1 to N of N on each host, its step naming no target list, and `emit --shard` deals every request to one shard; `BuildModes`: the shards together are every request once. |
| `environments/cortex-m/test.py` | the `cortex-m` job's `part` matrix is the runner's parts, and it passes `--part`. |
| `scripts/tests/test_rig_runner_hook.py` | nothing of the jobs: it passes the workflow's path to the rig runner's hook. |
| `scripts/tests/test_release.py` | nothing of the jobs: it names the workflow in the API path the release check asks for main's run. |
| `scripts/tests/test_nix_route.py` | `Gate`: the `flake-compiler` leg runs `scripts/nix_route.py` (D1707); it holds the matrix's `compiler` part by that step's condition. |
| `scripts/tests/test_check_controls.py` | nothing of the jobs: `PinnedToolchain` copies the workflow, so that `check.py` can hold the scripts job's actionlint step to `scripts/actionlint.py --install` and to no literal pin. |

### Physical boards and promotion

A board-scope event is a push to `main`, the weekly schedule at 04:00 UTC
on Mondays, or a manual dispatch, in this repository only;
`scripts/gate_inputs.py scope` decides it from the event. On such an event
`board-bundles` and every board leg run whether or not the software lanes
reuse a pass, and the aggregate requires each of them to succeed and every
port's outcome to be `passed`. A skipped, cancelled or failed leg, a leg
that never reached the rig, and any other outcome, `rig-busy`,
`needs-setup` and `unavailable` among them, fail the aggregate job: missing physical
evidence is not a pass. On every other event, a branch push or a pull
request, the board jobs must be skipped, and the gate's summary says
"physical boards: not run for this event". A green gate there is software
evidence only.

A dispatch of scope `boards`, and the schedule, run `inputs`, `documents`,
`scripts`, `board-bundles` and the board legs and no software lane. The
schedule and every dispatch also time the boards: each leg runs its
port's time steps, and the aggregate compares their figures with the base
commit's baselines. A dispatch leaves the timing out when a successful
dispatch on its branch under a week old, whose `measure-time` legs passed,
was made on a commit with the same gate key over a base with the same key,
the base `measure.py base` names (D1649); its summary names that run. Their
run is named "gate: boards only", their summary says "boards only: no
software lanes", and they never supply a software pass, because reuse takes
only push runs whose every software job ran and succeeded. `gate_inputs.py`'s
`PHYSICAL` keeps the board jobs out of the software reuse list. A push to
`main` takes its boards instead from a successful run of this repository
on a board-scope event under a week old, whose `board-bundles` and every
leg ran and passed, on the identical tree or on a base the explanatory rule
accepts (D1647): `gate_inputs.py physical` decides it in `inputs`, the
board jobs are skipped, and the aggregate accepts that on a push to `main`
alone and names the run. The schedule and a dispatch always run the boards.
A main run whose boards fail has a failed gate, and so cannot serve as a
reuse base, and a run that took its boards is never a boards base.

The board legs run on one non-ephemeral GitHub Actions runner on rigpi,
labelled `landin-rig` alone, as the system user `landin-rig`. That user is
in the groups `dialout`, `systemd-journal` and `rig`, and has no wheel or
sudo, no SSH keys and no secrets. The runner was registered once with a
one-hour registration token, and is configured in the maintainer's NixOS
configuration for rigpi, not in this repository. A pull request from a fork
runs its own workflow files, so no `if:` in `gate.yml` keeps it off the
runner. The control is the runner's job-started hook,
[`environments/rig-runner/hook.py`](../environments/rig-runner/README.md),
which accepts only a push to `main`, a schedule on `main` or a dispatch
from a branch by the maintainer, each of `gate.yml` at the run's own ref
with no pull request in its environment or payload. GitHub fails a job
whose pre-job script exits nonzero
([running scripts before or after a job](https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/run-scripts)),
but a failed job is not a job none of whose steps ran: a step under
`if: always()` and an action's `pre:` entry have conditions a failed
earlier step can satisfy. A refusal therefore does not rest on the exit
status. The hook removes the actions the runner downloaded for the job and
kills the runner's worker process for it before exiting, and no step runs
without the worker, so nothing from a refused job's checkout runs on the
rig. The hook's controls run that against a stand-in worker; a refused job
on the deployed runner has not been observed since the change, and the
[hook's page](../environments/rig-runner/README.md#what-a-refusal-does)
gives the one experiment that does. A second layer is
the repository's setting that a fork's pull request waits for approval
before its workflows run, set for all external contributors as GitHub
recommends. The board jobs read no
secret, and their token can only read the contents and the actions.

A candidate reaches `main` in three steps:

1. Its complete software push gate passes on its branch.
2. A dispatch of scope `boards` passes on the identical tree, or on an
   ancestor separated from it only by commits declared
   `Gate: explanatory`, `gh workflow run gate.yml --ref BRANCH -f
   scope=boards`. An edit declared `Gate: explanatory` skips this step:
   its main push takes the boards of a passed run before it, or runs them
   when there is none.
3. `main`'s own push gate, which takes the boards of that dispatch, is
   followed to its end. A failure there is investigated, never rerun
   blindly.

#### The promotion queue

A candidate gated while another item lands has to merge `main` again and
run its whole gate and boards again, so promotions take turns. The clone holds one promotion token, `landin-items/queue.json`.
`item.py merge-main` takes it before an item's final merge of `main`, and
`item.py promote` before pushing; the holder keeps it through its merged
tree's gate, its boards, its promotion and `main`'s gate on it, and gives
it up when that gate ends (`item.py gate ITEM --main`, or `finish`) or with
`item.py queue --release ITEM`. An item that finds the token held is put
in line and waits with `item.py queue --wait ITEM`, which returns once the
token is its own; it keeps working meanwhile, but takes no final merge.
A holder this clone no longer runs, or whose `main` gate has ended, holds
nothing. A merge whose main side is all `Gate: explanatory` and leaves the
gate key alone is declared so by `merge-main` and reuses the candidate's
pass and boards, as the reuse rule allows.

#### A timing failure is not a boards failure

A boards dispatch also runs the three `measure-time` jobs and each
leg's timing runs, unless its branch already timed its key (D1649), and the aggregate compares the boards' cycles with the
base's baselines. A run whose board legs all passed and whose only failed
jobs are `measure-time` ones, with the aggregate after them, failed in
timing, not in the boards: `gate_watch.py`, the aggregate's summary and
`item.py gate` say so. Read the failed timing job's log; when it reads as
noise, `item.py boards ITEM --rerun-failed` (`gh run rerun RUN --failed`)
runs only those jobs and the aggregate again as the run's next attempt,
which judges each port by its latest attempt and keeps the passed legs'
evidence, rather than a new dispatch. A run whose aggregate alone failed,
every job before it passed, failed its verdict or its cycles comparison; a
re-run would judge the same figures again, so read its log instead.

An unavailable rig blocks promotion. A RAM run's success never establishes
power-on, ROM loading or fixed-image restoration, so every leg runs each
port's RAM run before its final boot check, leaving the verified fixed image
at rest. An unknown or interrupted prior state prepends a restoring boot
check before RAM. The configured steps in `environments/boards/rig.json`
decide the order; the Pico 2 covers both architectures.

### Proving a change emits the same bytes

A change meant to alter no emitted output proves it with two manifests,
emitted over the same checkout by a compiler built before the change and
one built after it, and compared. Keep the first
compiler where it was built. `refine` finds its library in `lib/landin`
beside the `bin/` it runs from, or in the checkout six directories above a
build tree's `bin/refine`, so a copy anywhere else refuses every hosted
program as L0500, "no library holding platform/linux was found". Two
places keep it:

- Before the first edit, `LANDIN_BUILD_VARIANT=baseline ./scripts/dev-build.sh
  --compiler-only` builds the unchanged compiler into a build tree of its own,
  `compiler/ada/build/$LANDIN_BUILD_TAG.baseline/`, which later builds leave
  alone. Both compilers then read the checkout's library as it is when they
  run, so this proves a change to the compiler alone.
- For a change to `core/`, `hosted/` or `platform/` as well, build the
  baseline in a worktree of the starting revision, `git worktree add
  ../landin-base REV`, then `./scripts/build.sh --compiler-only` there;
  its `refine` reads that worktree's library. Still pass this checkout as
  ROOT to both runs.

```sh
base="compiler/ada/build/$LANDIN_BUILD_TAG.baseline/debug/bin/refine"
new="compiler/ada/build/$LANDIN_BUILD_TAG/debug/bin/refine"
proof=$(mktemp -d)
python3 scripts/emit_manifest.py emit "$base" . "$proof/base.json" \
    --corpus=positive --corpus=runtime --profile=size-auto --debug-info
python3 scripts/emit_manifest.py emit "$new" . "$proof/new.json" \
    --corpus=positive --corpus=runtime --profile=size-auto --debug-info
python3 scripts/emit_manifest.py compare "$proof/base.json" "$proof/new.json"
```

`emit` compiles every positive fixture for every target in both build
modes and at all nine profiles unless told otherwise, on every core.
The optional fourth operand names the targets, comma-separated;
`--corpus=` repeats and takes `positive`, `runtime` and `cortex-m`, the
Cortex-M counterparts; `--fixture=KIND/NAME` repeats and keeps only those;
`--profile=OPTIMIZE-SPECIALIZE` and `--mode=debug` or `release` repeat and
keep only those; `--jobs=N` sets how many compilations run at once; and
`--debug-info` compiles every entry again with the target's source
debugging, `--debug=full` hosted and `--debug=lines` on firmware. Debug
information names the directory a fixture was compiled in, which is why
both runs take the same ROOT, and why the gate's cross-host manifest has no
debug entries: two hosts' checkouts sit at different paths. An unexpected
refusal is reported with the first diagnostic the compiler gave for it.

### Comparing the images two compilers link

The manifests compare assembly. A firmware lane also links, with the
target's own linker and the startup and vectors refine writes, and keeps
each image it built under its output directory; it keeps no image of a
base, so a comparison of linked images runs the lane twice, once with each
compiler and each into a directory of its own, and then compares the two
trees with `scripts/compare_images.py`. For the Cortex-M lanes' programs
part, with `$base`, `$new` and `$proof` as above and `$TOOLS` the root
`environments/cortex-m/setup.py` installed:

```sh
python3 environments/cortex-m/run.py --part=programs --tools "$TOOLS" \
    --refine "$base" --output "$proof/base-programs"
python3 environments/cortex-m/run.py --part=programs --tools "$TOOLS" \
    --refine "$new" --output "$proof/new-programs"
python3 scripts/compare_images.py "$proof/base-programs" "$proof/new-programs"
```

It pairs every `*.elf` by its path below each directory, so the two runs
must select the same lanes, parts or chip, and compares what each loads:
the entry point, the `PT_LOAD` segments' addresses, sizes and flags, and
their bytes. Debugging information and symbols are not compared, so an
image whose only change is a path in its line table is the same image.
For an image that differs it names the routines and data of another size,
those of the same size whose bytes differ, those only in one image, those
whose bytes are the same at another address, and the loaded bytes outside
every named symbol, in the vectors for instance. A call or a literal
reaching a routine that moved changes too, so the routines of another size
and those in one image alone are usually the change, and the rest follow
from it. Images in one tree alone are named, and the last line counts
each kind; the status is 0 only when both trees hold the same images and
each loads the same bytes. It lists twelve names of each kind, and
`--names=N` lists N. The Xtensa corpus compares the same way, with its `--chip`,
`--memory-profile` and `--all` given to both runs alike.

## Releasing a version

A release is the maintainer's: the version, the declaration and the tag
are named by the maintainer, never chosen by an item or an agent, and the
project does not assume SemVer. The recipe below is the order a release
follows. Its settings, the tag ruleset, the `release` environment and the
attestations, are described with
[the release workflow](#the-release-workflow-and-its-settings); the
comments of `.github/workflows/release.yml` and of `flake.nix` beside
`releaseVersion` say why each step is the way it is.

1. **Declare.** One commit declares the version and changes nothing
   else: the README's status line, `**Status: version X.Y.Z.`, which the
   release workflow reads; the version `refine version` prints in
   `docs/capabilities.md`; `VERSION_LINE` in `docs/site/render_html.py`;
   `handoff.md`'s "Kept current" line and a new row of its version table
   naming what the release brings and its decisions; the version line of
   `tour.md`; and the "Current with" line of each of the five prototypes.
   The flake's `releaseVersion` does not move: a tagged tree cannot hold
   the hashes of archives built from itself. The release workflow refuses
   a tag the README's version does not match.
2. **Gate it.** The declaration is a candidate like any other: its push
   gate, a `scope=boards` dispatch on the same tree, promotion to `main`
   and `main`'s own push gate followed to its end. `scripts/release.py
   gated` refuses a tag on a commit that is not on `main` or whose own
   push gate there did not pass.
3. **Rehearse.** On that commit of `main`, run the release workflow with
   nothing to publish:

   ```sh
   gh workflow run release.yml --repo 701-dev/Landin --ref main -f rehearse=true
   ```

   It builds and checks the three archives, builds the user image from
   each Linux archive and the contributor image from the tree and checks
   them (`scripts/container_image.py check`), and assembles each image's
   two platforms into one list pushed into a layout on the runner, whose
   `index.json` the `images` job prints. The checks and the publishing
   job are skipped, and nothing leaves the run but its artifacts. Debian's
   archive and the toolchain downloads are what a rehearsal finds broken
   before a tag has been made.
4. **Tag.** An annotated tag `vX.Y.Z`, message `Landin X.Y.Z`, on that
   commit, pushed to GitHub through `origin`, whose second push URL sends
   it to the git.sr.ht mirror too. Only an administrator may push it, and
   the push asks for no approval: the ruleset's bypass list must name the
   role, as [the release settings](#the-release-workflow-and-its-settings)
   say.
5. **Approve.** The tag's push runs `release.yml`: the checks, the three
   builds and the image jobs, as in the rehearsal. The publishing job then
   waits in the `release` environment. Read the builds' checksums and the
   `images` job's list, then approve it under "Review deployments" on the
   run's page. It attests the archives, publishes the release with the
   verify command in its notes, pushes `ghcr.io/701-dev/landin:X.Y.Z` and
   `ghcr.io/701-dev/landin-contributor:X.Y.Z` as one list each, and
   attests each list in the registry. It moves no other tag, and a tag the
   registry already holds is left as it is, so a run that stopped
   part-way is completed by running the job again.
6. **Check what was published.** The archives as the release notes say,
   with `gh attestation verify`. Each image the same way, and by running
   it:

   ```sh
   gh attestation verify oci://ghcr.io/701-dev/landin:X.Y.Z --repo 701-dev/Landin \
     --signer-workflow 701-dev/Landin/.github/workflows/release.yml \
     --source-ref refs/tags/vX.Y.Z --deny-self-hosted-runners
   docker run --rm ghcr.io/701-dev/landin:X.Y.Z   # refine X.Y.Z, library: /usr/local/lib/landin
   docker buildx imagetools inspect ghcr.io/701-dev/landin-contributor:X.Y.Z
   ```

   The last names `linux/amd64` and `linux/arm64`. A package the
   organisation's registry has not held before is created private: on
   the first publication of each image, `gh api
   orgs/701-dev/packages/container/landin --jq .visibility` (and the same
   for `landin-contributor`) must say `public`; if not, make it public
   under the package's settings on GitHub, once. The source label links
   each package to the repository.

   Then the install script the README pipes from `curl`, which names
   each archive itself:

   ```sh
   python3 scripts/install_check.py --published vX.Y.Z
   curl -fsSL https://www.701.dev/install.sh | sh -s -- --dir /tmp/landin-X.Y.Z
   /tmp/landin-X.Y.Z/bin/refine version   # refine X.Y.Z
   ```

   The first holds the names `install.sh --list` gives for X.Y.Z to the
   release's assets as `gh release view` lists them: each must be
   published, and each archive published must be one the script names.
   A failure there means the release workflow and `install.sh` name a
   platform differently, and `install.sh` is changed on `main` before the
   release is announced. The scripts job holds the script's names to the
   text of `release.yml` (`scripts/tests/test_install_script.py`); this
   step holds them to what the release published.
7. **Move the flake.** On a branch from `main`, one commit moves
   `flake.nix`'s `releaseVersion` to X.Y.Z and its `releaseHashes` to the
   sums in the published `.sha256` files, which the publishing job's log
   also prints. `nix build .#refine-bin` must then print `refine X.Y.Z`
   from `result/bin/refine version`, and `python3 scripts/nix_route.py
   --work /tmp/nix-route` must pass on the branch: the default
   `nix profile install` and `nix run` then fetch the newly published
   archive, report X.Y.Z and run the first program (D1707). The commit is
   gated, its flake job running the same check, and promoted like any
   other; after it is on `main`,
   `nix run github:701-dev/Landin -- version` prints `refine X.Y.Z`.
8. **Move Homebrew**, as [the installers](#the-installers) say: run the
   tap's `bump-landin` workflow and check the formula.

The images are built only here (D1667, D1668): never from `main` or a
commit, so the Debian packages inside one are those of the day its
release was built. The gate builds the user image on every software run,
from its own packaged compiler, in `outside-user-stock` on amd64 and
`arm64-release` on arm64, and runs the first program inside it; the
contributor image, whose build fetches the toolchain and builds the
compiler, is built only by the release workflow and a rehearsal.

### The release workflow and its settings

`release.yml` is tag-driven: a `v*` tag builds and publishes the `refine`
assets that `nix build .#refine-bin` consumes, and the two container
images. Its first job,
`scripts/release.py gated`, refuses a tag whose commit is not on `main` or
whose own push gate on `main` did not succeed, so a tag on an unmerged or
ungated commit publishes nothing. Its last, `scripts/release.py publish`,
makes the release a draft, uploads every asset, reads the list back and
only then publishes it; a run that stops part-way leaves a draft that the
next run empties and fills, and an asset of a published release is never
replaced. The archives record root as every member's owner.

A release also rests on two repository settings and an attestation
(D1337), which `gh api` reads back:

- The ruleset `version tags`, `gh api repos/701-dev/Landin/rulesets/27105000`,
  is active on `refs/tags/v*` and refuses creating, moving, deleting and
  force-moving such a tag to everyone but the repository's
  administrators, who bypass it: its bypass list must name the role
  Repository admin, and the ruleset's `current_user_can_bypass` says
  whether the account about to push can. Check it before tagging: a
  transfer of the repository empties the list, and a refused push asks no
  one for approval. git.sr.ht has no tag protection, so a
  `v*` tag there proves nothing: a release tag is made on GitHub, by a
  push of it or with the release, and the mirror holds it only if it was
  pushed through both URLs.
- The environment `release`, `gh api repos/701-dev/Landin/environments/release`
  and its `deployment-branch-policies`, deploys only from a tag matching
  `v*` and requires JanHaan's approval; it lets JanHaan approve his own
  run, and an administrator may bypass it. Only the publishing job runs
  in it, so the run waits after the builds have passed and logged their
  checksums: approve it under "Review deployments" on the run's page
  once they are what was meant. A dispatch runs on the tag, `gh workflow
  run release.yml --ref vX.Y.Z -f tag=vX.Y.Z`; `scripts/release.py ref`
  refuses one made on a branch before anything is built.
- The publishing job alone holds `id-token: write` and
  `attestations: write`, and attests every archive with
  `actions/attest-build-provenance` before the release is published. The
  `.sha256` beside an asset is written by the same job with the same
  token, so it says the file arrived whole and not who built it; the
  attestation says this workflow built it from that tag. The release
  notes give the check:

```sh
gh attestation verify landin-VERSION-PLATFORM.tar.gz --repo 701-dev/Landin \
  --signer-workflow 701-dev/Landin/.github/workflows/release.yml \
  --source-ref refs/tags/vVERSION --deny-self-hosted-runners
```

The attestations of releases up to 0.2.10 name the repository's former
owner, the account `JanHaan`: for those, write `JanHaan` for `701-dev` in
both options.

A tag on a commit older than these steps runs that commit's workflow,
which has neither the environment nor the attestation; the ruleset leaves
making one to an administrator.

### The installers

Two installers follow a published release, and neither is moved by the
release workflow. The flake's `releaseVersion` and `releaseHashes` are
written by hand from the publishing job's log, as `flake.nix` says beside
them. The Homebrew formula, `Formula/landin.rb` in
<https://github.com/JanHaan/homebrew-tap>, is moved by that tap's
`bump-landin` workflow, which runs daily and points the formula at
GitHub's latest release. Right after publishing, run it at once rather
than waiting for the schedule:

```sh
gh workflow run bump-landin.yml --repo JanHaan/homebrew-tap -f version=X.Y.Z
```

Then check it: the tap's `main` gains the commit `Landin formula X.Y.Z`,
and on a Mac with Apple Silicon and on Linux `brew update && brew upgrade
landin` (or `brew install janhaan/tap/landin`) followed by `brew test
landin` passes; the formula's test runs `refine version`, which must name
X.Y.Z, `refine svd --help`, a split command found in the keg's
`libexec/landin` only through `refine`'s resolved path, and `refine run`
of the README's first program. The tap is the maintainer's own
repository, outside this one's gate.

The formula depends on these properties of a release, so a change to any
of them changes the formula first, in the tap:

- the assets are `landin-X.Y.Z-PLATFORM.tar.gz` under the tag `vX.Y.Z` of
  `701-dev/Landin`, for exactly the platforms `aarch64-darwin`,
  `aarch64-linux` and `x86_64-linux`, which the tap's bump script
  lists and the formula names one by one;
- beside each archive a `.sha256` file whose first field is the archive's
  SHA-256 sum; the bump reads those and downloads nothing else;
- the archive is an installed prefix with no top-level directory —
  `bin/refine`, `libexec/landin/refine-NAME` and `lib/landin` — which the
  formula installs whole into its keg;
- `refine` finds `lib/landin` and `libexec/landin` from its own resolved
  executable, because Homebrew links the keg's `bin` and `lib` into its
  prefix but not its `libexec`;
- the release is GitHub's latest one, which a draft or a prerelease is
  not, and the formula's test program still compiles and runs.
