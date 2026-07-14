# Docs

Documentation of the system **as it's actually built** — the decided, implemented state.
Written incrementally as features land.

> **Intent vs. docs:** what we _intend_ to build (requirements, decisions, the intended
> stack) lives in [../requirements/](../requirements/). This folder documents what
> _exists_ once implemented, so it stays trustworthy as the current state.

The M0 walking skeleton has landed — the `identity`, `organizations`, `apiaries` and `sync`
services plus the Flutter PWA client — so this folder now documents real as-built behavior
alongside the **High-Level Design** from EPIC-DESIGN (#103) the build refined toward.

| Path                           | Contents                                                                                                                                                                                                                                                                             |
| ------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| [CODEMAPS/](CODEMAPS/)         | **Token-lean architecture maps** — routes, schemas, sync flow and dependencies as file-path + signature indexes for AI context and fast newcomer orientation; they point back to the prose below (`/ecc:update-codemaps` output)                                                     |
| [architecture/](architecture/) | System architecture — HLD now (service decomposition, C4 views, data model, API contracts, auth/authz, sync & conflict resolution, history/audit, and the [walking-skeleton slice design](architecture/walking-skeleton.md) consolidating them for M0), as-built as it's implemented |
| [client/](client/)             | Client-specific as-built notes — e.g. [PWA installability](client/pwa-installability.md)                                                                                                                                                                                             |
| [design/](design/)             | UI/UX design guideline — the [Melargil prototype](design/prototype.md) and the [accessibility & field-first UX checklist](design/accessibility-field-ux-checklist.md) (`D-18`, #79/#80) other epics' feature stories reuse                                                           |
| [development/](development/)   | Dev tooling & conventions — [setup + task runner + hooks](development/tooling.md) (rationale: [ADR-0008](adr/0008-monorepo-tooling.md))                                                                                                                                              |
| [adr/](adr/)                   | Architecture Decision Records — captured as work is implemented                                                                                                                                                                                                                      |
| [spikes/](spikes/)             | Time-boxed investigation reports (e.g. [SP-1](spikes/sp-1-powersync-vs-electricsql.md) sync-engine pick) — the evidence + reproduction behind a decision                                                                                                                             |
| [research/](research/)         | Domain research behind product/compliance decisions — e.g. [PT/EU beekeeping regulation](research/regulatory-pt-eu-beekeeping.md)                                                                                                                                                    |
| [../contracts/](../contracts/) | **Contract-first** API definitions (OpenAPI 3.1) — the conventions are documented in [architecture/api-contracts.md](architecture/api-contracts.md) / [adr/0003](adr/0003-api-contract-conventions.md)                                                                               |

As components get built, document them here (e.g. `docs/architecture/…`, service docs) and
record significant choices as ADRs.
