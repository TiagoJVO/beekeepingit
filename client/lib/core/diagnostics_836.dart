// TEMPORARY diagnostic probe for #836 — removed before the fix lands.
//
// `dart:developer`'s `log()` is a NO-OP under dart2js
// (sdk/lib/_internal/js_runtime/lib/developer_patch.dart:
// `@patch void log(...) { // TODO. }`), so the release web bundle the e2e runs
// against emits nothing at all from `developer.log`. `print()` is what reaches
// `console.log` on web, and therefore Playwright's `page.on("console")`.
library;

import 'dart:async';

/// Monotonic since first use, so every line is comparable within one page.
final Stopwatch _sw = Stopwatch()..start();

/// The last step marked — reprinted by the heartbeat so a wedged thread's last
/// line names the statement it wedged on.
String lastStep = 'none';

/// Marks a step. Printed to the browser console.
void bk836(String step) {
  lastStep = step;
  // ignore: avoid_print
  print('[bk836] t=${_sw.elapsedMilliseconds}ms step=$step');
}

/// Starts a 200ms heartbeat. If the browser's main thread stops executing JS,
/// the heartbeat stops with it (a Dart `Timer` on web is a `setTimeout`), so
/// the last heartbeat line pins the moment the thread went away and names the
/// last step reached. Self-cancels after 90s.
Timer bk836Heartbeat(String tag) {
  var ticks = 0;
  final timer = Timer.periodic(const Duration(milliseconds: 200), (t) {
    ticks++;
    // ignore: avoid_print
    print(
      '[bk836] HEARTBEAT $tag #$ticks t=${_sw.elapsedMilliseconds}ms '
      'last=$lastStep',
    );
    if (ticks >= 450) t.cancel();
  });
  return timer;
}

/// A microtask-level heartbeat: schedules itself again via
/// `scheduleMicrotask`, but only prints every 500th hop. If TIMERS stop while
/// MICROTASKS keep running, the thread is not wedged — it is starved by an
/// unbounded microtask chain (suspect 1). Self-cancels after 90s of wall time.
void bk836MicrotaskProbe(String tag) {
  var hops = 0;
  final start = _sw.elapsedMilliseconds;
  void hop() {
    hops++;
    if (hops % 500 == 0) {
      // ignore: avoid_print
      print(
        '[bk836] MICROTASK $tag hops=$hops t=${_sw.elapsedMilliseconds}ms '
        'last=$lastStep',
      );
    }
    if (_sw.elapsedMilliseconds - start > 90000) return;
    // Re-arm through a Timer, not a microtask: a self-re-arming microtask IS
    // the starvation this probe is trying to detect. One timer hop per 500
    // microtask hops keeps the probe cheap and keeps it observable.
    if (hops % 500 == 0) {
      Timer(const Duration(milliseconds: 50), hop);
    } else {
      scheduleMicrotask(hop);
    }
  }

  scheduleMicrotask(hop);
}
