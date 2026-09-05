import 'package:beekeepingit_client/l10n/gen/app_localizations_en.dart';
import 'package:beekeepingit_client/l10n/gen/app_localizations_pt.dart';
import 'package:flutter_test/flutter_test.dart';

/// ARB-level cover for Home's strings that interpolate a number (#658, D-35,
/// NFR-I18N-1).
///
/// `apiaryVisitRecencyDays` is 30 today, so the all-clear sentence reads
/// correctly by luck. The window is documented as this decision's own
/// adjustable default — the day it becomes 1, an un-pluralized `{days}`
/// renders "the last 1 days" in EN and "os últimos 1 dias" in PT. Pinned
/// here rather than in a widget test because the constant is a `const` the
/// widget layer cannot vary.
void main() {
  group('homeAllClearMessage pluralizes its recency window (#658 review)', () {
    test('English uses the singular day form at 1', () {
      final en = AppLocalizationsEnGb();
      expect(en.homeAllClearMessage(1), isNot(contains('1 days')));
      expect(en.homeAllClearMessage(1), contains('the last day'));
    });

    test('English uses the plural day form above 1', () {
      final en = AppLocalizationsEnGb();
      expect(en.homeAllClearMessage(30), contains('the last 30 days'));
      expect(en.homeAllClearMessage(2), contains('the last 2 days'));
    });

    test('Portuguese follows the same singular/plural split', () {
      final pt = AppLocalizationsPtPt();
      expect(pt.homeAllClearMessage(1), isNot(contains('1 dias')));
      expect(pt.homeAllClearMessage(1), contains('no último dia'));
      expect(pt.homeAllClearMessage(30), contains('nos últimos 30 dias'));
    });
  });
}
