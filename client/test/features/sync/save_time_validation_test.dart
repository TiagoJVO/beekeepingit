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

  test('never renders a column name for a field #443 has no label for', () {
    // `dgav_registration_number` is one of the labels #443 closed without
    // (#600 adds them). Until it lands, the field still gets a truthful,
    // localized, non-technical line rather than a leaked column name.
    final errors = SaveTimeFieldErrors.check(
      apiaryPut({
        'name': 'Montargil',
        'dgav_registration_number': 'x' * 51,
        'location_lon': -8.16,
        'location_lat': 39.09,
      }),
      columns: const {'dgav_registration_number'},
    );

    final message = errors.messageFor(en, 'dgav_registration_number')!;
    expect(message, isNot(contains('dgav')));
    expect(message, isNot(contains('_')));
    expect(errors.messageFor(pt, 'dgav_registration_number'), isNot(message));
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
