---
paths: ["client/**/*.dart"]
---

# Rule: Dart conventions (client)

> Extends coding-standards.md for Dart.

`dart format` and the shared `analysis_options.yaml` are enforced by `task dart:lint`; this rule
covers what the analyzer can't catch.

## Null safety

- **Avoid `!`.** Prefer `?.`, `??`, an early-return null guard (which promotes), or a pattern
  `switch`. `!` is acceptable only where null is a programming error and crashing is correct —
  and then say so in a comment.
- **Avoid `late`** unless initialization is provably before first use. Prefer a nullable field or
  constructor initialization.
- Use `required` for constructor parameters that must always be provided.

## Sealed types & exhaustive switch

- Model closed state hierarchies as `sealed class` + `final class` variants, and match them with
  an exhaustive `switch` expression — **no `default`, no wildcard**, so adding a variant becomes a
  compile error instead of a silent fallthrough.
- Prefer that over `if (state is Loading)` chains. For Riverpod's `AsyncValue`, use `when`/`switch`
  and handle `error`/`loading` explicitly — never `.value!`.

## Error handling

- Always type the `on` clause: `on NetworkException catch (e)`. Never bare `catch (e)`.
- Never catch `Error` subtypes — they are bugs, not recoverable conditions.
- Offline is the normal case, not an error path: a failed network call must degrade to the local
  PowerSync store, not surface as an exception to the widget tree.

## Async & `BuildContext`

- `await` every `Future`, or wrap it in `unawaited()` to make fire-and-forget explicit.
- **Check `context.mounted` after any `await` before touching `BuildContext`** (navigation,
  `ScaffoldMessenger`, `Theme.of`). This is the most common crash shape in this client.

## Imports

- `package:` for every external dependency; keep the existing **relative** imports inside
  `client/lib/`. Never import the same file both ways in one package — Dart treats them as two
  libraries and the types stop matching.

## Generated code

- Generated files (`client/lib/l10n/gen/`, `client/lib/core/validation/gen/*.g.dart`) are
  **committed and never hand-edited**. Change the source (the ARB files, or
  `contracts/validation/sync-ops.validation.json`) and re-run its generator
  (`flutter gen-l10n` in `client/`, `scripts/gen-sync-validation.sh`).
- A stale committed generation fails CI — regenerate in the same commit as the source change.

## Widgets

- Business logic lives in providers/services, not widgets; a widget reads state and renders.
- Every user-visible string comes from the ARB files (EN/PT), and every interactive element carries
  a semantics label and a gloves-friendly hit target (WCAG 2.2 AA).
