import 'package:beekeepingit_client/core/sync/powersync_schema.dart';
import 'package:beekeepingit_client/core/sync/sync_op_draft.dart';
import 'package:beekeepingit_client/features/sync/save_time_validation.dart';
import 'package:beekeepingit_client/l10n/gen/app_localizations.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Unit tests for the form-facing half of the save-time check (#597): the
/// localized copy a form puts against the offending field.
///
/// The copy itself is **not** re-authored here — it is #443's
/// `localizedRejectionMessages` mapping, reused unchanged, so a save-time
/// message and the needs-fix message for the same `(field, code)` pair are the
/// same sentence in both languages.
const _uuid = '018f5f4e-2a3b-7c1d-9e2f-0a1b2c3d4e5f';
const _now = '2026-09-01T10:00:00.000Z';

void main() {
  late AppLocalizations en;
  late AppLocalizations pt;

  setUp(() async {
    en = await AppLocalizations.delegate.load(const Locale('en'));
    pt = await AppLocalizations.delegate.load(const Locale('pt'));
  });

  SyncOpDraft apiaryPut(Map<String, dynamic> data) => SyncOpDraft(
    op: 'put',
    entityType: apiaryEntityType,
    id: _uuid,
    data: data,
    updatedAt: _now,
  );

  test('a valid draft blocks nothing', () {
    final errors = SaveTimeFieldErrors.check(
      apiaryPut({
        'name': 'Montargil',
        'location_lon': -8.16,
        'location_lat': 39.09,
      }),
      columns: const {'name', 'location'},
    );

    expect(errors.isEmpty, isTrue);
    expect(errors.messageFor(en, 'name'), isNull);
  });

  test('reuses the needs-fix copy for the offending field', () {
    final errors = SaveTimeFieldErrors.check(
      apiaryPut({
        'name': 'x' * 201,
        'location_lon': -8.16,
        'location_lat': 39.09,
      }),
      columns: const {'name'},
    );

    expect(errors.isEmpty, isFalse);
    expect(errors.messageFor(en, 'name'), 'Name: this text is too long.');
  });

  test('translates the same failure to Portuguese', () {
    final errors = SaveTimeFieldErrors.check(
      apiaryPut({
        'name': 'x' * 201,
        'location_lon': -8.16,
        'location_lat': 39.09,
      }),
      columns: const {'name'},
    );

    final message = errors.messageFor(pt, 'name')!;
    expect(message, isNot(errors.messageFor(en, 'name')));
    expect(message, isNot(contains('name')));
  });

  test('a pair #443 deliberately has no copy for falls back, never leaks', () {
    // Every field the description names is labelled today (#595 added the last
    // three), but #443 also withholds copy per `(field, code)` PAIR where the
    // generic fragment would misdescribe the constraint — a journey's
    // `default_attributes` is capped in BYTES of encoded JSON, so "this text is
    // too long" would be both untrue and unactionable. That pair still has to
    // produce something truthful and localized rather than silence or a column
    // name, and it is the path a rule added to the description later would take
    // before anyone writes copy for it.
    final errors = SaveTimeFieldErrors.check(
      SyncOpDraft(
        op: 'put',
        entityType: journeyEntityType,
        id: _uuid,
        data: {
          'name': 'Colheita',
          'main_activity_type': 'harvest',
          'default_attributes': {'notes': 'x' * 9000},
        },
        updatedAt: _now,
      ),
      columns: const {'default_attributes'},
    );

    final message = errors.messageFor(en, 'default_attributes')!;
    expect(message, isNot(contains('default_attributes')));
    expect(message, isNot(contains('_')));
    expect(errors.messageFor(pt, 'default_attributes'), isNot(message));
  });

  test('messageForAny takes the first bound column that failed', () {
    final errors = SaveTimeFieldErrors.check(
      apiaryPut({'name': 'Montargil'}),
      columns: const {'location', 'location_lat', 'location_lon'},
    );

    expect(
      errors.messageForAny(en, const ['location', 'location_lat']),
      'Location: this is required.',
    );
    expect(errors.messageForAny(en, const ['name']), isNull);
  });

  test('none() is an empty verdict', () {
    const errors = SaveTimeFieldErrors.none();
    expect(errors.isEmpty, isTrue);
    expect(errors.messageFor(en, 'name'), isNull);
  });
}
