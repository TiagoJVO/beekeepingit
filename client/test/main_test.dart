import 'package:beekeepingit_client/main.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('configureGlobalErrorHandlers (MEDIUM-4)', () {
    tearDown(() {
      // Restore Flutter's own defaults so this test file doesn't leak
      // handlers into other test files run in the same isolate. (Any
      // ErrorWidget.builder mutation is restored per-test via addTearDown
      // instead — flutter_test's TestWidgetsFlutterBinding asserts that
      // value is unchanged by the time a testWidgets() body's own teardown
      // phase finishes, which runs before this file-level tearDown.)
      FlutterError.onError = FlutterError.presentError;
      PlatformDispatcher.instance.onError = null;
    });

    test('wires FlutterError.onError without throwing, and still forwards to '
        'the previously-registered handler', () {
      FlutterErrorDetails? forwarded;
      FlutterError.onError = (details) => forwarded = details;

      configureGlobalErrorHandlers();
      final sample = FlutterErrorDetails(exception: Exception('boom'));

      expect(() => FlutterError.onError!(sample), returnsNormally);
      expect(
        forwarded,
        same(sample),
        reason: 'must chain to the previous handler, not replace/swallow it',
      );
    });

    test(
      'wires PlatformDispatcher.instance.onError, marking errors handled',
      () {
        configureGlobalErrorHandlers();

        final handled = PlatformDispatcher.instance.onError!(
          Exception('boom'),
          StackTrace.current,
        );

        expect(handled, isTrue);
      },
    );

    testWidgets(
      'in release mode, installs a friendly ErrorWidget.builder instead of '
      'the raw exception/stack trace',
      (tester) async {
        final originalBuilder = ErrorWidget.builder;

        configureGlobalErrorHandlers(releaseMode: true);

        final details = FlutterErrorDetails(exception: Exception('boom'));
        await tester.pumpWidget(
          MaterialApp(home: ErrorWidget.builder(details)),
        );

        expect(find.textContaining('boom'), findsNothing);
        expect(find.text('Something went wrong.'), findsOneWidget);

        // Must be restored before this test body function returns —
        // flutter_test's TestWidgetsFlutterBinding asserts ErrorWidget.builder
        // is unchanged immediately after the body completes (before any
        // addTearDown/tearDown callback would run), so those run too late.
        ErrorWidget.builder = originalBuilder;
      },
    );

    test('in debug mode (default), leaves the default ErrorWidget.builder '
        'alone', () {
      final defaultBuilder = ErrorWidget.builder;

      configureGlobalErrorHandlers(releaseMode: false);

      expect(ErrorWidget.builder, same(defaultBuilder));
    });
  });

  group('AppProviderObserver (MEDIUM-4)', () {
    test('providerDidFail does not throw when invoked', () {
      // ProviderObserverContext's constructor is package-internal, so this
      // exercises the observer through a real ProviderContainer instead —
      // the same seam Riverpod itself uses to invoke providerDidFail.
      final container = ProviderContainer(observers: [AppProviderObserver()]);
      addTearDown(container.dispose);

      final failing = Provider<int>((ref) => throw Exception('boom'));

      // Reading a provider that throws during initialization must not
      // itself throw an unrelated/unhandled error out of the observer path
      // — Riverpod surfaces it as an AsyncError-shaped failure instead.
      expect(() => container.read(failing), throwsA(isA<Exception>()));
    });
  });
}
