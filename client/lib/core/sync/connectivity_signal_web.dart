import 'package:web/web.dart' as web;

import 'connectivity_signal.dart';

/// Web implementation of [ConnectivitySignal] over the browser's `online`
/// event on `window` — fired when the browser transitions back to online
/// (`navigator.onLine` flipping `false` → `true`). `package:web`'s
/// `EventStreamProvider` hands back a broadcast stream and detaches the DOM
/// listener when the subscription is cancelled, so there is nothing extra to
/// own or tear down here.
///
/// Note what this deliberately is **not**: `navigator.onLine` is famously
/// optimistic (it reports "a network interface is up", not "the server is
/// reachable"), which is exactly why it stays a *trigger* for a
/// `ConnectivityProbe` round trip rather than a substitute for one
/// (sync.md §7.1's "connectivity restored is necessary but not sufficient").
ConnectivitySignal makeConnectivitySignal() => _WebConnectivitySignal();

class _WebConnectivitySignal implements ConnectivitySignal {
  @override
  Stream<void> get onRestored =>
      web.EventStreamProviders.onlineEvent.forTarget(web.window);
}
