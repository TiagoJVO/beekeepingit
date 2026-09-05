# 0025 — Client↔server sync validation parity via a shared rule description, not the OpenAPI schema

- **Status:** Accepted
- **Date:** 2026-09-01
- **Issue / Epic:** #584 · EPIC-06 (#7) · enables #585
- **Requirements:** FR-OF-2, NFR-TST-1
- **Decisions:** [D-12](../../requirements/decisions.md#d-12--offline-sync-write-back-atomic-validation-parity-notify-and-fix)
  (validation parity), [D-6](../../requirements/decisions.md) (offline sync),
  [D-20](../../requirements/decisions.md) (controlled vocabularies validated in code)
- **Refines:** [sync.md §9](../architecture/sync.md), which fixed the _approach_ and left the
  mechanism as a hand-off
- **Design:** [sync.md §9 "As built"](../architecture/sync.md) ·
  [`contracts/validation/README.md`](../../contracts/validation/README.md)

## Context

FR-OF-2 and D-12 require the client to **revalidate queued edits against the same rules the
server will apply, before pushing**, so a problem is caught offline rather than arriving as a
rejection. `sync.md` §9 fixed the approach in three parts:

1. express as much as possible declaratively in the **OpenAPI schema**, which is contract-first
   and codegen'd to both sides;
2. keep richer business rules in a **small shared validation description** mirrored by client and
   server, with the server as the single source of truth;
3. treat any divergence as a **bug caught by boundary contract tests**.

Part 1 does not currently hold. `contracts/README.md` records that **Dart/TS typed-client codegen
is deferred** — no client consumes a generated client and no tool is decided — so "codegen'd to
both sides" has exactly one side today. The rules themselves are also a poor fit for JSON Schema:
almost every `required` here is conditional on the op kind (`put` requires a full row, `patch` is a
partial update — [#378](https://github.com/TiagoJVO/beekeepingit/issues/378)), which JSON Schema
can only express as nested `if`/`then`/`else`, and the byte-length, calendar-date and
paired-coordinate rules need custom keywords regardless.

The concrete risk this ADR has to manage is **asymmetric**. A rule the client fails to mirror
merely costs a round-trip: the server still rejects the op and the existing notify-and-fix path
handles it. A rule the client mirrors **wrongly** costs the beekeeper a valid edit, with no server
to overrule the verdict — the client's rejection is a prediction the server never got to disagree
with.

## Decision

### 1. A first-class, language-neutral rule description, not an OpenAPI schema

`contracts/validation/sync-ops.validation.json` is the single definition of the mechanical
sync-op rules for every syncable entity type. It is a real, addressable artifact (part 2 of §9), sitting
beside `contracts/openapi/` rather than inside it, with its own README. `contracts/openapi/`
remains the contract for the HTTP surface; this file is the contract for what a queued op must
contain.

### 2. The client embeds it verbatim; it does not re-express it

`scripts/gen-sync-validation.sh` wraps the JSON, byte-for-byte, into a Dart constant
(`client/lib/core/validation/gen/sync_validation_rules.g.dart`), committed like the repo's
generated l10n. The rule **data** on the device therefore cannot drift from the shared file — a
stale copy fails a client test. What can still differ is the _interpreter_: the Dart evaluator and
each service's Go validator are separate implementations of the same description.

### 3. A rule is mirrored only if mirroring it cannot cost a valid edit

The description carries a `serverOnly` array naming every rule deliberately left out, with the
reason. Three classes stay server-only:

- rules needing server state (cross-organization ownership) — undecidable offline;
- rich schemas (the per-activity-type attribute bag);
- **extensible controlled vocabularies** (D-20). A value added server-side reaches an older client
  by down-sync and is re-uploaded by it; a frozen client copy would reject it permanently. The
  UI already constrains what a user can pick, so mirroring buys nothing and risks everything.

The same reasoning removes apiaries' "a patch must change at least one field" rule, which is
defined over an exact field list: adding a field server-side would silently turn valid patches into
client-side rejections, for no user-visible benefit.

### 4. Each owning service binds its own constants to the description in its own tests

`services/shared/syncvalidation` reads the description; `…/paritytest` holds the assertions;
each `services/*/api/sync_validation_parity_test.go` asserts the described caps, bounds, allowed op
kinds and `put`/`patch` required gating against that package's own constants and wire structs — and
that no described field has fallen off the struct. Changing a rule in Go without updating the
description now fails `go test`, so "hand-kept mirror" becomes "mirror a build fails on". The
services' validators are **not** rewritten to be driven by the description: the server stays the
authority, and the description is checked against it.

### 5. Failures land in the existing notify-and-fix flow

A pre-push failure reuses the `sync_rejected_ops` dead-letter, the `rejectedChanges` stream and the
needs-fix screen (sync.md §8), carrying the distinct problem code `validation.failed.local` so the
user is told the change **was not sent**, rather than that a server refused it, and so a predicted
rejection stays distinguishable from a real one in logs and in the UI.

## Consequences

**Positive**

- One definition of the mirrored rules, embedded byte-identically on the client and bound to the
  server's constants by tests — instead of validation logic hand-written twice.
- Works fully offline: the check runs before the token fetch and before any HTTP.
- Zero new UI surface; the whole needs-fix flow, Fix deep-links, clear-on-success and Dismiss are
  reused unchanged.
- The artifact is what #585's boundary contract tests are built on, and what a save-time
  (form-level) check can reuse without any new source of truth.

**Negative**

- The rule set is a **subset** by design; the server still rejects things the client cannot
  predict. That is the intended trade, not a gap to close.
- Two evaluators (Dart, Go) interpret one description. The current tests bind the _data_; binding
  the _interpretation_ case-by-case is #585.
- A false positive drops the op from the upload queue (it must, or the FIFO queue wedges) and the
  user has to re-save from the needs-fix card. The edit is retained, never lost, but the cost of a
  wrong rule is real — which is why §3 exists.
- The deployed client runs whatever copy its last release embedded, so **relaxing** a described
  limit or range server-first makes older clients reject values the server now accepts. Relaxations
  ship with a client release; tightenings are always safe. Recorded in
  [`contracts/validation/README.md`](../../contracts/validation/README.md).

## Alternatives considered

- **Express the rules in OpenAPI and codegen both sides** (§9's stated first choice). Rejected for
  now: no Dart codegen exists or is decided, and conditional-by-op-kind requireds plus custom
  formats fit JSON Schema badly. Revisit if a Dart client generator is adopted — the description
  would then become a generator input rather than a second artifact.
- **Drive the Go validators from the description too**, making it the literal single
  implementation. Rejected for v1: it rewrites four services' validators, with the failure mode
  being a server that stops enforcing a rule — a far worse blast radius than a client that
  over-defers. The parity tests get most of the benefit at a fraction of the risk.
- **Generate Dart type-safe rule literals** instead of embedding the JSON. Rejected: a translation
  step is exactly where drift hides; byte-identical embedding plus a parser that throws on any
  unknown rule kind gives the same fail-closed property with no transformation.
- **Ship the check non-blocking first** (validate, log, push anyway) and enable it once the field
  false-positive rate is known. Rejected because it does not satisfy the AC — the failing edit must
  be surfaced _before_ it is pushed — and because the vocabularies and the patch-changes-any rule,
  which carried nearly all the false-positive risk, are now out of scope entirely.
