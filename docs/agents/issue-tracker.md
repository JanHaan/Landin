# Issue tracker: Local Markdown

Issues and execution specs for this repo live as Markdown files in `.scratch/`.
They are disposable execution detail, not durable project authority.
`ROADMAP.md` owns every durable item, dependency, decision, disposition, and
gate. Before an issue closes, promote any durable discovery there; a semantic
change also updates `tour.md` and its affected derived fixtures.

## Conventions

- One feature per directory: `.scratch/<feature-slug>/`
- The spec is `.scratch/<feature-slug>/spec.md`
- Implementation issues are one file per ticket at `.scratch/<feature-slug>/issues/<NN>-<slug>.md`, numbered from `01`, never a single combined tickets file
- Triage state is recorded as a `Status:` line near the top of each issue file (see `triage-labels.md` for the role strings)
- Comments and conversation history append to the bottom of the file under a `## Comments` heading

## When a skill says "publish to the issue tracker"

Create a new file under `.scratch/<feature-slug>/` (creating the directory if needed).

## When a skill says "fetch the relevant ticket"

Read the file at the referenced path. The user will normally pass the path or the issue number directly.

## Wayfinding operations

Used by `/wayfinder`. The **map** is a file with one **child** file per ticket.

- **Map**: `.scratch/<effort>/map.md` (the Notes / Decisions-so-far / Fog body). Decisions-so-far is a local handoff aid, not durable authority; promote durable content to `ROADMAP.md`.
- **Child ticket**: `.scratch/<effort>/issues/NN-<slug>.md`, numbered from `01`, with the question in the body. A `Type:` line records the ticket type (`research`/`prototype`/`grilling`/`task`); a `Status:` line records `claimed`/`resolved`.
- **Blocking**: a `Blocked by: NN, NN` line near the top. A ticket is unblocked when every file it lists is `resolved`.
- **Frontier**: scan `.scratch/<effort>/issues/` for files that are open, unblocked, and unclaimed; first by number wins.
- **Claim**: set `Status: claimed` and save before any work.
- **Resolve**: append the answer under an `## Answer` heading, promote every durable discovery, dependency, decision, or disposition to `ROADMAP.md` (and semantic changes to `tour.md` plus derived fixtures), set `Status: resolved`, then append a context pointer (gist + link) to the map's Decisions-so-far in `map.md`.
