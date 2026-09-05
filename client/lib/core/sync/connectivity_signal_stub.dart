import 'connectivity_signal.dart';

/// VM/non-web stub — silently never emits, like
/// `core/storage/local_prefs_stub.dart`'s no-op rather than
/// `core/auth/auth_platform_stub.dart`'s throwing one: a missing
/// connectivity hint only costs promptness (the gate still probes and backs
/// off on its own schedule), so no caller should have to special-case this
/// target. Tests that want the behavior drive `SyncGate`'s stream directly.
ConnectivitySignal makeConnectivitySignal() => _StubConnectivitySignal();

class _StubConnectivitySignal implements ConnectivitySignal {
  @override
  Stream<void> get onRestored => const Stream<void>.empty();
}
