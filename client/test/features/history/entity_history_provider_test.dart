import 'dart:async';

import 'package:beekeepingit_client/core/sync/powersync_schema.dart';
import 'package:beekeepingit_client/features/history/history_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// A repository whose local stream and remote fetch are both driven by the
/// test, and which counts remote calls.
///
/// `implements` rather than `extends`: the real class's constructor wants a
/// LocalStoreEngine + ApiClient, neither of which this test needs — the whole
/// point is to exercise [entityHistoryProvider]'s own combining logic in
/// isolation from both the SQL and the network.
class _FakeHistoryRepository implements HistoryRepository {
  _FakeHistoryRepository({
    required this.localController,
    this.remote = const [],
    this.landedAfterFetch = const [],
    this.remoteDelay = Duration.zero,
  });

  final StreamController<List<HistoryEntry>> localController;

  /// What the online fallback resolves to.
  List<HistoryEntry> remote;

  /// What a re-read of the local slice returns *after* the fallback resolves
  /// — i.e. what a sync that landed while the network call was in flight
  /// would have written.
  List<HistoryEntry> landedAfterFetch;

  final Duration remoteDelay;

  int remoteCalls = 0;
  int localReReads = 0;

  @override
  Stream<List<HistoryEntry>> watchLocalTimeline({
    required String entityType,
    required String entityId,
  }) => localController.stream;

  @override
  Future<List<HistoryEntry>> fetchRemoteTimeline({
    required String entityType,
    required String entityId,
  }) async {
    remoteCalls++;
    if (remoteDelay > Duration.zero) await Future.delayed(remoteDelay);
    return remote;
  }

  @override
  Future<List<HistoryEntry>> getLocalTimeline({
    required String entityType,
    required String entityId,
  }) async {
    localReReads++;
    return landedAfterFetch;
  }
}

HistoryEntry _entry(String id) => HistoryEntry(
  id: id,
  entityType: apiaryEntityType,
  entityId: 'a1',
  kind: HistoryEventKind.updated,
  recordedAt: DateTime.utc(2026, 7, 19, 10),
);

const _target = HistoryTarget(entityType: apiaryEntityType, entityId: 'a1');

/// Drives the provider and collects everything it emits.
({ProviderContainer container, List<List<HistoryEntry>> emissions}) _listen(
  _FakeHistoryRepository repo,
) {
  final container = ProviderContainer(
    overrides: [historyRepositoryProvider.overrideWith((ref) async => repo)],
  );
  addTearDown(container.dispose);

  final emissions = <List<HistoryEntry>>[];
  container.listen(entityHistoryProvider(_target), (_, next) {
    final value = next.value;
    if (value != null) emissions.add(value);
  }, fireImmediately: true);

  return (container: container, emissions: emissions);
}

/// Lets the provider's async generator run to quiescence.
Future<void> _settle() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  group('entityHistoryProvider local-first/remote-fallback (#60)', () {
    test('an empty local slice triggers exactly one remote fetch', () async {
      final controller = StreamController<List<HistoryEntry>>();
      addTearDown(controller.close);
      final repo = _FakeHistoryRepository(
        localController: controller,
        remote: [_entry('r1')],
      );
      final h = _listen(repo);

      controller.add(const []);
      await _settle();

      expect(repo.remoteCalls, 1);
      expect(h.emissions.last.map((e) => e.id), ['r1']);
    });

    test('a second empty local emission does NOT re-fetch', () async {
      // The cache-once guard: without it, every local change notification on
      // an entity with no synced history would hit the network again.
      final controller = StreamController<List<HistoryEntry>>();
      addTearDown(controller.close);
      final repo = _FakeHistoryRepository(
        localController: controller,
        remote: [_entry('r1')],
      );
      final h = _listen(repo);

      controller.add(const []);
      await _settle();
      controller.add(const []);
      await _settle();

      expect(repo.remoteCalls, 1, reason: 'remote should be fetched once');
      // The cached remote result is re-yielded rather than dropped to empty.
      expect(h.emissions.last.map((e) => e.id), ['r1']);
    });

    test(
      'local wins as soon as it has rows, and stops using the remote cache',
      () async {
        final controller = StreamController<List<HistoryEntry>>();
        addTearDown(controller.close);
        final repo = _FakeHistoryRepository(
          localController: controller,
          remote: [_entry('remote')],
        );
        final h = _listen(repo);

        controller.add(const []);
        await _settle();
        expect(h.emissions.last.map((e) => e.id), ['remote']);

        controller.add([_entry('local')]);
        await _settle();

        expect(h.emissions.last.map((e) => e.id), ['local']);
        expect(
          repo.remoteCalls,
          1,
          reason: 'a non-empty local never re-fetches',
        );
      },
    );

    test('a sync landing during the fetch beats the remote result', () async {
      // The race `await for` creates: the local subscription is PAUSED while
      // the network call is in flight, so rows that sync mid-fetch are still
      // queued when the (now stale) remote result resolves. Local must win.
      final controller = StreamController<List<HistoryEntry>>();
      addTearDown(controller.close);
      final repo = _FakeHistoryRepository(
        localController: controller,
        remote: const [], // e.g. the fetch failed, or returned nothing
        landedAfterFetch: [_entry('synced-mid-fetch')],
        remoteDelay: const Duration(milliseconds: 10),
      );
      final h = _listen(repo);

      controller.add(const []);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await _settle();

      expect(
        repo.localReReads,
        1,
        reason: 'must re-check local after the fetch',
      );
      expect(h.emissions.last.map((e) => e.id), ['synced-mid-fetch']);
      expect(
        h.emissions.any((e) => e.isEmpty),
        isFalse,
        reason: 'the stale empty remote result must never be shown',
      );
    });

    test(
      'a failed fetch with no local data yields empty, not an error',
      () async {
        // fetchRemoteTimeline swallows API/network errors by design, so an
        // offline device with no slice sees an empty history rather than an
        // error screen.
        final controller = StreamController<List<HistoryEntry>>();
        addTearDown(controller.close);
        final repo = _FakeHistoryRepository(localController: controller);
        final h = _listen(repo);

        controller.add(const []);
        await _settle();

        expect(h.emissions.last, isEmpty);
        expect(
          h.container.read(entityHistoryProvider(_target)).hasError,
          isFalse,
        );
      },
    );
  });
}
