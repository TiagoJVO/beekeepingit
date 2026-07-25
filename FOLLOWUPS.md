# Follow-ups ledger

> Session-persisted **pending** work, committed for continuity and cross-session handoff.
> Maintained per the [`track-pending-work`](.claude/rules/track-pending-work.md) rule.
> **Not the backlog** (GitHub Issues is) — this is the pre-merge checklist for in-flight
> branches, and it **trends toward empty**: an entry belongs to the PR that added it and is
> resolved — pruned or promoted to an Issue — by the time that PR merges. Completed work is
> not recorded here; the commit, the PR description, and git history already keep that record.

## `feat/admin-org-management` (#73 — admin org view/edit)

- **CORS: expose `ETag` for the cross-origin admin app** — the org-management screen's
  `If-Match` optimistic concurrency (FR-TEN-2) needs the API to send
  `Access-Control-Expose-Headers: ETag`, which no service/gateway config does yet. #73 ships a
  client fail-safe (a null ETag blocks the save with a clear message — no silent overwrite), so
  this is **not a merge blocker for #73**, but the edit feature is unusable cross-origin until
  it lands. Promoted to [#449](https://github.com/TiagoJVO/beekeepingit/issues/449). _Status:
  tracked in #449 (infra/services), not owed by this PR._

## `feat/organizations-member-lifecycle` (#290 — member remove + role change)

- **Re-invite / re-join after member removal** — enabling member removal (#290, soft
  `status` → `removed`) makes a previously-unreachable edge reachable: if an admin later
  **re-invites a removed member's email** and that user logs in, the accept-on-login path
  (`acceptPendingInvitationByEmail` in `services/organizations/api/invitations.go`) does an
  `INSERT` into `organizations.memberships`, which violates `UNIQUE (organization_id, user_id)`
  because the `removed` row persists — surfacing as a `500` instead of re-activating the
  membership. **Not a merge blocker for #290** (remove + role change only; the removal endpoint
  itself is correct). Re-invite is explicitly still-open detail under D-3. **Fix when re-invite
  is built:** have the accept path **reactivate** an existing `removed` membership (UPSERT /
  `ON CONFLICT (organization_id, user_id) DO UPDATE SET status='active', role=…`) instead of a
  bare `INSERT`. **Promote to a GitHub Issue** and fold into the re-invite/expiry story; prune
  here once referenced.

---

_Aside from the above: PR #418's before-merge item (create the `cluster-ops.yml`
secrets/variables) is done — the `staging-gate` set is in place. `production-gate` secrets are
not owed here: prod is deferred until DR (`Q-DR`) + #90 land (D-26), and the fill-in steps live in
`infra/README.md#secrets--remote-cluster-operations`. The `DEPLOY_NOTIFY_TOKEN` manual step remains
tracked in [#413](https://github.com/TiagoJVO/beekeepingit/issues/413), still open._
