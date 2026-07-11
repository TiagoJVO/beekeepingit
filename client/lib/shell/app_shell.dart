import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../l10n/gen/app_localizations.dart';
import 'sync_status.dart';

/// Per-tab quick-add config for the contextual FAB (FR-UX-2). Tabs without a
/// real feature screen yet (Activities/Journeys/Todos/Assistant — M3/M4/M5/M8)
/// have no entry here, so [AppShell] omits the FAB rather than wiring it to a
/// screen that doesn't exist.
class _FabConfig {
  const _FabConfig({required this.label, required this.destination});

  final String Function(AppLocalizations l10n) label;
  final String destination;
}

const _fabConfigByTab = <String, _FabConfig>{
  'apiaries': _FabConfig(label: _apiaryFabLabel, destination: '/apiaries/new'),
};

String _apiaryFabLabel(AppLocalizations l10n) => l10n.addApiary;

/// The persistent app shell (FR-UX-2, #197): a 5-tab bottom nav wrapping a
/// [StatefulShellRoute] (one navigation stack per tab, per go_router's
/// idiomatic pattern), a header (contextual back, brand + screen title,
/// sync-status pill, account), an offline banner, and a contextual honey FAB.
///
/// Only the Apiaries tab has real screens this milestone; the other four show
/// [ComingSoonScreen] placeholders (see coming_soon_screen.dart) — this shell
/// itself doesn't know or care which, it just renders whatever the active
/// branch's navigator holds.
class AppShell extends ConsumerWidget {
  const AppShell({required this.navigationShell, super.key});

  final StatefulNavigationShell navigationShell;

  static const tabs = [
    (
      route: 'apiaries',
      icon: Icons.hive_outlined,
      selectedIcon: Icons.hive,
      label: _apiariesLabel,
    ),
    (
      route: 'activities',
      icon: Icons.event_note_outlined,
      selectedIcon: Icons.event_note,
      label: _activitiesLabel,
    ),
    (
      route: 'journeys',
      icon: Icons.route_outlined,
      selectedIcon: Icons.route,
      label: _journeysLabel,
    ),
    (
      route: 'todos',
      icon: Icons.task_alt_outlined,
      selectedIcon: Icons.task_alt,
      label: _todosLabel,
    ),
    (
      route: 'assistant',
      icon: Icons.forum_outlined,
      selectedIcon: Icons.forum,
      label: _assistantLabel,
    ),
  ];

  static String _apiariesLabel(AppLocalizations l10n) => l10n.apiariesTitle;
  static String _activitiesLabel(AppLocalizations l10n) => l10n.activitiesTitle;
  static String _journeysLabel(AppLocalizations l10n) => l10n.journeysTitle;
  static String _todosLabel(AppLocalizations l10n) => l10n.todosTitle;
  static String _assistantLabel(AppLocalizations l10n) => l10n.assistantTitle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final activeTab = tabs[navigationShell.currentIndex];
    final syncStatus = ref.watch(syncStatusProvider);
    final fab = _fabConfigByTab[activeTab.route];
    final routeName = GoRouterState.of(context).topRoute?.name;

    // Whether there's somewhere to go back to *within the active tab's own
    // navigation stack* — e.g. Apiaries list -> apiary detail/form. Derived
    // from the matched route's own name rather than the branch Navigator's
    // canPop() (GlobalKey.currentState lags a frame behind a same-build
    // push, which made the back button miss its first render): each tab's
    // *root* route is named exactly like its branch (see the routes table in
    // app_router.dart) — any other matched name means we're pushed deeper.
    final canGoBack = routeName != null && routeName != activeTab.route;

    return Scaffold(
      appBar: _ShellHeader(
        title: _titleFor(routeName, activeTab, l10n),
        syncStatus: syncStatus,
        onBack: canGoBack ? () => _popBranch() : null,
        onSyncTap: () => context.go('/account'),
        onAccountTap: () => context.go('/account'),
      ),
      body: Column(
        children: [
          if (!syncStatus.isOnline)
            _OfflineBanner(pendingCount: syncStatus.pendingCount),
          Expanded(child: navigationShell),
        ],
      ),
      floatingActionButton: fab == null
          ? null
          : FloatingActionButton.extended(
              key: const Key('shell-fab'),
              backgroundColor: const Color(0xFFF0A81F),
              foregroundColor: const Color(0xFF3A2E14),
              onPressed: () => context.go(fab.destination),
              icon: const Icon(Icons.add),
              label: Text(fab.label(l10n)),
            ),
      bottomNavigationBar: NavigationBar(
        key: const Key('shell-bottom-nav'),
        selectedIndex: navigationShell.currentIndex,
        onDestinationSelected: (index) => navigationShell.goBranch(
          index,
          initialLocation: index == navigationShell.currentIndex,
        ),
        destinations: [
          for (final tab in tabs)
            NavigationDestination(
              key: Key('shell-tab-${tab.route}'),
              icon: Icon(tab.icon),
              selectedIcon: Icon(tab.selectedIcon),
              label: tab.label(l10n),
            ),
        ],
      ),
    );
  }

  // Pops the active branch's own Navigator (via the key StatefulShellRoute
  // assigns each branch) back to its root — not the root GoRouter, since a
  // shell branch's pushed pages live in a nested Navigator the root router
  // doesn't directly control.
  void _popBranch() {
    final navigatorKey = navigationShell
        .route
        .branches[navigationShell.currentIndex]
        .navigatorKey;
    navigatorKey.currentState?.pop();
  }

  // The header shows a per-route title, not just the tab label — e.g. "New
  // apiary" while pushed on top of the Apiaries tab — falling back to the
  // active tab's own label at the branch root. Named routes pushed within a
  // branch (apiaryNew, apiaryEdit) opt into a specific title here; anything
  // else (including the placeholder tabs) just shows the tab label.
  String _titleFor(
    String? routeName,
    ({
      String route,
      IconData icon,
      IconData selectedIcon,
      String Function(AppLocalizations) label,
    })
    activeTab,
    AppLocalizations l10n,
  ) {
    return switch (routeName) {
      'apiaryNew' => l10n.newApiaryTitle,
      'apiaryEdit' => l10n.editApiaryTitle,
      _ => activeTab.label(l10n),
    };
  }
}

class _ShellHeader extends StatelessWidget implements PreferredSizeWidget {
  const _ShellHeader({
    required this.title,
    required this.syncStatus,
    required this.onBack,
    required this.onSyncTap,
    required this.onAccountTap,
  });

  final String title;
  final SyncStatus syncStatus;
  final VoidCallback? onBack;
  final VoidCallback onSyncTap;
  final VoidCallback onAccountTap;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AppBar(
      leading: onBack == null
          ? null
          : IconButton(
              key: const Key('shell-back-button'),
              icon: const Icon(Icons.arrow_back),
              tooltip: MaterialLocalizations.of(context).backButtonTooltip,
              onPressed: onBack,
            ),
      automaticallyImplyLeading: false,
      titleSpacing: onBack == null ? null : 0,
      title: Text(
        title,
        style: const TextStyle(fontFamily: 'Playfair Display'),
      ),
      actions: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: _SyncStatusPill(
            key: const Key('shell-sync-pill'),
            status: syncStatus,
            onTap: onSyncTap,
          ),
        ),
        const SizedBox(width: 4),
        IconButton(
          key: const Key('shell-account-button'),
          icon: const Icon(Icons.account_circle_outlined),
          tooltip: l10n.accountTitle,
          onPressed: onAccountTap,
        ),
      ],
    );
  }
}

class _SyncStatusPill extends StatelessWidget {
  const _SyncStatusPill({super.key, required this.status, required this.onTap});

  final SyncStatus status;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final color = status.isOnline
        ? const Color(0xFF7BC98A)
        : const Color(0xFFF0A81F);
    final label = status.isOnline
        ? l10n.syncStatusOnline
        : (status.pendingCount > 0
              ? l10n.syncStatusOfflinePending(status.pendingCount)
              : l10n.syncStatusOffline);

    return Semantics(
      button: true,
      label: l10n.syncStatusSemanticLabel(label),
      child: Material(
        color: Colors.white.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44, minWidth: 44),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 9,
                    height: 9,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    label,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _OfflineBanner extends StatelessWidget {
  const _OfflineBanner({required this.pendingCount});

  final int pendingCount;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Container(
      key: const Key('shell-offline-banner'),
      width: double.infinity,
      color: const Color(0xFF3A3149),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          const Icon(Icons.cloud_off, size: 18, color: Color(0xFFF0A81F)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              l10n.offlineBannerMessage(pendingCount),
              style: const TextStyle(color: Color(0xFFE8E3F2), fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}
