---
name: landin-change
description: Carry a Landin roadmap item, or any other repository change, from its start to main - worktree, brief, reserved identities, checks, gate, boards, promotion, clean-up and the report - and dispatch items to agents. Use for compiler, fixture, tooling, process and roadmap work; exclude read-only language questions and release/version changes.
---

# Carry a Landin item or change to main

Read the checkout's [AGENTS.md](../../../AGENTS.md), then the item's text in
`ROADMAP.md` (its heading, the Mechanics section and the rows and questions
it names; never the file whole) and the authorities it touches. The
[development loop](../../../docs/process.md#the-loop-that-runs-now) owns the
commands and gate conditions; this skill puts them in order.
`scripts/item.py` does every step that needs no judgement, and keeps the
item's state on disk, so a reopened session loses nothing: `python3
scripts/item.py --help` lists the steps.

## After any reopen, first

A restart, a resume or a change of account ends the session's background
commands. Run `python3 scripts/item.py resume ITEM` (or without ITEM from
the item's worktree) before anything else: it prints the worktree's state,
every recorded run as running, finished or lost, the gate runs, the
journal's last lines and the next step. A detached run survives a reopen;
wait on it again rather than starting it anew. Write a decision or a
finding into the journal as you make it, `item.py note ITEM TEXT`, so that
what a successor needs is never only in the conversation.

## An item, start to finish

1. **Start.** `python3 scripts/item.py start ITEM`, run from the clone's
   main checkout, fetches, refuses a complete item or one whose
   dependencies are not complete, makes the worktree `../Landin-ITEM` and
   its branch from `origin/main`, reserves decision, row and question
   numbers no other running item of the clone holds, marks the item
   active, moves the pointer if it names the item, commits that
   (`Gate: explanatory`) and writes the brief. `--adopt WORKTREE` takes on
   one made by hand. The brief says what runs beside the item; an item
   beside another coordinates shared ground (register rows, item text, the
   controls that read the live roadmap) with that item's owner.
2. **Work** only in the worktree. Choose exact `dev-test.sh` selectors in one
   invocation; run anything longer than a few minutes as `item.py run ITEM
   NAME --limit SECONDS -- COMMAND`, which is `run_logged.py --detach` kept
   in the state, and wait with the `run_logged.py --wait DIR` it prints, or
   by the harness's notification. Script controls: `python3
   scripts/script_tests.py NAME ...` runs named modules and shards
   `check.py`'s controls; whole `test_check_controls` under plain unittest
   takes over ten minutes. A new script that names `ROADMAP.md`,
   `README.md` or `roadmap/` needs an entry in `scripts/tests/
   test_gate_inputs.py`'s `READERS`, or the scripts job fails.
3. **Push** once the affected checks pass, then `item.py gate ITEM --watch`:
   it records the head's runs and follows the gate in a detached
   `gate_watch.py --all`. Investigate a failed job from its log; a fixed
   push supersedes the run. Another item's gate at the same time shares
   the runners and both take longer.
4. **Boards.** When the push gate passed, `item.py boards ITEM` dispatches
   the `scope=boards` run on the same head and records it; `item.py gate
   ITEM` refreshes its result.
5. **Close** by [the checklist](../../../docs/process.md#closing-an-item):
   activations against the item's base, the passes it lists, the `Done:`
   paragraph naming the findings fixed, rows deleted or filed, the
   register's cap and age rule, the pointer, the full `python3 check.py`.
   A closing commit that touches only the explanatory files says
   `Gate: explanatory` and reuses the gate; any other is a new tree.
6. **Promote** with `item.py promote ITEM` (`--dry-run` first if unsure). It
   refuses unless the head is the pushed head, main is its ancestor, a push
   gate on the head passed with every job passed or skipped, a boards run
   passed on the same tree or before only explanatory commits, and the item
   is complete in the candidate (`--partial` for work short of the close).
   If main moved, merge `origin/main`, push and gate the merged tree. An
   item that says `Promotion: maintainer` stops at the passed candidate.
7. **Follow main**: `item.py gate ITEM --main --watch`. A failure there is
   investigated, never rerun blindly.
8. **Finish**: `item.py finish ITEM` refuses until main's gate passed, then
   removes the worktree, the local and remote branch, and moves the state
   to `landin-items/done/`, where it stays.
9. **Report** in [the report form](report.md); `item.py report ITEM`
   drafts it from the state, with the open questions the item asked last.

A decision only the maintainer can take is a question file, never only a
line in a report: `python3 scripts/register_next.py --question --file
--asked-by ITEM`. Carry on with its default and with all the work its
answer cannot change. A finding the item fixes is named in its commit and
`Done:` paragraph; only one that outlives the item becomes a row under
`roadmap/register/`, and a usability finding met on the way is one too, as
AGENTS.md's "Friction is a finding" says.

The item's agent holds standing authority to push, promote and clean up
its own worktrees and branches unless the item says `Promotion: maintainer`
(`ROADMAP.md`'s Mechanics); other work promotes only when that action is
authorized. Releases and versions are never covered.

## Dispatching items to agents

A session that runs the roadmap rather than an item keeps no state of its
own beyond what `item.py` keeps:

- `item.py start ITEM` makes the item's worktree and brief; the brief is
  the agent's whole first message. Create the agent in that worktree, one
  item each, with the host's own rules for model and account.
- `item.py status` lists the running items; `item.py stalled` names any
  that nothing has moved for an hour, with its next step, and exits 1. An
  idle agent is not proof that its runs ended: the state says.
- Act on reports, not raw material: the report's runs and commits are what
  to check (`gh run view RUN`, `git log -1 COMMIT`).
- A successor to such a session needs only `item.py status` and the open
  questions, which `roadmap/register.md` lists with their defaults.

## Improving this skill

Fix the skill and `item.py` from a review held between items, never
while an item runs on them: a running item keeps the steps it started
with. Record what an item met in its report's FRICTION, and as a register
row when it outlives the item.

## Other changes

A change that is no roadmap item follows the same order without `item.py`:
its own worktree and branch from an explicit base, the exact checks, the
push, the gate, and promotion only when authorized. For parallel streams
within one item use the
[ownership and integration recipe](../../../docs/process.md#parallel-sessions-and-shared-resources):
each writer its own worktree, branch and identity range, a named
integrator. Hardware work needs its authorized operator and the rig's
common lock. A review request returns findings without assuming
permission to implement or publish.
