# Follow-ups ledger

> Session-persisted **pending** work, committed for continuity and cross-session handoff.
> Maintained per the [`track-pending-work`](.claude/rules/track-pending-work.md) rule.
> **Not the backlog** (GitHub Issues is) — this is the pre-merge checklist for in-flight
> branches, and it **trends toward empty**: an entry belongs to the PR that added it and is
> resolved — pruned or promoted to an Issue — by the time that PR merges. Completed work is
> not recorded here; the commit, the PR description, and git history already keep that record.

---

## `fix/flutter-profile-theming`

- **Consolidate the duplicated "looks like an email" validator onto the new
  shared helper.** `client/lib/core/validation/email.dart` (`looksLikeEmail`)
  was extracted from `profile_screen.dart`'s previously-private
  `_looksLikeEmail`, which was byte-for-byte duplicated in
  `client/lib/features/account/account_screen.dart:360-362`. `account_screen.dart`
  was left untouched here because a separate, concurrent PR is already
  editing that file (per this branch's review scope) — once that PR lands,
  switch `account_screen.dart`'s copy over to `core/validation/email.dart`'s
  `looksLikeEmail` and delete its own private `_looksLikeEmail`. Not tied to
  a tracked issue; low-risk cleanup, do in whichever PR touches
  `account_screen.dart` next.
