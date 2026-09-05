import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart' as intl;
import 'package:intl/number_symbols.dart' show NumberSymbols;

import 'supported_locales.dart';

/// Locale-aware NUMERIC INPUT — the typing/parsing counterpart to
/// [LocaleFormatting]'s display formatting (NFR-I18N-1, FR-AC-1, FR-OF-2,
/// C-2, D-12; #623, #657).
///
/// Why this exists: a numeric `TextFormField` filtered with a hard-coded
/// `RegExp(r'[0-9.]')` (or `FilteringTextInputFormatter.digitsOnly`) is an
/// English-only field. With the app in Portuguese — the in-scope market
/// (C-2), and the one whose phone keypad offers a comma as its ONLY decimal
/// separator — typing `40,5` into "Mel colhido (kg)" had the comma dropped
/// before validation ever ran, storing **405**: a silent 10x corruption of
/// the app's headline metric, with no error and nothing on screen to notice.
///
/// The rule, in one place so every numeric field shares it:
///
/// * **Nothing is silently dropped.** [formatters] keeps digits, the locale's
///   own separators, and every character that is a decimal separator in one
///   of the locales this app ships ([kSupportedLocales]) — so a separator
///   from the "other" locale reaches the parser instead of vanishing.
/// * **A separator that cannot mean thousands is the decimal point** (#657).
///   Grouping is *always* exactly three digits; a decimal point takes any
///   number. So `40.5` in Portuguese and `40,5` in English are 40.5 in both:
///   a lone `5` is not a thousands group in any locale, so there is nothing
///   to guess about.
/// * **Where it genuinely could mean thousands, the ACTIVE LOCALE decides.**
///   `1,234` in `en-GB` is 1234, because the comma is that locale's grouping
///   separator and three digits follow it. `1.234` in `pt-PT` is *rejected*:
///   the dot is neither that locale's decimal separator nor its grouping one
///   (European Portuguese groups with a NON-BREAKING SPACE — #656/D-34), so
///   the locale has no tie-breaker and reading it either way would be the
///   guess #623 exists to prevent.
/// * **Anything with no coherent reading is still `null`** — which the caller
///   renders as a visible "invalid value" error that blocks the save. Nothing
///   is ever quietly turned into another number.
/// * **Round-trip is exact.** [format] writes a value back into a field in
///   the form [parseDouble]/[parseInt] will read, so loading an activity for
///   editing in Portuguese doesn't produce text its own field rejects.
///
/// Every one of those rules is expressed against the ACTIVE locale's symbols
/// and the shipped locales' separators, never against literal `.`/`,`: #656
/// moved the app from `pt` to `pt-PT` and changed the grouping character out
/// from under exactly that kind of assumption.
///
/// Only presentation and input change: the parsed `num` handed on to the
/// repository/wire payload is the same plain JSON number the server's
/// validation expects, and the set of *values* a field can produce is
/// unchanged — #657 only widens which TEXT maps onto one (D-12 parity).
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

  /// The locale's thousands/grouping separator — a NON-BREAKING SPACE in
  /// `pt-PT`, `,` in `en-GB` (#656/D-34; generic `pt` used `.`).
  String get groupingSeparator => _symbols.GROUP_SEP;

  /// Every character that is a DECIMAL separator in one of the locales this
  /// app offers ([kSupportedLocales]) — today `{',', '.'}`, from `pt-PT` and
  /// `en-GB`.
  ///
  /// This is "the other locale's decimal separator" in #657, derived rather
  /// than written down: adding a locale extends the set automatically, and a
  /// character no shipped locale uses as a decimal point (a non-breaking
  /// space, say) never becomes one here.
  static final Set<String> _shippedDecimalSeparators = {
    for (final locale in kSupportedLocales)
      intl.NumberFormat.decimalPattern(locale.toLanguageTag())
          .symbols
          .DECIMAL_SEP,
  };

  /// The separator characters [parseDouble]/[parseInt] will even look at:
  /// this locale's own two, plus the shipped decimal separators. Anything
  /// else in the text makes it not-a-number here.
  Set<String> get _acceptedSeparators => {
    decimalSeparator,
    groupingSeparator,
    ..._shippedDecimalSeparators,
  };

  /// The input formatters a numeric field should use.
  ///
  /// Deliberately permissive about WHICH separator is typed (see the class
  /// doc): every separator the parser can reason about is kept, so a wrong
  /// one is caught by the validator and shown to the user rather than being
  /// erased mid-keystroke. Letters, signs and spaces are dropped, exactly as
  /// before.
  List<TextInputFormatter> get formatters => [
    FilteringTextInputFormatter.allow(
      RegExp('[0-9${_escaped(_acceptedSeparators)}]'),
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

    final allowed = RegExp('^[0-9${_escaped(_acceptedSeparators)}]+\$');
    if (!allowed.hasMatch(text)) return null;

    final point = _decimalPointIn(text);
    if (point == null) return null;

    final sides = point.character == null
        ? [text]
        : text.split(point.character!);
    if (sides.length > 2) return null;
    final fraction = sides.length == 2 ? sides[1] : '';
    // Grouping never appears after the decimal point, whichever character is
    // playing which role.
    if (fraction.split('').any(_isSeparator)) return null;

    final whole = _ungroup(sides[0]);
    if (whole == null) return null;
    if (whole.isEmpty && fraction.isEmpty) return null;
    return (whole: whole, fraction: fraction);
  }

  /// Which character in [text] is acting as the decimal point — `null`
  /// *inside* the record when there is none (a whole number), and a `null`
  /// record when [text] has no coherent reading at all and must be rejected.
  ///
  /// This is #657's rule (see the class doc):
  ///
  /// * The locale's own decimal separator always wins where it is present.
  /// * Otherwise a single foreign separator is the decimal point UNLESS the
  ///   text is grouping-shaped (every separator followed by exactly three
  ///   digits, and at most three leading them) — that is the one genuinely
  ///   ambiguous case.
  /// * A grouping-shaped text is thousands only if the character really is
  ///   THIS locale's grouping separator. If it isn't, the locale has no
  ///   reading to offer and we reject rather than pick one.
  ({String? character})? _decimalPointIn(String text) {
    final separators = text.split('').where(_isSeparator).toSet();
    if (separators.isEmpty) return (character: null);
    if (separators.contains(decimalSeparator)) {
      return (character: decimalSeparator);
    }
    if (separators.length > 1) return null;

    final candidate = separators.single;
    if (_isGroupingShaped(text, candidate)) {
      return candidate == groupingSeparator ? (character: null) : null;
    }
    // Not grouping — so it can only be a decimal point, and only if it is
    // one somewhere we ship (a stray non-breaking space is not).
    if (!_shippedDecimalSeparators.contains(candidate)) return null;
    if (candidate.allMatches(text).length > 1) return null;
    return (character: candidate);
  }

  bool _isSeparator(String character) => !_digit.hasMatch(character);

  static final RegExp _digit = RegExp(r'^[0-9]$');

  /// Whether [text] split on [separator] reads as thousands groups.
  static bool _isGroupingShaped(String text, String separator) =>
      _areGroups(text.split(separator));

  /// The digits of [value] with its grouping separators removed, or null when
  /// the grouping is malformed.
  ///
  /// [value] is the integer side, so any separator left in it can only be
  /// grouping — including a foreign one the locale's own decimal separator
  /// has already displaced (`1.234,5` in `pt-PT` is 1234.5). Malformed groups
  /// are null, never joined up behind the user's back.
  static String? _ungroup(String value) {
    if (value.isEmpty) return '';
    final separators = value
        .split('')
        .where((c) => !_digit.hasMatch(c))
        .toSet();
    if (separators.isEmpty) return value;
    if (separators.length > 1) return null;
    final groups = value.split(separators.single);
    if (!_areGroups(groups)) return null;
    return groups.join();
  }

  /// Whether [groups] are well-formed thousands groups: at most three digits
  /// before the first separator, and exactly three after every one of them.
  static bool _areGroups(List<String> groups) {
    if (groups.length < 2) return false;
    if (groups.first.isEmpty || groups.first.length > 3) return false;
    for (final group in groups.skip(1)) {
      if (group.length != 3) return false;
    }
    return true;
  }
}
