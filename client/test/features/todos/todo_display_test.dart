import 'package:beekeepingit_client/features/apiaries/apiaries_repository.dart';
import 'package:beekeepingit_client/features/todos/todo_display.dart';
import 'package:beekeepingit_client/l10n/gen/app_localizations_en.dart';
import 'package:flutter_test/flutter_test.dart';

final _l10n = AppLocalizationsEn();

/// Invisible codepoints, written by code point on purpose (#582): spelled
/// literally they are unreviewable in a diff, and an editor or a formatter
/// could silently drop them.
final _rlo = String.fromCharCode(0x202E); // right-to-left OVERRIDE
final _zwsp = String.fromCharCode(0x200B); // zero-width space
final _nbsp = String.fromCharCode(0x00A0); // no-break space

void main() {
  group('todoAssigneeLabel (#293, mirrors activityAttributionText)', () {
    test('null assigneeId renders as Unassigned', () {
      expect(todoAssigneeLabel(_l10n, null, const {}), 'Unassigned');
    });

    test('empty assigneeId renders as Unassigned', () {
      expect(todoAssigneeLabel(_l10n, '', const {}), 'Unassigned');
    });

    test('a known assigneeId resolves to the member\'s real name', () {
      expect(
        todoAssigneeLabel(_l10n, 'user-1', const {'user-1': 'Maria Silva'}),
        'Maria Silva',
      );
    });

    test('an unknown assigneeId (not yet in the roster, offline/pre-fetch) '
        'falls back to a short id fragment', () {
      expect(
        todoAssigneeLabel(_l10n, 'abcdefgh12345678', const {}),
        'Member 12345678',
      );
    });

    test('a blank name in the roster still falls back to the short id', () {
      expect(
        todoAssigneeLabel(_l10n, 'abcdefgh12345678', const {
          'abcdefgh12345678': '',
        }),
        'Member 12345678',
      );
    });

    // #582 (NFR-SEC-1): the roster name is authored outside this app, so it
    // goes through `sanitizedMemberName` rather than being rendered verbatim.
    // The rules themselves are covered in member_display_test.dart; these two
    // pin that THIS caller is wired to them.
    // Invisible codepoints written as escapes on purpose: spelled literally
    // they are unreviewable in a diff, and an editor could silently drop them.
    test('a name carrying a bidi override renders sanitized', () {
      expect(
        todoAssigneeLabel(_l10n, 'user-1', {'user-1': '${_rlo}Ana Silva'}),
        'Ana Silva',
      );
    });

    test('a name with nothing readable left falls back to the short id', () {
      expect(
        todoAssigneeLabel(_l10n, 'abcdefgh12345678', {
          'abcdefgh12345678': '$_nbsp$_zwsp',
        }),
        'Member 12345678',
      );
    });
  });

  group('todoApiaryLabel (#293)', () {
    const apiaries = [
      Apiary(id: 'a1', name: 'Serra Norte', hiveCount: 3),
      Apiary(id: 'a2', name: 'Monte Alto', hiveCount: 5),
    ];

    test('null apiaryId renders as No apiary (a general, org-level todo)', () {
      expect(todoApiaryLabel(_l10n, null, apiaries), 'No apiary');
    });

    test('empty apiaryId renders as No apiary', () {
      expect(todoApiaryLabel(_l10n, '', apiaries), 'No apiary');
    });

    test('a known apiaryId resolves to the apiary\'s name', () {
      expect(todoApiaryLabel(_l10n, 'a2', apiaries), 'Monte Alto');
    });

    test('an apiaryId not found in the locally-synced set (stale/deleted) '
        'falls back to Unknown apiary', () {
      expect(todoApiaryLabel(_l10n, 'gone', apiaries), 'Unknown apiary');
    });
  });
}
