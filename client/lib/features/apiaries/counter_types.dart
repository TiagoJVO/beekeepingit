import '../../l10n/gen/app_localizations.dart';

/// The known apiary-counter types (#256/#346, FR-AP-7, D-20) — the client
/// mirror of the owning service's set (services/apiaries/api/counters.go's
/// knownCounterTypes). Adding a future countable (nucs, queens, ...) is a
/// code-only append: a new const + list entry here and in the Go set, a
/// value-label case in [counterValueLabel] and a name case in
/// [counterTypeLabel] with their EN/PT `.arb` strings, and nothing else — no
/// schema migration, no new sync plumbing, no new screen code (the detail
/// screen renders and edits generically over this list, #346).
const counterTypeHive = 'hive';

/// Supers (Portuguese "alças") — the second known countable (D-20 names
/// "nucs, supers, queens" as examples; supers is the one the Melargil
/// prototype's apiary detail already surfaces). Its presence is what makes
/// the detail screen's generic "add a counter" picker (#346) non-empty:
/// unlike [counterTypeHive] (which always shows), a supers counter appears
/// only once a row exists, so it is offerable in the add picker until then.
const counterTypeSuper = 'super';

/// Ordered as the detail screen renders them: hive first — it ALWAYS
/// displays (0 when no counter row exists, #256 AC); every other known type
/// renders only when a row exists for the apiary.
const knownCounterTypes = [counterTypeHive, counterTypeSuper];

/// The localized display string for one counter's value, or null for a type
/// this client version has no label for (an unknown/newer type replicated
/// down from a newer server — skipped by the detail screen rather than
/// rendered as raw internals; additive row shapes are the sync contract,
/// sync.md §5.1 rule 6, so unknown types must degrade gracefully, not
/// crash or leak identifiers into the UI).
String? counterValueLabel(
  AppLocalizations l10n,
  String counterType,
  int value,
) {
  return switch (counterType) {
    counterTypeHive => l10n.hiveCountValue(value),
    counterTypeSuper => l10n.superCountValue(value),
    _ => null,
  };
}

/// The localized TYPE name of a counter (e.g. "Hives", "Supers") — used by
/// the detail screen's add-counter picker and inline value editor (#346),
/// where the value label ([counterValueLabel]) would be wrong (it embeds the
/// count). Returns null for a type this client version has no name for, so
/// callers filter unknown/newer-server types out of the picker the same way
/// [counterValueLabel] filters them out of the badges.
String? counterTypeLabel(AppLocalizations l10n, String counterType) {
  return switch (counterType) {
    counterTypeHive => l10n.counterTypeHiveLabel,
    counterTypeSuper => l10n.counterTypeSuperLabel,
    _ => null,
  };
}
