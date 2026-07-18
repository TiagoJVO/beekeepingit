# services/todos

The **todos** service — owner of todo records
([#50](https://github.com/TiagoJVO/beekeepingit/issues/50), EPIC-05, M5). It
owns the `todos.todos`, `todos.sync_conflict_log` and `todos.audit_log` tables
(`docs/architecture/service-decomposition.md` §3) and the todo model +
lifecycle (FR-TD-1, FR-TEN-2, FR-HIS-1, D-20, D-23).

Unlike `services/activities`, a todo has **no per-type JSONB attributes
bag** — every field FR-TD-1 names (title, description, due date, priority,
assignee, apiary) is a plain typed column, so the data model here is
strictly simpler. The optional `assignee_id` (D-23) is a **cross-service
soft reference** to an `organizations` member — it must be HTTP-verified
against the organizations service (not just "exists", but "has an ACTIVE
membership in the CALLER's own org") before every write that sets it,
mirroring activities' `apiary_id` → apiaries verification carry-over of
#284's cross-tenant IDOR fix. [#51](https://github.com/TiagoJVO/beekeepingit/issues/51)
adds the optional `apiary_id` field the same way: a todo may be associated
with a specific apiary, or left as a general, org-level todo (FR-TD-1) — see
this file's own "Apiary association" section below.

Stamped from [`services/servicetemplate`](../servicetemplate/README.md); DB
access via [`services/shared/dbaccess`](../shared/README.md). Its own Go
module, linked through the repo-root `go.work`.

**Out of scope for #50/#51** (tracked separately, doesn't preclude either):
list/filter UI ([#53](https://github.com/TiagoJVO/beekeepingit/issues/53)).
There is consequently no `GET`/list route yet, and no new client-facing UI
screen consuming `apiary_id` for display yet — i18n/a11y are N/A for this
issue; that later UI is where the read-time apiary-deletion tolerance
described below will actually be exercised.

## Data model (FR-TD-1, FR-TEN-2, D-20, D-23)

`todos.todos`: `id` (client-supplied UUID PK, the idempotency anchor),
`organization_id` (NOT NULL, tenancy), `title` (required), `description`
(nullable free text), `due_date` (nullable `DATE` — a todo may legitimately
have none), `priority` (`low`/`medium`/`high`) and `status`
(`open`/`done`, default `open`) — both **Go-validated controlled
vocabularies** (`api/types.go`'s `IsKnownPriority`/`IsKnownStatus`), **not** a
DB enum/CHECK (D-20), so extending either is a code-only append.
`completed_at` (nullable `TIMESTAMPTZ`, set on complete, cleared on reopen) is
stored alongside `status` rather than derived from it. `assignee_id`
(nullable UUID, D-23: optional, default unassigned, assignable/reassignable/
clearable — never an access boundary, every org member can see every org
todo regardless of assignee) and `apiary_id` (nullable UUID, #51, FR-TD-1:
"may be associated with a specific apiary, or left as a general, org-level
todo") are both **cross-service soft references** — no FK, per the
data-ownership rule "cross-context references are by ID, not FK"
(`store/migrations/00003_add_apiary_id.sql`). The usual audit/tombstone
columns round it out (`created_at`/`updated_at`/`recorded_at`/`deleted_at`,
matching activities' shape).

## Surface

| Route                          | Auth                 | Purpose                                                                                                                                                                                                                                                                                     |
| ------------------------------ | -------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `POST /v1/todos`               | OIDC JWT + org scope | Create a todo (FR-TD-1). Validates title/priority/due_date, verifies `assignee_id`/`apiary_id` (if present) against organizations/apiaries before insert, records history. Always starts `status=open`. 201, or 422/409 on validation/idempotency conflict.                                 |
| `PATCH /v1/todos/{id}`         | OIDC JWT + org scope | Edit a todo — a **full resubmit** of title/description/due_date/priority/assignee_id/apiary_id. Re-verifies `assignee_id`/`apiary_id` only when the resubmitted value is non-empty; clearing either (omitted/null) writes NULL with **no** upstream call. Records history. 200, or 404/422. |
| `POST /v1/todos/{id}/complete` | OIDC JWT + org scope | Sets `status=done` + `completed_at=now`. Idempotent if already done (no-op, `completed_at` is not bumped). Records an ordinary `update` history row. 200, or 404.                                                                                                                           |
| `POST /v1/todos/{id}/reopen`   | OIDC JWT + org scope | Sets `status=open`, clears `completed_at`. Idempotent if already open. 200, or 404.                                                                                                                                                                                                         |
| `DELETE /v1/todos/{id}`        | OIDC JWT + org scope | Delete a todo — a **tombstone** (`deleted_at`), never a hard delete. Records history. 204, or 404 if already gone.                                                                                                                                                                          |
| `POST /internal/sync/validate` | OIDC JWT + org scope | Dry-runs a batch of `entity_type: "todo"` sync ops (`put`/`patch`/`delete`), including the assignee/apiary ownership checks — the counterpart of `services/activities/api/sync.go`'s own route, called by `services/sync`'s coordinator.                                                    |
| `POST /internal/sync/apply`    | OIDC JWT + org scope | Applies a batch of `entity_type: "todo"` ops in one local transaction — idempotent on the client id, LWW-compared against `updated_at`, tombstone-aware, conflict-logged on an LWW loss, records history.                                                                                   |
| `GET /healthz`, `GET /readyz`  | none                 | Liveness / readiness.                                                                                                                                                                                                                                                                       |

### Complete/reopen over sync — no bespoke wire op

PowerSync only ever queues `put`/`patch`/`delete` (sync.md §5.1) — there is no
"complete" op on the wire. The client's local `complete()`/`reopen()` are
ordinary SQL `UPDATE`s that touch only `status`/`completed_at`(`/updated_at`),
so offline they queue as a **patch** carrying just those columns, applied by
the exact same LWW path (`api/sync.go`'s `applyTodoOp`/`mergeTodoOp`) as any
other edit. The resulting audit row is an ordinary
`change_type='update'` with `changed_fields` including `status`/
`completed_at` — no dedicated audit change_type or schema change was needed.
See `TestTodosSync_Apply_CompleteViaPatch_RecordsUpdateHistory`
(`main_test.go`).

## Configuration

Inherits the template's env vars, plus the org-resolver's in-cluster URLs,
organizations' own URL for the cross-service assignee-ownership check, and
(#51) apiaries' own URL for the cross-service apiary-ownership check:

| Variable                     | Notes                            |
| ---------------------------- | -------------------------------- |
| `INTERNAL_IDENTITY_URL`      | e.g. `http://identity:8080`      |
| `INTERNAL_ORGANIZATIONS_URL` | e.g. `http://organizations:8080` |
| `INTERNAL_APIARIES_URL`      | e.g. `http://apiaries:8080`      |

## Development

```sh
cd services/todos
sqlc generate -f store/sqlc/sqlc.yaml
go build ./...
go test ./...   # api/... is fast, pure-Go unit tests (priority/status vocabulary
                 # validation, the MemberVerifier's/ApiaryVerifier's HTTP behavior
                 # against an httptest fake — no real DB); the top-level package needs
                 # testcontainers/Postgres (postgres:16-alpine — no PostGIS/JSONB
                 # columns here): schema tenancy check, the create/edit/complete/
                 # reopen/delete REST paths (including the cross-org assignee_id/
                 # apiary_id rejection), the sync validate/apply endpoints (create/
                 # edit/delete, LWW, tombstone-exclusion, offline op idempotency,
                 # assignee-/apiary-ownership de-dup, fail-closed on upstream
                 # error), and store-layer insert/read + cross-org isolation.
```

## Tenancy (FR-TEN-2)

Every route runs behind OIDC authn + `authn.NewOrgResolver` +
`authn.RequireRole` (mirroring activities/apiaries), and every owned table
carries `organization_id`, verified by an automated schema check
(`TestTodosSchema_EveryOwnedTableCarriesOrganizationID`, using
[`dbaccess.UnscopedTables`](../shared/dbaccess/tenancy.go)). Store-layer
cross-org isolation (a foreign org's `GetTodo` call never sees another org's
rows) is covered directly against the generated sqlc queries in
`main_test.go`. Assignment (D-23) and apiary association (#51) are **not**
access boundaries — every org member can see/edit every org todo regardless
of who it's assigned to or which apiary it relates to; only the WRITE of
`assignee_id`/`apiary_id` themselves is tenancy-guarded (below).

**Cross-service assignee ownership (D-23, CRITICAL):** `assignee_id` is a
cross-service reference this service has no database access to verify
directly (ownership rule 1) — every write path that sets it
(`api/write.go`'s `createTodo`/`updateTodo`, `api/sync.go`'s `applyTodoOp`)
calls `api/members_client.go`'s `MemberVerifier.BelongsToOrg`
(organizations' own internal
`GET /internal/memberships/active?user_id=<uid>` — the SAME endpoint
`services/servicetemplate/authn/resolver.go`'s `NewOrgResolver` already calls
to resolve the CALLER's own org, so no new endpoint was needed on
organizations), forwarding the caller's own bearer (zero-trust) BEFORE any
row is written — exactly mirroring how activities closed apiary_id's own
cross-tenant IDOR (itself a carry-over of #284). A 404 (no active membership
anywhere) and a 200 with a DIFFERENT `organization_id` (a member of another
org) are both treated identically: rejected, never distinguished to the
caller (ADR-0002 scope-hiding). Clearing the assignee (explicit
null/omitted) writes NULL with **no** upstream call at all — the common
"unassign" action never touches the network. Covered by
`TestTodosRest_Create_CrossOrgAssigneeIsRejected`,
`TestTodosRest_Update_CrossOrgAssigneeIsRejected`,
`TestTodosRest_Update_ClearAssignee_NoVerificationCall`,
`TestTodosSync_Validate_RejectsCrossOrgAssignee`,
`TestTodosSync_Apply_CrossOrgAssigneeIsNoOp`,
`TestTodosSync_Apply_DedupesAssigneeOwnershipCalls` (`main_test.go`), plus
`api/members_client_test.go`'s pure-unit coverage of the verifier itself.

**Apiary association (#51, FR-TD-1, CRITICAL):** `apiary_id` is a
cross-service reference this service has no database access to verify
directly (ownership rule 1) — every write path that sets it
(`api/write.go`'s `createTodo`/`updateTodo`, `api/sync.go`'s `applyTodoOp`)
calls `api/apiaries_client.go`'s `ApiaryVerifier.BelongsToOrg` (apiaries' own
client-facing, org-scoped `GET /v1/apiaries/{id}` — that handler already
404s for an apiary that doesn't exist OR belongs to a different organization,
ADR-0002 scope-hiding), forwarding the caller's own bearer (zero-trust)
BEFORE any row is written — exactly mirroring how activities closed its own
`apiary_id` cross-tenant IDOR (itself a carry-over of #284) and how this
service's own `assignee_id` guard works (above). The association can be set,
changed, or cleared: a resubmitted `apiary_id` (create or the PATCH full
resubmit) is re-verified only when non-empty; clearing it (explicit
null/omitted) writes NULL with **no** upstream call at all. It also survives
offline creation and sync: the sync validate/apply paths verify every
DISTINCT, well-formed `apiary_id` in a batch up front
(`resolveApiaryOwnership`, de-duplicated — one upstream call per distinct
apiary, not one per op — and fail-closed on a transport/5xx error, mirroring
`resolveAssigneeOwnership`'s own discipline), then apply the same LWW/
tombstone rules as every other field. Covered by
`TestTodosRest_Create_WithApiary_Verified`,
`TestTodosRest_Create_NoApiary_IsGeneralOrgLevelTodo`,
`TestTodosRest_Create_CrossOrgApiaryIsRejected`,
`TestTodosRest_Update_SetApiary_Verified`,
`TestTodosRest_Update_ChangeApiary_Verified`,
`TestTodosRest_Update_CrossOrgApiaryIsRejected`,
`TestTodosRest_Update_ClearApiary_NoVerificationCall`,
`TestTodosHistory_ApiaryIDChangeIsRecorded`,
`TestTodosSync_ValidateThenApply_Create_WithApiary_Success`,
`TestTodosSync_Validate_RejectsCrossOrgApiary`,
`TestTodosSync_Apply_CrossOrgApiaryIsNoOp`,
`TestTodosSync_Apply_ClearApiaryViaPatch`,
`TestTodosSync_Apply_DedupesApiaryOwnershipCalls`,
`TestTodosSync_Apply_ApiaryVerifierUnavailable_FailsClosed` (`main_test.go`),
plus `api/apiaries_client_test.go`'s pure-unit coverage of the verifier
itself.

**Apiary deletion — DECIDED, well-defined state without active
reconciliation:** apiaries never hard-deletes (tombstone via `deleted_at`,
a universal convention in this codebase). Mirroring activities' own
long-standing `apiary_id` precedent (live since #38 — no clear-on-delete
mechanism exists there either), this service does **not** run any active
reconciliation that reaches back into `todos.todos` when an apiary is later
deleted: a todo's `apiary_id` simply keeps pointing at the (now soft-deleted,
404-on-read) apiary id. This satisfies "well-defined state, not silently
lost" via two facts, not a schema/code change here: (1) the apiary's own
deletion is already recorded in `apiaries.audit_log` — no history is
missing; (2) the client tolerates a stale `apiary_id` at READ time (render
as unassociated / "apiary unavailable", never crash, never show broken
data) — out of this service's own scope since no `GET`/list route exists
yet (#53), to be exercised by that later UI. Covered by
`TestTodosApiaryDeletion_TodoApiaryIDSurvivesUntouched`, which proves the
negative: the stored row is completely unaffected by the apiary's deletion.

**Tombstones (FR-TD-1, FR-OF-1):** delete is a soft-delete (`deleted_at`),
never a hard `DELETE`, on both the REST (`deleteTodo`) and sync-apply
(`applyTodoOp`'s `delete` op) paths — every read query filters
`deleted_at IS NULL`, and the PowerSync Sync Rules
(`infra/helm/beekeepingit/charts/powersync/values.yaml`) apply the identical
filter so a delete propagates to every device on their next sync. A
tombstoned row still physically exists (`GetTodoForUpdate` carries no
`deleted_at` filter) so a strictly-newer offline `put`/`patch` can
legitimately "undelete" it under LWW, and a stale offline `delete` loses to a
newer edit/create the same way any other op does. Covered by
`TestTodosRest_Delete_TombstoneRowExcludedFromGet`,
`TestTodosSync_Apply_Delete_TombstonesRow`,
`TestTodosSync_Apply_Delete_IdempotentReplay` and
`TestTodosSync_Apply_Put_UndeletesUnderNewerLWW`.

**Attribution (FR-TEN-2):** the audit `actor_user_id` is derived
server-side from the authenticated caller's resolved claims (`requireOrg`),
never from a client-supplied field — neither `todoCreateRequest`/
`todoUpdateRequest` (REST) nor `todoData` (sync) has an actor field at all.
`assignee_id`/`apiary_id` are, by contrast, legitimate client-supplied data
(the user picks who to assign / which apiary this relates to) — accepted on
the wire and written, but always ownership-verified first (above). Covered
by `TestTodosRest_Attribution_ActorFromClaimsNeverClientSupplied`.
