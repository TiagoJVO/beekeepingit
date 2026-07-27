import 'package:beekeepingit_client/features/todos/todo_priority.dart';
import 'package:beekeepingit_client/l10n/gen/app_localizations_en.dart';
import 'package:flutter_test/flutter_test.dart';

final _l10n = AppLocalizationsEn();

void main() {
  group('knownTodoPriorities (#50/#53, D-20)', () {
    test('is ordered low -> medium -> high, mirroring the server registry '
        '(services/todos/api/types.go)', () {
      expect(knownTodoPriorities, [
        todoPriorityLow,
        todoPriorityMedium,
        todoPriorityHigh,
      ]);
    });
  });

  group('todoPriorityLabel (#53)', () {
    test('returns the localized label for each known priority', () {
      expect(todoPriorityLabel(_l10n, todoPriorityLow), 'Low');
      expect(todoPriorityLabel(_l10n, todoPriorityMedium), 'Medium');
      expect(todoPriorityLabel(_l10n, todoPriorityHigh), 'High');
    });

    test('returns null for a priority this client version does not know '
        '(graceful degradation, mirrors activityTypeLabel)', () {
      expect(todoPriorityLabel(_l10n, 'urgent'), isNull);
    });
  });

  group('todoPriorityRank (#53 AC: sortable by priority level)', () {
    test('ranks high above medium above low', () {
      expect(
        todoPriorityRank(todoPriorityHigh),
        greaterThan(todoPriorityRank(todoPriorityMedium)),
      );
      expect(
        todoPriorityRank(todoPriorityMedium),
        greaterThan(todoPriorityRank(todoPriorityLow)),
      );
    });

    test('ranks an unknown priority below every known level, so a sort never '
        'crashes on unrecognized data', () {
      expect(
        todoPriorityRank('urgent'),
        lessThan(todoPriorityRank(todoPriorityLow)),
      );
    });
  });
}
