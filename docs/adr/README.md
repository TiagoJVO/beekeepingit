# Architecture Decision Records (ADRs)

Granular, dated decisions captured **as work is implemented**. Project-level decisions
still also go to [../../requirements/decisions.md](../../requirements/decisions.md) as
`D-*`; ADRs capture the finer-grained "why" for a component or implementation.

## Convention

- One file per decision: `NNNN-short-title.md` (e.g. `0005-sync-engine-choice.md`).
- Suggested sections: **Context → Decision → Consequences → Alternatives** (+ Status:
  proposed / accepted / superseded).
- Link the related `FR-*/NFR-*`, `D-*`, `Q-*`, and `EPIC-*`.

Architecture **intent** lives in [../../requirements/](../../requirements/) (e.g.
`tech-stack.md`); the **built** architecture is documented in this `docs/` tree as work lands.
