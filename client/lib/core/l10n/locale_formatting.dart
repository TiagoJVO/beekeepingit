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
/// Kept deliberately thin: it does not invent a display format policy beyond
/// "use the device/app locale's conventions", which is what NFR-I18N-1
/// asks for (e.g. PT's `dd/MM/yyyy` and `,` decimal separator vs. EN's
/// `M/d/yyyy` and `.` decimal separator).
class LocaleFormatting {
  const LocaleFormatting._(this._localeName);

  final String _localeName;

  /// Reads the active locale off [context] (the same `Localizations` the
  /// generated `AppLocalizations.of(context)` uses), so callers don't have
  /// to thread a `Locale` through separately.
  factory LocaleFormatting.of(BuildContext context) {
    final locale = Localizations.localeOf(context);
    return LocaleFormatting._(locale.languageCode);
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

  /// A medium-length localized date, e.g. `Jul 12, 2026` (en) / `12 de jul.
  /// de 2026` (pt).
  String date(DateTime value) =>
      intl.DateFormat.yMMMd(_localeName).format(value);

  /// A localized date + 24-hour time, e.g. `Jul 12, 2026 15:04` (en) / `12
  /// de jul. de 2026 15:04` (pt) — `add_Hm()` is the skeleton for "hour of
  /// day (0-23) : minute", so both locales render the same 24h clock rather
  /// than switching to a 12h AM/PM convention.
  String dateTime(DateTime value) =>
      intl.DateFormat.yMMMd(_localeName).add_Hm().format(value);

  /// A plain decimal number using the locale's grouping/decimal separators
  /// (e.g. PT's `1.234,5` vs. EN's `1,234.5`).
  String decimal(num value, {int decimalDigits = 1}) =>
      intl.NumberFormat.decimalPatternDigits(
        locale: _localeName,
        decimalDigits: decimalDigits,
      ).format(value);
}
