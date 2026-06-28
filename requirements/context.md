# Context & Guiding Principles

This document captures the high-level context that frames every functional and
non-functional requirement. When a requirement appears to conflict with another,
these principles are the tie-breaker.

## C-1 — Single organization now, multi-organization later

The app is **designed to scale to many organizations**, but at this stage it will
be used by a **single organization**.

- Feature prioritization must favour what matters to a **single organization**.
- Multi-tenant-only features must **not be prioritized** over single-organization
  features.
- The multi-organization path must **not be blocked** by near-term decisions, but
  it is **not the priority** for the first releases.

> The data-ownership model (see `functional-requirements.md`, FR-TEN group) treats
> the **Organization as the tenant boundary**. "Single organization now" therefore
> means a single tenant in production, not a single-user app.

## C-2 — Portugal-first

At this stage the app is used **only in Portugal**.

- It must respect **Portuguese (and applicable EU) beekeeping regulations**.
- It must reflect **Portuguese beekeeping practices** (e.g., seasonal journeys,
  treatments, harvest cycles, regulatory record-keeping).
- Internationalization is still required (see NFR-I18N), but Portugal is the only
  in-scope locale/regulatory regime for now.

> **Open question:** the specific Portuguese/EU regulations the app must satisfy
> (e.g., apiary registration with DGAV, hive identification, treatment logging,
> traceability for honey as a food product) are not yet enumerated. See
> `open-questions.md` (Q-REG).
