import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart' as intl;

/// Locale-aware date/number formatting (NFR-I18N-1, #77 AC: "Dates, times,
/// and numbers render using locale-specific formats... via Flutter `intl`").
///
/// No screen in this slice displays a date or a decimal number yet — the
/// apiary/profile/organization/members/account screens (#23, #32, #58,
/// #196, #197) only show plain strings, counts (ICU plurals, already
/// exercised) and lat/lon coordinates as raw text. Rather than wiring
/// locale-aware formatting into UI that doesn't exist, this small helper
/// wraps `intl`'s `DateFormat`/`NumberFormat` keyed to the active
/// `BuildContext` locale so the *first* real feature that needs to render a
/// date or a decimal (e.g. an activity timestamp, a harvest weight in kg)
/// can call it directly instead of re-deriving the pattern. See
/// `LocaleFormatting` tests for EN vs. PT output (`test/core/l10n/
/// locale_formatting_test.dart`).
///
/// Kept deliberately thin: numbers simply follow the active locale's
/// conventions, which is what NFR-I18N-1 asks for (`pt-PT`'s `,` decimal
/// separator and non-breaking-space grouping vs. `en-GB`'s `.` and `,`).
///
/// Dates are the ONE deliberate exception — the app pins a named-month
/// pattern for both locales rather than taking each locale's default. See
/// [LocaleFormatting._datePattern] for the reasoning (D-34, #656).
class LocaleFormatting {
  const LocaleFormatting._(this._localeName);

  final String _localeName;

  /// Reads the active locale off [context] (the same `Localizations` the
  /// generated `AppLocalizations.of(context)` uses), so callers don't have
  /// to thread a `Locale` through separately.
  factory LocaleFormatting.of(BuildContext context) {
    final locale = Localizations.localeOf(context);
    // The FULL tag (`pt-PT`, not `pt`) — #656/D-34. `languageCode` alone
    // threw the country away, so every date and number in the app came out
    // with Brazilian/American conventions no matter which locale the tree
    // had resolved to.
    return LocaleFormatting._(locale.toLanguageTag());
  }

  /// For tests/non-widget code where a `BuildContext` isn't available.
  ///
  /// Note: [date]/[dateTime] need `intl`'s locale date-symbol data loaded
  /// first. [LocaleFormatting.of] gets this for free — Flutter's
  /// `GlobalMaterialLocalizations` delegate (already in this app's
  /// `localizationsDelegates`) initializes it for every supported locale on
  /// app start. A caller using this constructor outside a widget tree (e.g.
  /// a background isolate, or a plain `test()` — see
  /// `locale_formatting_test.dart`) must call `initializeDateFormatting()`
  /// from `package:intl/date_symbol_data_local.dart` first, or a non-English
  /// [date]/[dateTime] call throws.
  const factory LocaleFormatting.forLocale(String localeName) =
      LocaleFormatting._;

  /// The date pattern this app pins for BOTH locales: day, abbreviated
  /// MONTH NAME, year — `3 Sept 2026` (en-GB) / `3 set. 2026` (pt-PT).
  ///
  /// **This deliberately overrides the locale's own medium-date default**
  /// (D-34, #656), the one place in this file that does not simply defer to
  /// CLDR. `DateFormat.yMMMd` for `pt-PT` is CLDR's numeric `d/MM/y`, which
  /// renders `3/09/2026` — and on a field app read one-handed in gloves, a
  /// wholly numeric date is the one format a reader can genuinely get wrong:
  /// `3/09` and `09/03` are the same six characters in a different order,
  /// while `3 set.` cannot be misread as March. Readability of a date a
  /// beekeeper acts on beats matching the locale's default here. (Product
  /// owner, 2026-09-03; recorded in D-34.)
  ///
  /// The month NAME is still fully localized — `Sept` vs `set.`, including
  /// European Portuguese's trailing dot — because only the pattern is
  /// pinned, not the symbols. What the pattern also fixes is the field
  /// ORDER (day first), which is correct for both locales the app ships;
  /// adding a locale that orders differently (e.g. `ja`) means revisiting
  /// this, not silently inheriting it.
  static const _datePattern = 'd MMM y';

  /// A localized date with a named month, e.g. `3 Sept 2026` (en-GB) /
  /// `3 set. 2026` (pt-PT). See [_datePattern] for why the pattern is
  /// pinned rather than taken from the locale.
  String date(DateTime value) =>
      intl.DateFormat(_datePattern, _localeName).format(value);

  /// [date] plus a 24-hour time, e.g. `3 Sept 2026 15:04` (en-GB) /
  /// `3 set. 2026 15:04` (pt-PT).
  ///
  /// Built on the same pinned pattern, so a date and a date-with-time can
  /// never disagree about how the month is written. `add_Hm()` is the
  /// skeleton for "hour of day (0-23) : minute", so both locales render the
  /// same 24h clock rather than switching to a 12h AM/PM convention.
  String dateTime(DateTime value) =>
      intl.DateFormat(_datePattern, _localeName).add_Hm().format(value);

  /// A number rendered with the locale's grouping/decimal separators and
  /// only as many fraction digits as the value actually has (#624,
  /// NFR-I18N-1): `62,5` / `999.999.999` in pt, `62.5` / `999,999,999` in
  /// en.
  ///
  /// Use this — not `toString()` — for any number that came from stored
  /// data and whose scale isn't known up front (an activity's `honey_kg`,
  /// `honey_supers`, `hives_involved`, `feed_amount`). [decimal] is the
  /// right call instead when a stat tile wants a FIXED number of decimals
  /// regardless of the value (the journey statistics card's `0,0 kg`).
  ///
  /// The counterpart for numbers the user TYPES is
  /// `LocalizedNumberInput` (localized_number_input.dart) — this one groups
  /// thousands, which is correct for display and wrong for an editable
  /// field.
  String number(num value) =>
      intl.NumberFormat.decimalPattern(_localeName).format(value);

  /// A plain decimal number using the locale's grouping/decimal separators
  /// (e.g. PT's `1.234,5` vs. EN's `1,234.5`).
  String decimal(num value, {int decimalDigits = 1}) =>
      intl.NumberFormat.decimalPatternDigits(
        locale: _localeName,
        decimalDigits: decimalDigits,
      ).format(value);
}
