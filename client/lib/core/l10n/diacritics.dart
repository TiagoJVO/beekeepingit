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

/// Unicode "Combining Diacritical Marks" block (U+0300–U+036F). [_diacriticFold]
/// only maps *precomposed* (NFC) accented characters (e.g. U+00E3 'ã' as a
/// single code point) — text that instead arrives already *decomposed*
/// (NFD: a base letter followed by one of these standalone combining
/// marks, e.g. 'a' U+0061 + COMBINING TILDE U+0303) would fold to nothing
/// via that map and silently keep its accent. Dropping any code point in
/// this range as a second pass handles that case without a full NFC/NFD
/// normalization routine (see the file-level doc comment on why this file
/// avoids pulling in a normalization package).
const int _kCombiningMarksStart = 0x0300;
const int _kCombiningMarksEnd = 0x036F;

/// Strips the diacritics [_diacriticFold] knows about from [value], leaving
/// everything else (case, other characters) untouched — callers combine this
/// with `.toLowerCase()` themselves for a full case+diacritic-insensitive
/// comparison (matching how [normalizeForSearch] below composes it).
///
/// Handles both precomposed (NFC) input, via [_diacriticFold], and
/// decomposed (NFD) input, by dropping standalone Unicode combining marks
/// (U+0300–U+036F) left over after the base letter is copied through.
String stripDiacritics(String value) {
  final buffer = StringBuffer();
  for (final rune in value.runes) {
    if (rune >= _kCombiningMarksStart && rune <= _kCombiningMarksEnd) {
      continue;
    }
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
