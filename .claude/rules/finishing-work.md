# Rule: Finishing work

When you find work that isn't in scope — a bug, a gap, a missing test, a stale doc — decide once,
now, in one of three ways:

- **Do it** if it's small (under ~30 min) and adjacent to what you're already changing.
- **File it** otherwise: `gh issue create` **in this session**, shaped per the
  `backlog-management` skill, and link it from the PR's "Before merge" section.
- **Ask the user** only when it changes scope or touches a `D-*` (see `mandatory-workflow.md`).

**Nothing gets parked.** Not in a chat note, not in a TODO comment, not in a Markdown ledger. A PR
is finished when it owes nothing, or when every remaining item is an Issue linked from it.

## Don't use ECC's epic/project commands

`/epic-claim`, `/epic-sync`, `/epic-decompose`, `/epic-validate`, the rest of `/epic-*`, and
`/projects` write a coordination block and `coordination:*` labels into the issue body. That is
exactly the duplication of native GitHub fields the `backlog-management` skill forbids. **Claiming
an issue here is the native assignee field** (`gh issue edit <n> --add-assignee <actor>`); parent,
type, milestone and dependencies stay in their native panels.
