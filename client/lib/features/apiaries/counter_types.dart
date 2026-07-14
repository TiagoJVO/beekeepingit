import '../../l10n/gen/app_localizations.dart';

/// The known apiary-counter types (#256, FR-AP-7) — the client mirror of the
/// owning service's set (services/apiaries/api/counters.go's
/// knownCounterTypes). Adding a future countable (nucs, supers, queens, ...)
/// is a code-only append: a new const + list entry here and in the Go set, a
/// label case in [counterValueLabel] with its EN/PT `.arb` strings, and
/// nothing else — no schema migration, no new sync plumbing, no new screen
/// code (the detail screen renders generically over this list).
const counterTypeHive = 'hive';

/// Ordered as the detail screen renders them: hive first — it ALWAYS
/// displays (0 when no counter row exists, #256 AC); every other known type
/// renders only when a row exists for the apiary.
const knownCounterTypes = [counterTypeHive];

/// The localized display string for one counter's value, or null for a type
/// this client version has no label for (an unknown/newer type replicated
/// down from a newer server — skipped by the detail screen rather than
/// rendered as raw internals; additive row shapes are the sync contract,
/// sync.md §5.1 rule 6, so unknown types must degrade gracefully, not
/// crash or leak identifiers into the UI).
String? counterValueLabel(AppLocalizations l10n, String counterType, int value) {
  return switch (counterType) {
    counterTypeHive => l10n.hiveCountValue(value),
    _ => null,
  };
}
