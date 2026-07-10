# Beekeeping App — Requirements

Field-management app for beekeepers (apiaries, activities, journeys, todos, and an
AI assistant), offline-first, used initially by a single organization in
Portugal.

## Documents

| File                                                             | Purpose                                                               |
| ---------------------------------------------------------------- | --------------------------------------------------------------------- |
| [context.md](context.md)                                         | Guiding principles and tie-breakers (single-org-now, Portugal-first). |
| [functional-requirements.md](functional-requirements.md)         | What the app does, with stable `FR-*` IDs.                            |
| [non-functional-requirements.md](non-functional-requirements.md) | Quality/architecture constraints, with stable `NFR-*` IDs.            |
| [open-questions.md](open-questions.md)                           | Gaps, ambiguities, and decisions needed **before planning**.          |
| [decisions.md](decisions.md)                                     | Resolved decisions (`D-*`) that supersede open questions.             |
| [tech-stack.md](tech-stack.md)                                   | **Intended** technical approach/stack (revisitable; not yet built).   |

The original `context.txt`, `frs.txt`, and `nfrs.txt` are kept untouched as the
source of record.

## Status

Requirements refined and ID'd; **core product + tech decisions resolved**
(`D-1`…`D-10` in [decisions.md](decisions.md)): scope, hive model, org invites, full
microservices, Flutter (PWA-first → native), Postgres + sync, Authentik (OIDC), cloud-AI.

**Remaining (before / early in planning)** — highest-impact open items in
[open-questions.md](open-questions.md):

- **Q-SYNC** — conflict-resolution policy (engine chosen; spike **SP-1**).
- **Q-AICLOUD** — cloud-AI privacy/GDPR (consent, DPA, no-training, EU residency).
- **Q-JOUR** — journey planned-vs-actual model.
