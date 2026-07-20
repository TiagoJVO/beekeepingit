import 'package:beekeepingit_client/features/history/history_display.dart';
import 'package:beekeepingit_client/features/history/history_repository.dart';
import 'package:beekeepingit_client/l10n/gen/app_localizations_en.dart';
import 'package:beekeepingit_client/l10n/gen/app_localizations_pt.dart';
import 'package:flutter_test/flutter_test.dart';

final _l10n = AppLocalizationsEn();

HistoryEntry _entry({
  HistoryEventKind kind = HistoryEventKind.updated,
  String? actor,
  List<String> changedFields = const [],
}) => HistoryEntry(
  id: 'h1',
  entityType: 'apiary',
  entityId: 'a1',
  kind: kind,
  recordedAt: DateTime.utc(2026, 7, 18, 10),
  actorUserId: actor,
  changedFields: changedFields,
);

void main() {
  group('historyEventLabel (#60)', () {
    test('labels every known kind', () {
      expect(historyEventLabel(_l10n, HistoryEventKind.created), 'Created');
      expect(historyEventLabel(_l10n, HistoryEventKind.updated), 'Updated');
      expect(historyEventLabel(_l10n, HistoryEventKind.deleted), 'Deleted');
      expect(
        historyEventLabel(_l10n, HistoryEventKind.superseded),
        'Superseded',
      );
    });

    test('falls back to a generic label for an unknown kind', () {
      // D-20's extensible vocabulary: a kind this client version doesn't
      // know must still render as a timeline row.
      expect(historyEventLabel(_l10n, HistoryEventKind.unknown), 'Changed');
    });
  });

  group('historyActorText (#60, FR-HIS-1, history.md §7.3)', () {
    test('"Unknown" when the row carries no actor', () {
      expect(historyActorText(_l10n, null, 'me'), 'Unknown');
      expect(historyActorText(_l10n, '', 'me'), 'Unknown');
    });

    test('"You" when the actor is the signed-in user', () {
      expect(historyActorText(_l10n, 'me', 'me'), 'You');
    });

    test('the roster display name when one is known', () {
      expect(
        historyActorText(
          _l10n,
          'user-1',
          'me',
          memberNames: const {'user-1': 'Ana Silva'},
        ),
        'Ana Silva',
      );
    });

    test('a short id fragment when the roster has no name', () {
      // The offline / pre-first-fetch / removed-member case — distinguishable
      // per actor without inventing a name the app doesn't have.
      expect(
        historyActorText(_l10n, 'abcdef0123456789', 'me'),
        'Member 23456789',
      );
    });

    test('"You" wins over a roster name for the current user', () {
      expect(
        historyActorText(
          _l10n,
          'me',
          'me',
          memberNames: const {'me': 'Ana Silva'},
        ),
        'You',
      );
    });
  });

  group('historyFieldLabel (#60)', () {
    test('localizes the columns the owning services actually audit', () {
      expect(historyFieldLabel(_l10n, 'name'), 'Name');
      expect(historyFieldLabel(_l10n, 'notes'), 'Notes');
      expect(historyFieldLabel(_l10n, 'place_label'), 'Place label');
      expect(historyFieldLabel(_l10n, 'hive_count'), 'Number of hives');
      expect(historyFieldLabel(_l10n, 'location'), 'Location');
      expect(historyFieldLabel(_l10n, 'occurred_at'), 'Date');
      expect(historyFieldLabel(_l10n, 'type'), 'Activity type');
      expect(historyFieldLabel(_l10n, 'attributes'), 'Details');
      expect(historyFieldLabel(_l10n, 'apiary_id'), 'Apiary');
    });

    test('falls through to the raw column name for anything unmapped', () {
      // A newly-audited column reads slightly technical rather than
      // vanishing from the changed-fields line.
      expect(historyFieldLabel(_l10n, 'future_column'), 'future_column');
    });

    test('is translated, not hardcoded English', () {
      expect(
        historyFieldLabel(AppLocalizationsPt(), 'location'),
        'Localização',
      );
    });
  });

  group('historyChangedFieldsText (#60)', () {
    test('lists the changed fields under their localized names', () {
      expect(
        historyChangedFieldsText(
          _l10n,
          _entry(changedFields: const ['name', 'notes']),
        ),
        'Changed: Name, Notes',
      );
    });

    test('null when there is nothing to list', () {
      // create/delete/superseded all write a NULL changed_fields
      // server-side; the caller omits the widget rather than rendering a
      // stray label.
      expect(historyChangedFieldsText(_l10n, _entry()), isNull);
      expect(
        historyChangedFieldsText(_l10n, _entry(kind: HistoryEventKind.created)),
        isNull,
      );
    });
  });

  group('historyDetailText (#60, history.md §6)', () {
    test('explains a superseded entry', () {
      expect(
        historyDetailText(_l10n, _entry(kind: HistoryEventKind.superseded)),
        'Replaced by a newer version from another device',
      );
    });

    test('null for every other kind', () {
      for (final kind in [
        HistoryEventKind.created,
        HistoryEventKind.updated,
        HistoryEventKind.deleted,
        HistoryEventKind.unknown,
      ]) {
        expect(historyDetailText(_l10n, _entry(kind: kind)), isNull);
      }
    });
  });
}
