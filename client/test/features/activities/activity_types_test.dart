import 'package:beekeepingit_client/features/activities/activity_types.dart';
import 'package:beekeepingit_client/l10n/gen/app_localizations_en.dart';
import 'package:beekeepingit_client/l10n/gen/app_localizations_pt.dart';
import 'package:flutter_test/flutter_test.dart';

/// Render-time localization of the controlled attribute vocabularies (#625,
/// NFR-I18N-1, FR-AC-1, D-19).
///
/// The stored/wire values stay the historical Portuguese strings
/// (services/activities/api/types.go is the contract) — these tests pin BOTH
/// halves of that: the stored vocabulary never changes, and every stored value
/// resolves to a language-appropriate display label.
void main() {
  final en = AppLocalizationsEn();
  final pt = AppLocalizationsPt();

  group('stored vocabularies are the stable wire values (#625)', () {
    // If one of these ever needs to change, it is a CONTRACT change: the Go
    // set (services/activities/api/types.go) and already-stored rows move
    // together. Localization alone must never touch them.
    test('diseaseConditions is unchanged', () {
      expect(diseaseConditions, [
        'Varroose',
        'Loque americana',
        'Loque europeia',
        'Nosemose',
        'Acariose',
        'Aethina tumida (pequeno besouro da colmeia)',
        'Tropilaelaps spp.',
        'Outro',
      ]);
    });

    test('treatmentTypes is unchanged', () {
      expect(treatmentTypes, [
        'Apivar/amitraz',
        'Ácido oxálico',
        'Timol',
        'Outro',
      ]);
    });

    test('feedTypes is unchanged', () {
      expect(feedTypes, ['Xarope 1:1', 'Xarope 2:1', 'Candi', 'Pólen']);
    });
  });

  group('diseaseConditionLabel (#625)', () {
    test(
      'English renders English disease names, not the stored Portuguese',
      () {
        expect(diseaseConditionLabel(en, 'Varroose'), 'Varroosis');
        expect(
          diseaseConditionLabel(en, 'Loque americana'),
          'American foulbrood',
        );
        expect(
          diseaseConditionLabel(en, 'Loque europeia'),
          'European foulbrood',
        );
        expect(diseaseConditionLabel(en, 'Nosemose'), 'Nosemosis');
        expect(diseaseConditionLabel(en, 'Acariose'), 'Acarapisosis');
        expect(diseaseConditionLabel(en, 'Outro'), 'Other');
      },
    );

    test('Latin names stay Latin in both languages', () {
      expect(
        diseaseConditionLabel(en, 'Tropilaelaps spp.'),
        'Tropilaelaps spp.',
      );
      expect(
        diseaseConditionLabel(pt, 'Tropilaelaps spp.'),
        'Tropilaelaps spp.',
      );
      expect(
        diseaseConditionLabel(
          en,
          'Aethina tumida (pequeno besouro da colmeia)',
        ),
        'Aethina tumida (small hive beetle)',
      );
      expect(
        diseaseConditionLabel(
          pt,
          'Aethina tumida (pequeno besouro da colmeia)',
        ),
        'Aethina tumida (pequeno besouro da colmeia)',
      );
    });

    test('Portuguese still renders exactly the stored Portuguese value', () {
      for (final stored in diseaseConditions) {
        expect(diseaseConditionLabel(pt, stored), stored);
      }
    });

    test('every stored value has an English label distinct from a raw echo '
        'where the languages genuinely differ', () {
      for (final stored in diseaseConditions) {
        expect(diseaseConditionLabel(en, stored), isNotEmpty);
      }
      // Only the two Latin names legitimately echo the stored string.
      final echoed = diseaseConditions
          .where((v) => diseaseConditionLabel(en, v) == v)
          .toList();
      expect(echoed, ['Tropilaelaps spp.']);
    });

    test('an unknown/legacy stored value falls back to the raw value', () {
      // A `disease` captured while the attribute was still free text, or
      // replicated down from a newer server with a wider vocabulary — show
      // what is stored rather than a blank cell or a lookup key.
      expect(
        diseaseConditionLabel(en, 'Alguma outra doença'),
        'Alguma outra doença',
      );
      expect(
        diseaseConditionLabel(pt, 'Alguma outra doença'),
        'Alguma outra doença',
      );
      expect(diseaseConditionLabel(en, ''), '');
    });
  });

  group('treatmentTypeLabel (#625)', () {
    test('English renders English product names', () {
      expect(treatmentTypeLabel(en, 'Ácido oxálico'), 'Oxalic acid');
      expect(treatmentTypeLabel(en, 'Timol'), 'Thymol');
      expect(treatmentTypeLabel(en, 'Outro'), 'Other');
      // Brand + active substance — the same in both languages.
      expect(treatmentTypeLabel(en, 'Apivar/amitraz'), 'Apivar/amitraz');
    });

    test('Portuguese still renders exactly the stored Portuguese value', () {
      for (final stored in treatmentTypes) {
        expect(treatmentTypeLabel(pt, stored), stored);
      }
    });

    test('an unknown/legacy stored value falls back to the raw value', () {
      expect(treatmentTypeLabel(en, 'Apitraz'), 'Apitraz');
    });
  });

  group('feedTypeLabel (#625)', () {
    test('English renders English feed names', () {
      expect(feedTypeLabel(en, 'Xarope 1:1'), '1:1 syrup');
      expect(feedTypeLabel(en, 'Xarope 2:1'), '2:1 syrup');
      expect(feedTypeLabel(en, 'Pólen'), 'Pollen');
      expect(feedTypeLabel(en, 'Candi'), 'Candi (fondant)');
    });

    test('Portuguese still renders exactly the stored Portuguese value', () {
      for (final stored in feedTypes) {
        expect(feedTypeLabel(pt, stored), stored);
      }
    });

    test('an unknown/legacy stored value falls back to the raw value', () {
      expect(feedTypeLabel(en, 'Xarope 3:2'), 'Xarope 3:2');
    });
  });
}
