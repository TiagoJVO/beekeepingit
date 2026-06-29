# Docs

Documentation of the system **as it's actually built** — the decided, implemented state.
Written incrementally as features land.

> **Intent vs. docs:** what we *intend* to build (requirements, decisions, the intended
> stack) lives in [../requirements/](../requirements/). This folder documents what
> *exists* once implemented, so it stays trustworthy as the current state.

Right now almost nothing is built, so this folder is nearly empty. The exception is the
**High-Level Design** from EPIC-DESIGN (#103): the architecture the M0 build targets, refined
toward as-built as services land.

| Path | Contents |
|---|---|
| [architecture/](architecture/) | System architecture — HLD now (service decomposition, C4 views), as-built as it's implemented |
| [adr/](adr/) | Architecture Decision Records — captured as work is implemented |

As components get built, document them here (e.g. `docs/architecture/…`, service docs) and
record significant choices as ADRs.
