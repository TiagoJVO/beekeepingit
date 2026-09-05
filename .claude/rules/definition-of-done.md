# Rule: Definition of Done

The checklist lives in **one** place: [`.github/PULL_REQUEST_TEMPLATE.md`](../../.github/PULL_REQUEST_TEMPLATE.md).
A change is done when every item there holds truthfully for the PR — acceptance criteria,
traceability (`FR-*/NFR-*`, `D-*`, issue), tests green in CI, offline/sync, i18n + a11y,
tenancy + history, security, docs, and the `CLAUDE.md`/`README.md` map rows for any new
top-level directory. Don't restate that list elsewhere; point at it.

Two things the template can't enforce, so they're rules here:

- **Decisions change only with the user.** Contradicting a `D-*` or a requirement is fine
  when it genuinely makes sense — but confirm it with the user first and update
  `requirements/` in the same change (see `mandatory-workflow.md`). Never silently diverge.
- **A PR owes nothing when it merges.** Whatever it still owes is finished before merge, or
  is opened as a GitHub Issue from the PR (shaped per the `backlog-management` skill) and
  linked in its "Before merge" section — in the same session, not "later".
