# History / Audit Architecture

> **Status:** High-Level Design (HLD) for v1 — the target the M0 build realizes; refined toward
> as-built as history capture lands (EPIC-07 #8). Builds on
> [service-decomposition.md](service-decomposition.md), [data-model.md](data-model.md) and
> [sync.md](sync.md). Intent lives in [../../requirements/](../../requirements/).

**Issue:** #107 · **Epic:** #103 (EPIC-DESIGN) · **Milestone:** M0
**Requirements:** FR-HIS-1, FR-TEN-2, NFR-CMP-1, NFR-ARC-1
**Decisions:** [D-6](../../requirements/decisions.md#d-6--data--offline-sync-postgresql--postgis-sqlite-on-device-managed-sync) (schema-per-service, sync),
[D-11](../../requirements/decisions.md#d-11--ai-write-actions-propose--confirm--owner-executes) (AI writes via owner), [D-19](../../requirements/decisions.md#d-19--pteu-beekeeping--honey-traceability-obligations-scoped-hipaa-dropped) (PT/EU regulatory scope), [D-1](../../requirements/decisions.md) (microservices)
**Questions:** **resolves [Q-HIS](../../requirements/open-questions.md)** (retention, immutability,
visibility, offline behaviour) — now removed from open-questions; this doc + [ADR-0007](../adr/0007-history-audit.md) are its place of record
**Depends on:** #105 (data model), #106 (sync) · **ADR:** [0007-history-audit](../adr/0007-history-audit.md)

---

## 1. Scope

The **append-only change history** (FR-HIS-1) for every entity: who changed what, when, and how,
kept correct across **offline edits + sync** (#106). Concretely this document decides the five
things #107 owes:

1. the **append-only, per-entity history model** — actor + timestamps + change (§3);
2. the **capture mechanism** — synchronous, in-transaction, per owning service (§4);
3. the **storage placement** — per-service vs central, decided with trade-offs (§5);
4. how history **survives offline + sync**, incl. the interaction with the #106 conflict policy (§6);
5. the **retention / immutability / visibility** stance (§7–§8), resolving [Q-HIS](../../requirements/open-questions.md).

The **build is EPIC-07** (#8); this doc fixes the shapes and rules that build realizes. It refines
the `audit_log` shape reserved in [data-model.md](data-model.md) §3 and finalizes the "mechanism
#107" that [sync.md](sync.md) §5.2/§7 defers to here.

---

## 2. Mental model — history is a side-effect of the write, in the same transaction

```text
   owning service (e.g. apiaries)
   ┌───────────────────────────────────────────────────────────────┐
   │  write path (ONE local transaction)                            │
   │    1. validate + authorize + org-scope                         │
   │    2. UPSERT domain row        ── apiaries                     │
   │    3. INSERT audit row         ── apiaries.audit_log (append)  │
   │    COMMIT  ── domain change and its history commit together    │
   └───────────────────────────────────────────────────────────────┘
        ▲                                   ▲
        │ online API write                  │ offline write replayed via
        │ (normal request)                  │ the sync-apply endpoint (sync §5.2)
        └───────────────────────────────────┘
              same code path → history recorded identically either way
```

History is **not** a separate subsystem the write has to reach. Each owning service appends its
audit row **in the same local transaction** as the domain mutation, on **both** the online write
path and the offline **sync-apply** path ([sync.md](sync.md) §5.2). The history row therefore
commits **iff** the change commits — it can never be lost, backdated, or drift from the data.

---

## 3. The history model (append-only, per entity)

One immutable row per change, polymorphic over every entity by (`entity_type`, `entity_id`). This
finalizes the `AUDIT_LOG` shape from [data-model.md](data-model.md) §3.

| Column            | Type           | Meaning                                                                                                                                                                                                                                                     |
| ----------------- | -------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `id`              | `uuid` (v7) PK | client/server-generatable; time-ordered                                                                                                                                                                                                                     |
| `organization_id` | `uuid`         | tenancy key — every audit row is org-scoped (FR-TEN, RLS, sync slice)                                                                                                                                                                                       |
| `entity_type`     | `text`         | `apiary` \| `activity` \| `journey` \| `todo` \| `membership` \| … (open set)                                                                                                                                                                               |
| `entity_id`       | `uuid`         | soft reference to the changed row (no cross-schema FK)                                                                                                                                                                                                      |
| `change_type`     | `text`         | `create` \| `update` \| `delete` (soft-delete tombstone, §6)                                                                                                                                                                                                |
| `actor_user_id`   | `uuid`         | **internal user UUID only** — soft ref to `identity.users`; **never** denormalized actor PII (§7.3)                                                                                                                                                         |
| `occurred_at`     | `timestamptz`  | **device** time the change was made (offline-correct, §6)                                                                                                                                                                                                   |
| `recorded_at`     | `timestamptz`  | **server** time the change was applied/committed                                                                                                                                                                                                            |
| `changed_fields`  | `text[]`       | on `update`, the columns that changed — drives the timeline UI and lets a reader filter                                                                                                                                                                     |
| `change`          | `jsonb`        | the **delta**, not a full snapshot: on `create` the initial field values (the baseline); on `update` `{ field: { from, to } }` for **changed columns only**; on `delete` just the tombstone marker. Soft ID refs only, **no embedded personal data** (§7.3) |

**As built (`organizations` only, #470, migration `00005`):** `organizations.audit_log` carries one
additional column, `actor_scope text` (`'member'` \| `'platform_operator'`), recorded **explicitly,
at write time, in the same INSERT** as the rest of the row (never inferred afterwards by
cross-referencing `memberships` — a platform-operator write has no membership row to
cross-reference against in the first place). It distinguishes a row written by an ordinary
organization member/admin from one written by a verified **platform operator** acting on an
organization it is not a member of (`services/organizations/api/platform_authz.go`, #466,
[ADR-0021](../adr/0021-platform-operator-tenancy-carve-out.md)) — "the app owner edited someone
else's organization" is a materially more sensitive event than an ordinary member edit, and this
column is what makes it distinguishable after the fact (FR-HIS-1, NFR-SEC-1, FR-TEN-2). No other
service's `audit_log` has this column: the platform-operator carve-out is `organizations`-specific
today.

**Notes**

- **Actor is an opaque internal ID.** The audit row records _that user `<uuid>` changed it_, never
  their name/email. Personal data is resolved by **join** to `identity.users` at display time
  (§7.3, §8) — the design property that removes the GDPR-erasure clash.
- **Two clocks.** `occurred_at` (device) vs `recorded_at` (server) mirror
  [data-model.md](data-model.md) §2's device-time-vs-server-time split, so a change made offline
  Monday and synced Wednesday reads _occurred Monday, recorded Wednesday_ — not backdated or lost.
- **Store the delta, not a full snapshot.** Writing the whole row on every edit grows `audit_log`
  with **row size × edit count**, re-copying unchanged fields each time — wasteful, and it scales
  with entity size rather than with how much actually changed. Instead each row stores only **what
  changed**, which is also exactly what the "view history" timeline renders. The owning service
  already holds both old and new values at write time ([sync.md](sync.md) §5.2 captures prior state
  for reversibility), so the delta is free to produce. A `create` writes the initial values as its
  baseline; updates write per-field `{from, to}`; a `delete` writes only the tombstone marker.
- **Trade-off (accepted):** reconstructing an entity's _full_ state as-of an arbitrary past time
  then needs **replay** (baseline + deltas). FR-HIS-1 requires a **change log**, not point-in-time
  reconstruction, and deep history is an online query anyway — so materialization/replay is a
  deferred refinement, not a v1 need. Growth is bounded by real change volume (a low-write,
  single-org field domain — Context C-1), and Postgres **TOAST** compresses any large JSONB
  out-of-line.

---

## 4. Capture mechanism — synchronous, in-transaction, per owning service

**Decision:** each owning service writes its own audit row **synchronously, inside the same local
transaction** as the domain mutation — on both the online write path and the sync-apply path
([sync.md](sync.md) §5.2). No triggers, no CDC, no event bus, no outbox in v1.

**Why in-transaction (not async):**

- **Atomicity = correctness.** History commits with the change or not at all. There is no window
  where a change exists without its history, and no relay/consumer that could lag or drop events.
- **One path for online and offline.** The sync-apply endpoint is _the same service write path_;
  recording history there means offline-then-synced edits are audited **identically** to online
  ones, with the device `occurred_at` preserved (§6). Nothing special is needed for the sync case.
- **Least v1 infra.** It reuses the local transaction each service already opens; it does **not**
  pull in the event-bus/outbox machinery that [ADR-0006](../adr/0006-sync-conflict-resolution.md)
  explicitly **deferred** ("overlaps the #107 history/outbox work").

**Rejected for v1** (full weighing in [ADR-0007](../adr/0007-history-audit.md)): DB **triggers**
(hidden control flow, harder to test/version, can't see the app-level actor cleanly),
**CDC/logical-decoding** into a history service (async, extra infra, eventual), **transactional
outbox → events → central projection** (async + new infra; the reserved _upgrade_, not v1, §5),
and **app-level after-commit write** (a second transaction that can fail independently — reopens
the lost-history window).

**Idempotency.** The sync-apply step is idempotent on the client UUID PK ([sync.md](sync.md) §5.2 /
§6.2 forward-retry). Because the audit INSERT lives **inside** that same idempotent apply, a
replayed/forward-retried op that no-ops the domain write also writes **no** new audit row — history
is not double-counted on retry.

---

## 5. Storage placement — per-service, co-located (the #107 storage decision)

**Decision:** history is **per-service** — each owning service holds its own append-only
`audit_log` table **inside its own schema** (`apiaries.audit_log`, `activities.audit_log`, …).
There is **no** central `history` schema/service written to synchronously by everyone.

**Why (this is forced by ownership + the in-transaction choice):**

- **Ownership rule 1** ([service-decomposition.md](service-decomposition.md) §4: _a service writes
  only its own schema_) **forbids** a central history schema written synchronously by every
  service — that would be a cross-schema write. Keeping the audit INSERT in the domain write's
  local transaction (§4) therefore **requires** the audit table to live in the **same schema**.
- **The FR-HIS view is per-entity.** "View the history of _this_ apiary / activity / journey"
  (FR-HIS-1, §8) is answered entirely by the **owning service's own** `audit_log` — no cross-schema
  join (ownership rule 3), no fan-out.

**Trade-offs considered**

| Option                                                         | Atomic w/ write  | Honors ownership               | Per-entity view   | Global timeline             | v1 infra                     | Verdict                                     |
| -------------------------------------------------------------- | ---------------- | ------------------------------ | ----------------- | --------------------------- | ---------------------------- | ------------------------------------------- |
| **Per-service, in-tx `audit_log`** (chosen)                    | ✅ same local tx | ✅ own schema only             | ✅ owning service | ⚠️ needs fan-out/projection | none                         | **v1**                                      |
| Central `history` schema, **sync** write                       | ✅               | ❌ cross-schema write          | ✅                | ✅ single table             | none                         | **rejected** — breaks rule 1                |
| Central `history` schema, **async** (outbox→events→projection) | ❌ eventual      | ✅ (services write own outbox) | ✅                | ✅                          | event bus + relay + consumer | **deferred upgrade** (§5.1)                 |
| One shared audit table, all services write                     | ✅               | ❌ shared ownership            | ✅                | ✅                          | none                         | **rejected** — ownership ambiguity (D-1/AC) |

### 5.1 Reserved upgrade — a global cross-entity timeline behind the boundary

A **cross-entity / org-wide** audit feed (e.g. an admin "everything that changed today" view) is
**not** an FR-HIS-1 requirement and is **not built in v1**. When it is wanted, it is added
**without changing how services record history**: each service emits its already-captured audit
rows via a **transactional outbox**, and a **history read-projection** consumes them into a single
queryable timeline — a projection **behind the service boundary**, the same seam-preserving pattern
[sync.md](sync.md) §6 uses for write-back. Until then, cross-entity history is **API composition**
over the per-service logs (ownership rule 3), which is sufficient for v1.

---

## 6. Survives offline edits + sync (interaction with the #106 conflict policy)

History is designed against the [sync.md](sync.md) reconciliation flow, not bolted on after:

- **Recorded on the apply path.** Every applied create/update/delete — whether written online or
  replayed from an offline queue — records history in the same transaction (§4), stamping
  `occurred_at` = device time and `recorded_at` = server time ([sync.md](sync.md) §7). Late sync is
  therefore **correct, not backdated**.
- **Recent history is offline-viewable.** A recent window of `audit_log` **replicates down
  read-only** in the org slice ([sync.md](sync.md) §3.2), so the entity's history view works
  **offline** for recent changes. **Deep history is an online query** against the owning service —
  the field client does not carry unbounded history.
- **LWW losers are not lost.** The #106 policy is **record-level last-write-wins + a conflict log**.
  A losing offline edit is preserved in **`sync_conflict_log`** ([sync.md](sync.md) §4.2), captured
  the **same way** as `audit_log` — per-service, in the apply transaction. The entity timeline can
  therefore surface a **`superseded`** event ("your offline change to _Serra Norte_ was superseded
  by a newer value") alongside the applied changes, so no edit silently vanishes from the record.
- **Deletes are tombstones.** A soft-delete (`deleted_at`) is a `change_type = delete` audit row and
  participates in LWW like any update ([sync.md](sync.md) §4.5). Physical purge of tombstones is a
  retention concern (§7.2).

`sync_conflict_log` is the conflict-specific sibling of `audit_log`: same per-service placement,
same in-transaction capture, and it is the shape [sync.md](sync.md) §4.2 left "aligns with #107" —
now fixed here.

---

## 7. Immutability & retention (resolves Q-HIS)

### 7.1 Immutability — append-only, DB-enforced

`audit_log` is **append-only**: `INSERT`-only, never `UPDATE`/`DELETE` from the application.

- **Enforced at the database, not just in code:** the owning service's **runtime DB role is granted
  `INSERT` (and `SELECT`) but not `UPDATE`/`DELETE`** on its `audit_log` (and `sync_conflict_log`).
  A code path that tries to mutate history fails at the database — defense-in-depth, the same
  philosophy as the optional RLS backstop in [data-model.md](data-model.md) §5.
- **The protected set is fail-closed, not remembered (#553).** The revokes key on one central list
  (`postgres.historyTables` in `charts/postgres/values.yaml`), and the grants pass **errors the
  release** — at deploy time, naming the table, inside the same transaction as the blanket DML
  grant — if any table ending `_log` in a schema is not on it. So the `_log` suffix is reserved for
  append-only history: shipping a new history table means adding its name to that list in the same
  change, and forgetting produces a failed deploy rather than a silently mutable audit trail. (A
  history table named _without_ the suffix evades the tripwire and rests on the list alone — the
  guard enforces the naming convention, the list classifies.)
- **The runtime role owns nothing, which is what makes that durable.** An owner can re-`GRANT` to
  itself at will and keeps `TRUNCATE`/`ALTER`/`DROP` regardless of any `REVOKE`, so "not granted
  `UPDATE`" only means something for a role that is not the table's owner. Since
  [ADR-0023](../adr/0023-migrations-as-a-deploy-time-admin-process.md) migrations run in a
  deploy-time Job, not in the serving process, so `<schema>_svc` never creates a table and
  therefore never owns one. `CREATE` on the schema is revoked from it explicitly. It is also a
  member of no other role, so it cannot borrow the owner's privileges either.
- **The owner is `<schema>_migrator`, one per schema** — see
  [ADR-0024](../adr/0024-per-schema-migrator-roles.md) (#545). Before that, a single
  `beekeepingit` role owned every schema's tables and was the credential in every service's
  migrate Job, so compromising any one service image reached every other service's audit log.
  Now each migrator's authority stops at its own schema boundary.
- **Corrections are new rows**, never edits — the record of "what the system believed and when"
  stays intact.
- Purge for retention (§7.2) is a **separate, privileged** maintenance role, not the service role.

**What this guarantee does and does not cover.** It is a guarantee against the service's **runtime
role** — the credential the serving process holds while answering requests. It is **not** a
guarantee against the service's **deploy artifact**.

The migrate Job runs the service's own container image with a credential that owns that schema's
tables, and the migration `.sql` files ship inside that image. So a malicious or compromised
_build_ of a service can rewrite its own schema's history, and no arrangement of database roles
inside this design prevents that: a migration that must be able to `ALTER TABLE audit_log` (as
`audit_log.actor_scope`/#470 was) cannot be run by a principal that must not be able to alter
`audit_log`. ADR-0024 §"Consequences" sets out why the obvious escapes — a neutral migration image,
or an owner the image never holds — do not work.

Closing that half needs history to leave the database's trust boundary: an out-of-band append-only
sink (WAL archiving to immutable storage, or an external WORM store), which belongs to the
compliance epic (**EPIC-14 #15**) rather than to the Helm chart. Recorded here so the guarantee is
not read as broader than it is.

### 7.2 Retention — retain in v1, purge policy deferred

- **v1 retains history indefinitely** (it is immutable and small relative to domain data). No
  automatic purge ships in v1.
- A **configurable retention window** and **legal-hold** semantics are **deferred to the compliance
  epic (#586, EPIC-14 #15)**; nothing in this design blocks adding a purge job later (it operates via the
  privileged role of §7.1). Tombstone/soft-delete physical purge is the same concern.
- **One retention _floor_ is already fixed**, though, and constrains that future purge job:
  Treatment activities carry a ~5-year veterinary record-keeping expectation and may not be
  physically purged inside it — §7.4.

### 7.3 GDPR / right-to-erasure — pseudonymous by construction (NFR-CMP)

There is **no clash** between immutable history and the GDPR right-to-erasure, because the audit log
never stores personal data in the first place:

- **`audit_log` holds only opaque internal identifiers** — `actor_user_id` (internal user UUID),
  `entity_id`, `organization_id` — and `change` deltas that themselves carry **soft ID references**,
  **never** denormalized names/emails. It is **pseudonymous by construction**.
- **Personal data lives in exactly one place:** `identity.users`. Actor and subject names are
  resolved by **join** to that table **at display time** (§8), from the org roster slice
  ([sync.md](sync.md) §3.2).
- **Erasure / unregister** operates on `identity.users` — the person's PII is deleted/scrubbed
  there. The audit rows **keep the opaque internal ID with no link back to a person**, so:
  - **audit integrity is preserved** (immutable, append-only, nothing rewritten), **and**
  - **no personal data remains** in history — the internal ID no longer resolves to anyone.

  This is crypto/pseudonymization-by-design rather than deletion of audit rows, and it is what lets
  history be simultaneously **immutable** and **GDPR-compliant**.

- **Design constraint this imposes:** the `change` delta and audit rows MUST NOT embed actor/member
  personal data — only soft ID references. Services build audit rows from IDs, not denormalized profiles.
  (This is a boundary/contract test target, NFR-TST.)

### 7.4 Regulatory retention vs. erasure — Treatment activities (D-19, #295)

§7.3 settles erasure for the **audit log**. It does not settle it for the **domain rows the audit
log points at**, and for one activity type those rows carry an external retention expectation that
pulls the opposite way from erasure. D-19 flagged the tension; this section is its reconciliation,
owed **before the Treatment-activity work goes live** — which #291 now has.

**The two obligations.**

- **Erasure (GDPR Art. 17, FR-HIS-1, NFR-CMP-1).** A subject can ask for their personal data to be
  deleted or anonymized; #90 builds that path.
- **Veterinary record-keeping ([Reg (EU) 2019/6](https://eur-lex.europa.eu/eli/reg/2019/6/oj)).**
  Records of veterinary medicinal product administration to food-producing animals — bees included,
  so every varroacide or other treatment logged as a **Treatment activity** — must be kept for the
  **longer of** 5 years from the record date or 1 year after the batch's expiry date
  ([research note §B.7](../research/regulatory-pt-eu-beekeeping.md)).

**The reconciliation, in one line:** they do not actually collide, because **the personal data and
the regulated record are different data**, and erasure only reaches the first.

1. **The retention obligation is the beekeeper's, not the app's.** Reg (EU) 2019/6 binds the
   _keeper of the animals_. BeekeepingIT is the record-keeping tool they use, not the duty-holder.
   So the app must not silently destroy a record its user is required to keep, and must let them
   take it with them — but it also has no standing to refuse an erasure request by citing an
   obligation that is not its own. The design consequence is **export-before-erase**, not
   **retain-over-erase**: #90's erasure path must offer the org a portable export (EPIC-09 #69)
   of its activity data _before_ it destroys anything, so the regulatory record survives with the
   person who owes it.
2. **A Treatment activity is not personal data.** Its regulated content — date, product, treatment
   context, disease/condition, hive/apiary — is a record about **bees**, and D-19 already decided
   bee-health data is ordinary, non-special-category data about an animal, not about a natural
   person. The personal data attached to it is the **actor attribution** (`performed_by`, and the
   audit rows in §7.3), plus whatever a user typed into **free-text notes**.
3. **So erasure anonymizes attribution; it does not delete the treatment record.** This is exactly
   §7.3's move, extended one layer out: scrubbing `identity.users` leaves the Treatment row intact
   with an internal ID that no longer resolves to anyone. The record stays available for the
   retention window, and no personal data remains in it. **Free-text `notes` is the one field this
   reasoning does not cover** — it can contain anything, including third-party personal data — so
   notes are in scope for #90's PII review (Q-EXPORT-PII), and the reconciliation above holds for
   the structured attributes only.
4. **Erasing the whole tenant is a different act, and it is the user's call.** Deleting an
   _organization_ outright takes its Treatment activities with it. That is legitimate — the org is
   asking for it — but it is the case where step 1's export is load-bearing rather than a courtesy,
   because after it the app holds no copy at all. #90 should therefore treat a full-tenant erasure
   as an explicit, confirmed, audited act with the export offered first, not as a bulk `DELETE`.

**The design constraint this leaves for the deferred purge work (#586, §7.2).** v1 satisfies
all of the above by doing nothing: deletes are soft-delete tombstones
([data-model.md](data-model.md) §2), no physical purge ships, and history is retained indefinitely.
The constraint bites when an automatic retention window is actually built:

- A purge job **MUST NOT** physically remove a Treatment activity, its tombstone, or its `audit_log`
  rows while it is inside the retention floor — **5 years from `occurred_at`** as the operative
  test, since the app does not capture a product batch-expiry date and so cannot evaluate the
  "1 year after expiry" limb. If a batch/expiry field is ever added to the Treatment attributes,
  the floor becomes the **longer** of the two, per the regulation.
- This is a **retention floor on one activity type**, not a legal hold on everything: other
  activity types carry no equivalent obligation and remain purgeable under whatever window
  #586 chooses.
- The floor is **a constraint on physical purge only**. It does not stop a user from soft-deleting
  a Treatment activity in the UI, and it does not stop erasure from anonymizing its attribution —
  both leave the regulated record recoverable for its window.

> **Not legal advice.** This section records how the design reconciles two requirements we have
> written down; it does not opine on whether a given deployment meets its own regulatory duties.
> The retention floor is a **conservative default**, deliberately set so the app is not the reason
> a record went missing.

---

## 8. Visibility — a per-entity timeline on the entity's screen

- **Where:** history is surfaced as a **per-entity timeline on that entity's detail screen** — e.g.
  _Apiary details → history_, and likewise for activities and journeys (the FR-HIS-1 "view the
  history" feature). It is not a separate global console in v1 (§5.1).
- **Who:** **any organization member who can already access the entity** may view its history —
  consistent with **FR-TEN-2** (members share all of the org's data). No admin-only gate is added in
  v1; history visibility follows the entity's own access, adding no new authz surface. (An
  admin-scoped global feed can come with the §5.1 projection if ever needed.)
- **Actor names** shown in the timeline are resolved from `actor_user_id` against the org roster; a
  since-erased actor simply shows as unknown/removed (§7.3).
  **As built (#60):** the roster is _not_ a synced device slice — it comes from the online-only
  `GET /organizations/{orgId}/members/names` endpoint via the client's `memberNamesProvider`, the
  same source activity attribution already uses. The timeline itself still renders fully offline
  (its rows come from the local `audit_log`/`sync_conflict_log` tables); only the _display names_
  need the network, and they degrade to a short, stable id fragment (`Member <last-8>`) offline or
  before the roster loads — never to a blank or an error. Should the roster ever become a genuinely
  synced slice ([sync.md](sync.md) §3.2), this resolution swaps behind `memberNamesProvider` with no
  change to the timeline.
- The concrete screens (diff rendering, EN/PT strings, WCAG 2.2 AA, gloves-friendly) belong to the
  entity EPICs (EPIC-02/03/04) and the history build (EPIC-07 #8); this doc fixes the data + rules
  they render.
  **As built (#60):** one entity-agnostic component pair —
  `client/lib/features/history/history_section.dart` (embedded, capped preview) and
  `history_screen.dart` (full, virtualized) — serves every entity type, keyed by
  `(entity_type, entity_id)`. Apiaries and activities are wired today; journeys (#315) and todos
  (EPIC-05) attach to the same component with no new UI.

---

## 9. Entity coverage

FR-HIS-1 is **all entities**. In v1 that is:

| Entity                                        | Owning service | History source                            |
| --------------------------------------------- | -------------- | ----------------------------------------- |
| `apiaries`                                    | apiaries       | `apiaries.audit_log`                      |
| `activities`                                  | activities     | `activities.audit_log`                    |
| `journeys`, `journey_plan_items`              | journeys       | `journeys.audit_log`                      |
| `todos`                                       | todos          | `todos.audit_log`                         |
| `memberships`, `organizations`, `invitations` | organizations  | `organizations.audit_log` (admin actions) |

`identity.users` records only minimal self-profile changes; it is global (not org-owned) and carries
no `organization_id`. The `ai` service **records no domain history** — a confirmed AI action executes
through the **owning** service's API and is audited there like any edit (D-11 / ownership rule 5),
so the AI write-safety guarantee and the audit trail reinforce each other.

---

## 10. Open items, deferred scope & hand-offs

| Item                                                                                                                            | Status                                                                                                                                                                   | Where                                      |
| ------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------ |
| Global / cross-entity audit timeline (outbox → projection)                                                                      | **Reserved, not built** — API composition suffices for v1; projection behind the boundary later (§5.1)                                                                   | future; EPIC-07 if needed                  |
| Configurable retention window / automatic purge / legal-hold                                                                    | **Deferred** — v1 retains indefinitely (§7.2)                                                                                                                            | #586 (EPIC-14 #15)                         |
| Treatment-activity retention floor (~5y, Reg (EU) 2019/6) vs. GDPR erasure                                                      | **Policy fixed** (#295) — anonymize attribution, never purge inside the floor; export-before-erase (§7.4)                                                                | #586 (purge) / #90 (erasure)               |
| Diff / `changed_fields` presentation in the timeline                                                                            | **Built** (#60) — rendered as a localized "Changed: Name, Notes" sub-line; unmapped columns fall through to their raw server name                                        | EPIC-07 (#8), entity EPICs                 |
| Build: in-tx audit append on each service write + sync-apply path; INSERT-only grant; append-only + pseudonymity contract tests | **Built** for `identity`/`organizations`/`apiaries` (in-tx append on both the REST and sync-apply paths); remaining domain services follow the same pattern as they land | EPIC-07 (#8), per-service EPIC-02/03/04/05 |
| History view screens (per-entity timeline, EN/PT, a11y)                                                                         | **Built** for apiaries + activities (#60) — one entity-agnostic component pair (§8), local-first with a REST fallback; journeys #315, todos EPIC-05 reuse it             | EPIC-02/03/04, EPIC-07 (#8)                |
| `sync_conflict_log` surfaced as `superseded` timeline events                                                                    | **Built** (#60) — folded into the same timeline via a UNION, labelled "Superseded" with an explanatory sub-line (§6)                                                     | EPIC-06 (#7) / EPIC-07 (#8)                |

---

## 11. Acceptance-criteria traceability (#107)

- [x] **Append-only, per-entity history model** (actor + timestamp + change) designed — §3
- [x] **History survives offline edits + sync**; interaction with the #106 conflict policy specified
      (recorded on the apply path, recent-history offline slice, LWW losers via `sync_conflict_log`) — §6
- [x] **Storage approach** (per-schema vs central) decided **with trade-offs** — per-service,
      co-located, in-transaction; central-async reserved as an upgrade — §5
- [x] **Retention / immutability stance noted** — append-only + DB-enforced immutability; retain in
      v1, purge deferred; **GDPR resolved** by pseudonymity-by-construction — §7
- [x] **Design + ADR in `docs/`**, resolving Q-HIS — this doc + [ADR-0007](../adr/0007-history-audit.md)

## 12. Links

- This decision: [ADR-0007](../adr/0007-history-audit.md)
- Builds on: [service-decomposition.md](service-decomposition.md) (#104) ·
  [data-model.md](data-model.md) (#105) · [sync.md](sync.md) (#106) ·
  [auth.md](auth.md) (#109, actor identity)
- Intent: [functional-requirements.md](../../requirements/functional-requirements.md) (FR-HIS-1) ·
  [decisions.md](../../requirements/decisions.md) (D-6, D-11, D-19) — resolves
  [Q-HIS](../../requirements/open-questions.md)
- Regulatory basis for §7.4: [regulatory-pt-eu-beekeeping.md](../research/regulatory-pt-eu-beekeeping.md)
  §B.7 (#91) · GDPR export/erasure build: **#90** (M6) · retention/purge: **#586** (EPIC-14 #15)
- Build: **EPIC-07 — History & Audit (#8)**
- Last in EPIC-DESIGN's data/sync chain: #105 → #106 → **#107** → #108 (contracts) / #110 (skeleton)
