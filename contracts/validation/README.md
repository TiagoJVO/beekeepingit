# Shared validation description

`sync-ops.validation.json` is the **single definition** of the mechanical validation rules
a client→server **sync write-back op** must satisfy. It exists so the offline client can
re-check queued edits against the rules the server will apply **before pushing them**
(FR-OF-2, [D-12](../../requirements/decisions.md#d-12--offline-sync-write-back-atomic-validation-parity-notify-and-fix),
[sync.md §9](../../docs/architecture/sync.md)) — so a problem is caught on the device
instead of arriving as a rejection after the fact.

> **The server is authoritative.** Client-side validation is a **UX optimization, not a
> security boundary**. Nothing here relaxes what the owning services enforce.

## Who reads it

| Consumer                                                                                                 | How                                                                                                                                                                          |
| -------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Client** — `client/lib/core/validation/`                                                               | Embedded verbatim into `gen/sync_validation_rules.g.dart` by `scripts/gen-sync-validation.sh`; parsed by `sync_validation_rules.dart`, evaluated by `sync_op_validator.dart` |
| **Owning services** — `services/{apiaries,activities,journeys,todos}/api/sync_validation_parity_test.go` | Read through `services/shared/syncvalidation` (+ `…/paritytest`) to bind each service's own constants to this file                                                           |

The client copy is embedded **byte-for-byte**, never translated into Dart literals, so the
rule _data_ on the device cannot drift from this file. A stale copy fails
`client/test/core/validation/sync_validation_rules_test.dart`.

## Changing a rule

1. Change the rule in the owning service (`services/<svc>/api/sync.go`) — it stays the
   source of truth.
2. Mirror it here.
3. Run `./scripts/gen-sync-validation.sh` and commit the regenerated Dart file.
4. `go test ./api/...` in the owning service and `flutter test` in `client/` must pass.

**Relaxing a described limit is a client-breaking change; tightening one is not.** The
parity tests bind this file to the server's constants at build time, but the copy actually
running on a device is whatever the last client release embedded. So if `notes`'
`maxLength` goes 10000 → 20000 server-side, an older client keeps rejecting a valid
15000-character note it received by down-sync — the same permanent-rejection asymmetry
that keeps the extensible vocabularies out of this file entirely. **Ship a relaxation with
a client release**, or move the rule to `serverOnly`. A tightening only makes the client
defer more often, which is always safe.

## What is deliberately **not** here

The `serverOnly` array at the top of the file is the list, with the reason for each. The
principle: **a rule belongs here only if mirroring it cannot cost a user a valid edit.**

- Rules needing server state (cross-organization ownership of `apiary_id` / `journey_id` /
  `assignee_id`) — undecidable offline.
- Rich schemas (activities' per-activity-type attribute bag) — not a mechanical constraint.
- **Extensible controlled vocabularies** (`counter_type`, `main_activity_type`, journey
  `status`, todo `priority`/`status`, D-20). A newer vocabulary value can reach an older
  client by down-sync and be re-uploaded; a frozen client copy would then reject it
  **permanently**, with no server to overrule it. The asymmetry makes mirroring them worse
  than leaving them out.
- Whole-request properties (batch/body size caps) — not something a queued edit can fix.

## Rule vocabulary

Every check carries its own `code` and `message`, matching the RFC 9457
`problem.FieldError` the server would have returned, so no consumer has to reconstruct
either.

**Envelope** (all entity types): `id` must be a UUID; `updated_at` (the LWW comparator) is
required.

**Per entity type:** `ops.allowed` (the op kinds it accepts), `fields[]`, `entityChecks[]`.
`entityTypeCheck` records the server's own `entity_type` guard; the client dispatches _by_
`entity_type`, so it cannot fail that check — it is described for completeness, not for the
client to run.

**`absentWhen`** — how a field counts as "not supplied", mirroring the exact guard the
server uses for _that_ field (this differs per field and is load-bearing):

| Value       | Meaning                  | Server form                        |
| ----------- | ------------------------ | ---------------------------------- |
| _(omitted)_ | only `null`/missing      | `data.X == nil`                    |
| `empty`     | `null` or `""`           | `data.X == nil \|\| *data.X == ""` |
| `blank`     | `null` or all-whitespace | `strings.TrimSpace(*data.X) == ""` |

**Field checks:** `required` (with `on`: the op kinds it applies to), `maxLength` (UTF-8
**bytes**, matching Go's `len()`), `maxBytes`, `min`, `range` (with `onlyWithAll`),
`uuid`, `date` (`YYYY-MM-DD`), `dateTime` (RFC 3339), `jsonObject`.

**Entity checks:** `requiredGroup` (several fields required together, reported under one
path), `requiredWhenPresent` (a paired field).

### The `put` / `patch` distinction

`required.on` is almost always `["put"]`. A `patch` is a **partial** update — PowerSync
uploads only the columns that actually changed — so demanding a `put`-only field of a
patch would reject perfectly valid edits. That is the client-side face of
[#378](https://github.com/TiagoJVO/beekeepingit/issues/378), and it is asserted from both
sides: `AssertRequiredOn` in each service's parity test, and an explicit
`patch`-passes case per rule in `client/test/core/validation/sync_op_validator_test.dart`.

## Known rough edge: `journey.default_attributes` and an explicit `null`

`validateDefaultAttributes` (`services/journeys/api/types.go`) treats an **absent**
`default_attributes` as "don't touch" but a present JSON `null` as invalid — `len(raw) == 0`
skips, whereas the four bytes `null` unmarshal to a nil map and report
`default_attributes must be a JSON object`. The client's `jsonObject` check mirrors that
faithfully, which is why it is described here.

The rough edge is that `journeys_repository.dart` stores SQL **NULL** for an empty bag. If
PowerSync includes null columns in a `put`'s `opData` (not verified either way), clearing a
journey's defaults already produces an op this service rejects today — the parity check
would then surface it before the push rather than after, but would not have caused it.
Every other "absent means don't touch" field on that struct treats `null` as absent, so the
fix, if it is real, belongs server-side in `validateDefaultAttributes`; the `jsonObject`
check here would then need to skip an explicit null for that field. Tracked in
`FOLLOWUPS.md`.

## Status

The consumers above are what exists today. The exhaustive **boundary contract tests** —
synthesize an op violating exactly one described rule, assert the owning service reports
exactly that field path and code, and vice versa for the client evaluator — are
[#585](https://github.com/TiagoJVO/beekeepingit/issues/585), built on this artifact.
