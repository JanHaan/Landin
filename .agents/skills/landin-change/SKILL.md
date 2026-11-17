---
name: landin-change
description: Implement or validate a Landin repository change and prepare its candidate for CI or main promotion. Use for compiler, fixture, tooling and process changes; exclude read-only language questions and release/version changes.
---

# Carry a Landin change through validation

Read the checkout's [AGENTS.md](../../../AGENTS.md) and the affected source
authorities. Use the current [development loop](../../../docs/process.md#the-loop-that-runs-now)
and its relevant recipes; they own the commands and gate conditions.

Establish the checkout, starting commit and existing changes before editing.
Keep unrelated work out of the candidate. For implementation, identify the
affected behavior and choose exact checks that can expose it. For a review
request, return findings without assuming permission to implement or publish.
Carry the user's existing authorization forward without asking again.

For parallel work, use the
[ownership and integration recipe](../../../docs/process.md#parallel-sessions-and-shared-resources).
Before dispatch, give each writer its own worktree and branch from the
common base, its owned paths and identity ranges, and name the integrator
and who publishes.
Paseo's default shared checkout and its agent status are not isolation or
resource locks. Use the current `paseo-hubbish` skill when coordinating there;
carry exact commit and evidence handoffs between the authorized sessions.
Hardware work requires its authorized operator and the common rig lock,
even when streams address different boards or probe slots.

Use the [local feedback recipe](../../../docs/process.md#local-agent-feedback)
for environment setup, combined selectors, retained logs and the wait method
supported by this harness. Inspect the final result and selected scope before
reporting completion. A running command or a child's idle state alone does
not establish that its work is finished.

Before closing implementation work, use the
[closing checklist](../../../docs/process.md#closing-an-item) against the
starting commit, including its unmatched activations and the checks its
changes require. Do not add closure work to a documentation-only review.
Keep language decisions in the specification and remaining work in the
roadmap, rather than in this skill or a separate task list: a finding the
item fixes is named in its commit and `Done:` paragraph, and only one that
outlives the item becomes a row under `roadmap/register/`.

Once a push is authorized and affected checks pass, push the candidate and
follow the [gate](../../../docs/process.md#the-mechanical-gate). Investigate
failed jobs and verify the complete job listing. An item's agent holds
standing authority to push, promote and clean up its own worktrees and
branches unless the item says `Promotion: maintainer` (`ROADMAP.md`'s
Mechanics); other work promotes only when that action is authorized.
Promote to main when the complete software gate passed, a `scope=boards`
dispatch passed on the identical tree unless the edit is declared
`Gate: explanatory`, and the promoted tree is the tested tree; then follow
main's own push gate, with its fresh boards, to its end. If main advanced, integrate first and obtain evidence for
the resulting tree. A decision only the maintainer can take is a question
file, never only a line in a report: `python3 scripts/register_next.py
--question --file --asked-by ITEM` writes the next one with the parts
`ROADMAP.md`'s Mechanics require. Carry on with its default and with the
work its answer cannot change, and name the question in the report.

Return what changed, the check scope and result, retained evidence, findings,
and any pending work. State whether the candidate is local, pushed or on
main. This skill supplies no release/version authorization or host access.
