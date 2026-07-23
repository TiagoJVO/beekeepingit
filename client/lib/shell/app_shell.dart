import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/widgets/actions_speed_dial.dart';
import '../core/widgets/tap_target.dart';
import '../core/widgets/unsaved_changes.dart';
import '../features/apiaries/apiaries_list_screen.dart';
import '../features/sync/sync_rejected_repository.dart';
import '../l10n/gen/app_localizations.dart';
import '../theming/brand_tokens.dart';
import 'sync_status.dart';

/// One quick-action's config (FR-UX-2), fed to the shell's [ActionsSpeedDial].
/// [onPressed] takes the [BuildContext] rather than being a bare [VoidCallback]
/// so every action shares the same `context.go(...)`-navigation shape — #389
/// retired the one action that used to instead open a bottom sheet
/// (`showTodoQuickCreateSheet`, #52's quick-create), so this could in
/// principle collapse to a bare route string now, but keeping the
/// `BuildContext`-taking shape avoids a second config type for one field.
/// Hero tagging and expanded/collapsed styling are the speed dial's own
/// concern now (#347), so this no longer carries a hero tag or a tonal flag.
class _FabAction {
  const _FabAction({
    required this.key,
    required this.label,
    required this.onPressed,
    this.icon = Icons.add,
  });

  final Key key;
  final String Function(AppLocalizations l10n) label;
  final IconData icon;
  final void Function(BuildContext context) onPressed;
}

/// Per-tab quick-add config for the contextual actions (FR-UX-2). Tabs without
/// a real feature screen yet (Assistant — M8) have no entry here, so [AppShell]
/// omits the control rather than wiring it to a screen that doesn't exist.
/// [secondary] is optional — only the Apiaries tab has one (#52): a "New todo"
/// action alongside its primary "New apiary" action. With two actions the
/// shell renders a single expandable "Actions" button (#347); with one, a
/// direct FAB.
class _FabConfig {
  const _FabConfig({required this.primary, this.secondary});

  final _FabAction primary;
  final _FabAction? secondary;

  /// The scope's actions, primary first, for [ActionsSpeedDial].
  List<_FabAction> get actions => [primary, if (secondary != null) secondary!];
}

const _fabConfigByTab = <String, _FabConfig>{
  'apiaries': _FabConfig(
    primary: _FabAction(
      key: Key('shell-fab-new-apiary'),
      label: _apiaryFabLabel,
      onPressed: _openNewApiary,
    ),
    // A secondary, contextual quick-add (#52, FR-UX-2) — no pre-filled
    // apiary, since it's opened from the tab root, not a specific apiary.
    secondary: _FabAction(
      key: Key('shell-fab-new-todo'),
      label: _todoFabLabel,
      icon: Icons.task_alt_outlined,
      onPressed: _openNewTodo,
    ),
  ),
  // Journeys (#45): unlike Activities (whose create entry point lives on the
  // apiary detail page, since an activity always needs an apiary context
  // first), a journey isn't tied to a single apiary — so its own tab root is
  // a sensible "New journey" entry point, mirroring the Apiaries tab's FAB.
  'journeys': _FabConfig(
    primary: _FabAction(
      key: Key('shell-fab'),
      label: _journeyFabLabel,
      onPressed: _openNewJourney,
    ),
  ),
  // Todos (#52, FR-TD-1): "the main screen" quick-create entry point — this
  // tab's own root IS "the main screen" FR-TD-1 refers to (distinct from
  // "the apiaries list", named separately in the same AC).
  'todos': _FabConfig(
    primary: _FabAction(
      key: Key('shell-fab'),
      label: _todoFabLabel,
      icon: Icons.task_alt_outlined,
      onPressed: _openNewTodo,
    ),
  ),
};

String _apiaryFabLabel(AppLocalizations l10n) => l10n.addApiary;
String _journeyFabLabel(AppLocalizations l10n) => l10n.addJourney;
String _todoFabLabel(AppLocalizations l10n) => l10n.addTodo;

void _openNewApiary(BuildContext context) => context.go('/apiaries/new');
void _openNewJourney(BuildContext context) => context.go('/journeys/new');

/// Routes to the full create form (#389, replacing #52's quick-create
/// sheet) — no `?apiaryId=` query param, since both entry points wired to
/// this (the Apiaries tab's secondary FAB, the Todos tab's own primary FAB)
/// sit at a tab ROOT, not on a specific apiary, unlike the apiary detail
/// page's own contextual "New todo" action (apiary_detail_screen.dart),
/// which passes one.
void _openNewTodo(BuildContext context) => context.go('/todos/new');

/// The persistent app shell (FR-UX-2, #197): a 5-tab bottom nav wrapping a
/// [StatefulShellRoute] (one navigation stack per tab, per go_router's
/// idiomatic pattern), a header (contextual back, brand + screen title,
/// sync-status pill, account), an offline banner, and a contextual honey FAB.
///
/// Apiaries, Activities, Journeys and Todos (M2/M3/M4/M5, #293) now have
/// real screens; Assistant still shows a [ComingSoonScreen] placeholder (see
/// coming_soon_screen.dart, M8) — this shell itself doesn't know or care
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
        onSyncTap: () => _guardedGo(context, ref, '/account'),
        onAccountTap: () => _guardedGo(context, ref, '/account'),
      ),
      body: Column(
        children: [
          const _OfflineBanner(),
          const _NeedsFixBanner(),
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
        onDestinationSelected: (index) => _onSelectTab(context, ref, index),
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
  // assigns each branch) — not the root GoRouter, since a shell branch's
  // pushed pages live in a nested Navigator the root router doesn't directly
  // control. Uses `maybePop` (not `pop`) so a pushed edit/create screen's
  // [PopScope] unsaved-changes guard (#345) is consulted — a plain `pop`
  // bypasses PopScope and would discard edits silently. Read-only pushed
  // screens have no PopScope, so `maybePop` just pops them as before.
  void _popBranch() {
    final navigatorKey = navigationShell
        .route
        .branches[navigationShell.currentIndex]
        .navigatorKey;
    navigatorKey.currentState?.maybePop();
  }

  // Switching primary tabs (#345, FR-UX-2): two behaviors bundled here.
  // (1) Scope reset — `initialLocation: true` always resets the target branch
  // to its root, so a tab never carries over the previous session's scoped
  // state (the product owner's directed change: a fresh tab, not wherever it
  // was last left). (2) Unsaved-changes guard — a tab-switch is a
  // `context.go`-style route change no PopScope sees, so if the current
  // edit/create screen has pending edits, prompt confirm-discard first and
  // only switch if the user confirms.
  Future<void> _onSelectTab(
    BuildContext context,
    WidgetRef ref,
    int index,
  ) async {
    if (!await _confirmLeaveIfDirty(context, ref)) return;
    navigationShell.goBranch(index, initialLocation: true);
  }

  // Guards a header `context.go` (account/sync) the same way as a tab-switch:
  // these too are route changes a PopScope never sees (#345).
  Future<void> _guardedGo(
    BuildContext context,
    WidgetRef ref,
    String location,
  ) async {
    if (!await _confirmLeaveIfDirty(context, ref)) return;
    if (context.mounted) context.go(location);
  }

  // Returns whether it's OK to leave the current screen: true immediately when
  // nothing is dirty (read-only screens never set the flag), otherwise prompts
  // the confirm-discard dialog and clears the flag on confirmation (#345).
  Future<bool> _confirmLeaveIfDirty(BuildContext context, WidgetRef ref) async {
    if (!ref.read(unsavedChangesProvider)) return true;
    final discard = await showDiscardChangesDialog(context);
    if (discard) {
      ref.read(unsavedChangesProvider.notifier).markClean();
    }
    return discard;
  }

  // Extracted out of build() (MEDIUM-7: oversized build()) — a self-contained
  // concern that doesn't need to sit inline in the widget-building method.
  // `ref.listen` (not `ref.watch`) means the provider changing doesn't trigger
  // a rebuild — only the SnackBar callback fires — so this doesn't reintroduce
  // HIGH-4's "watched too high up the tree" problem.
  //
  // #379: the rejected-write notice used to also live here, as a one-shot
  // SnackBar with a "Fix" action. Two bugs with that: (1) nothing ever hid it
  // once the rejection was resolved — a SnackBar with an action doesn't
  // auto-dismiss under accessible navigation, and it has no link to
  // [syncNeedsFixCountProvider] — so it could outlive the dead-letter row it
  // was about; (2) its "Fix" closure captured this build's context, which goes
  // stale once the user navigates to /account or /sync-needs-fix (both
  // top-level routes outside this shell), silently no-oping the action from
  // most screens. [_NeedsFixBanner] below replaces it: state-driven off the
  // same count, so it appears/disappears with the dead-letter queue itself,
  // and its own Fix button uses its own (always-current) build context.
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
      // #384: the journey-scoped activity detail route renders the same
      // ActivityDetailScreen as 'activityDetail' above — same title.
      'journeyActivityDetail' => l10n.activityDetailTitle,
      'activityEdit' => l10n.editActivityTitle,
      'journeyNew' => l10n.newJourneyTitle,
      'journeyDetail' => l10n.journeyDetailTitle,
      'journeyEdit' => l10n.editJourneyTitle,
      'journeyStats' => l10n.journeyStatsDetailTitle,
      'todoNew' => l10n.newTodoTitle,
      'todoDetail' => l10n.todoDetailTitle,
      'todoEdit' => l10n.editTodoTitle,
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

/// A [ConsumerWidget] (HIGH-4, matching [_OfflineBanner]'s own rationale)
/// that watches [syncNeedsFixCountProvider] itself and renders nothing while
/// the count is 0 — so it **auto-appears** the moment an offline write is
/// rejected and **auto-clears** the moment the last one is fixed or
/// dismissed, with no event stream involved (#379: replaces the one-shot
/// SnackBar in [AppShell._listenForSyncToasts] — see that method's doc for
/// the two bugs this fixes). Always mounted while visible, as part of the
/// shell body rather than a transient overlay, so its own Fix button's
/// [BuildContext] is never stale the way the toast's captured one went once
/// the user navigated away from the shell.
class _NeedsFixBanner extends ConsumerWidget {
  const _NeedsFixBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final needsFixCount = ref.watch(syncNeedsFixCountProvider).value ?? 0;
    if (needsFixCount == 0) return const SizedBox.shrink();

    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    // Same plum/cream banner treatment as [_OfflineBanner] (#243's verified
    // contrast), with the error color reserved for the icon — this is a
    // "needs your attention" notice, not a connectivity status.
    return Container(
      key: const Key('shell-needs-fix-banner'),
      width: double.infinity,
      color: BrandTokens.plum800,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Icon(Icons.sync_problem_outlined, size: 18, color: colorScheme.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              l10n.syncRejectedNotice,
              style: const TextStyle(color: BrandTokens.cream, fontSize: 13),
            ),
          ),
          TextButton(
            key: const Key('shell-needs-fix-banner-fix'),
            onPressed: () => context.go('/sync-needs-fix'),
            style: TextButton.styleFrom(foregroundColor: BrandTokens.honey),
            child: Text(l10n.syncNeedsFixFixAction),
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
    final config = (canGoBack || onApiaryMap)
        ? null
        : _fabConfigByTab[activeTabRoute];
    if (config == null) return const SizedBox.shrink();

    final l10n = AppLocalizations.of(context);

    // One "Actions" control (#347, FR-UX-1/FR-UX-2): with a single action it
    // renders as a direct primary FAB; the Apiaries tab's two actions collapse
    // into an expandable speed dial instead of stacking. Each config action
    // maps to a [SpeedDialAction], closing over this build's [context] so both
    // navigating and sheet-opening actions share one shape.
    return ActionsSpeedDial(
      actions: [
        for (final action in config.actions)
          SpeedDialAction(
            key: action.key,
            label: action.label(l10n),
            icon: action.icon,
            onPressed: () => action.onPressed(context),
          ),
      ],
    );
  }
}
