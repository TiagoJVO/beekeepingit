import 'package:beekeepingit_client/core/sync/powersync_schema.dart';
import 'package:beekeepingit_client/core/sync/sync_op_draft.dart';
import 'package:flutter_test/flutter_test.dart';

/// Unit tests for the **save-time** half of validation parity (FR-OF-2, D-12,
/// sync.md §9, #597): [SyncOpDraft] is the one place the wire op's envelope is
/// shaped, so the check a form runs before writing sees exactly the op
/// `powersync_connector.dart` would later push.
///
/// The properties that matter here, in order:
///
///  1. **The two call sites cannot disagree.** The draft is validated through
///     the same [validateSyncOps] evaluator, on the same wire shape.
///  2. **A form can never be made unsaveable.** Only columns the form declares
///     it binds are reported; the wire envelope's own fields, and columns the
///     form doesn't own, are left to the pre-push pass and the server.
const _uuid = '018f5f4e-2a3b-7c1d-9e2f-0a1b2c3d4e5f';
const _now = '2026-09-01T10:00:00.000Z';

void main() {
  group('toWireOp', () {
    test('builds the envelope powersync_connector pushes', () {
      const draft = SyncOpDraft(
        op: 'put',
        entityType: apiaryEntityType,
        id: _uuid,
        data: {'name': 'Montargil'},
        updatedAt: _now,
      );

      expect(draft.toWireOp(), {
        'op': 'put',
        'entity_type': apiaryEntityType,
        'id': _uuid,
        'data': {'name': 'Montargil'},
        'updated_at': _now,
      });
    });
  });

  group('validateColumns', () {
    SyncOpDraft apiaryPut(Map<String, dynamic> data) => SyncOpDraft(
      op: 'put',
      entityType: apiaryEntityType,
      id: _uuid,
      data: data,
      updatedAt: _now,
    );

    test('a valid draft reports nothing', () {
      final errors = apiaryPut({
        'name': 'Montargil',
        'location_lon': -8.16,
        'location_lat': 39.09,
      }).validateColumns(const {'name', 'notes', 'location'});

      expect(errors, isEmpty);
    });

    test('reports a mirrored rule against its own column', () {
      final errors = apiaryPut({
        'name': 'x' * 201,
        'location_lon': -8.16,
        'location_lat': 39.09,
      }).validateColumns(const {'name'});

      expect(errors.keys, ['name']);
      expect(errors['name']!.code, 'too_long');
    });

    test('measures a length cap in UTF-8 bytes, like the server', () {
      // 'ç' is two bytes: 150 of them are 300 bytes, over the 200-byte cap,
      // while being only 150 UTF-16 code units — the exact case a naive
      // client-side `length` check would wave through into a rejection.
      final errors = apiaryPut({
        'name': 'ç' * 150,
        'location_lon': -8.16,
        'location_lat': 39.09,
      }).validateColumns(const {'name'});

      expect(errors['name']!.code, 'too_long');
    });

    test('reports an entity-level rule under the column it names', () {
      // The apiary location rule is reported as `data.location`, a synthetic
      // path with no column of its own — the form binds one control for it.
      final errors = apiaryPut({'name': 'Montargil'})
          .validateColumns(const {'name', 'location'});

      expect(errors.keys, ['location']);
      expect(errors['location']!.code, 'required');
    });

    test('drops a column the form does not bind', () {
      final errors = apiaryPut({
        'name': 'x' * 201,
        'location_lon': -8.16,
        'location_lat': 39.09,
      }).validateColumns(const {'notes'});

      expect(errors, isEmpty);
    });

    test('never reports the wire envelope, which no form can fix', () {
      const draft = SyncOpDraft(
        op: 'put',
        entityType: apiaryEntityType,
        id: 'not-a-uuid',
        data: {
          'name': 'Montargil',
          'location_lon': -8.16,
          'location_lat': 39.09,
        },
        updatedAt: null,
      );

      expect(draft.validateColumns(const {'id', 'updated_at', 'op'}), isEmpty);
    });

    test('a patch is validated as a partial update, not as a full row', () {
      // #378, seen from the form: editing only the notes of an apiary queues a
      // `patch`, where the server does not require `name`. Reporting it here
      // would block a save the server would have accepted.
      final errors = const SyncOpDraft(
        op: 'patch',
        entityType: apiaryEntityType,
        id: _uuid,
        data: {'notes': 'moved the hives'},
        updatedAt: _now,
      ).validateColumns(const {'name', 'notes', 'location'});

      expect(errors, isEmpty);
    });

    test('an unknown entity type defers entirely to the server', () {
      final errors = const SyncOpDraft(
        op: 'put',
        entityType: 'something_newer',
        id: _uuid,
        data: {'name': ''},
        updatedAt: _now,
      ).validateColumns(const {'name'});

      expect(errors, isEmpty);
    });

    test('fails open — an evaluator that throws blocks nothing', () {
      // The property that keeps a defect from making a form unsaveable. Forced
      // through a real path: `default_attributes` is byte-capped, so the
      // evaluator jsonEncodes it, and an object with no JSON encoding makes
      // that throw. `validateSyncOps` swallows it and reports nothing, so the
      // save proceeds and the authoritative server decides.
      final errors = SyncOpDraft(
        op: 'put',
        entityType: journeyEntityType,
        id: _uuid,
        data: {'name': 'x' * 201, 'default_attributes': Object()},
        updatedAt: _now,
      ).validateColumns(const {'name', 'default_attributes'});

      expect(errors, isEmpty);
    });

    test('reports the first failure per column, not one entry per rule', () {
      final errors = const SyncOpDraft(
        op: 'put',
        entityType: todoEntityType,
        id: _uuid,
        data: {'title': '', 'priority': null},
        updatedAt: _now,
      ).validateColumns(const {'title', 'priority'});

      expect(errors.keys.toSet(), {'title', 'priority'});
      expect(errors['title']!.code, 'required');
    });
  });
}
