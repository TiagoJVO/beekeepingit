import 'package:flutter/widgets.dart';

/// The locales this app actually ships, and the one place a stored locale
/// code is turned into one of them (D-34, NFR-I18N-1, C-2; #656).
///
/// **Why the country code is load-bearing.** `pt` and `en` are not neutral:
/// `intl`/CLDR resolve them to *Brazilian* and *American* conventions. The
/// app shipped them, so it rendered `Sep 3, 2026` (American ordering) to a
/// British reader and `1.234,5` (Brazilian grouping) to a Portuguese one —
/// for both of its intended audiences, the wrong conventions. D-34 settles
/// the supported set as **European Portuguese** and **British English**, so
/// every locale identifier in the app is country-qualified from here on.
///
/// Deliberately NOT `AppLocalizations.supportedLocales`: `flutter gen-l10n`
/// requires a base-language ARB behind each region variant, so the generated
/// list also carries the generic `en`/`pt` those base files describe. Handing
/// that list to `MaterialApp` would let a device set to `pt-BR` resolve to
/// generic `pt` and get Brazilian formatting back — exactly what #656 is
/// about. [kSupportedLocales] is the offered set; the generated delegate is
/// free to be able to load more than we offer.
const List<Locale> kSupportedLocales = <Locale>[
  Locale('en', 'GB'),
  Locale('pt', 'PT'),
];

/// The locale a caller gets when nothing is stored and nothing is resolvable
/// — the first of [kSupportedLocales], matching Flutter's own "fall back to
/// the head of the supported list" rule.
const Locale kDefaultLocale = Locale('en', 'GB');

/// [kDefaultLocale] as a stored profile value. Spelled out so it can be used
/// in `const` contexts (the language picker's items); a test pins it to
/// `kDefaultLocale.toLanguageTag()` so the two cannot drift.
const String kDefaultLocaleTag = 'en-GB';

/// The European Portuguese tag, as stored on a profile.
const String kPortugueseLocaleTag = 'pt-PT';

/// The supported BCP 47 tag [stored] means, or null if it means none of
/// them.
///
/// This is the whole of #656's migration story, and it runs on read rather
/// than as a one-shot rewrite, so it holds for values written by an older
/// client too:
///
/// * `pt-PT` / `en-GB` — already canonical.
/// * `pt` / `en` — what every profile written before #656 stores. Mapped to
///   the country variant of the same language, so an existing user keeps the
///   language they chose and gains the right conventions.
/// * `pt_PT`, `en-gb`, … — separator/case variants are canonicalized rather
///   than rejected.
/// * `pt-BR` / `en-US` — a supported *language* in an unsupported region maps
///   to the region we ship. Portugal is the only in-scope market (C-2), and
///   answering "Portuguese" with European Portuguese is strictly better than
///   the alternative of no match at all.
/// * anything else (`fr`, `xx`, blank) — null. The caller then falls back to
///   the device locale; it must never be persisted or displayed as a choice.
String? canonicalLocaleTag(String? stored) {
  final raw = stored?.trim();
  if (raw == null || raw.isEmpty) return null;
  final language = raw.replaceAll('_', '-').split('-').first.toLowerCase();
  for (final locale in kSupportedLocales) {
    if (locale.languageCode == language) return locale.toLanguageTag();
  }
  return null;
}

/// The locale to carry on a `Profile` read off the wire (or out of the
/// offline cache) — #656's migration at the point every stored value enters
/// the app.
///
/// A legacy `pt`/`en` becomes `pt-PT`/`en-GB` here, so the language picker
/// shows the right option and the next save writes the canonical tag back to
/// the server. Blank/absent takes [kDefaultLocaleTag] (as `?? 'en'` did
/// before). A value that is neither — some future or foreign tag — is passed
/// through UNCHANGED rather than being coerced: [localeProvider] then
/// resolves it to null and the app follows the device locale, which is the
/// honest answer for a language we do not ship.
String readProfileLocale(String? stored) {
  final raw = stored?.trim() ?? '';
  if (raw.isEmpty) return kDefaultLocaleTag;
  return canonicalLocaleTag(raw) ?? raw;
}

/// The supported [Locale] [stored] means, or null (→ device locale).
Locale? supportedLocaleFor(String? stored) {
  final tag = canonicalLocaleTag(stored);
  if (tag == null) return null;
  for (final locale in kSupportedLocales) {
    if (locale.toLanguageTag() == tag) return locale;
  }
  return null;
}
