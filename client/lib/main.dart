import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';

void main() {
  configureGlobalErrorHandlers();
  runApp(
    ProviderScope(
      observers: [AppProviderObserver()],
      child: const BeekeepingitApp(),
    ),
  );
}

/// Minimal global error capture (MEDIUM-4): no dedicated crash-reporting
/// backend/telemetry pipeline is wired for the client yet — `NFR-OBS-1`
/// (requirements/non-functional-requirements.md) covers the *server-side*
/// OTel → Loki/Tempo/Grafana stack (docs/architecture/platform.md §…), and
/// nothing in `requirements/` defers a client-side equivalent, so rather than
/// leave framework/async errors entirely uncaptured (or half-wire a real
/// reporting SDK this task isn't scoped to add), this wires the cheapest
/// correct thing: `dart:developer` logging so errors are at least visible
/// (DevTools / `flutter logs`) instead of silently lost to the default
/// zone/console printer.
///
/// [releaseMode] is a seam for tests — production always uses [kReleaseMode].
@visibleForTesting
void configureGlobalErrorHandlers({bool releaseMode = kReleaseMode}) {
  // Chain to whatever was previously registered (Flutter's own binding sets
  // this to `FlutterError.presentError` by default) rather than clobbering
  // it — the framework's own red-screen-of-death / console dump still runs,
  // this just additionally logs.
  final previousOnError = FlutterError.onError;
  FlutterError.onError = (FlutterErrorDetails details) {
    developer.log(
      'FlutterError: ${details.exceptionAsString()}',
      name: 'app',
      error: details.exception,
      stackTrace: details.stack,
    );
    (previousOnError ?? FlutterError.presentError)(details);
  };

  // Uncaught errors *outside* the Flutter widget error boundary — e.g. an
  // unhandled Future rejection (the exact shape of bug HIGH-2 fixed for
  // login()) — otherwise fall through to the platform's default zone error
  // handling with no application-level visibility at all.
  PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    developer.log(
      'Uncaught async error',
      name: 'app',
      error: error,
      stackTrace: stack,
    );
    return true; // handled — don't crash the isolate.
  };

  if (releaseMode) {
    // The default ErrorWidget renders the raw exception/stack trace, which
    // is useful in debug but not something a beekeeper in the field should
    // ever see. A release build shows a plain, translated-later-if-needed
    // fallback instead.
    ErrorWidget.builder = (FlutterErrorDetails details) => const ColoredBox(
      color: Colors.black,
      child: Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Something went wrong.',
            style: TextStyle(color: Colors.white),
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }
}

/// Minimal `ProviderObserver` (MEDIUM-4): logs a provider's own
/// initialization/rebuild failures via `dart:developer` — the Riverpod-level
/// counterpart to [configureGlobalErrorHandlers]' Flutter/Zone-level hooks,
/// for failures Riverpod catches internally (e.g. a `FutureProvider`/
/// `AsyncNotifier.build()` throwing) that would otherwise only surface as an
/// `AsyncError` state with no separate log trail.
base class AppProviderObserver extends ProviderObserver {
  @override
  void providerDidFail(
    ProviderObserverContext context,
    Object error,
    StackTrace stackTrace,
  ) {
    developer.log(
      'Provider failed: ${context.provider}',
      name: 'app',
      error: error,
      stackTrace: stackTrace,
    );
  }
}
