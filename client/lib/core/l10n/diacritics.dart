/// Diacritic-insensitive text matching (FR-AP-6, #254: "São" ≈ "sao" in
/// apiary search). Dart's `String` has no built-in Unicode NFD
/// normalization (unlike, say, JS's `String.normalize('NFD')`), and pulling
/// in a full ICU/normalization package for one small helper would be a
/// disproportionate dependency for this app's otherwise deliberately thin
/// dependency footprint (see pubspec.yaml's own font-bundling rationale:
/// "NO runtime font fetching... no CDN" — the same minimal-dependency
/// preference applies here). A direct character-substitution map covering
/// the Latin-script diacritics that occur in Portuguese (the app's other
/// supported locale, NFR-I18N-1) — á/à/â/ã/ä, é/è/ê/ë, í/ì/î/ï, ó/ò/ô/õ/ö,
/// ú/ù/û/ü, ç, ñ — is small, dependency-free, and exactly matches this
/// app's actual i18n scope (EN/PT only); it does not attempt to be a
/// general-purpose Unicode folding routine for scripts this app doesn't
/// support.
const Map<String, String> _diacriticFold = {
  'á': 'a',
  'à': 'a',
  'â': 'a',
  'ã': 'a',
  'ä': 'a',
  'Á': 'A',
  'À': 'A',
  'Â': 'A',
  'Ã': 'A',
  'Ä': 'A',
  'é': 'e',
  'è': 'e',
  'ê': 'e',
  'ë': 'e',
  'É': 'E',
  'È': 'E',
  'Ê': 'E',
  'Ë': 'E',
  'í': 'i',
  'ì': 'i',
  'î': 'i',
  'ï': 'i',
  'Í': 'I',
  'Ì': 'I',
  'Î': 'I',
  'Ï': 'I',
  'ó': 'o',
  'ò': 'o',
  'ô': 'o',
  'õ': 'o',
  'ö': 'o',
  'Ó': 'O',
  'Ò': 'O',
  'Ô': 'O',
  'Õ': 'O',
  'Ö': 'O',
  'ú': 'u',
  'ù': 'u',
  'û': 'u',
  'ü': 'u',
  'Ú': 'U',
  'Ù': 'U',
  'Û': 'U',
  'Ü': 'U',
  'ç': 'c',
  'Ç': 'C',
  'ñ': 'n',
  'Ñ': 'N',
};

/// Strips the diacritics [_diacriticFold] knows about from [value], leaving
/// everything else (case, other characters) untouched — callers combine this
/// with `.toLowerCase()` themselves for a full case+diacritic-insensitive
/// comparison (matching how [normalizeForSearch] below composes it).
String stripDiacritics(String value) {
  final buffer = StringBuffer();
  for (final rune in value.runes) {
    final ch = String.fromCharCode(rune);
    buffer.write(_diacriticFold[ch] ?? ch);
  }
  return buffer.toString();
}

/// The normalized form used for diacritic-insensitive search matching
/// (#254 AC: "case-insensitive and diacritic-insensitive (PT: 'São' matches
/// 'sao')") — lowercase, then diacritics stripped, so both the query and the
/// candidate text are folded into the same comparable form.
String normalizeForSearch(String value) => stripDiacritics(value.toLowerCase());
