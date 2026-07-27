import 'package:beekeepingit_client/core/l10n/diacritics.dart';
import 'package:flutter_test/flutter_test.dart';

/// Diacritic-insensitive matching (FR-AP-6, #254 AC: PT "São" matches
/// "sao"). Exercises the pure helpers directly — the apiary search widget
/// tests (apiaries_list_screen_test.dart) cover the same behavior end to end
/// through [filterApiariesByQuery], but the folding logic itself is worth
/// its own focused unit coverage independent of any one caller.
void main() {
  group('stripDiacritics', () {
    test('removes Portuguese accents, leaving case untouched', () {
      expect(stripDiacritics('São'), 'Sao');
      expect(stripDiacritics('Montargil'), 'Montargil');
      expect(stripDiacritics('Alcácer'), 'Alcacer');
      expect(stripDiacritics('Ação'), 'Acao');
    });

    test('covers every diacritic the PT locale actually uses', () {
      expect(stripDiacritics('áàâãä'), 'aaaaa');
      expect(stripDiacritics('éèêë'), 'eeee');
      expect(stripDiacritics('íìîï'), 'iiii');
      expect(stripDiacritics('óòôõö'), 'ooooo');
      expect(stripDiacritics('úùûü'), 'uuuu');
      expect(stripDiacritics('ç'), 'c');
      expect(stripDiacritics('ñ'), 'n');
    });

    test('leaves plain ASCII text unchanged', () {
      expect(stripDiacritics('Encosta Norte'), 'Encosta Norte');
    });

    test('folds a decomposed (NFD) accented character the same as its '
        'precomposed (NFC) form', () {
      // 'a' (U+0061) followed by COMBINING TILDE (U+0303) is the NFD
      // spelling of the same grapheme as the precomposed 'ã' (U+00E3,
      // NFC) used elsewhere in this file. Built via explicit code points
      // (rather than a literal in this source file) so the combining
      // mark's position is unambiguous regardless of editor/encoding.
      // Dart has no built-in NFC/NFD normalizer, and text from other
      // systems (e.g. macOS's filesystem, which normalizes to NFD) can
      // arrive already decomposed — stripDiacritics must fold both
      // spellings to the same result.
      final nfd = String.fromCharCodes(const [
        0x53, // S
        0x61, // a
        0x0303, // COMBINING TILDE
        0x6f, // o
      ]);
      const nfc = 'São'; // precomposed atilde (same grapheme as nfd)
      expect(stripDiacritics(nfd), stripDiacritics(nfc));
      expect(stripDiacritics(nfd), 'Sao');
    });

    test(
      'normalizeForSearch matches an NFD-encoded query against NFC text',
      () {
        final nfdQuery = String.fromCharCodes(const [
          0x73, // s
          0x61, // a
          0x0303, // COMBINING TILDE
          0x6f, // o
        ]);
        expect(normalizeForSearch(nfdQuery), normalizeForSearch('São'));
      },
    );
  });

  group('normalizeForSearch', () {
    test('folds case and diacritics together (#254 AC)', () {
      expect(normalizeForSearch('São Domingos'), 'sao domingos');
      expect(normalizeForSearch('SAO DOMINGOS'), 'sao domingos');
      expect(normalizeForSearch('sao domingos'), 'sao domingos');
    });

    test('two differently-accented spellings normalize identically', () {
      expect(normalizeForSearch('São'), normalizeForSearch('sao'));
      expect(normalizeForSearch('SÃO'), normalizeForSearch('São'));
    });
  });
}
