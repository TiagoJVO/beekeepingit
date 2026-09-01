import 'connectivity_signal_stub.dart'
    if (dart.library.js_interop) 'connectivity_signal_web.dart';

/// The device's own "connectivity just came back" notification — the cheap,
/// platform-provided *hint* that complements `ConnectivityProbe`'s measured
/// verdict (FR-OF-3, sync.md §7.1). It says a link exists again, never that
/// the link is good enough: `SyncGate` still decides that with a probe.
///
/// Its one job is to make the gate re-probe **promptly** after a reconnect
/// (#240). Without it, a failed probe's exponential backoff (up to ~2 min)
/// runs to completion no matter what the radio does in the meantime, so a
/// write queued offline could sit unflushed long after the device was back
/// online unless the user tapped "sync now".
///
/// Mirrors `core/storage/local_prefs.dart`'s stub/web conditional-import
/// split, which keeps `package:web` out of VM-run widget/unit tests.
abstract interface class ConnectivitySignal {
  /// Emits once per connectivity-**return** transition (the browser `online`
  /// event on web). Broadcast, and carries no payload — the event is the
  /// whole signal.
  Stream<void> get onRestored;
}

/// Constructs the platform implementation for the current target.
ConnectivitySignal createConnectivitySignal() => makeConnectivitySignal();
