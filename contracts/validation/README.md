# Shared validation description

Two files, one contract:

| File                       | What it is                                                                                                           |
| -------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| `sync-ops.validation.json` | The **rules** — the single definition of what a queued sync op must satisfy                                          |
| `sync-ops.corpus.json`     | The **boundary contract corpus** — concrete ops replayed through both real evaluators ([below](#the-corpus), `#585`) |

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
| **Both, case by case** — `sync_validation_corpus_test.go` / `sync_op_corpus_test.dart`                   | Replay `sync-ops.corpus.json` through each side's **real** validator and compare the verdicts — see [The corpus](#the-corpus)                                                |

The client copy is embedded **byte-for-byte**, never translated into Dart literals, so the
rule _data_ on the device cannot drift from this file. A stale copy fails
`client/test/core/validation/sync_validation_rules_test.dart`.

## Changing a rule

1. Change the rule in the owning service (`services/<svc>/api/sync.go`) — it stays the
   source of truth.
2. Mirror it here.
3. Add or update the corpus case(s) for it in `sync-ops.corpus.json` — a rule with no case
   fails `TestCorpusExercisesEveryDescribedRule`.
4. Run `./scripts/gen-sync-validation.sh` and commit the regenerated Dart file.
5. `go test ./api/...` in the owning service, `go test ./syncvalidation/...` in
   `services/shared`, and `flutter test` in `client/` must pass.

CI runs all of that whenever anything in the parity surface changes — this directory,
`services/shared/syncvalidation/`, any service's sync validators, or the client's validation
layer — via the `ci` job's parity steps (`.github/workflows/ci.yml`). It has to be wired
explicitly there: `build-publish.yml` picks a component up only when a changed path is
prefixed by that component's own directory, so a change to this directory alone matches
nothing.

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

| Value       | Meaning                             | Server form                          |
| ----------- | ----------------------------------- | ------------------------------------ |
| _(omitted)_ | only `null`/missing                 | `data.X == nil`                      |
| `empty`     | `null` or `""`                      | `data.X == nil \|\| *data.X == ""`   |
| `blank`     | `null` or all-whitespace            | `strings.TrimSpace(*data.X) == ""`   |
| `jsonNull`  | missing, or an explicit JSON `null` | `len(raw) == 0 \|\| isJSONNull(raw)` |

`jsonNull` is for a `json.RawMessage` field, where a present `null` is four wire bytes
rather than a nil field. It is the **only** value that also makes the shape checks below
(`jsonObject`, `maxBytes`) skip an explicit null — those read raw presence, not this absence
notion. A RawMessage field left at the default keeps the stricter reading: a present `null`
is present-and-not-an-object. Both readings are live, one per field — see
[`journey.default_attributes` and an explicit `null`](#journeydefault_attributes-and-an-explicit-null).

**Field checks:** `required` (with `on`: the op kinds it applies to), `maxLength` (UTF-8
**bytes**, matching Go's `len()`), `maxBytes`, `min`, `range` (with `onlyWithAll`),
`uuid`, `date` (`YYYY-MM-DD`), `dateTime` (RFC 3339), `jsonObject`.

**Entity checks:** `requiredGroup` (several fields required together, reported under one
path), `requiredWhenPresent` (a paired field). The path a failure is reported against is
`reportAs` when present, otherwise — for `requiredWhenPresent`, which reports against the
half that is **missing**, not the half that triggered the rule — the `require` field,
otherwise `data` itself. Both readers apply that fallback
(`sync_validation_rules.dart`, `syncvalidation.EntityCheck.ReportPath`), and the corpus is
what keeps the two derivations equal.

### The `put` / `patch` distinction

`required.on` is almost always `["put"]`. A `patch` is a **partial** update — PowerSync
uploads only the columns that actually changed — so demanding a `put`-only field of a
patch would reject perfectly valid edits. That is the client-side face of
[#378](https://github.com/TiagoJVO/beekeepingit/issues/378), and it is asserted from both
sides: `AssertRequiredOn` in each service's parity test, and an explicit
`patch`-passes case per rule in `client/test/core/validation/sync_op_validator_test.dart`.

## `journey.default_attributes` and an explicit `null`

`journeys_repository.dart` stores SQL **NULL** for an empty defaults bag, while
`validateDefaultAttributes` (`services/journeys/api/types.go`) used to reject a present
JSON `null` — `len(raw) == 0` skipped, whereas the four bytes `null` unmarshal to a nil map
and reported `default_attributes must be a JSON object`. Whether that ever reached the wire
turned on one unanswered question: **does PowerSync include null columns in an upload op's
`opData`?**

### The answer, and how it was measured

It depends on the op kind, and the answer is not symmetric:

| Op                                                      | Is the null column in `opData`?            |
| ------------------------------------------------------- | ------------------------------------------ |
| `put` (insert)                                          | **No** — null columns are dropped entirely |
| `patch` where the column CHANGED to NULL                | **Yes** — as an explicit JSON `null`       |
| `patch` where the column was already NULL and untouched | No                                         |

Measured against the real `powersync-sqlite-core` extension (not the SDK docs): load the
extension into a plain SQLite connection, `powersync_init()`, `powersync_replace_schema()`
with the client's own `journeys` table, write through the generated view and read `ps_crud`
back. The mechanism is visible in the triggers the extension generates, which is why the
result is stable rather than a version accident:

- `ps_view_insert_journeys` queues `powersync_diff('{}', json_object(<every column>))`.
  Diffing against `{}` makes a null column equal to its (missing) old value, so it is
  dropped — a `put` never carries one.
- `ps_view_update_journeys` queues `powersync_diff(json_object(<OLD columns>),
json_object(<NEW columns>))`. A column that went from a value to NULL **differs**, so the
  key is emitted with a JSON `null` value.

So **clearing a journey's defaults produced an op the service rejected**, and had done since
`default_attributes` shipped (#385): `{"op":"patch", "data":{"main_activity_type":"harvest",
"default_attributes":null, ...}}` came back 422 and went to the needs-fix dead letter.
[#584](https://github.com/TiagoJVO/beekeepingit/issues/584)'s pre-push parity check only
made it visible one step earlier; it did not cause it.

The measurement also matches what another service already depends on:
`journeyIDKeyPresent` (`services/activities/api/sync.go`, #387) exists precisely because a
patch distinguishes "key absent" from "key present as `null`", and apiaries reads an
explicit null as "the user cleared the location". Journeys' `default_attributes` was the
one field that assumed the null could not arrive.

### The fix

`validateDefaultAttributes` now treats the `null` literal as a valid "no defaults" value,
and `normalizeDefaultAttributes` collapses it to nil bytes so a cleared bag lands as SQL
NULL rather than the JSONB literal `null`. Note that absent and `null` stay **distinct** on
apply, because PowerSync makes them distinct: an absent key means "this column did not
change" (keep the stored value), an explicit `null` means "the user cleared it".

The description follows with `"absentWhen": "jsonNull"` on that field — the one absence rule
that also skips an explicit null for the raw-presence checks (`jsonObject`, `maxBytes`).
That relaxation is **per field, not per check kind**: activities' `attributes` keeps the
strict reading, because `activities_repository.dart` always writes an encoded map and never
SQL NULL, so no device can produce that shape there. The corpus pins both — the case
`journey/patch/default-attributes-is-an-explicit-null` now expects acceptance, and
`activity/patch/attributes-is-an-explicit-null` still expects rejection.

## The corpus

`sync-ops.corpus.json` ([#585](https://github.com/TiagoJVO/beekeepingit/issues/585)) is the
other half of the contract. The description says what the rules **are**; the corpus is a set
of concrete wire ops run through **both real evaluators** — each owning service's actual
`validate*Op` and the client's actual `validateSyncOps` — asserting they reach the same
verdict and report the same `(field, code, message)`.

It exists because binding the description to each service's _constants_ (the parity tests
above) leaves three things unchecked, and the corpus closes all three at once:

1. **A described rule the server quietly stopped applying.** Delete the `notes` length check
   from `validateApiaryOp` and leave the constant in place: every constants-binding assertion
   still passes.
2. **The `code` / `message` / `ops[i].data.x` strings.** Nothing compared them to what a
   service actually emits, so they were in the description on trust. The corpus pins them
   against the server, and `TestCorpusMessagesMatchTheDescription`
   (`services/shared/syncvalidation`) pins the description against the corpus.
3. **The two evaluators reading one rule differently** — `absentWhen`, `onlyWithAll`, the
   delete short-circuit, byte-vs-code-unit lengths, calendar-date and RFC 3339 strictness.
   That is where two independent implementations of one description drift, and it is the only
   part no amount of constant-binding can reach.

**Shape of a case.** `op` is the wire op; `expect` is what **both** sides must report and
nothing else (empty means both must accept it); `serverOnly` is what **only** the server
reports — a rule in the description's `serverOnly` list, or one the client structurally
cannot run — and the client must report none of it. Each `serverOnly` entry carries a `why`,
so an asymmetry reads as a decision rather than as an unnoticed divergence.
`entityType` routes the case to its owning validator and is deliberately **not** read from
`op.entity_type`, which lets a case carry a wrong `entity_type` on the wire and still reach
the right validator. A string of the form `@repeat:<count>:<unit>` expands on both sides, so
a 10001-character `notes` field needn't be spelled out; keep `<`, `>` and `&` out of string
values, since Go escapes them by default and Dart does not.

**Who runs it.** `services/*/api/sync_validation_corpus_test.go` (via
`services/shared/syncvalidation/paritytest`) and
`client/test/core/validation/sync_op_corpus_test.dart`. A failure on either side prints the
case, both sides' full behaviour and the two-way difference, so the diverging rule is
readable straight off the CI log.

**What guards the corpus itself** (`services/shared/syncvalidation`): every described rule
must be exercised by at least one case, every entity must have at least one case both sides
**accept** (a corpus of nothing but rejections would pass against a validator that rejects
everything), and every message must match the description's.
