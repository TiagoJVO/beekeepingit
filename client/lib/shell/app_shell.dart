import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/widgets/tap_target.dart';
import '../features/apiaries/apiaries_list_screen.dart';
import '../features/sync/sync_rejected_repository.dart';
import '../l10n/gen/app_localizations.dart';
import '../theming/brand_tokens.dart';
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
  // Journeys (#45): unlike Activities (whose create entry point lives on the
  // apiary detail page, since an activity always needs an apiary context
  // first), a journey isn't tied to a single apiary — so its own tab root is
  // a sensible "New journey" entry point, mirroring the Apiaries tab's FAB.
  'journeys': _FabConfig(label: _journeyFabLabel, destination: '/journeys/new'),
};

String _apiaryFabLabel(AppLocalizations l10n) => l10n.addApiary;
String _journeyFabLabel(AppLocalizations l10n) => l10n.addJourney;

/// The persistent app shell (FR-UX-2, #197): a 5-tab bottom nav wrapping a
/// [StatefulShellRoute] (one navigation stack per tab, per go_router's
/// idiomatic pattern), a header (contextual back, brand + screen title,
/// sync-status pill, account), an offline banner, and a contextual honey FAB.
///
/// Apiaries, Activities and Journeys now have real screens (M2/M3/M4); Todos
/// and Assistant still show [ComingSoonScreen] placeholders (see
/// coming_soon_screen.dart, M5/M8) — this shell itself doesn't know or care
/// which, it just renders whatever the active branch's navigator holds.
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
    final routeName = GoRouterState.of(context).topRoute?.name;

    // Note (HIGH-4): syncStatusProvider, syncNeedsFixCountProvider, and
    // apiariesViewProvider are deliberately NOT watched here. All three
    // change frequently (connectivity flips, upload progress, the list/map
    // toggle), and this build() also constructs the Scaffold/NavigationBar/
    // FAB chrome — watching them here would re-run all of that on every
    // change. Instead, _ShellHeader/_OfflineBanner/_ShellFab below are their
    // own ConsumerWidgets that watch only what they individually need, so a
    // change to one of these providers only rebuilds the small widget that
    // actually depends on it.

    _listenForSyncToasts(context, ref, l10n);

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
        onBack: canGoBack ? () => _popBranch() : null,
        onSyncTap: () => context.go('/account'),
        onAccountTap: () => context.go('/account'),
      ),
      body: Column(
        children: [
          const _OfflineBanner(),
          Expanded(child: navigationShell),
        ],
      ),
      floatingActionButton: _ShellFab(
        activeTabRoute: activeTab.route,
        canGoBack: canGoBack,
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

  // Extracted out of build() (MEDIUM-7: oversized build()) — the two
  // one-shot toast listeners are a self-contained concern (D-12
  // notify-and-fix) that doesn't need to sit inline in the widget-building
  // method. `ref.listen` (not `ref.watch`) means neither provider changing
  // triggers a rebuild — only the SnackBar callback fires — so this doesn't
  // reintroduce HIGH-4's "watched too high up the tree" problem either way.
  void _listenForSyncToasts(
    BuildContext context,
    WidgetRef ref,
    AppLocalizations l10n,
  ) {
    // Non-blocking notice when an offline edit lost a last-write-wins
    // conflict (sync.md §4.2/§8, D-12's notify-and-fix) — a toast, matching
    // #197's "toast confirmations on save/sync" pattern
    // (docs/design/prototype.md), not a dedicated screen: the user needs to
    // know it happened, not be interrupted. The full conflict record is the
    // entity-history/timeline UI (FR-HIS, #59-#62).
    ref.listen(supersededNotificationProvider, (previous, next) {
      final change = next.value;
      if (change == null) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.syncSupersededNotice)));
    });

    // Non-blocking notice when an offline write was permanently rejected
    // (sync.md §8, D-12 notify-and-fix): a toast with a "Fix" action routing
    // to the needs-fix list, where the user opens the offending record,
    // corrects it and re-saves. The edit itself is retained in the local
    // dead-letter (syncRejectedOpsProvider) — this is just the one-shot
    // notification, and the account-button badge is the persistent
    // affordance.
    ref.listen(rejectedNotificationProvider, (previous, next) {
      final change = next.value;
      if (change == null) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.syncRejectedNotice),
          action: SnackBarAction(
            label: l10n.syncNeedsFixFixAction,
            onPressed: () => context.go('/sync-needs-fix'),
          ),
        ),
      );
    });
  }

  // The header shows a per-route title, not just the tab label — e.g. "New
  // apiary" while pushed on top of the Apiaries tab — falling back to the
  // active tab's own label at the branch root. Named routes pushed within a
  // branch (apiaryNew, apiaryDetail, apiaryEdit) opt into a specific title
  // here; anything else (including the placeholder tabs) just shows the tab
  // label. The map view (#34/#35) is a sibling view within the apiaries tab
  // root (not a pushed route — see _ShellFab's own apiariesViewProvider
  // watch) so it doesn't need an entry here — the segmented toggle itself is
  // the view indicator (#35 AC), the header title stays "Apiaries" for both
  // views.
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
      'apiaryDetail' => l10n.apiaryDetailTitle,
      'apiaryEdit' => l10n.editApiaryTitle,
      'activityNew' => l10n.newActivityTitle,
      'activityDetail' => l10n.activityDetailTitle,
      'activityEdit' => l10n.editActivityTitle,
      'journeyNew' => l10n.newJourneyTitle,
      'journeyEdit' => l10n.editJourneyTitle,
      _ => activeTab.label(l10n),
    };
  }
}

/// A [ConsumerWidget] (not [AppShell] itself, HIGH-4) so a sync-status or
/// needs-fix-count change only rebuilds this small header, not the whole
/// shell (Scaffold/NavigationBar/FAB) that [AppShell.build] also constructs.
class _ShellHeader extends ConsumerWidget implements PreferredSizeWidget {
  const _ShellHeader({
    required this.title,
    required this.onBack,
    required this.onSyncTap,
    required this.onAccountTap,
  });

  final String title;
  final VoidCallback? onBack;
  final VoidCallback onSyncTap;
  final VoidCallback onAccountTap;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final syncStatus = ref.watch(syncStatusProvider);
    // Count of offline writes awaiting a fix (D-12 notify-and-fix) — drives
    // the account-button badge. Defaults to 0 while the sync engine is still
    // opening, like the rest of the header's always-available state.
    final needsFixCount = ref.watch(syncNeedsFixCountProvider).value ?? 0;
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
      // The Playfair Display screen-title font + plum-header color come from
      // the theme's appBarTheme.titleTextStyle now (AppTheme), replacing the
      // old inline `fontFamily: 'Playfair Display'` that had no bundled font
      // and silently fell back to Roboto (#243).
      title: Text(title),
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
        // Account entry, badged when offline writes need fixing (D-12
        // notify-and-fix): the persistent affordance the rejection toast's
        // one-shot notice complements. The badge count also rides the tooltip
        // so it's announced to screen readers, not only shown visually.
        Badge(
          key: const Key('shell-needs-fix-badge'),
          isLabelVisible: needsFixCount > 0,
          label: Text('$needsFixCount'),
          child: IconButton(
            key: const Key('shell-account-button'),
            icon: const Icon(Icons.account_circle_outlined),
            tooltip: needsFixCount > 0
                ? l10n.syncNeedsFixCount(needsFixCount)
                : l10n.accountTitle,
            onPressed: onAccountTap,
          ),
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
    final theme = Theme.of(context);
    // The pill sits on the plum header; its label/tint use the header's own
    // foreground (white) so they read on plum (white-on-plum700 is ~9.6:1 AA —
    // the automated contrast test covers the ColorScheme role pairs, this
    // header pair was verified computationally in the #243 PR).
    final onHeader =
        theme.appBarTheme.foregroundColor ?? theme.colorScheme.onSurface;
    // sync.md §8's per-record vocabulary (pending/syncing/synced/superseded/
    // rejected) generalized to the header's single connection-level pill:
    // error (last upload/download attempt failed and PowerSync is waiting to
    // retry — distinct from merely having no signal) · offline (with/without
    // a pending count) · waiting for signal (the connection-quality gate is
    // backing off, FR-OF-3/§7.1, #55) · syncing (upload/download in flight) ·
    // online/up-to-date. Amber doubles as "offline"/"waiting"/"syncing" (all
    // in-progress, not-yet-settled states), red flags "error" (a beekeeper
    // whose uploads keep failing needs to notice this, not read it as plain
    // offline), green is reserved for "online and caught up". Amber == the
    // theme primary (BrandTokens honey); green == BrandTokens.online (#243).
    final color = status.hasError && !status.syncing
        ? theme.colorScheme.error
        : status.isOnline && !status.syncing
        ? BrandTokens.online
        : theme.colorScheme.primary;
    final label = status.syncing
        ? l10n.syncStatusSyncing
        : status.hasError
        ? l10n.syncStatusError
        : status.isOnline
        ? l10n.syncStatusOnline
        : status.isWaitingForSignal
        ? l10n.syncStatusWaitingForSignal
        : (status.pendingCount > 0
              ? l10n.syncStatusOfflinePending(status.pendingCount)
              : l10n.syncStatusOffline);

    return Semantics(
      button: true,
      label: l10n.syncStatusSemanticLabel(label),
      child: Material(
        color: onHeader.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: kMinTapTarget,
              minWidth: kMinTapTarget,
            ),
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
                    style: TextStyle(
                      color: onHeader,
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

/// A [ConsumerWidget] (HIGH-4) that watches [syncStatusProvider] itself and
/// decides whether to render at all — [AppShell.build] always includes this
/// widget in the tree unconditionally, rather than watching the provider
/// itself just to decide whether to include it, so a sync-status change only
/// rebuilds this small banner, not the whole shell.
class _OfflineBanner extends ConsumerWidget {
  const _OfflineBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(syncStatusProvider);
    if (status.isOnline) return const SizedBox.shrink();

    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    // Plum banner ground with a honey cloud-off icon and cream text — from the
    // tokens/theme (BrandTokens plum800 / honey / cream), not inline hexes.
    // Cream-on-plum800 is AA-legible (~10.4:1, verified computationally in the
    // #243 PR) (#243). The error variant swaps in the theme's error color and
    // icon so it reads as distinctly "stuck retrying", not plain offline
    // (HIGH-3, SyncStatus.hasError).
    return Container(
      key: const Key('shell-offline-banner'),
      width: double.infinity,
      color: BrandTokens.plum800,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Icon(
            status.hasError ? Icons.error_outline : Icons.cloud_off,
            size: 18,
            color: status.hasError ? colorScheme.error : colorScheme.primary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              status.hasError
                  ? l10n.offlineBannerErrorMessage
                  : l10n.offlineBannerMessage(status.pendingCount),
              style: const TextStyle(color: BrandTokens.cream, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

/// The shell's contextual "quick add" honey FAB (_fabConfigByTab) — a
/// [ConsumerWidget] (HIGH-4) so the list/map view toggle (which only this
/// widget needs, via [apiariesViewProvider]) doesn't force [AppShell.build]
/// to re-run and reconstruct the Scaffold/NavigationBar chrome too.
/// [activeTabRoute]/[canGoBack] come from the router, not a watched
/// provider, so passing them in as plain constructor params doesn't
/// reintroduce the same problem.
class _ShellFab extends ConsumerWidget {
  const _ShellFab({required this.activeTabRoute, required this.canGoBack});

  final String activeTabRoute;
  final bool canGoBack;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The apiaries tab's list/map toggle (#35, FR-AP-4) swaps sibling views
    // in place rather than pushing a route. Watched (not just read) so the
    // FAB actually shows/hides live as the user flips the toggle.
    final apiariesView = ref.watch(apiariesViewProvider);
    final onApiaryMap =
        activeTabRoute == 'apiaries' && apiariesView == ApiariesView.map;

    // The FAB only makes sense at a tab's root (e.g. "Add apiary" on the
    // apiaries list). Screens pushed deeper — the apiary detail screen (#32,
    // own FAB e.g. its edit action) and the create/edit form — are covered
    // by canGoBack; the map view (#34/#35, its own full-screen layout with
    // no room for a floating action) is covered by onApiaryMap above, since
    // it's a sibling view rather than a pushed route.
    final fab = (canGoBack || onApiaryMap)
        ? null
        : _fabConfigByTab[activeTabRoute];
    if (fab == null) return const SizedBox.shrink();

    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    // Honey FAB drawn from the theme primary/onPrimary (BrandTokens honey /
    // onHoney) — the "one honey primary action" shared with
    // PrimaryActionButton, not a second hardcoded honey (#243).
    return FloatingActionButton.extended(
      key: const Key('shell-fab'),
      backgroundColor: colorScheme.primary,
      foregroundColor: colorScheme.onPrimary,
      onPressed: () => context.go(fab.destination),
      icon: const Icon(Icons.add),
      label: Text(fab.label(l10n)),
    );
  }
}
