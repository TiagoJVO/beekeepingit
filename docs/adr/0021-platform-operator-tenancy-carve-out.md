# 0021 — Platform-operator tenancy carve-out: a per-endpoint, claim-gated exception to 404-not-403

- **Status:** Accepted
- **Date:** 2026-07-26
- **Issue / Epic:** [#466](https://github.com/TiagoJVO/beekeepingit/issues/466) /
  [EPIC-18 #463](https://github.com/TiagoJVO/beekeepingit/issues/463) · **Milestone:** M7
- **Requirements:** FR-TEN-2, NFR-ROL-1, NFR-SEC-1, NFR-TST-1
- **Decisions:** [D-3](../../requirements/decisions.md#d-3--organization-membership-first-user-is-admin-invites-others-by-email),
  [D-32](../../requirements/decisions.md#d-32--administration-is-two-tier-organization-admin--platform-operator)
- **Builds on:** [ADR-0002](0002-multi-tenancy.md) (multi-tenancy, the 404-not-403 rule),
  [ADR-0004](0004-authn-authz.md) (authN/authZ model — see its 2026-07-26 update)
- **Depends on:** [#465](https://github.com/TiagoJVO/beekeepingit/issues/465) (the
  `platform_operator` claim contract, merged in #472)
- **Design docs:** [`docs/architecture/auth.md` §3.3/§3.4/§5.3.2](../architecture/auth.md),
  [`docs/architecture/oidc-integration.md` §3.2](../architecture/oidc-integration.md)

## Context

[ADR-0002](0002-multi-tenancy.md) makes cross-organization access return **404, never 403**: a
caller outside an organization cannot even confirm it exists. That rule is what keeps every
tenant's data isolated from every other tenant, and until now it applied to **every** caller,
without exception.

[D-32](../../requirements/decisions.md) adds a second, **platform** administration tier above the
existing organization tier: a small number of BeekeepingIT operators (an app admin console,
EPIC-18) need to act **across every organization** — list organizations, inspect their members,
change membership roles — without being a member of any of them. That authority is real and
intentional (D-32), but it is also the single narrowest, highest-blast-radius exception this
codebase makes to its central tenancy invariant. Getting it wrong is not a UX bug; it is a
cross-tenant data leak.

[#465](https://github.com/TiagoJVO/beekeepingit/issues/465) shipped the **source of truth** for
this authority: a verified, admin-client-only `platform_operator` boolean claim
(`oidc-integration.md §3.2`), minted from a real `platform-operator` Authentik group membership
and never asserted or forged by a client. Nothing consumed that claim yet — this ADR and its
implementation (#466) are that consumer.

## Decision

### The carve-out is a distinct, per-endpoint authorization path — never a middleware bypass

`services/organizations/api/platform_authz.go` adds two functions,
`requirePlatformOperatorOrOrgMember` and `requirePlatformOperatorOrOrgAdmin`, that sit **next to**
the existing `requireOrgMember`/`requireOrgAdmin` (`invitations.go`) rather than modifying them:

```go
func requirePlatformOperatorOrOrgAdmin(w http.ResponseWriter, r *http.Request, q *sqlcgen.Queries, resolver UserResolver) (callerMembership, bool) {
    if isPlatformOperator(r) {
        return platformOperatorMembership(w, r, q, resolver)
    }
    return requireOrgAdmin(w, r, q, resolver) // byte-for-byte the pre-#466 call
}
```

`isPlatformOperator` reads exactly one field: `authn.Claims.PlatformOperator`, populated by the
shared `servicetemplate/authn.NewMiddleware` **only** from a signature-verified token's decoded
claims (never a client-supplied header/query param). When that field is false — every caller
before this story existed, and every caller without an admin-client token after it — the new
functions are **identical function calls** to the unmodified originals. `requireOrgMember` and
`requireOrgAdmin` are not edited by this change at all; ADR-0002's guarantee for them is therefore
not something this ADR asks the reader to trust by inspection — it is provably the same code path
that shipped before #466, exercised by the same pre-existing test suite, unmodified (#466's PR
proves this by running that suite verbatim alongside the new adversarial tests below).

The carve-out is wired into exactly five existing routes — the set #467 (list organizations) and
#468 (cross-org membership lookup) will need once they land, and no others:
`GET /organizations/{orgId}`, `PATCH /organizations/{orgId}`,
`GET /organizations/{orgId}/members`, `PATCH /organizations/{orgId}/members/{userId}`,
`DELETE /organizations/{orgId}/members/{userId}`. No new endpoint is introduced here — #466 is the
**mechanism**, reused by the endpoints #467/#468 add.

Four of the five (`PATCH /organizations/{orgId}`, `GET`/`PATCH`/`DELETE` on the members path) are a
pure **re-point**: the handler's one line changes from calling `requireOrgAdmin` to calling
`requirePlatformOperatorOrOrgAdmin`, nothing else moves. `GET /organizations/{orgId}` is one notch
weaker in that specific "provably unchanged" sense: `getOrganization` used to run its own inline
`resolveActiveMembership` + `{orgId}`-match check rather than calling `requireOrgMember` directly,
so wiring in the platform path there is a **rewrite** — replacing that inline logic with a call to
`requireOrgMember` (byte-for-byte the same checks, in the same order) before adding the platform
branch in front of it. The refactor is behavior-preserving and covered by the pre-existing
`TestGetOrganization_OtherOrg_Returns404` (run unmodified) plus this story's new adversarial tests,
but it is a slightly different kind of change than the other four's simple re-point, worth naming
explicitly rather than letting "additive" quietly cover two different things.

### Why `platform_operator` and never `groups`

Authentik's managed `profile` scope mapping emits a `groups` claim containing
`"platform-operator"` on **both** the `beekeepingit-pwa` and `beekeepingit-admin` OIDC clients
(`oidc-integration.md §3.2`) — it is who-you-are, informational, and shared. A **field-app (PWA)**
token for a real operator therefore already lists that group today. If any authorization code in
this service read `groups` instead of the dedicated claim, a beekeeper's ordinary, long-lived,
**offline-cached** phone token would silently carry cross-tenant platform authority — no admin
console session needed, no additional verification, just a stale token an attacker who steals a
device already has. This is not a hypothetical: it was flagged explicitly in #465's handoff comment on
[#466](https://github.com/TiagoJVO/beekeepingit/issues/466) as the landmine this story's design has
to avoid, and it is why `platform_operator` was minted as a **distinct, admin-client-scoped**
boolean rather than reusing `groups`.

`platform_authz.go`'s package doc states this constraint directly, `isPlatformOperator` is the
single sanctioned read site for the claim in this service, and `platform_operator_authz_test.go`'s
`TestPlatformOperator_GroupsClaimAlone_DoesNotGrantAccess` mints a token with `groups` set but the
boolean claim absent and asserts it is still refused (404) — a regression test for exactly this
landmine, not just a design note.

### What the carve-out permits, precisely

For a caller whose verified access token carries `platform_operator: true`:

- The `{orgId}` path parameter on the five routes above is **not** asserted against the caller's
  own membership (there may be none) — it only needs to name a **real** organization.
- The caller is granted the same capability `requireOrgAdmin` would grant an actual admin of that
  organization: read the organization, edit it, list/remove members, change roles.
- The caller's own identity (`identity.users` row, resolved the same way the ordinary path
  resolves it) is still what lands in `organizations.audit_log.actor_user_id` for any write —
  platform actions are attributed to the real operator, never to the target org's own admin.

For every other caller — an organization admin, a plain member, or an authenticated caller with no
organization at all — nothing changes: the same 404 (never 403) on any organization they do not
belong to, the same 403 on an admin-only action they are not privileged for within their own org.

### Why `404` still applies to everyone else

The carve-out is checked **first** and, only for a genuinely verified operator, is the request's
**entire** authorization decision — it is not layered on top of, or blended with, the membership
path. A caller who does not carry the claim never reaches any code this ADR added; they run the
exact `requireOrgMember`/`requireOrgAdmin` call that existed before #466. ADR-0002's rule was never
weakened for them because their code path was never touched.

### Recoverability of "which path granted this" (for #470)

`callerMembership` (`organizations.go`) gains one new field, `AuthorizedVia`, left at its zero
value `""` by the unmodified membership path and set to `"platform_operator"` only by
`platformOperatorMembership`. Every grant through the platform path is also logged at `INFO` —
distinct from this package's existing WARN-level _denial_ logging — carrying the organization id,
the operator's own resolved user id, and the request path/method. This ADR deliberately does **not**
add a persisted `audit_log` column for it: `auth.md §5.3.2`'s "Accountability" row assigns making
history **distinguishably** record platform actions to
[#470](https://github.com/TiagoJVO/beekeepingit/issues/470), which reads the history this story's
handlers already write (`actor_user_id` = the operator's own identity, never blank, never the
target org's admin — proven by `TestPlatformOperator_AuditAttributesToOperator`). `AuthorizedVia`
and the INFO log are the extension point #470 builds the persisted, queryable distinction on top
of, without this story pre-guessing #470's exact schema.

**Update (#470, landed):** the persisted column is `organizations.audit_log.actor_scope`
(migration `00005`) — `'member'` \| `'platform_operator'`, set by `actorScopeFor(AuthorizedVia)`
(`api/audit.go`) at every write site this ADR's five routes reach that writes an audit row
(`updateOrganization`, `removeMemberHandler`, `changeMemberRoleHandler`; `getOrganization`/
`listMembersHandler` are read-only, no audit write). See `history.md`'s "As built" note on `AUDIT_LOG`.

## Consequences

**Positive**

- The regression surface for this change is exactly one boolean check (`isPlatformOperator`) per
  combinator; every existing behavior for organization-tier admins and plain users is the same
  function call it was before this story, not a reimplementation that merely intends to match it.
- `#467`/`#468` get a proven, minimal extension point (`isPlatformOperator`) rather than needing to
  invent their own claim-reading convention.
- The single unsafe signal this design depends on NOT using (`groups`) has its own regression test,
  not just a comment.

**Negative / risks**

- **Mutual exclusivity, not a merge, of the two paths.** A caller who both carries
  `platform_operator: true` **and** happens to hold a real membership in the org being acted on
  (an edge case: an operator who is also a genuine tenant user) is authorized via the platform path
  unconditionally — `platformOperatorMembership` never consults their real membership row, and the
  response's `role` field reports the platform grant (`"admin"`), not their actual membership role.
  This was a deliberate simplification to keep the two paths provably independent (see Alternatives
  below) rather than a security gap, but it is a product-visible nuance worth a second look before
  this ships broadly.
- **`role: "admin"` overloads the wire contract.** The `Role` enum
  (`contracts/openapi/organizations.openapi.yaml`) is closed to `[admin, user]`; a platform-operator
  grant reuses `"admin"` rather than adding a third value, so the admin console cannot currently
  distinguish "I am this org's real admin" from "I am a platform operator viewing this org" purely
  from this field. Extending the enum was judged out of scope for an authorization-mechanism story
  (#466) versus a contract change, but it is flagged here for #467/#468/#470 to revisit if the
  console needs to render that distinction.
- **No persisted "authorized via platform operator" column yet.** ~~Until #470 lands, the only
  durable record that a given `audit_log` row came from the platform path (rather than the org's
  own admin) is that its `actor_user_id` does not correspond to a membership row in that
  organization — inferable, not stored.~~ **Resolved by #470**: `organizations.audit_log` gained an
  `actor_scope` column (migration `00005`) written explicitly, in the same transaction as every
  write this ADR's five routes make, directly from this ADR's own `AuthorizedVia` field — see
  `history.md`'s "As built (`organizations` only, #470...)" note and
  `services/organizations/api/audit.go`'s `actorScopeFor`.

## Alternatives considered

- **Try the membership path first, fall back to the platform path.** More "fair" for the dual-role
  edge case above. This is true only for _ordinary_ callers as a group: `requireOrgMember`/
  `requireOrgAdmin` themselves genuinely can't be reused as a non-failing probe (they write a
  `problem.Problem` directly on any failure), so a "membership-first, blend the two paths for
  everyone" design would need to restructure them — real intertwining, correctly avoided. But for
  an **operator caller specifically**, that restructuring was not actually a hard blocker:
  `activeMembershipFor` (`organizations.go`) already exists as a non-response-writing probe
  (`getMyOrganization` uses it exactly this way, returning `pgx.ErrNoRows` to its caller instead of
  writing to the `ResponseWriter`), so `platformOperatorMembership` could have called it first and
  preferred a real membership match over the platform grant, entirely without touching
  `requireOrgMember`/`requireOrgAdmin`. We did not do this — **rejected**, but on **YAGNI and
  strict-superset grounds** (the platform grant is a superset of what a real membership would give
  this caller on these five routes, so the extra probe adds a DB round-trip and a second code path
  to reason about for a case D-32 describes as atypical — "typically not a member of any
  organization" — with no observable behavior difference for the common case), not because the
  probe was architecturally unavailable. If the dual-role nuance (Consequences, above) proves
  worth closing, `activeMembershipFor` is the ready-made building block — no restructuring needed.
- **A blanket middleware bypass for any admin-client token.** Simpler to wire, but violates the
  explicit "never a blanket bypass" requirement (D-32) and would apply to routes never audited for
  the carve-out (e.g. future endpoints added without this ADR in mind). **Rejected** — the carve-out
  is deliberately opted into per handler.
- **Adding a third `Role` enum value (`platform_operator`) now.** Cleaner long-term, but a contract
  and (likely) admin-console client change beyond this story's authorization-mechanism scope.
  **Deferred** to whichever of #467/#468/#470 first needs the console to render the distinction.
- **Persisting `AuthorizedVia` to `audit_log` immediately.** Would fully close the "no persisted
  record" gap now, but pre-empts #470's own schema design for exactly that problem
  (`auth.md §5.3.2`'s "Accountability" row). **Deferred to #470**, with `AuthorizedVia` + the INFO
  log as the ready-made input.

## Follow-ups

- [#467](https://github.com/TiagoJVO/beekeepingit/issues/467) — ✅ **Built:** `GET /organizations`
  (list organizations) calls `isPlatformOperator(r)` directly and `problem.Forbidden(...)` (not
  `NotFound` — there is no `{orgId}` to hide) when it is false, exactly as anticipated below. The
  response is a minimal per-organization summary (`id`, `name`, `member_count`) — no member roster,
  no invitation data. See `platform_authz.go`'s package doc and
  `services/organizations/api/organizations.go`'s `listOrganizations`.
- [#468](https://github.com/TiagoJVO/beekeepingit/issues/468) — ✅ **Built:** the cross-org membership
  lookup, `GET /organizations/platform/memberships` (`services/organizations/api/platform_membership_lookup.go`),
  follows exactly this extension point: `isPlatformOperator(r)` directly, `problem.Forbidden` (not
  `NotFound`) for every non-operator caller, and the operator's own identity resolved
  (`resolver.Resolve`, mirroring `platformOperatorMembership`) purely for its INFO grant log — this
  is a read endpoint, so there is no `audit_log` write to attribute.
- ~~[#470](https://github.com/TiagoJVO/beekeepingit/issues/470) — persist a distinguishable,
  queryable record of platform-path actions in history, building on `AuthorizedVia` and the INFO
  grant log this ADR introduces.~~ **Done** — `organizations.audit_log.actor_scope` (migration
  `00005`), derived directly from `AuthorizedVia` at every write site this ADR's routes touch.
- Revisit the `role: "admin"` wire-contract overload (Consequences, above) if the admin console
  needs to visually distinguish a platform-operator grant from a real org admin.
