# The report an item's agent sends

An agent started for an item ends with one message in this form and sends
nothing before it. Whoever reads it acts on this message alone, so it must
stand without the agent's context. Keep it under 300 words; put everything
else in a file and give its path. `python3 scripts/item.py report ITEM`
drafts it from the item's state, the open questions it asked last.

```
RESULT: done | partly done | stopped | failed
  One sentence: what now exists, and where (commit, branch, main or not).

EVIDENCE:
  Each claim with what a reader can check: commit hashes, run numbers with
  their result, the command and its scope (say FILTERED or HOST-ONLY where
  it is). "Passed" without a run number or a command is not evidence.

NOT DONE:
  What the brief asked that you did not do, and why.

STATE:
  Where a successor finds what it needs: the item's state directory,
  files, worktree, branch. Whether you can be archived.

FRICTION:
  What a newcomer could not have guessed, one line each. Rows you filed,
  by identity. "None" when none.

NEEDS JAN:
  Last, so that it is what the reader leaves with. One line per open
  question: its file, the question, the options, your recommendation,
  the default you took and what waits on the answer. "nothing" when there
  is nothing. If an answer must come from the maintainer in your own
  session (a release, a version, anything your rules reserve), say so and
  that you have stopped for it.
```

Rules that go with it:

- Wait for your own subagents and background runs before sending it. A
  message sent while work is still running wakes its reader for nothing.
- If you must wait more than an hour for the maintainer, note your state
  (`item.py note`), send the report with RESULT: stopped, and end.
- Say plainly what you did not verify.
