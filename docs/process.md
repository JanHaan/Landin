# Development and validation

`ROADMAP.md` owns the work left on this process. The loop below is the
one that runs now. The [gate reference](#the-mechanical-gate) describes its
jobs and reuse rules. The historical sections preserve the exact-revision
native acceptance that approved every revision through 0.2.0 and was retired
with SourceHut: nothing submits it, `scripts/ci/` is gone, and no revision is
accepted. They record how those approvals were chosen and what they cost.

## The loop that runs now

| stage | command | what it says |
|---|---|---|
| edit/test loop | `./scripts/dev-test.sh` with affected exact `--suite` and `--case` selectors, or one `--fixture` selector | checksum-safe feedback; the transcript says `FILTERED` |
| Mac compiler host | `./scripts/dev-test.sh --host --target=linux-x86-64` | compiler checks only; every selected case passes, and no Linux workload is emitted or run |
| another Linux architecture from this host | `./scripts/dev-test.sh --target=linux-arm64 --runner=qemu-aarch64 --toolchain=DRIVER` | a cross lane under QEMU: the emitted code's evidence, not the pinned toolchain's |
| before pushing a candidate | affected exact developer cases/suites and script controls; `python3 check.py` after documentation changes | focused feedback; the complete matrix runs once in CI |
| before pushing explanatory-only prose | `python3 check.py` and review the prose against what it describes | every document invariant and the accuracy of the explanation |
| after touching the harness | `./scripts/parallel-equivalence.sh --suite='fixture execution'` | a wider run reaches the same verdicts, byte for byte |
| before pushing a Darwin change | focused native Mac checks, with LLDB in an appropriate security audit session when affected | native developer feedback; full host/parity/debugger coverage runs in CI |
| candidate push or pull request | `.github/workflows/gate.yml` | every target unless verified identical-candidate or explanatory-only reuse applies: both compiler modes on Linux x86-64 with GDB, quality and bindings; both on Linux arm64 with GDB and bindings; the host suite, hosted parity and LLDB on macOS arm64; Linux emission followed by separate runtime, LLDB and C ABI verdicts in each FreeBSD architecture's Linux-hosted VM; the RV64 Linux test program under QEMU's user emulation, its physical runtime, GDB, C ABI and ISA-level verdicts on RISE runners suspended until further notice; every QEMU lane on Cortex-M; the editor grammar, the flake, `scripts/tests`, cross-host assembly-manifest comparison and the scaling benchmark |
| physical boards for a candidate | `gh workflow run gate.yml --ref BRANCH -f scope=boards`, by the maintainer | each port's RAM run, then its boot check, on the rig through `environments/boards/gate.py`, with `inputs`, documents and scripts; never a software pass |
| promotion to main | the [promotion rule](#physical-boards-and-promotion): the candidate's complete software gate, a passed boards dispatch on the identical tree, then main's own push gate followed to its end | the push reuses the full candidate software pass and runs the boards fresh; documents and script controls still run |
| closing an item | `python3 scripts/activations.py`, then the steps in [closing an item](#closing-an-item) | the register rows whose activation the item's changes met, and the passes only the gate runs that the changes reach |

Every software lane runs on GitHub-hosted images; the FreeBSD lanes boot
their VMs inside the job. Only the physical board legs run on the rig's
self-hosted runner, and only for a push to `main`, the weekly schedule or a
manual dispatch.
See [the runner requirements](environments.md#github-actions-runners) for
labels, tools and scheduling.

From a modern checkout on a Mac, choose the affected exact case or suite.
The host selector accepts a suite or case, not a fixture selector. With the
default `darwin-arm64` build tag, an example is:

```sh
./scripts/dev-build.sh
LANDIN_TEST_JOBS=1 ./scripts/dev-test.sh --host --target=linux-x86-64 --suite=checking
```

For debugger changes, run an affected native workload/profile with
`scripts/debug.sh` after building this checkout's compiler. A second run
replaces its own earlier output; an `--output` naming any other nonempty
directory is refused. Full native parity and debugger matrices belong to
the candidate CI run, rather than every local editing loop.

When a push is authorized, push the final candidate to a branch and let its
complete gate finish. Use completion notifications and investigate failed logs instead of repeatedly
watching or rerunning the matrix. A failed gate reports itself only when its
last lane ends, so follow it with `python3 scripts/gate_watch.py`, which
returns at the first failed job with its step and log command; a pushed fix
cancels the superseded run. Before promotion, verify the complete job
listing and the tested tree; a changed merge tree needs its own full pass.
Promotion also needs a passed boards dispatch on that tree, unless the edit
is explanatory, and `main`'s own gate followed to its end, as the
[promotion rule](#physical-boards-and-promotion) says.
The item may be closed in the candidate itself or after its gate. A closing
commit made after the branch's full gate that changes only the content of
`README.md`, `ROADMAP.md`, `handoff.md` and `AGENTS.md`, and says
`Gate: explanatory`, reuses that gate under the explanatory exception, on
the branch and again when main is promoted to it (D586). A close that changes
any other file, `docs/capabilities.md` among them, is a new tree and needs
its own full gate.
The [identical-candidate reuse policy](#the-mechanical-gate) compares all
tracked bytes, paths and modes, including workflow definitions and tool pins, with
a recent complete successful push run from this repository. It never uses
local filtered transcripts or build caches as test evidence. A manual
dispatch of scope `full` requests a fresh full matrix and the boards.
Superseded runs on a branch are cancelled.

The [explanatory-only remote reuse policy](#the-mechanical-gate) permits
qualifying edits to reuse a complete successful push run, of main or of a
branch, from the preceding seven days, whose commit is an ancestor of the
edit. Document and script checks always run.

Choose the smallest test that can expose the changed behavior first, broaden
only for another affected subsystem, and let the full CI gate validate the
final candidate once. Run a complete local suite when an investigation needs
it, rather than as a duplicate mandatory pre-push step. The
explanatory-only prose path does not cover generated Ada or catalogues,
executable examples or fixtures, or grammar and semantic rules in `spec.md`.
The gate is a safety net rather than a verdict: each push runs every target
or meets the verified candidate/explanatory reuse conditions above. On a failed Cortex-M job, it is configured to upload
diagnostic output if present and retain it for 14 days. The called determinism workflow retains assembly manifests as short-lived
artifacts. These are not a successful exact-revision acceptance record; green says the tree passed there, not that
a revision is accepted. Documentation changes still receive the full
`check.py`; its mechanical checks do not establish prose accuracy.

The parallel-equivalence wrapper builds once under the standard mode lock,
then holds the same binaries across both runs. Its printed evidence directory,
or a new directory selected with `--output=DIR`, retains build output, both
raw stdout/stderr streams, exact commands, exit statuses and full diffs.
Verdict text is compared byte for byte; only the exact elapsed field of a
progress line is normalized. Matching case failures establish equivalence
but are printed explicitly and still need investigation.

On Linux, `scripts/test.sh` (also used by `dev-test.sh`) and
`scripts/parallel-equivalence.sh` disable glibc's per-thread allocation cache
in the fresh test process, preserving other allocator tunables. This lets the
memory controls distinguish live small allocations from freed cached blocks;
each measurement first checks that a held 512-byte block is counted and that
freeing it restores the baseline exactly. Direct test-binary invocations
whose meter fails that check refuse with the launcher route. The initial build
retains its inherited allocator settings; test subprocesses inherit the
prepared test setting. Ordinary `refine` invocations keep their defaults. The
worker comparison records the effective setting alongside each command.

## Closing an item

Before an item closes:

1. Run `python3 scripts/activations.py --base REV`, with REV the commit the
   item started from (`main` by default). It lists every `open` or
   `scheduled` register row whose Activation names a path the item changed
   since REV, uncommitted changes included, and the passes only the gate
   runs that those paths reach: the editor grammar's corpus,
   `./highlight/test.sh --integration`, when the grammar, a positive,
   runtime or ABI fixture or `core/` changed, and the flake's build when
   `flake.nix`, `flake.lock` or `environments/pins.sh` did. Take each row it
   lists, or restate its activation, in the item; run each pass it names
   inside `nix develop`, or add `--run` to have it run them. A row counts
   only the changes made after the commit that added it or last changed its
   Activation, when that commit is since REV: a change its writer had
   already seen is what the row was written about. Each listed row names
   the commits that met it, the rows left out for this are named, and
   `--whole-window` counts every change since REV for every row.

   It is a heuristic and says so: it matches paths an activation writes,
   in backticks or bare, base names of tracked files, Ada unit names and a
   few names of an area that always mean one file. A row that names an area
   in words is counted and not matched; `--unmatched` lists those rows, to
   be read against the item's changes by hand.
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
3. Write the `Done:` paragraph, remove the register rows the item settled
   and list their identities among the records that have left the
   register, as `ROADMAP.md`'s mechanics ask.

   Update the pointer in `README.md` and `handoff.md` too. Substitute the
   item identity and title in these exact forms. Use the current form for
   active work, the next form for the first dependency-ready planned item
   when no item is active, and the endpoint form only when all roadmap
   work is complete:

   ```text
   **Current roadmap work: ITEM — TITLE.**
   **Next roadmap item: ITEM — TITLE (planned).**
   **Roadmap endpoint: ITEM — TITLE (complete).**
   ```

An item worked in parallel streams merges each stream's branch with git.
When a stream's work is passed as a patch instead, make it with
`git add -N . && git diff HEAD --binary`: `git diff --binary` alone compares
the working tree with the index, so a change already staged, a file removed
with `git rm` among them, is silently missing from the patch.

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
count at the project's `-j0`, every core: a build of the whole compiler took
190 seconds at `-j4` and 72 at the default on a 32-core host, and the kernel
shares the cores between concurrent builds better than a `-j` or a `taskset`
chosen for each one. When several related commands are necessary, enter
`nix develop` once and run them inside it. Use `sh -eu -c` for dependent
commands, so an earlier failure stops the sequence.

An agent harness runs every command in a fresh shell, and `nix develop -c`
evaluates the flake before each one, about two seconds a command.
`scripts/agent_env.sh` evaluates it once per `flake.nix`, `flake.lock` and
`environments/pins.sh`, writes what the shell exports to a file under
`~/.cache/landin/agent-env/`, and prints that file's path; sourcing it takes a
few milliseconds and leaves `TMPDIR` alone. Where there is no nix, or the
toolchain is already on `PATH`, it prints `/dev/null`, so
`. "$(./scripts/agent_env.sh)"` holds in either shell. Claude Code takes the file
through a SessionStart hook in `.claude/settings.local.json`, which then
reaches every Bash command of the session and of its subagents:

```json
{"hooks": {"SessionStart": [{"matcher": "", "hooks": [{"type": "command",
  "timeout": 180,
  "command": "s=\"$CLAUDE_PROJECT_DIR/scripts/agent_env.sh\"; [ -x \"$s\" ] && [ -n \"$CLAUDE_ENV_FILE\" ] && f=$(\"$s\") && [ -n \"$f\" ] && cat \"$f\" >> \"$CLAUDE_ENV_FILE\"; exit 0"}]}]}}
```

The file is the environment of the checkout the session started in; a
worktree whose flake or pins differ needs its own `nix develop`. The hook is
local to Claude Code and is not installed by cloning the repository. In
Codex, whose commands may each start a fresh shell, source the helper's
cached exports before commands that need the pinned tools:

```sh
landin_agent_env=$(./scripts/agent_env.sh)
if [ -n "$landin_agent_env" ]; then
    . "$landin_agent_env"
fi
```

An empty result means the helper has nothing to add; do not source an empty
path. Re-run the helper after changing the flake or pins.

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
540 seconds by default it exits 124 and prints the log's last line instead,
so the same call is made again. Choose a timeout below the calling tool's
limit: a 600-second tool call can use the default, while a tool limited to
60 seconds can use `--timeout 45`. A tool that yields a process session can
resume that session instead of opening another wait. Exit 124 means the
logged command is still running, not that it failed. A run whose wrapper
died without a result exits 125 at once. Do not wait with `sleep`
loops over the log, nor with `pgrep -f`, whose pattern also matches the
waiting shell's own command line, so the wait never ends. A live progress
inspection is appropriate when diagnosing a stall, rather than as a timer.

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
when its integrator owns publication. Merge each stream's branch with Git,
as the closing recipe describes, so staged additions and removals survive.
Reconcile semantics and fixtures as well as textual conflicts.

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
resulting tree under the [reuse rules](#the-mechanical-gate). A green gate
on a stream's old tree does not cover a changed merge. Promote the tested
tree with a normal fast-forward push; a rejected race calls for another
fetch and integration, not a force push. Before deleting refs, compare
GitHub and the mirror as the gate reference requires, and remove only the
task's refs and worktrees after their owner has released them.

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
whole boot-then-RAM sequence. A manual run waits for a CI leg as for any
other holder; a CI leg waits 1200 seconds, then ends `rig-busy` naming the
holder, which fails its gate. While the shared directory is used, a held
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
`.claude/skills/landin-change` resolves to that source. Check discovery from
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
python3 scripts/script_tests.py
python3 scripts/script_tests.py test_fuzz_close test_scaling

# Follow HEAD's gate run and return at its first failed job, rather than
# when its last lane ends; with --all, follow it to its end and name every
# failed job, when a round's fixes should go in one push.
python3 scripts/gate_watch.py
python3 scripts/gate_watch.py --all

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

# Render the documents selected in docs/site/render_html.py as HTML,
# verify their text was not dropped, and package them. It does not publish:
# .github/workflows/pages.yml is the only publisher; see docs/site/README.md.
./scripts/site.sh

# On a nix machine, a shell holding the pinned toolchain and python3.  It
# reads environments/pins.sh and tags its objects `nix-${system}`, so it does not
# collide with the other environments; see docs/environments.md.
nix develop

# Build the compiler through the flake.  .#refine is the default and builds
# this checkout from source -- about 140s on a fast Linux host, and the same
# cold, because the 478MB of pinned toolchain fetches alongside the compile.
# .#refine-bin fetches the published release asset instead, in about 5s, and
# ignores the working tree: it answers "give me the compiler", not "build
# what I have".
nix build .#refine
nix build .#refine-bin
```

## The mechanical gate

`.github/workflows/gate.yml` is the mechanical gate, and it runs on every
push and pull request, weekly on `main` and on a manual dispatch. A new
candidate runs every target the compiler has,
in jobs that report separate verdicts. RV64 runs under QEMU's user
emulation on an x86-64 runner, which is evidence about its emitted code and
none about RV64 hardware; its jobs on RISE's physical runners stay skipped
until they are dependable. A recent verified identical candidate
or the explanatory-only exception below may reuse a full pass. Compiler
builds supply checked executables to their same-host consumers, including
the debug compilers used for cross-host determinism. The final `gate` job requires every build and verification
job, including cross-host determinism, to succeed or be skipped under verified
reuse or the event's scope; document and script checks must always succeed,
and on a board-scope event so must every physical board leg.

Linux x86-64, Linux arm64 and Darwin host checks run the production C
publication, private-directory and cancellation controls alongside formatter write
safety, with cancellation also exercised through actual `compile` and
`run` commands. Each FreeBSD architecture's first runtime shard compiles
and executes the same C adapters inside its guest. That is native system
call evidence, separate from the Linux-hosted compiler and the generated
program corpus; it is not a FreeBSD-hosted Ada compiler claim.

A branch push or same-repository pull request by an author with write access
may reuse a complete successful push run from this repository from the
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

A declared explanatory edit confined to the content of `README.md`,
`ROADMAP.md`, `handoff.md` and `AGENTS.md` may reuse a complete successful
push run of this repository from the preceding seven days, of `main` or of
any other branch, whose commit is an ancestor of the edit (D586). So a
documents-only commit that closes an item after its branch's full gate
reuses that gate on the branch and again when main is promoted to it. A
branch's run is as trustworthy a base as main's: only someone with write
access can push to a branch, and the tree key covers the workflow that run
executed and every tool pin. Live GitHub verification of a full main
run, the classifier output and a skipped-lane aggregate gate completed before
this path was enabled.
Every intervening commit must carry the exact line `Gate: explanatory`;
the event must be a push to a branch of this repository, `main` or another,
or a same-repository pull request whose author has write access. Declare
only changes to explanation, with no
change to language rules, targets, scope or acceptance claims. The source
tree key preserves all other bytes, paths and modes. Missing, partial,
expired or mismatching evidence runs everything. Documents and script
checks always run, and a reused run can never itself supply the full pass.
The aggregate gate covers each build, test and determinism host separately.

For a successful reuse, the `inputs` log names the source commit and links
the full run being reused. Target and build jobs, including `determinism`,
appear as skipped; `inputs`, `documents`, `scripts` and the final `gate`
still succeed. The linked full run contains the target-test results.

| job | runner | runs |
|---|---|---|
| `inputs` | `ubuntu-24.04-arm` | verify a recent full pass for an identical candidate, or a full push pass of main or a branch for a declared explanatory edit |
| `documents` | `ubuntu-24.04` | `check.py`, about ninety seconds, needing neither the toolchain nor a built compiler |
| `scripts` | `ubuntu-24.04` | every `scripts/tests` module at once through `scripts/script_tests.py`, `check.py`'s controls among them in shards, and the determinism, quality and debugging controls |
| `linux-debug-build` | `ubuntu-24.04` | build the debug executables once for the `compiler` shards, `compiler-checks`, `build-modes` and the Linux x86-64 determinism manifest |
| `compiler` matrix | `ubuntu-24.04` | the debug compiler's complete suite in three `--shard` jobs, `compiler-1` to `compiler-3`, at `LANDIN_TEST_JOBS=8` |
| `compiler-checks` | `ubuntu-24.04` | with the same debug compiler: the default target, a required Emacs-to-`refine lsp` diagnostic smoke, the determinism closures, native report identity, the scripted server sessions through `refine lsp`, and the server under one round of mutated corpus sources |
| `linux-release-build` | `ubuntu-24.04` | build the release executables once for the Linux release, outside-user-stock, build-modes, Cortex-M and scaling jobs |
| `release` | `ubuntu-24.04` | the same with the release compiler and the scripted server sessions, then object quality and the GDB sessions |
| `outside-user-stock` | `ubuntu-24.04` | the release compiler packaged and used outside the checkout on a stock Ubuntu with only its own GCC, refusing to run if the pinned driver is reachable: the first program, every `examples.md` program, the distribution's driver and a trap's report |
| `build-modes` matrix | `ubuntu-24.04` | the debug and the release compiler of one tree emit the positive and runtime corpora, the firmware corpus and the Cortex-M counterparts at the four standard profiles and must agree byte for byte: Linux x86-64 and RV32 in `build-modes-1`, Linux arm64 and Cortex-M in `build-modes-2`; `build-modes-1` also compares both Xtensa configurations |
| `bindings` | `ubuntu-24.04` | `refine bindings`, with the debug compiler `linux-debug-build` made, against its pinned Clang |
| `editor-grammar` | `ubuntu-24.04` | the structural grammar's integration pass with the pinned tree-sitter CLI |
| `flake` | `ubuntu-24.04` | `nix build .#refine .#refine-bin`, the native and Pi board RAM helpers built (including native Rust controls), every flake output of every system evaluated and the development shell entered, on every run that does not reuse a pass, a full-scope dispatch included (D585) |
| `cortex-m` matrix | `ubuntu-24.04` | every Cortex-M and RV32 lane on the locked QEMU and GDB, at `LANDIN_CORTEX_JOBS=4`, as `run.py`'s three parts, which together are every lane once: the probes, firmware, device programs and debug evidence in `cortex-m-programs`, which also builds all eight board ports in boot and RAM layouts without hardware and keeps their build/drift evidence and the stack-switch consumer's capacity report (D470); the whole corpus on the M0, the M33 and the M7 in `cortex-m-corpus`; and the RV32 controls and corpora on Espressif's QEMU in `cortex-m-rv32` |
| `xtensa` matrix | `ubuntu-24.04` | `xtensa-esp32` and `xtensa-esp32s3` each run bounded chip-machine window, scalar, floating, assembly and completion-oracle controls, independent vendor-C layout/carrier probes, strict configured-assembler and baseline compatibility controls, plus the complete freestanding inventory on the pinned Espressif QEMU's `sim` machine with the exact selected CPU and explicitly virtual RAM; logs and per-fixture verdicts are retained |
| `scaling` | `ubuntu-24.04` | `scripts/scaling.sh`, failing when frontend time, emission time or peak memory grows more than 2.5 times per doubling, or when a compact static image's assembly, object or assembler memory outgrows its bound |
| `darwin-debug-build` | `macos-26` | build the debug executables once for the `darwin-host` job and the Darwin determinism manifest |
| `darwin-release-build` | `macos-26` | build the release executables once for the `darwin-host-release` and `darwin-parity` jobs |
| `darwin-host` | `macos-26` | the debug compiler host suite, determinism, report identity and the scripted server sessions |
| `darwin-host-release` | `macos-26` | the release compiler host suite and the same follow-on checks, then the LLDB sessions, which had a job of their own until it was found holding one of the five macOS runners the account may use at once while `darwin-parity` queued for it |
| `darwin-parity` | `macos-26` | the hosted corpus executed natively, every Darwin source verdict and the bindings |
| `arm64-debug-build` | `ubuntu-24.04-arm` | build the debug executables once for the `arm64-compiler` shards, `arm64-compiler-checks` and the Linux arm64 determinism manifest |
| `arm64-compiler` matrix | `ubuntu-24.04-arm` | the debug compiler's whole test program on the Linux arm64 lane in two `--shard` jobs, `arm64-compiler-1` and `arm64-compiler-2` |
| `arm64-compiler-checks` | `ubuntu-24.04-arm` | with the same debug compiler: representative verifier resources, the default target, the determinism closures, native report identity and the scripted server sessions |
| `arm64-release` | `ubuntu-24.04-arm` | the same corpus with the release compiler, the default target, the server sessions, the GDB sessions with the pinned aarch64 GDB and the generated bindings for the standard AAPCS64 |
| `freebsd-amd64-runtime`, `freebsd-arm64-runtime-1`, `freebsd-arm64-runtime-2` | `ubuntu-24.04` | emit with the checked Linux release compiler and locked sysroot, check source verdicts, assembler boundaries and linked instructions, then execute the applicable runtime corpus in a fresh FreeBSD 14.4 VM, amd64 under KVM and arm64 emulated, including guest CPU confirmation; the emulated arm64 lane runs as two shards of whole fixtures |
| `freebsd-amd64-debugger`, `freebsd-arm64-debugger` | `ubuntu-24.04` | the same emission, then native FreeBSD LLDB source stops, frames, local values and unwinding in the VM |
| `freebsd-amd64-abi`, `freebsd-arm64-abi` | `ubuntu-24.04` | the same emission, then nonempty C ABI fixture sets against independently compiled FreeBSD C peers in the VM |
| `rv64-qemu` matrix | `ubuntu-24.04` | the release compiler's whole test program on the Linux RV64 lane in two `--shard` jobs, `rv64-qemu-1` and `rv64-qemu-2`, linked by Ubuntu's riscv64 cross driver and run under the flake's pinned `qemu-riscv64`, its CPU's every level confirmed; the emulator's own failures listed in `compiler/tests/cross-lanes.json` are reported and not counted; the first shard also runs the RV64 GDB sessions, the stack switch's among them, under the same emulator's GDB stub |
| `rv64-emit` matrix | `ubuntu-24.04` | suspended since 2026-10-13 and not required by `gate`; when running, cross-emit checked RV64 runtime, GDB, C ABI and ISA payloads for RISE; source/hash checks, invalid IR register regression and instruction inspection |
| `rv64-runtime`, `rv64-debugger`, `rv64-abi`, `rv64-isa` | ubuntu-24.04-riscv | suspended since 2026-10-13 and not required by `gate`; when running, separate corpus, native GDB, nonempty independent C peers and hardware-confirmed baseline/extended ISA execution on physical RISE runners |
| `board-bundles` | `ubuntu-24.04` | on a board-scope event only, whatever the software lanes reuse: the release compiler built from the commit, every board's boot and RAM bundles by `environments/boards/build.py --mode=both --records=strict`, so drift from a hardware record fails before a board runs, and one 14-day artifact with `provenance.json` and `files.sha256`; never reused |
| `board` matrix | `[landin-rig]`, the rig's self-hosted runner | `board-rp2040`, `board-pico2`, `board-stm32h753`, `board-esp32c3`, `board-esp32c5`, `board-esp32` and `board-esp32s3`, one at a time on the rig's one runner: a sparse checkout of the exact commit, the bundles downloaded by artifact id against their digest, their file list and provenance checked, then `environments/boards/gate.py --lock-wait=1200`, each port's RAM run and then its boot check; 50 minutes a leg, 70 for the Pico 2's four steps; each leg's evidence, `board-evidence-PORT-ATTEMPT`, one per run attempt, kept 90 days, also after a failure or a cancellation, and the aggregate judges each port by its latest attempt; never reused |
| `determinism` | `ubuntu-24.04`, `ubuntu-24.04-arm`, `macos-26` | the called workflow emits the fixture manifest for all nine targets on each host in two jobs of four and five targets, including both Xtensa levels, joins each host's parts and compares the three, starting once the three debug builds succeed rather than after their suites |

Linux and Darwin lanes run on GitHub-hosted images for every event, as do
the called determinism workflow and the links, Pages and release workflows;
the registered runners measured slower and are no longer selected. The
board legs alone run on the self-hosted rig runner described below. The
FreeBSD lanes boot their VMs inside the hosted job, arm64 under emulation
because GitHub's arm64 images offer no KVM. See [the runner environment requirements](environments.md#github-actions-runners).

A compile error surfaces in its host's debug or release build job; Linux
arm64's release lane still builds its own. In
[run 37227405592](https://github.com/JanHaan/Landin/actions/runs/37227405592),
the successful shared release-build jobs took 300 seconds on Linux and 447
on Darwin; their compilation steps took 273 and 425 seconds respectively.
Successful verification jobs took 328 seconds for `release`, 153 for
`scaling`, 102 for the then separate `lldb` job and 486 for `darwin-parity`.
These whole-job times
include setup and artifact handling, but exclude queueing and waiting for
the shared build dependency.

The determinism manifest jobs covering all nine optimization/specialization
combinations took 150 seconds on Linux x86-64, 137 on Linux arm64 and 276 on
Darwin arm64; manifest emission itself took 50, 40 and 105 seconds
respectively. The agreement job took five seconds. These are observations
from a single run, excluding failed jobs whose durations cover only part
of their work. They are not a controlled
comparison with the earlier measurements before artifact sharing, and no
CI time saving has been demonstrated. Same-run build archives are
short-lived inputs, not acceptance records.

The gate is **not** the retired acceptance: it retains no successful
exact-revision acceptance record, and green is not a verdict on a revision.
On a failed Cortex-M job, it is configured to upload diagnostic output if
that output exists; uploaded artifacts are retained for 14 days. It is a
safety net over every target.

The gate calls `determinism.yml`, which
requires every host in its matrix to emit the same bytes; it emits and hashes
but never assembles, links or runs. It also supports manual dispatch.
`pages.yml` publishes <https://www.701.dev>
when a site input changes on `main`, or when dispatched manually. `links.yml`
checks changed documents on a push and every document weekly or manually.
Changes to link checker configuration and unknown changed ranges also check
every document.
`release.yml` is tag-driven: a `v*` tag builds and publishes the `refine`
assets that `nix build .#refine-bin` consumes.

The exact-revision native acceptance in `scripts/ci/` approved every revision
through 0.2.0 and was removed when the project left SourceHut. Do not cite it
as current and do not claim a change is accepted: nothing accepts revisions
now, and the gate above is a safety net rather than a verdict on a revision.
`environments/native-ci/README.md` and `environments/macos-arm64/README.md`
describe the retired arrangement.

The repository submits no build manifests. GitHub is canonical and takes
pushes directly; git.sr.ht is a mirror, kept in step by a second push URL on
the same remote rather than by a job. The mirror therefore holds only what a
push through that remote sent it: a branch or tag made on GitHub itself —
the release tags, a branch opened from the web — is not on it, and a ref
deleted on GitHub alone stays on it. A deletion reaches it only when
`git push origin --delete` runs from a clone with both push URLs, and git
refuses that whole push to sr.ht when any ref it names is missing there,
while GitHub still accepts it. Compare `git ls-remote` of
<https://github.com/JanHaan/Landin> and <https://git.sr.ht/~sinnfrei/landin>
before deleting, and delete what is only on one of them from that one by its
URL. Nothing reports a disagreement between the two. `pages.yml` fetches the licensed code
face from object storage because it is not in this repository; it renders and
verifies, and runs no compiler test. `scripts/site.sh` renders and packages
and does not publish. Nix CI is limited to the gate's `flake` job, which
builds the flake on every run that does not reuse a pass (D585); no derivation is cached, `rv64-qemu` takes only its emulator from
the flake, and the former automatic Nix manifest is retired. Historical SourceHut gate links
remain evidence for their original revisions.

`check.py` uses only the Python standard library and changes to its own directory, so it can also be invoked by absolute path from elsewhere. It is a heuristic invariant checker, not a parser, compiler, formatter, or semantic test suite. Run the full command after documentation changes; targeted checking of an absolute `tour.md` path does not run all citation checks.

Use `scripts/dev-test.sh --host --target=linux-x86-64` on the Mac for
compiler-host feedback, and expect every selected case to pass. The unfiltered harness includes Linux
execution and fails without its target toolchain, so do not run Linux
containers, Linux workload emission or repeated complete suites on the Mac as
routine feedback. Run changed-component tests while editing, then push the
final candidate to a branch for one complete CI matrix. Do not repeat the
complete local matrix merely before pushing and watching the same CI tests.
Before promoting the candidate to main, verify its complete gate succeeded,
that a boards dispatch passed on the same tree unless the edit is
explanatory, and that the promoted tree
is the one tested; merge changes require new evidence. A full local run remains useful when an investigation requires it,
and is not a substitute for the multi-host gate.
After documentation changes run the full `python3 check.py` and review the
prose against what it describes. The explanatory reuse exception does not
cover generated Ada or catalogues, executable examples or fixtures, or the
grammar and semantic rules in `spec.md`. `LANDIN_TEST_JOBS` splits the corpus fixtures across
workers, which is most of what the suite costs. One worker is still the
default, and `scripts/parallel-equivalence.sh` is what holds a wider run to
the same verdicts.

Linux, Darwin and Cortex-M runtime and debugger evidence comes from the
gate, or from a host you run yourself; the former exact-revision native
acceptance runner is retired.
A Darwin change receives focused checks on a Mac before it is pushed, and so,
when a Mac is available, does a change to the harness or to fixtures the
Darwin lanes run: `darwin-parity` and `darwin-host` were the lanes most often
red in October's gate runs. The full Darwin suites run in the candidate's CI
matrix. LLDB must inherit a
graphical or terminal security audit session; an arbitrary background
session may not launch a debugged process, regardless of debugger rights.
The hosted macOS image's runner session may launch one. The first native Mac run's retained
expected-refusal transcript, in which the unfiltered harness failed only for
want of a Linux driver, is historical bootstrap evidence, never a current
success rule.
`docs/process.md` explains the workflow.

`scripts/test.sh` builds and runs the complete Linux test program on native
Linux. Its `--host` selector retains compiler checks on the Mac. `scripts/dev-build.sh` and
`scripts/dev-test.sh` use GPRbuild's checksum mode for fast feedback, and the
latter accepts exact `--suite`, `--case` and `--fixture` selectors, as many
as a change reaches in one run; each named fixture executes in turn. A
filtered run says `FILTERED` in its transcript and is not gate evidence. There
is no separate lint or typecheck step: the pinned build treats every warning
as an error and enforces GNAT style checks. Warnings are policy, not preference
— do not silence one without a recorded reason.

Staleness is decided by source checksums, not timestamps: `build.sh` rebuilds
from clean when the manifest disagrees, because an edited-and-reverted file
keeps a newer mtime than the object built from it and gprbuild would serve the
stale object. The developer wrappers instead pass the pinned GPRbuild's `-m2`
checksum mode; source inventory or project-file changes still force a clean
tree, and a failed developer build is resumed rather than cleaned. A clean
tree keeps `bin/`: executables are linked into `link/` and published into
`bin/` by a rename, only while no corpus lane or manifest run holds the
build's readers lock (`scripts/build_lock.py`). A compiler-only build records `refine` as current without claiming that
`landin_tests` is current; the next full build still builds the test program.

### Physical boards and promotion

A board-scope event is a push to `main`, the weekly schedule at 04:00 UTC
on Mondays, or a manual dispatch, in this repository only;
`scripts/gate_inputs.py scope` decides it from the event. On such an event
`board-bundles` and every board leg run whether or not the software lanes
reuse a pass, and the aggregate requires each of them to succeed and every
port's outcome to be `passed`. A skipped, cancelled or failed leg, a leg
that never reached the rig, and any other outcome, `rig-busy`,
`needs-setup` and `unavailable` among them, fail the gate: missing physical
evidence is not a pass. On every other event, a branch push or a pull
request, the board jobs must be skipped, and the gate's summary says
"physical boards: not run for this event". A green gate there is software
evidence only.

A dispatch of scope `boards`, and the schedule, run `inputs`, `documents`,
`scripts`, `board-bundles` and the board legs and no software lane. Their
run is named "gate: boards only", their summary says "boards only: no
software lanes", and they never supply a software pass, because reuse takes
only push runs whose every software job ran and succeeded. Physical jobs are
never reused: `gate_inputs.py`'s `PHYSICAL` keeps them out of the reuse
list, so a main push that reuses its candidate's software pass still runs
the boards fresh. A main run whose boards fail has a failed gate, and so
cannot serve as a reuse base.

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
whose pre-job script exits nonzero before any of its steps
([running scripts before or after a job](https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/run-scripts)),
so nothing from a refused job's checkout runs on the rig. The repository's
setting for approving fork pull requests, the maintainer's and recommended
at all external contributors, is a second layer. The board jobs read no
secret, and their token can only read the contents and the actions.

A candidate reaches `main` in three steps:

1. Its complete software push gate passes on its branch.
2. A dispatch of scope `boards` passes on the identical tree,
   `gh workflow run gate.yml --ref BRANCH -f scope=boards`. An edit declared
   `Gate: explanatory` skips this step; its main push still runs the boards.
3. `main`'s own push gate, with its fresh boards, is followed to its end.
   A failure there is investigated, never rerun blindly.

An unavailable rig blocks promotion. A RAM run's success never establishes
power-on, ROM loading or fixed-image restoration, so every leg runs each
port's RAM run before its final boot check, leaving the verified fixed image
at rest. An unknown or interrupted prior state prepends a restoring boot
check before RAM. The configured steps in `environments/boards/rig.json`
decide the order; the Pico 2 covers both architectures.

### Proving a change emits the same bytes

A change meant to alter no emitted output is shown to by two manifests,
one from a compiler built before the change and one from a compiler built
after it, emitted over the same checkout and compared. Keep the first
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

## Historical: choosing acceptance scope

The maintainer's decision for the retired acceptance was: full
gates only at major milestones, Linux work on native Linux, debugger checks
only for substantial regression risk, and Nix CI deferred. The rest of this
section is that policy as it stood at 0.2.0.

| stage | work | evidence |
|---|---|---|
| edit/test loop | checksum-based build and exact affected case/suite/fixture selectors; affected Python tests | development feedback |
| Mac compiler host | `scripts/dev-test.sh --host`; diagnostics, compiler units and complete IR golden | explicit host scope; no Linux workload emission/execution |
| Linux development | `scripts/ci/controller.py dev --slot NAME -- COMMAND...` on the native runner | focused native feedback; no approval |
| native Darwin candidate | schema-4 debug/release host checks and complete release source/runtime/ABI, derived programs and bindings | required matching archive and compatible Linux scope |
| routine main promotion | five committed jobs: debug host suite, full release suite/runtime/ABI and native report identity, release object quality, bindings, documents/tooling | exact-commit routine approval |
| substantial debugging risk | routine coverage plus full native release GDB and LLDB | exact-commit routine approval that includes the debugger job |
| major phase/parity milestone | full Linux suite/quality/GDB and Darwin host/source/runtime/ABI/bindings/LLDB in both compiler modes, plus documents/tooling | exact-commit milestone approval |
| publication | verified export, annotated approval, atomic main/tag promotion, guarded Pages rendering | delivery of the approved revision |

Do not run Linux containers or Linux workload matrices on the Mac during
development. In-process compiler units may still inspect target-specific data;
that is host-compiler coverage, not Linux execution. `--host` excludes the two
native target-workload cases and requires every remaining case to pass. The
IR comparison that exposed the first native Mac run's Ada argument-order defect
remains included.

Choose the smallest test that can expose the changed behavior first. When it
passes, broaden only for another affected subsystem or a remaining concern.
Run routine acceptance once for the final committed promotion candidate;
Linux can resume verified successful jobs after interruption. Darwin has no
resume path: interrupted or failed runs require a new run. Failed Linux jobs
or changed source also require a new acceptance run. Do not repeat full local matrices before
that gate. Documentation changes still receive full `check.py`; the checker
retains every invariant and fixture.

Debugger risk means changed debug metadata, source/variable locations,
unwind/frame conventions, debugger transport, debugger checks, or acceptance
selection/verification of debugger evidence. Record the
reason for enabling it. A status-page edit or an unrelated tool change is not
a reason to run debugger matrices. An Ada evaluation-order repair that changed
no debug encoding, location or unwind code and passed the unchanged IR golden
used routine scope without GDB; a change to debugger selection and
verification used routine scope with full release GDB and LLDB.

The judgments made under these definitions ran as follows. Noreturn and panic
control flow, frames and source-site identity needed debugger-risk coverage,
and so did the generated device fixtures' debugger-controlled boot and stack
assertions. A new debugger-visible type — the several-atom pointer union, with
GDB and LLDB presentation checks — selected routine scope with debugger
coverage; it closed no phase and added no target, ABI convention or
instruction selection, so milestone scope was not warranted. Committing a
check that reads and verifies debug metadata on all three targets forced
debugger coverage even though no emission changed, because selecting or
verifying debugger evidence is itself debugger risk; the size of the run did
not make it a milestone. The derived prototype coverage register changed no
debug metadata and selected or verified no debugger evidence, so it ran at
routine scope without debugger coverage: every result it records came from a
job routine scope runs anyway, and running the prototypes according to the
applicability matrix is not a parity claim.

Milestone scope was selected for a phase or parity closure: complete hosted
parity, the freestanding evidence that closed the Cortex-M0 work, and the
first roadmap's endpoint. The endpoint changed no compiler code, which is why
the items before it that closed no phase ran routine; a phase closure is
answered by milestone scope whatever the code change, because a routine
approval cannot later be cited as a milestone result. Its debugger coverage
arrived with the full matrix rather than with a risk.

Before a major milestone, select and commit milestone scope with the closure
candidate. A routine approval cannot be cited as a full milestone result.
Subsequent development returns to routine scope.

```sh
python3 scripts/ci/policy.py routine
python3 scripts/ci/policy.py routine --debugger
python3 scripts/ci/policy.py milestone
```

These commands edit both native policy files; commit them before acceptance.
Darwin schema 4 records host modes, hosted modes and debugger modes explicitly.
Routine retains complete release coverage; `--debugger` adds every release
native debugger profile and derivative. Milestones run both modes. Approval
validates the exact commands, selected scope and matching archive. Historical
Linux schema-1 approvals remain full eight-job evidence; Darwin schemas 1/2/3
retain their original contracts, including schema 3's Linux milestone rule. The native
operations guide documents acceptance, export, approval and promotion.

## What the measurements say

The retained full Linux run `20260914T204024Z-147ccbe20b60` ran its eight jobs
concurrently. Its slowest job determined about 91 minutes of wall time:

| component | debug compiler, seconds | release compiler, seconds |
|---|---:|---:|
| complete suite command | 4738.5 | 1096.4 |
| object-quality command | 5438.8 | 1070.2 |
| native debugger command | 2823.9 | 555.8 |

The document/tooling job took 111.0 seconds, including 88.2 in `check.py`,
10.5 in CI failure-path tests and 2.1 in rendering. The complete first native
Mac harness took 2522.2 seconds in debug and 911.3 in release, largely compiling
Linux workloads before the inevitable missing-tool refusal. Those runs remain
historical evidence, not the future development cadence.

A local Python profile put 99.9 of 106.5 instrumented seconds in the grammar
corpus check: 50.9 in recognition and 44.7 in lexical membership. The lexical
matcher was called 952266 times. It now reuses repeated spellings within one
file with a bounded cache. Grammar edits cannot reuse answers from a previous
invocation, and token offsets/refusals remain checked. No corpus is skipped
and no persistent cache supplies acceptance evidence.

The subsequent same-host profile took 72.6 seconds, about 32% less. Lexical
membership fell to 101568 calls and 8.2 instrumented seconds. The new debug
host run passed 711 cases and 192905 checks; its transcript timestamps span
about 280 seconds including incremental rebuilding. These local measurements
describe this checkout and host, not fixed performance bounds.

The first routine run, `20260915T082011Z-70a07a37aea3`, measured 1208.5
seconds for its slowest job. Release suite and quality commands took 1094.9
and 1081.5 seconds; their separate bootstrap builds took 111.6 and 113.8.
Debug host checks took 437.3 seconds after a 46.1-second build. Documents
and bindings jobs took 84.1 and 60.6 seconds. These are measured results,
not fixed performance bounds.

## Parallel work and build reuse

The outer jobs already run in parallel. The remaining opportunity is inside
long jobs: independent workload/profile compilations run sequentially, and
the same compiler mode or workload is built for several consumers.

The proposed build graph is: one compiler build per mode, independent program
builds keyed by their complete inputs and flags, then separate execution,
quality and debugger consumers. Share immutable artifacts with verified
identities, not mutable output paths. Use one aggregate CPU/memory budget;
nested unrestricted worker pools would oversubscribe the runner. Keep
GPRbuild's existing Ada dependency and checksum handling.

An evaluation compared one and two workers on native Linux using the same
immutable release compiler and fresh outputs for the parser/container
programs under none/off and size/auto. The four compilations took 111.15
seconds sequentially and 55.55 with two workers; every assembly hash matched.
Individual peak RSS was at most 50372 KiB. These samples justify two-worker
experimentation; they do not bound memory for the whole fixture matrix.

The evaluated dependency graph keys a compiler artifact by complete source,
project/pin inventory, host/tool identities, mode, flags and path mapping.
A workload artifact additionally keys reached source/roots, configuration,
profile, debug settings, compiler identity, adapter inputs and target tools.
Execution, quality and debugger consumers retain independent run records.
The two existing release compiler artifacts have different binary hashes and
sizes in their different build contexts; they cannot simply be exchanged
under today's acceptance identity records. Their builds already overlap, so
sharing would save CPU but is not a measured 112-second wall-time improvement.

The production scheduler/cache remains deferred to the scale and self-hosting
successor that `ROADMAP.md`'s register names. Integrating bounded workers
requires shared cancellation, timeout ownership and aggregate resource tests;
artifact sharing requires an acceptance-schema change for producer identities.
The quality command's second compilation deliberately checks determinism and
must stay fresh. Cache hits must be labelled as reuse, and native execution
must still run. This closes the evaluation without weakening those oracles or
introducing nested worker pools into the routine gate.

## Nix later

The current `flake.nix` supplies development shells and two `refine`
packages, one built from the checkout and one fetched from a release. It does
not define the project's test derivations. More `nix develop` invocations
alone would not remove repeated compilation. The gate's `flake` job builds
both packages, evaluates every output of every system and enters the shell
on every gate run that does not reuse a pass (D585); that is the whole of
Nix CI today, and what follows is what it does not do.

Nix could later own compiler packages and suitable `checks` with narrow,
complete inputs, and schedule them on the correct native builders. Its flake
checks build the declared check derivations; distributed builds and separate
job/core controls provide the scheduling mechanisms.
[Flake checks](https://nix.dev/manual/nix/2.35/command-ref/new-cli/nix3-flake-check.html),
[distributed builds](https://nix.dev/tutorials/nixos/distributed-builds-setup.html),
[job/core controls](https://nix.dev/manual/nix/2.32/advanced-topics/cores-vs-jobs).

Nix CI beyond building the flake is explicitly deferred. A later evaluation
must account for the pinned Apple SDK, native debugger permissions, input selection, cache provenance and
the existing native acceptance record. Build reuse cannot replace the native
Darwin, Linux or freestanding executions required at a milestone.


## Historical Darwin acceptance progression

Native Darwin lowering added `scripts/ci/darwin.py accept COMMIT` to ordinary
promotion. It ran the committed native Mac policy and exported source, tools,
artifacts and execution evidence. Approval used `approve LINUX_BUNDLE --darwin
DARWIN_BUNDLE`; the two bundles had to describe exactly the same archive, and
the annotated approval bound both. macOS source debugging added native LLDB
acceptance and selected the sixth Linux routine job, release GDB, because DWARF
serialization became shared. Full hosted parity was a separate milestone scope.

The Darwin lowering work used a focused LLDB session to locate an Ada
precondition failure in variant emission and a native C frame-chain probe for
the newly implemented arm64 frame convention. No Linux GDB matrix was selected:
Linux frame layout, DWARF and instruction selection were unchanged. Nix CI
remained deferred.

macOS source debugging used the exact same archived source for the native LLDB
policy and Linux routine acceptance with GDB. Native debugger, dsymutil and
dwarfdump versions were checked against the Mac policy, with binary hashes
retained. Source maps, Mach-O UUIDs, dSYM identities and stripped behavior were
required evidence. The production scheduler/cache and broader resource
dispositions stayed as recorded; Nix CI stayed deferred.

Hosted parity selected and committed `policy.py milestone` before its closure
candidate. Its Linux gate ran the complete suite, quality and native GDB in both
compiler modes, plus bindings and documents/tooling. Matching Mac schema-3
acceptance ran compiler-host checks, the complete shared source/runtime/ABI
corpus and all three derived programs with native LLDB in both compiler modes.
The [parity guide](../compiler/tests/darwin/README.md) records exact coverage
and platform limits. The accepted revision kept its milestone policy; routine
scope returned only in subsequent development. No local Linux containers,
production scheduler/cache changes or Nix CI were added.

## Historical Cortex-M environment acceptance

The Linux documents job additionally ran the pinned
[Cortex-M environment probes](../environments/cortex-m/README.md) and their
failure controls. Its exported `cortex-m` artifacts bound the live result to
the accepted archive. Missing tools or failed probes refused acceptance.
Adding the environment selected routine debugger-risk coverage for its debugger
controls and acceptance command/retention changes, not the full milestone
matrix. Darwin kept native hosted/LLDB validation.

The Cortex-M0 layout and ABI work kept compatible routine policies with release
native GDB/LLDB because it added ABI/frame obligations and executable debugger
assertions. The Linux embedded path also ran the layout/ABI controls; the
original CPU, peripheral and Renode-lock regression obligations stayed
mandatory. Pure target/compiler checks used the Mac host selector; embedded
execution used only the supported Linux runner.

The concurrency memory model kept compatible routine debugger-risk policies:
new instruction selection, scratch use, alignment traps and verifier coverage
affect the native code/debug boundary. Full release GDB/LLDB accompanied
complete release hosted coverage and both Mac compiler-host modes. The Linux
embedded evidence export also included the memory controls and models, from
the identical candidate archive. Nix CI remained deferred.

Packed images selected routine debugger risk because packed
extraction/selection, verification and raw-carrier DWARF changed. The Linux
documents job built the committed debug compiler before the mandatory combined
embedded probe. The probe exported compiler-generated native/Renode execution
alongside independent M0 C/assembly and model controls, with existing lock
cleanup and ABI/memory lanes preserved. These development or model results did
not authorize promotion; matching native archive acceptance and the guarded
publication path did.

Generated Cortex-M0 code ran through the supported native Linux runner and the
existing Cortex probe/export path. The complete corpus ran under an external
startup/linker test harness. Its physical-limit and source-restriction records
remain distinct from execution passes. This changed neither native
Linux/Darwin acceptance nor the firmware publication path; the identical
archive still needed both native bindings before approval and promotion.

Compiler-owned firmware added mandatory execution to that same embedded
probe/export command. Its fresh-image comparisons, QEMU boot/exception runs,
Renode device traces and independent C/assembly controls remain
distinguishable from the old external backend harness. Startup, frame and
exception changes selected routine acceptance **with debugger risk**: full
release Linux GDB and Darwin LLDB, debug compiler-host checks and complete
release hosted execution. Both policies were committed before the closure
candidate, and all embedded artifacts bound to that archive.

The derived driver kept routine debugger-risk scope because it exposed a
checking control-flow defect and a firmware ELF load-address defect. Both native
policies had to match; the mandatory embedded lane included every inherited
probe plus `environments/cortex-m/driver.py`. Its complete program and protocol
ran on native Linux, while Mac development used `--host`. The exact accepted
archive bound the source, model premises, literal oracles, firmware/linker
artifacts and bounded resource observations.

The freestanding evidence selected compatible **milestone** policies on both
native hosts before the closure candidate. They kept debug/release
compiler-host, hosted execution, quality and native debugger coverage plus every
inherited embedded lane. The mandatory embedded entry also invoked
`evidence.py`: complete-driver resource scenarios, Cortex source sessions,
source/debug selection refusals and independent stack/exception controls.
Cortex remote GDB is distinct from native Linux GDB and native Darwin LLDB. An
isolated development function call did not replace execution through this
mandatory entry or exact-revision acceptance, and failed or interrupted
resource runs remained failed evidence. That closure needed both native
archives and all of its embedded gates to pass; delivery promoted precisely
that shared revision, without a later bookkeeping commit.
