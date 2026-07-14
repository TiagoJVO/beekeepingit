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
