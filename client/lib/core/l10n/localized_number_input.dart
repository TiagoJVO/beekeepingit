import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart' as intl;
import 'package:intl/number_symbols.dart' show NumberSymbols;

/// Locale-aware NUMERIC INPUT — the typing/parsing counterpart to
/// [LocaleFormatting]'s display formatting (NFR-I18N-1, FR-AC-1, FR-OF-2,
/// C-2, D-12; #623).
///
/// Why this exists: a numeric `TextFormField` filtered with a hard-coded
/// `RegExp(r'[0-9.]')` (or `FilteringTextInputFormatter.digitsOnly`) is an
/// English-only field. With the app in Portuguese — the only in-scope locale
/// (C-2), and the one whose phone keypad offers a comma as its ONLY decimal
/// separator — typing `40,5` into "Mel colhido (kg)" had the comma dropped
/// before validation ever ran, storing **405**: a silent 10x corruption of
/// the app's headline metric, with no error and nothing on screen to notice.
///
/// The rule, in one place so every numeric field shares it:
///
/// * **Nothing is silently dropped.** [formatters] keeps digits AND both
///   `,`/`.` (plus whatever the locale's own separators are), so a
///   mis-typed separator reaches the validator instead of vanishing.
/// * **Parsing is locale-strict.** [parseDouble]/[parseInt] accept the
///   locale's decimal separator, and its grouping separator only in valid
///   3-digit groups. Everything else is `null` — which the caller renders as
///   a visible "invalid value" error. So in Portuguese `40.5` is *rejected*
///   (a lone `5` is not a thousands group) rather than read as 405, and in
///   English `40,5` is rejected for the mirror-image reason.
/// * **Round-trip is exact.** [format] writes a value back into a field in
///   the form [parseDouble]/[parseInt] will read, so loading an activity for
///   editing in Portuguese doesn't produce text its own field rejects.
///
/// Only presentation and input change: the parsed `num` handed on to the
/// repository/wire payload is the same plain JSON number the server's
/// validation expects (D-12 parity — the client rejects, on the same values,
/// what the server would reject).
@immutable
class LocalizedNumberInput {
  const LocalizedNumberInput._(this._localeName);

  final String _localeName;

  /// Reads the active locale off [context] — the same `Localizations` the
  /// generated `AppLocalizations.of(context)` and [LocaleFormatting.of] use.
  factory LocalizedNumberInput.of(BuildContext context) =>
      LocalizedNumberInput._(
        // The FULL tag (`pt-PT`, not `pt`) — #656/D-34, see
        // `LocaleFormatting.of`. It also changes which grouping separator
        // this field accepts: European Portuguese groups thousands with a
        // NON-BREAKING SPACE, where Brazilian `pt` uses a full stop.
        Localizations.localeOf(context).toLanguageTag(),
      );

  /// For tests and non-widget code. Unlike dates, `intl`'s NUMBER symbols are
  /// compiled in, so this needs no `initializeDateFormatting()` first.
  const factory LocalizedNumberInput.forLocale(String localeName) =
      LocalizedNumberInput._;

  NumberSymbols get _symbols =>
      intl.NumberFormat.decimalPattern(_localeName).symbols;

  /// The locale's decimal separator — `,` in pt, `.` in en.
  String get decimalSeparator => _symbols.DECIMAL_SEP;

  /// The locale's thousands/grouping separator — `.` in pt, `,` in en.
  String get groupingSeparator => _symbols.GROUP_SEP;

  /// The input formatters a numeric field should use.
  ///
  /// Deliberately permissive about WHICH separator is typed (see the class
  /// doc): both `,` and `.` are kept, alongside the locale's own separators,
  /// so a wrong one is caught by the validator and shown to the user rather
  /// than being erased mid-keystroke. Letters, signs and spaces are dropped,
  /// exactly as before.
  List<TextInputFormatter> get formatters => [
    FilteringTextInputFormatter.allow(
      RegExp(
        '[0-9${_escaped({decimalSeparator, groupingSeparator, '.', ','})}]',
      ),
    ),
  ];

  static String _escaped(Set<String> characters) =>
      characters.map(RegExp.escape).join();

  /// The value [raw] denotes in this locale, or null when [raw] is blank or
  /// cannot be read as a number here (the caller must then reject it
  /// visibly — never store a "best effort" reading).
  double? parseDouble(String raw) {
    final parts = _split(raw);
    if (parts == null) return null;
    final whole = parts.whole.isEmpty ? '0' : parts.whole;
    final fraction = parts.fraction.isEmpty ? '0' : parts.fraction;
    return double.tryParse('$whole.$fraction');
  }

  /// As [parseDouble], but for a field that only accepts whole numbers.
  ///
  /// A fractional value is `null` (rejected), NOT truncated or rounded: the
  /// pre-#623 `digitsOnly` filter turned a Portuguese `12,5` into `125`, and
  /// quietly answering `12` instead would be the same class of bug.
  int? parseInt(String raw) {
    final parts = _split(raw);
    if (parts == null) return null;
    if (parts.fraction.split('').any((digit) => digit != '0')) return null;
    return int.tryParse(parts.whole.isEmpty ? '0' : parts.whole);
  }

  /// [value] as editable field text in this locale: the locale's decimal
  /// separator, and NO grouping separators (grouping belongs to display
  /// output — see [LocaleFormatting.number] — not to text a user is about to
  /// edit). A whole double loses its trailing `.0`, matching what the form
  /// showed before this class existed.
  String format(num value) {
    if (value is int) return value.toString();
    if (value == value.truncate()) return value.truncate().toString();
    return value.toString().replaceFirst('.', decimalSeparator);
  }

  /// Splits [raw] into its (grouping-free) integer and fraction digits, or
  /// null when it isn't a number in this locale.
  ({String whole, String fraction})? _split(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return null;

    final decimal = decimalSeparator;
    final grouping = groupingSeparator;
    final allowed = RegExp('^[0-9${_escaped({decimal, grouping})}]+\$');
    if (!allowed.hasMatch(text)) return null;

    final sides = text.split(decimal);
    if (sides.length > 2) return null;
    final fraction = sides.length == 2 ? sides[1] : '';
    if (fraction.contains(grouping)) return null;

    final whole = _ungroup(sides[0], grouping);
    if (whole == null) return null;
    if (whole.isEmpty && fraction.isEmpty) return null;
    return (whole: whole, fraction: fraction);
  }

  /// The digits of [value] with valid grouping separators removed, or null
  /// when the grouping is malformed — `1.234` is 1234 in pt, but `40.5` and
  /// `1.2345` are not numbers there at all, and must not be joined into
  /// `405`/`12345` behind the user's back.
  static String? _ungroup(String value, String grouping) {
    if (value.isEmpty) return '';
    if (!value.contains(grouping)) return value;
    final groups = value.split(grouping);
    if (groups.first.isEmpty || groups.first.length > 3) return null;
    for (final group in groups.skip(1)) {
      if (group.length != 3) return null;
    }
    return groups.join();
  }
}
