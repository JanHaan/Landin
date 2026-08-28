# Domain documentation

Landin is one repository context. It does not use a `CONTEXT.md`, a context
map, or an ADR directory, and an agent must not invent those as a second
authority.

Use the repository's existing vocabulary and authority order:

- `spec.md` decides the language and names every normative construct.
- `tour.md` teaches the language in the same terms.
- `ROADMAP.md` owns open work, dependencies, dispositions and gates.
- `handoff.md` compresses the inherited design principles and held positions.
- `compiler/ada/README.md` assigns implementation ownership and forbidden
  dependencies between compiler packages.

When a task discovers a durable domain distinction, put it in the source that
owns it above. Execution detail may live under `.scratch/`, but a glossary,
ADR, issue or code comment must not become a competing language or work
authority.
