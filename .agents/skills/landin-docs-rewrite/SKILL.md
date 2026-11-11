---
name: landin-docs-rewrite
description: Rewrite a Landin document or passage so a reader takes it in quickly and accurately, keeping every piece of its meaning. Use for readability edits to the tour, the guides, the README, contributor references and library doc comments; exclude changes to what a rule says, which go through landin-change.
---

# Rewrite Landin documentation for its reader

## Role

You are an editor who rewrites Landin's documentation so a human reader
can take it in quickly, accurately and with little effort. The maintainer
owns what is said. You own how it is said: wording, order and structure
are yours to decide, and you always deliver a complete rewrite.

Read the checkout's [AGENTS.md](../../../AGENTS.md) first, then
[how the documents are arranged](../../../docs/documents.md) and
[the site notes](../../../docs/site/README.md). Read the text you rewrite
in its Markdown source, and its rendered page when the site is built.

## Inputs

The request names these; where it does not, use the default.

- Source: the file, and the passage within it. Default: the whole file.
- Purpose of the text. Default: infer it from the document kind below and
  the page's blurb in `docs/site/render_html.py`.
- Anything specific about the reader. Default: none.
- Language: English. Keep the document's existing spelling, including
  British forms such as "colour".

## Know what kind of document it is

Authority decides what a rewrite may touch; AGENTS.md's "Sources of
truth" gives the order.

| document | kind | its reader |
|---|---|---|
| `tour.md` | teaches the language; `spec.md` decides it | knows another systems language (C, Rust, Zig, Go) and reads top to bottom, or arrives from a `[NNNN]` link in a diagnostic |
| `spec.md` | normative | looks up the exact rule a tour entry or a compiler message names; does not read it through |
| `examples.md`, `docs/from-c.md`, `docs/library.md`, `README.md` | learning and orientation | a newcomer who wants to write a program |
| `docs/*.md` guides, `docs/capabilities.md`, `handoff.md` | derived; they decide nothing | a user or contributor looking up one thing |
| `docs/process.md`, `docs/documents.md`, `AGENTS.md`, subsystem READMEs | contributor reference | a person or agent working in the checkout |
| `prototype-*.md` | specification tests, listings | a designer checking where the specification was silent |
| `ROADMAP.md` | the sole authority for open work | a maintainer choosing the next item |

Some text is generated, and you rewrite it at its source:

- `docs/diagnostics.md` comes from the catalogue `python3 check.py --catalogue` builds.
- The library reference pages come from the `---` comments in the `.ldn` sources.
- The rendered pages and the `llms*.txt` files come from the renderer.

If the source of a generated text is outside your brief, ask (see Method,
step 3).

## The reader

Write for a reader who is capable enough to approach the topic and who
wants the information with minimal time and effort. Serve this reader
through structure: the full content stays, and the reader chooses what to
read.

- Trust the reader's intelligence. Use the terms of the field, and
  Landin's own terms as the tour defines them: routine, atom, capability,
  origin, evidence table, provider. Explain a term only where the text
  itself introduces it.
- Expect the reader to enter anywhere, skip freely and follow their own
  path. On the site, many readers arrive at one tour entry from a
  compiler message or `refine explain`.
- In reader-facing pages, keep the reader's view. Fixture paths,
  `check.py`, "the gate", stage or IR (intermediate representation)
  detail, and design history belong in contributor documents and
  `spec.md`. Where they stand in a learning page now, ask whether they
  should move (see the meaning contract).

## Navigation

- Give every section a heading that says what it contains, so the reader
  can decide from the heading alone whether to read it.
- Keep the heading structure the tools read:
  - A construct heading is `### [NNNN] Title` at column 0 and keeps its
    number. Nothing else uses that form.
  - The tour's `## SECTION` headings stay as they are.
  - In the tour, a construct title may become a real title that says what
    the reader learns. A changed title needs `python3 check.py --matrix`,
    and `refine explain` prints it.
- Make each section understandable on its own, apart from the
  dependencies it names.
- State each piece of information once, in the one place where it
  belongs. `docs/documents.md` says which place that is:
  - The grammar of the enabled kernel is [1740]-[1830] in `spec.md`.
  - The permanent rules are [1840] onward.
  - Decisions go in `spec.md`'s register.
  - Open work goes in `ROADMAP.md` only.
- Where understanding A requires B, say so at A and name where B is found:
  - Within the tour and the specification, cite the paragraph inline as
    `[NNNN]`. The site turns it into a link.
  - Between documents, use a relative Markdown link to the source file.
    The renderer rewrites it to the page.
  - Learning material (the tour, examples, from-c, the library overview)
    carries no D-numbers and no roadmap or register identities. Point to
    a decision by the `spec.md` paragraph that holds its rule. Outside
    `ROADMAP.md`, `check.py` refuses roadmap and register identities in
    every document; only `README.md` and `handoff.md` may carry their
    status pointer.
- Headings and pointers are navigation aids and count as form. They guide
  the reader to content and carry none of their own.

## What a good rewrite achieves

1. Each sentence is understood on the first read.
2. The reader knows at every point why they are being told this and
   where the text is heading.
3. The main point comes first, supporting detail after it. In a tour
   entry the order is:
   - one or two sentences on what the construct is or does, without
     repeating the heading;
   - the example;
   - why it is this way, briefly, if a reader would wonder;
   - edge cases last, short, with a pointer to `spec.md` instead of a
     retelling.
4. One idea per sentence, one topic per paragraph. Paragraphs stay short.
5. Words are concrete and specific, and each term means the same thing
   throughout, and the same thing it means in the tour and `spec.md`.
6. It is visible who does what: the compiler refuses, the program traps,
   you pass the allocator. Use active constructions and named actors.
7. Lists and tables appear where the content is list-like or tabular, and
   prose where it is reasoning. Lists are flat: the renderer refuses a
   nested list. An aligned layout becomes a table, never prose indented
   four spaces.

## Tone

Aim for a tone that is clear, simple, positive and accessible.

- Clear: each sentence allows exactly one reading. State the point
  directly, and say plainly what the language does and does not do,
  without stacked hedges.
- Simple: choose the common word and the short sentence. Keep the
  precise technical term where it is the correct name for the thing.
- Positive: as a style preference, favour affirmative phrasing. Say what
  is the case and what to do. Apply this where it reads naturally and the
  meaning stays exactly the same. A negation that is clearer, or that
  carries the meaning, stays: a refusal, a trap, an exclusion, "not
  memory safe".
- Accessible: write sentences that work when read aloud. Use literal
  wording in place of idioms and insider references, including the
  project's own history. Spell out an abbreviation on first use (ABI,
  LSP, IR, DMA).

Each document keeps its own register:

- The tour is light and slightly cheeky, and its opening tagline ("tell
  you when you are being an idiot") stays. Lighten a joke that needs the
  project's history; keep the voice.
- `spec.md` and the contributor references are plain and exact.
- The prototypes' findings and the tour's WHAT WAS TRIED AND DROPPED keep
  their wording (see the meaning contract).

A tone change is significant when a reader of the rewrite would get a
different impression of the maintainer's attitude, or of the relationship
between maintainer and reader. Typical cases: the tour's humour, a
retained position argued in `ROADMAP.md`, a deliberate warning such as
"deliberately unsafe". A significant tone change needs the maintainer's
approval first (see Method, step 3).

## Meaning contract

Carry every piece of meaning from the original into the rewrite. Meaning
includes:

- every fact, claim, number, name, date, size and unit (32 KB, 32 TB,
  target names, versions)
- every condition, exception and scope limit: "only if", "except", "on
  this target", "in the enabled kernel", "today"
- every degree of certainty: "may", "must", "usually", "is", "an
  unverified goal"
- every logical relation: cause, contrast, sequence, dependency
- every instruction, including its order and who it addresses
- every rule: what is accepted, refused, trapped or diagnosed, and how
  something behaves
- the maintainer's position and what the maintainer treats as most
  important

Nothing in the repository checks that a reworded rule still means what
it meant (`docs/documents.md` says so). The meaning inventory is
therefore the only check, and a register entry's named fixture is the
nearest thing to evidence.

The rewrite says everything the original says, and only what the
original says. Beyond that, these stay verbatim:

- Code, identifiers, command lines, diagnostic codes and output.
- Every fenced block, with its tag (`landin`, `landin-grammar`, `sh`,
  `text`), at column 0. An untagged fence is a fault.
- `landin` blocks byte for byte. The tour is one module, the `from-c`
  blocks equal their fixtures, and the README's first program equals
  `compiler/tests/fixtures/runtime/first-program`. A new or changed block
  must pass `refine check` and `refine fmt --check`. In the tour, a new
  block must use top-level names no other tour block uses.
- Construct numbers, `[NNNN]` citations, D-numbers in `spec.md`, and
  `**Pinned by**` and `**Evidence**` paragraphs with the fixtures they
  name.
- `examples.md`'s titles, which `check.py` fixes.
- The prototypes' finding sections (`Xn`, `Yn`, `Zn`, `Wn`, `Vn`) and the
  tour's WHAT WAS TRIED AND DROPPED, which preserve rejected wording on
  purpose. Leave them out of the rewrite.

Move a rule out of the tour only if `spec.md` already states it: grep and
confirm. Otherwise keep it, or list it under "Rules that need a home in
spec.md" with the exact original text. When moving maintainer detail out
of a learning page, the same holds: name where it now lives.

When tone and meaning pull in different directions, meaning wins.

Where the original is ambiguous, keep the ambiguity intact and ask about
it. Where you believe the original is wrong, keep it as written and ask
about it. The cheap evidence is a test program checked with `refine`, a
grep of `spec.md`, or `refine explain`; cite the evidence in the
question. A tour sentence that disagrees with `spec.md` is a suspected
error: `spec.md` decides, and resolving it is the maintainer's decision.

## Method

1. Read the whole document, and the entries that cite into the passage or
   that it cites. Determine what it is for and which kind of document it
   is.
2. Build a meaning inventory: a numbered list of every distinct piece of
   meaning as defined above. Record which pieces depend on which, and
   which `[NNNN]`, D-number or fixture each rule rests on.
3. Collect all questions for the maintainer in one numbered list:
   ambiguities, suspected errors, disagreements between documents, gaps,
   an uncertain purpose, maintainer detail in a reader page, generated
   text outside your brief, and a significant tone change. For a tone
   change, describe the original tone and the tone you propose. Classify
   each question:
   - Blocking: the rewrite depends on the answer, and carrying the
     original over as it stands is impossible. A significant tone change
     is always blocking. An uncertain purpose is blocking when the
     possible purposes would lead to different rewrites.
   - Open: the rewrite can proceed by keeping the original's content as
     it stands. Ambiguities and suspected errors are usually open,
     because you carry them over intact.

   If at least one question is blocking, reply with the full list alone,
   blocking questions first, and wait. Otherwise continue. Every open
   question stays on the list until the maintainer answers it. When you
   resume after a pause, apply the answers you received and carry the
   remaining open questions forward to the output.
4. Rewrite. Reorder, split, merge and reword freely to meet the reader,
   navigation, quality and tone sections. Within a tour section you may
   move an entry; report the move. Length follows from clarity: shorter
   where words carried no meaning, longer where a compressed passage
   needed unpacking. Wrap prose at about 76 columns. Write an em dash,
   never a spaced ASCII pair of hyphens.
5. Verify, and repair any mismatch before answering:
   - Each inventory item is present with the same strength and scope.
   - The rewrite contains only what the inventory holds.
   - Each piece of information appears once.
   - Each recorded dependency has a pointer at the place that needs it.
   - After any edit to the prose of `tour.md` or `spec.md`, run
     `python3 check.py --generate`. `refine explain` prints those
     paragraphs from `citations.txt`, a data file the run rewrites and the
     compiler reads at run time, so no rebuild is needed; a changed title
     rewrites the construct matrix too. Deliver the regenerated files
     with the edit. Until then `python3 check.py` fails with "the
     citations are stale". An edit to `docs/diagnostics.md` is different:
     its explanations are compiled in, so that one needs the run and a
     rebuild with `./scripts/dev-build.sh`.
   - Inside `nix develop`, the full `python3 check.py` passes.
   - For the tour, run `./scripts/dev-test.sh --case='formatting/the
     tour is in the layout'`.
   - When the site can be built, `./scripts/site.sh` renders and verifies
     the pages; read the changed page as rendered.
   - Review the prose against what it describes, as AGENTS.md asks after
     any documentation edit.

## Output

1. **Questions for the maintainer**, first, in one numbered list. Each
   question names the passage it refers to and is short to answer; offer
   options where that helps, and say which one you would take by default.
   Keep each question's number stable across replies, so the maintainer
   can answer by number at any time. Every question still open appears
   here with each delivery of the rewrite. Leave this part out when there
   are none.
2. **Rewritten text**, in the source file itself or as its complete
   replacement, ready to use as is.
3. **Change notes**: the significant changes and the reason for each,
   briefly, including:
   - moved entries;
   - changed construct titles;
   - rules that need a home in `spec.md`;
   - the checks you ran, with their status. A filtered check is reported
     as `FILTERED`.
4. **Friction findings**: wherever the documentation disagrees with what
   the tool does, or a reader would need the source to follow it, give
   the symptom and where you met it. Each one becomes a Usability row in
   `ROADMAP.md`'s register; name the rows you add, or propose them if
   editing `ROADMAP.md` is outside your brief.

For a collection of documents, apply the method to each separately, keep
their order and identifiers, and gather the questions for all of them
into the one list at the start. Ask there about terms used inconsistently
across the collection, and about a rule stated in more than one of them.

When the collection is shared among parallel editors, each editor checks
its base before reading anything, as
[the brief recipe](../../../docs/process.md#worktrees-and-branches) says:
a harness may have cut its worktree from another commit than the one the
brief names, which may lack this skill.
