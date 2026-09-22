# How the two language documents are arranged

`tour.md` explains the language and `spec.md` decides it. This says how each
is laid out, so that a reader looking for a rule knows where to look and an
editor adding one knows where to put it. It is derived from the documents
and is not an authority over them.

## Both are arranged by subject

Neither document is in the order its contents were written. `tour.md`
teaches in subject sections, from comments through to the toolchain, and
`spec.md` follows the same subjects in the same order, so a question about
arrays is answered in one place whichever document it is asked of.

`spec.md` is three parts:

| part | what it holds |
| --- | --- |
| the grammar of the enabled kernel, [1740] to [1830] | what the compiler accepts today, and nothing else. It shrinks as the language grows. |
| the rules the tour left unsaid, [1840] to [1990] | the permanent rules a tutorial omits because a reader supplies them. Grouped: names and scopes, types and literal context, what an operator takes, places and assignment, calls and errors, module values, and the boundaries the compiler owns. |
| the decisions this document took, D1 to D242 | fourteen subject sections, each decision with what the tour said before, what was chosen, the alternative, and the fixture that pins it. |

A construct id is a stable citation anchor and never moves. The consequence
is that the numbers no longer ascend down the page: [1950] sits beside
[1890] because both say what an operator takes, and D1 sits beside D233
because both say what a declaration introduces. Inside a register section
the numbers still ascend, so a run of decisions that built one subject
together is read in the order it was built. Nothing that cites an id has to
know where it sits.

## Where a new rule goes

A rule about the shape of accepted source belongs in the grammar, and
`check_grammar_corpus` will hold it to the fixture corpus. A rule about what
an accepted program means belongs in [1840] onward, in the group whose
subject it shares. If the rule was a choice rather than a transcription of
something `tour.md` already said, it also gets a register entry, in the
register section matching its subject — and that entry names the fixture
that pins it, which `check.py` requires to exist.

The subject is decided by what the rule decides, not by its heading. Two
register entries were filed under the wrong subject on a first pass for
exactly that reason: D154 reads as a function-outcome rule and is a
`core/diag` rule, and D185 reads as a scope rule and is the condition-binding
form.

## What the reorganisation preserved, and how that is known

The reorganisation moved units; it did not rewrite them. All 443 units — 270
in `spec.md`, 173 in `tour.md` — moved with their content unchanged, checked
by parsing both documents before and after and comparing every unit by its
key. The prose that was edited is the prose that the moves made false: the
two documents' own descriptions of how they are ordered.

`check.py`'s grammar corpus is the standing evidence that the language did
not change with the documents. It derives the positive fixture corpus from
`spec.md`'s own grammar while the Ada parser meets the same corpus from the
other side, so a grammar broken while being moved fails there rather than in
a review.

That covers the syntax, and it is worth being exact about what it leaves
uncovered. Nothing in this repository checks that a prose rule from [1840]
on, or a register entry, still means what it meant: a rule whose meaning
changed while it was being reworded would pass every check here. What stands
behind those is that they were moved rather than rewritten, which is a
property of how this pass was done and not one anything re-checks. An editor
who rewords one is on their own, and the fixture named in a register entry is
the nearest thing to a check that the entry still describes the compiler.
