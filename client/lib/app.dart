import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/sync/local_data_purge.dart';
import 'l10n/gen/app_localizations.dart';
import 'routing/app_router.dart';
import 'theming/app_theme.dart';

class BeekeepingitApp extends ConsumerWidget {
  const BeekeepingitApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    // Starts the membership-loss local-data purge (#125) as soon as the app
    // boots — a `Provider<void>` whose only job is the `ref.listen` inside
    // it (local_data_purge.dart), independent of which screen is on top.
    ref.watch(membershipLossPurgeProvider);

    return MaterialApp.router(
      onGenerateTitle: (context) => AppLocalizations.of(context).appTitle,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.system,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      routerConfig: router,
    );
  }
}
