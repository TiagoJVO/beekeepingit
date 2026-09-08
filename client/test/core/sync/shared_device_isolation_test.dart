import 'package:beekeepingit_client/core/storage/local_prefs.dart';
import 'package:beekeepingit_client/core/sync/local_store.dart';
import 'package:beekeepingit_client/core/sync/local_store_owner.dart';
import 'package:beekeepingit_client/features/todos/todos_repository.dart';
import 'package:flutter_test/flutter_test.dart';

/// #664's fourth acceptance criterion: the shared-device case **with unsynced
/// rows present**.
///
/// Every feature repository filters reads with
/// `WHERE organization_id = ? OR organization_id IS NULL`. The `IS NULL` half
/// is deliberate — a row created offline carries a NULL `organization_id`
/// until write-back stamps it server-side (`TodosRepository`'s own class doc)
/// — and it is also the hole: the PREVIOUS user's locally-created,
/// never-round-tripped rows pass that filter for whoever signs in next, in ANY
/// org. These tests exercise that NULL half specifically, not just the synced
/// path (FR-TEN-1, FR-TEN-2, FR-OF-1, NFR-SEC-1, D-38).

/// An in-memory [LocalStoreEngine] holding `todos` rows, faithfully modelling
/// the one SQL predicate under test: [TodosRepository.watchAll]'s
/// `organization_id = ? OR organization_id IS NULL`. Deliberately narrower
/// than `todos_repository_test.dart`'s own fake (which interprets the write
/// statements too) — the point here is the READ filter and what [clear]
/// leaves behind, so writes are no-ops.
class _FakeStore implements LocalStoreEngine {
  _FakeStore(this.rows);

  final List<Map<String, Object?>> rows;

  /// The SQL of the last [watch], so a test can assert the predicate it is
  /// modelling is the one the repository actually issued - otherwise these
  /// tests would keep passing against a re-implemented filter even if the
  /// real `WHERE` clause changed underneath them.
  String? lastSql;

  /// A single-event stream (not a live one): each test reads `.first` once,
  /// after the purge under test has already settled.
  @override
  Stream<List<Map<String, Object?>>> watch(
    String sql, [
    List<Object?> args = const [],
  ]) {
    lastSql = sql;
    final organizationId = args.isEmpty ? null : args.first;
    return Stream.value(
      rows
          .where(
            (r) =>
                r['organization_id'] == organizationId ||
                r['organization_id'] == null,
          )
          .toList(),
    );
  }

  @override
  Future<Map<String, Object?>?> getOptional(
    String sql, [
    List<Object?> args = const [],
  ]) async => null;

  @override
  Future<List<Map<String, Object?>>> getAll(
    String sql, [
    List<Object?> args = const [],
  ]) async => const [];

  @override
  Future<void> execute(String sql, [List<Object?> args = const []]) async {}

  /// What `PowerSyncLocalStore.clear()` (`disconnectAndClear`) does: every
  /// locally-held row goes, synced or not, along with the upload queue.
  @override
  Future<void> clear() async => rows.clear();
}

/// An in-memory [LocalPrefs] — see `local_store_owner_test.dart`.
class _FakePrefs implements LocalPrefs {
  final Map<String, String> values = {};

  @override
  String? read(String key) => values[key];

  @override
  void write(String key, String value) => values[key] = value;

  @override
  void remove(String key) => values.remove(key);
}

/// One `todos` row carrying exactly the columns [TodosRepository.watchAll]
/// selects, so the real repository parses it unchanged.
Map<String, Object?> _todoRow({
  required String id,
  required String? organizationId,
  required String title,
}) => {
  'id': id,
  'organization_id': organizationId,
  'title': title,
  'description': '',
  'due_date': '',
  'priority': 'medium',
  'status': 'open',
  'completed_at': '',
  'assignee_id': '',
  'apiary_id': '',
};

/// User A's device: one row that has round-tripped through sync (stamped
/// `org-a`) and one written in the field, offline, that never has
/// (`organization_id` NULL) — the actual leak in #664.
List<Map<String, Object?>> _userADeviceRows() => [
  _todoRow(
    id: 'todo-synced',
    organizationId: 'org-a',
    title: 'Requeen hive 12',
  ),
  _todoRow(
    id: 'todo-unsynced',
    organizationId: null,
    title: 'Treat for varroa — written in the field, offline',
  ),
];

void main() {
  group('shared device isolation (#664, D-38)', () {
    test('the hole, stated: without a purge, a DIFFERENT org reads the '
        'previous user\'s unsynced (NULL organization_id) todo', () async {
      final store = _FakeStore(_userADeviceRows());

      final visibleToUserB = await TodosRepository(store)
          .watchAll(organizationId: 'org-b')
          .first;

      expect(
        visibleToUserB.map((t) => t.id),
        ['todo-unsynced'],
        reason:
            'the IS NULL half of the org filter lets user A\'s offline row '
            'through for user B, in a completely different org',
      );
      expect(
        store.lastSql?.replaceAll(RegExp(r'\s+'), ' '),
        contains('organization_id = ? OR organization_id IS NULL'),
        reason:
            'the predicate this test models must be the one the repository '
            'really issues - otherwise a change to the real WHERE clause '
            'would silently stop being covered here',
      );
    });

    test('a different user signing in purges the store, unsynced rows '
        'included (AC 1)', () async {
      final store = _FakeStore(_userADeviceRows());
      final prefs = _FakePrefs()..write(kLocalStoreSubjectKey, 'sub-user-a');
      final repository = TodosRepository(store);

      final purged = await ensureLocalStoreBelongsTo(
        owner: const KnownOwner('sub-user-b'),
        prefs: prefs,
        purge: store.clear,
      );

      expect(purged, isTrue);
      expect(
        await repository.watchAll(organizationId: 'org-b').first,
        isEmpty,
        reason: 'AC 1: user B sees nothing of A\'s, synced or unsynced',
      );
      expect(
        await repository.watchAll(organizationId: 'org-a').first,
        isEmpty,
        reason:
            'nothing survives the purge — the synced row is gone too, and '
            'comes back down the bucket for whoever legitimately owns it',
      );
      expect(prefs.values[kLocalStoreSubjectKey], 'sub-user-b');
    });

    test('the purge also drops the localStorage caches, so user B does not '
        'inherit the previous user profile and organization (AC 1)', () async {
      final store = _FakeStore(_userADeviceRows());
      final prefs = _FakePrefs()
        ..write(kLocalStoreSubjectKey, 'sub-user-a')
        ..write(kProfileCacheKey, '{"name":"User A"}')
        ..write(kOrganizationCacheKey, '{"id":"org-a"}')
        ..write(kNotificationDedupStateKey, '{"hive-12":"notified"}');

      await ensureLocalStoreBelongsTo(
        owner: const KnownOwner('sub-user-b'),
        prefs: prefs,
        purge: () async {
          await store.clear();
          clearPerUserPrefs(prefs);
        },
      );

      expect(
        prefs.values.keys,
        [kLocalStoreSubjectKey],
        reason:
            'only the freshly-stamped marker survives. bk.profile and '
            'bk.organization are read as last-known-good on any failed or '
            'offline post-login fetch, so leaving them would hand user B the '
            'previous identity and, via organizationProvider, the previous '
            'org id - the value every repository read is scoped by',
      );
      expect(prefs.values[kLocalStoreSubjectKey], 'sub-user-b');
    });

    test('the same user signing back in keeps their unsynced offline work '
        '(AC 2)', () async {
      final store = _FakeStore(_userADeviceRows());
      final prefs = _FakePrefs()..write(kLocalStoreSubjectKey, 'sub-user-a');
      final repository = TodosRepository(store);

      final purged = await ensureLocalStoreBelongsTo(
        owner: const KnownOwner('sub-user-a'),
        prefs: prefs,
        purge: store.clear,
      );

      expect(purged, isFalse);
      final stillVisible = await repository
          .watchAll(organizationId: 'org-a')
          .first;
      expect(
        stillVisible.map((t) => t.id),
        containsAll(<String>['todo-synced', 'todo-unsynced']),
        reason:
            'AC 2: a token expiry or browser restart must not destroy work '
            'that has never reached the server',
      );
    });

    test('a boot that resolves logged-out keeps the unsynced work too — the '
        'token-expiry path (AC 2)', () async {
      final store = _FakeStore(_userADeviceRows());
      final prefs = _FakePrefs()..write(kLocalStoreSubjectKey, 'sub-user-a');
      final repository = TodosRepository(store);

      final purged = await ensureLocalStoreBelongsTo(
        owner: const SignedOutOwner(),
        prefs: prefs,
        purge: store.clear,
      );

      expect(purged, isFalse);
      expect(
        (await repository.watchAll(organizationId: 'org-a').first).map(
          (t) => t.id,
        ),
        containsAll(<String>['todo-synced', 'todo-unsynced']),
        reason:
            'a rejected refresh token resolves the boot logged-out; purging '
            'there would drop user A\'s field work before A gets to sign in '
            'again, and the very next sign-in (KnownOwner) re-decides anyway',
      );
    });
  });
}
