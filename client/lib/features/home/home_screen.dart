import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/l10n/locale_formatting.dart';
import '../../core/widgets/field_action_button.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../theming/brand_dimens.dart';
import '../../theming/brand_widgets.dart';
import '../activities/activity_types.dart';
import '../apiaries/apiary_visit_recency.dart';
import '../journeys/journey_status.dart';
import '../journeys/journeys_repository.dart';
import '../todos/todo_due.dart';
import '../todos/todo_priority.dart';
import '../todos/todos_repository.dart';
import 'home_providers.dart';
import 'home_summary.dart';

/// The Home tab (#658, D-35, FR-UX-1): the centre of the bottom nav and the
/// app's landing screen — "what needs me right now", at a glance.
///
/// Renders exactly one of [HomeSummaryState]'s cases via an exhaustive
/// `switch` (dart-conventions.md): the three attention sections, a genuine
/// first-run state, or the all-clear. D-35 asks for that closed set
/// explicitly — "a genuine first-run state (one action: add your first
/// apiary) and an all-clear state, rather than several empty sections" — so
/// an empty section is never rendered as an empty section.
///
/// Two further cases exist so the screen can be **honest about not knowing**
/// (#658 review): [HomeSummaryState.notReady] paints nothing at all while
/// the local store is still opening, and [HomeSummaryState.unavailable] says
/// so plainly when it could not be read. Both used to render as the
/// first-run state, telling a user whose org already owns apiaries to add
/// their first one.
///
/// **Every value it displays rides on [HomeSummary]; this file reads no
/// clock.** The badge on a row comes from the [AttentionTodo.bucket] the
/// summary already decided, and an apiary's staleness from the carried
/// [ApiaryVisitRecency.daysSinceLastVisit] — never from a second
/// `DateTime.now()`, which can straddle a midnight rollover and badge a row
/// differently from the list it sits in.
///
/// No own AppBar/Scaffold — like the apiaries/activities/journeys/todos list
/// screens, this is a tab root's content within the app shell, which supplies
/// the header. It gets no FAB from the shell either: per D-35, FR-UX-2's
/// quick-add is contextual to the active area and Home's area is every area,
/// so no single create action is the right one.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summary = ref.watch(homeSummaryProvider);

    // Keyed here (rather than on the route's `HomeScreen()` construction) so
    // the marker travels with the screen itself, whatever pumps it, and so it
    // wraps whichever of the three states is showing.
    return KeyedSubtree(
      key: const Key('home-screen'),
      child: switch (summary.state) {
        // Nothing has loaded yet: show nothing, and specifically NOT a
        // spinner — history_section.dart takes the same non-spinner loading
        // state for the same two reasons (a spinner inside a shrink-wrapped
        // section janks the page, and it hangs `pumpAndSettle` in tests).
        HomeSummaryState.notReady => const SizedBox.shrink(),
        HomeSummaryState.unavailable => const _UnavailableState(),
        HomeSummaryState.firstRun => const _FirstRunState(),
        HomeSummaryState.allClear => const _AllClearState(),
        HomeSummaryState.needsAttention => _AttentionSections(summary: summary),
      },
    );
  }
}

/// The three D-35 sections, each rendered only when it matched something.
///
/// A plain [SingleChildScrollView] + [Column] rather than a lazy list: at
/// most three sections of at most [kHomePreviewLimit] rows exist, so laziness
/// would buy nothing and would make "is the third section on screen" depend
/// on viewport height.
class _AttentionSections extends StatelessWidget {
  const _AttentionSections({required this.summary});

  final HomeSummary summary;

  @override
  Widget build(BuildContext context) {
    final sections = <Widget>[
      // Some dependency failed while others resolved, so what follows is
      // partial or frozen. The sections that DID load still render — that
      // per-section degrade is the point of home_providers.dart's
      // `?? const []` — but the screen says so rather than letting the gap
      // pass for "nothing there" (#658 review).
      if (summary.readiness == HomeDataReadiness.unavailable)
        const _UnavailableNotice(),
      if (summary.attentionTodos.isNotEmpty)
        _TasksSection(
          section: summary.attentionTodos,
          overdueCount: summary.overdueTodoCount,
          now: summary.now,
        ),
      if (summary.openJourneys.isNotEmpty)
        _JourneysSection(section: summary.openJourneys),
      if (summary.staleApiaries.isNotEmpty)
        _StaleApiariesSection(section: summary.staleApiaries),
    ];

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        BrandDimens.gutter,
        8,
        BrandDimens.gutter,
        BrandDimens.scrollBottomInset,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < sections.length; i++) ...[
            if (i > 0) const SizedBox(height: 24),
            sections[i],
          ],
        ],
      ),
    );
  }
}

/// D-35's "tasks overdue or due soon" section (FR-TD-1).
class _TasksSection extends StatelessWidget {
  const _TasksSection({
    required this.section,
    required this.overdueCount,
    required this.now,
  });

  final HomeSummarySection<AttentionTodo> section;

  /// How many of [section]'s FULL set are overdue ([HomeSummary.
  /// overdueTodoCount]) — what the footer link is labelled with, since that
  /// is the subset the link opens.
  final int overdueCount;

  /// The single instant the whole summary was computed against
  /// ([HomeSummary.now]) — the ONLY time input a row's badge may use.
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final formatting = LocaleFormatting.of(context);

    return _HomeSection(
      sectionKey: const Key('home-tasks-section'),
      countKey: const Key('home-tasks-count'),
      title: l10n.homeTasksSectionTitle,
      count: section.count,
      countLabel: l10n.homeTasksCountLabel(section.count),
      // The only urgent-toned count on Home: an overdue task is the one
      // thing here that is already late, unlike an open journey or an
      // unvisited apiary.
      countUrgent: true,
      rows: [
        for (final attention in section.preview)
          BrandRowCard(
            key: Key('home-todo-${attention.todo.id}'),
            title: attention.todo.title,
            subtitle: _todoSubtitle(l10n, formatting, attention.todo),
            trailing: _todoBadge(l10n, attention),
            onTap: () => context.go('/todos/${attention.todo.id}'),
          ),
      ],
      // D-35 asks for a link "to that list screen filtered to the same set",
      // and the Todos tab cannot express this section's set: it is "overdue
      // OR due soon", a UNION, while the tab's filters combine with AND, its
      // `open` status excludes overdue, and its due-date presets are calendar
      // windows (today/this week/this month) rather than todo_due.dart's
      // per-priority "due soon" lead time. Closing that gap is #661.
      //
      // Until it closes, `?status=overdue` is the closest honest subset and
      // the LABEL is what has to stay truthful. Labelling it with
      // `section.count` — the union — promised rows the destination would
      // not show, and with no overdue row at all it read "View all 2 tasks"
      // and landed on "No todos match your filters." So: count and word the
      // link as OVERDUE, and when nothing is overdue offer no link at all
      // rather than one that opens an empty list. The count badge above
      // still reports the full section, which is the number that is true of
      // what is on screen.
      footer: overdueCount == 0
          ? null
          : _SectionFooterLink(
              buttonKey: const Key('home-tasks-view-all'),
              label: l10n.homeTasksViewAllOverdueAction(overdueCount),
              onPressed: () => context.go('/todos?status=overdue'),
            ),
    );
  }

  /// `due date · priority`, built the same way `_TodoTile` builds its own
  /// subtitle (todo_list_widgets.dart) so a task reads identically on Home
  /// and on the Todos tab.
  static String _todoSubtitle(
    AppLocalizations l10n,
    LocaleFormatting formatting,
    Todo todo,
  ) {
    final priorityLabel =
        todoPriorityLabel(l10n, todo.priority) ?? todo.priority;
    final dueDate = todo.dueDate;
    final dueText = dueDate == null
        ? l10n.todoDueDateUnset
        : formatting.date(DateTime.parse(dueDate));
    return '$dueText · $priorityLabel';
  }

  /// The trailing badge, derived from the bucket the summary carried — this
  /// widget never calls [todoDueBucket] itself.
  Widget _todoBadge(AppLocalizations l10n, AttentionTodo attention) {
    final badgeKey = Key('home-todo-badge-${attention.todo.id}');
    return switch (attention.bucket) {
      TodoDueBucket.overdue => _AttentionBadge(
        badgeKey: badgeKey,
        icon: Icons.warning_amber_outlined,
        label: l10n.homeTodoOverdueBadge(_daysLate(attention.todo)),
        semanticLabel: l10n.homeTodoOverdueLabel(_daysLate(attention.todo)),
        urgent: true,
      ),
      TodoDueBucket.dueSoon => _AttentionBadge(
        badgeKey: badgeKey,
        icon: Icons.schedule,
        label: l10n.homeTodoDueSoonBadge,
        semanticLabel: l10n.homeTodoDueSoonLabel,
        urgent: false,
      ),
    };
  }

  /// Whole days between the todo's due date and [now], counted on UTC
  /// midnights so a DST transition can't turn a 1-day slip into 0 (the same
  /// subtraction apiary_visit_recency.dart documents).
  ///
  /// `dueDate!` is safe by construction: [todoDueBucket] returns null without
  /// a due date, so an [AttentionTodo] always has one — a null here would be
  /// a programming error, and `??` would silently render a wrong number
  /// instead of surfacing it (home_summary.dart's `_dueDate` says the same).
  int _daysLate(Todo todo) {
    final due = DateTime.parse(todo.dueDate!);
    return DateTime.utc(
      now.year,
      now.month,
      now.day,
    ).difference(DateTime.utc(due.year, due.month, due.day)).inDays;
  }
}

/// D-35's "open journeys" section (FR-JO-1).
class _JourneysSection extends StatelessWidget {
  const _JourneysSection({required this.section});

  final HomeSummarySection<Journey> section;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return _HomeSection(
      sectionKey: const Key('home-journeys-section'),
      countKey: const Key('home-journeys-count'),
      title: l10n.homeJourneysSectionTitle,
      count: section.count,
      countLabel: l10n.homeJourneysCountLabel(section.count),
      countUrgent: false,
      rows: [
        for (final journey in section.preview)
          BrandRowCard(
            key: Key('home-journey-${journey.id}'),
            title: journey.name,
            // The main activity type, exactly as the Journeys tab's own rows
            // subtitle themselves (journeys_list_screen.dart).
            subtitle:
                activityTypeLabel(l10n, journey.mainActivityType) ??
                journey.mainActivityType,
            onTap: () => context.go('/journeys/${journey.id}'),
          ),
      ],
      footer: _SectionFooterLink(
        buttonKey: const Key('home-journeys-view-all'),
        label: l10n.homeJourneysViewAllAction,
        // D-35's "filtered to the same set", exactly: this section IS the
        // open journeys ([Journey.isOpen]), and `?status=open` is the same
        // predicate expressed in the Journeys tab's own status filter
        // (added for this link — the tab had no status control before).
        onPressed: () => context.go('/journeys?status=$journeyStatusOpen'),
      ),
    );
  }
}

/// D-35's "apiaries not visited recently" section (FR-AP-2).
///
/// Deliberately has **no "view all" link**: D-35 scopes this section to
/// tapping through to the record, and no list screen currently offers the
/// same not-visited-recently filter to hand off to.
class _StaleApiariesSection extends StatelessWidget {
  const _StaleApiariesSection({required this.section});

  final HomeSummarySection<ApiaryVisitRecency> section;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final formatting = LocaleFormatting.of(context);

    return _HomeSection(
      sectionKey: const Key('home-apiaries-section'),
      countKey: const Key('home-apiaries-count'),
      title: l10n.homeApiariesSectionTitle,
      count: section.count,
      countLabel: l10n.homeApiariesCountLabel(section.count),
      countUrgent: false,
      rows: [
        for (final recency in section.preview)
          BrandRowCard(
            key: Key('home-apiary-${recency.apiary.id}'),
            title: recency.apiary.name,
            subtitle: _apiarySubtitle(l10n, formatting, recency),
            trailing: _apiaryBadge(l10n, recency),
            onTap: () => context.go('/apiaries/${recency.apiary.id}'),
          ),
      ],
    );
  }

  /// Never-visited is its own sentence, never "0 days ago"
  /// ([ApiaryVisitRecency.lastVisitedAt]'s own contract).
  static String _apiarySubtitle(
    AppLocalizations l10n,
    LocaleFormatting formatting,
    ApiaryVisitRecency recency,
  ) {
    final lastVisit = recency.lastVisitedAt;
    if (lastVisit == null) return l10n.homeApiaryNeverVisitedSubtitle;
    return l10n.homeApiaryLastVisitSubtitle(formatting.date(lastVisit));
  }

  /// Built from the carried [ApiaryVisitRecency.daysSinceLastVisit] — this
  /// widget re-derives no date difference of its own.
  static Widget _apiaryBadge(
    AppLocalizations l10n,
    ApiaryVisitRecency recency,
  ) {
    final badgeKey = Key('home-apiary-badge-${recency.apiary.id}');
    final days = recency.daysSinceLastVisit;
    if (recency.neverVisited || days == null) {
      return _AttentionBadge(
        badgeKey: badgeKey,
        icon: Icons.event_busy_outlined,
        label: l10n.homeApiaryNeverVisitedBadge,
        semanticLabel: l10n.homeApiaryNeverVisitedSubtitle,
        urgent: false,
      );
    }
    return _AttentionBadge(
      badgeKey: badgeKey,
      icon: Icons.schedule,
      label: l10n.homeApiaryStaleBadge(days),
      semanticLabel: l10n.homeApiaryStaleLabel(days),
      urgent: false,
    );
  }
}

/// The shape every Home section shares: a [SectionHeader] with a count badge
/// beside it, the preview rows, and an optional footer link.
///
/// Rows sit on the screen background as [BrandRowCard]s rather than inside a
/// card container: nesting a white bordered row card inside a white bordered
/// section card renders the two hairlines against each other and loses the
/// row separation entirely. The header-plus-row-cards grouping is the same
/// visual language the apiaries/journeys/todos tabs already use.
class _HomeSection extends StatelessWidget {
  const _HomeSection({
    required this.sectionKey,
    required this.countKey,
    required this.title,
    required this.count,
    required this.countLabel,
    required this.countUrgent,
    required this.rows,
    this.footer,
  });

  final Key sectionKey;
  final Key countKey;
  final String title;

  /// The FULL matching count — deliberately not `rows.length`, which is
  /// capped at [kHomePreviewLimit].
  final int count;

  /// The spoken expansion of [count] (the badge itself shows the bare
  /// number, which alone would announce as a meaningless digit).
  final String countLabel;

  final bool countUrgent;
  final List<Widget> rows;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    return Column(
      key: sectionKey,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: SectionHeader(title)),
            const SizedBox(width: 8),
            _CountBadge(
              badgeKey: countKey,
              count: count,
              semanticLabel: countLabel,
              urgent: countUrgent,
            ),
          ],
        ),
        const SizedBox(height: 10),
        for (var i = 0; i < rows.length; i++) ...[
          if (i > 0) const SizedBox(height: BrandDimens.gapCard),
          rows[i],
        ],
        // The footer link's own 48px tap box would otherwise butt straight up
        // against the last row card's, and a slightly-off tap meant for the
        // bottom row would navigate away from Home instead. FR-UX-1's
        // "forgiving spacing" (accessibility-field-ux-checklist.md) asks for
        // at least 8px between adjacent tap targets; the row cards already
        // keep [BrandDimens.gapCard] from each other.
        if (footer != null) ...[const SizedBox(height: 8), footer!],
      ],
    );
  }
}

/// A section's count pill. Urgent sections use the theme's error container
/// (the same treatment `_OverdueBadge` uses on the Todos tab); the rest use
/// the muted secondary container, since "open" and "not visited recently"
/// are states to notice, not alarms.
class _CountBadge extends StatelessWidget {
  const _CountBadge({
    required this.badgeKey,
    required this.count,
    required this.semanticLabel,
    required this.urgent,
  });

  final Key badgeKey;
  final int count;
  final String semanticLabel;
  final bool urgent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final background = urgent
        ? theme.colorScheme.errorContainer
        : theme.colorScheme.secondaryContainer;
    final foreground = urgent
        ? theme.colorScheme.onErrorContainer
        : theme.colorScheme.onSecondaryContainer;

    return Semantics(
      label: semanticLabel,
      child: ExcludeSemantics(
        child: Container(
          key: badgeKey,
          constraints: const BoxConstraints(minWidth: 28),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(BrandDimens.radiusBadge),
          ),
          child: Text(
            '$count',
            textAlign: TextAlign.center,
            style: theme.textTheme.labelLarge?.copyWith(
              color: foreground,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

/// A row's trailing badge — icon **and** text together, never colour alone
/// (WCAG 2.2 AA 1.4.1), so it survives greyscale and a gloved glance. Follows
/// `_OverdueBadge` (todo_list_widgets.dart), with [semanticLabel] spelling
/// out the abbreviated visual text for a screen reader.
class _AttentionBadge extends StatelessWidget {
  const _AttentionBadge({
    required this.badgeKey,
    required this.icon,
    required this.label,
    required this.semanticLabel,
    required this.urgent,
  });

  final Key badgeKey;
  final IconData icon;
  final String label;
  final String semanticLabel;
  final bool urgent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final background = urgent
        ? theme.colorScheme.errorContainer
        : theme.colorScheme.surfaceContainerHighest;
    final foreground = urgent
        ? theme.colorScheme.onErrorContainer
        : theme.colorScheme.onSurfaceVariant;

    return Semantics(
      label: semanticLabel,
      child: ExcludeSemantics(
        child: Container(
          key: badgeKey,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(BrandDimens.radiusBadge),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: foreground),
              const SizedBox(width: 4),
              Text(
                label,
                style: theme.textTheme.labelSmall?.copyWith(color: foreground),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A section's "view all" link into the owning list screen — the same
/// left-aligned [TextButton] history_section.dart uses for the identical
/// affordance.
class _SectionFooterLink extends StatelessWidget {
  const _SectionFooterLink({
    required this.buttonKey,
    required this.label,
    required this.onPressed,
  });

  final Key buttonKey;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: TextButton(
        key: buttonKey,
        onPressed: onPressed,
        child: Text(label),
      ),
    );
  }
}

/// Home when the local store could not be read at all
/// ([HomeSummaryState.unavailable], #658 review).
///
/// **Deliberately not an error dump.** It borrows the notify-and-fix
/// vocabulary the app already uses for this class of problem — the plain,
/// non-technical sentence-plus-remedy of `sync_needs_fix_screen.dart` — and
/// interpolates no exception: nothing the user can do with a `StateError`
/// justifies putting one on the landing screen. The header's sync pill is no
/// substitute; it reports *connection* state, and a dead local store is
/// perfectly compatible with being online.
///
/// Offers no action. Unlike a rejected write there is no specific record to
/// fix, and unlike first-run there is nothing safe to create — a write into a
/// store that will not open cannot be honoured.
///
/// Scrollable and centred for the same reason [_AllClearState] is: at high
/// text scales the message outgrows a 375x667 viewport, and a bare
/// [EmptyState] is a fixed [Column] that would clip it (FR-AX-1).
class _UnavailableState extends StatelessWidget {
  const _UnavailableState();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return Center(
      child: SingleChildScrollView(
        key: const Key('home-unavailable'),
        child: EmptyState(
          message: l10n.homeUnavailableMessage,
          icon: Icons.cloud_off_outlined,
        ),
      ),
    );
  }
}

/// The same admission, reduced to one line, for when SOME sections did
/// resolve (#658 review): those are still worth showing, but what is missing
/// — or frozen, since an `AsyncError` keeps its last value — must not read as
/// "nothing there".
///
/// Toned like the shell's `_OfflineBanner`/`_NeedsFixBanner` family: an icon
/// paired with text, never colour alone (WCAG 2.2 AA 1.4.1), on the theme's
/// muted surface rather than the error container — this is a "some of this
/// may be stale" notice, not an alarm about the rows below it.
class _UnavailableNotice extends StatelessWidget {
  const _UnavailableNotice();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Container(
        key: const Key('home-unavailable-notice'),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BrandDimens.borderCard,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.cloud_off_outlined,
              size: 18,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                l10n.homeUnavailableNotice,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// D-35's first-run state: the org owns nothing at all, so Home is one
/// message and exactly one action — never three empty sections, and never a
/// section header.
class _FirstRunState extends StatelessWidget {
  const _FirstRunState();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return Center(
      child: SingleChildScrollView(
        key: const Key('home-first-run'),
        padding: const EdgeInsets.symmetric(horizontal: BrandDimens.gutter),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            EmptyState(
              message: l10n.homeFirstRunMessage,
              icon: Icons.hive_outlined,
            ),
            PrimaryActionButton(
              key: const Key('home-first-run-action'),
              label: l10n.homeFirstRunAction,
              icon: Icons.add,
              onPressed: () => context.go('/apiaries/new'),
            ),
          ],
        ),
      ),
    );
  }
}

/// D-35's all-clear state: the org has data, but nothing matched a section.
///
/// Quieter than [_FirstRunState] — no action, since there is nothing to do —
/// and it names the recency window (from [apiaryVisitRecencyDays], never a
/// hardcoded "30") so the threshold behind "not visited recently" is
/// discoverable rather than folklore.
///
/// Scrollable for the same reason [_FirstRunState] is: its message is the
/// longest string on Home (three clauses plus the window), and at 2x text
/// scale on a 375x667 phone it is taller than the viewport — a bare
/// [EmptyState] is a fixed [Column] and clips the tail of the sentence
/// instead of letting the user reach it (FR-AX-1's increased-text-scale bar,
/// accessibility-field-ux-checklist.md). [Center] keeps it vertically
/// centred at the scales where it does fit.
class _AllClearState extends StatelessWidget {
  const _AllClearState();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return Center(
      child: SingleChildScrollView(
        key: const Key('home-all-clear'),
        child: EmptyState(
          message: l10n.homeAllClearMessage(apiaryVisitRecencyDays),
          icon: Icons.check_circle_outline,
        ),
      ),
    );
  }
}
