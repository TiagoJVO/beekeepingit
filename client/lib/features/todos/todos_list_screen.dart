import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'todo_filters.dart';
import 'todo_list_widgets.dart';

/// The main Todos tab (#53, FR-TD-1): every todo in the caller's
/// organization, offline-first over the local synced set
/// ([todosStreamProvider] — see todos_repository.dart's own doc on how
/// FR-TEN-2 scoping is enforced), filterable by status/priority/due date
/// (combinable, #53 AC) and sortable by due date, priority or status (#53
/// AC), distinguishing open/overdue/done rows (#53 AC).
///
/// No own AppBar/Scaffold — like ActivitiesListScreen/JourneysListScreen,
/// this is the Todos tab's root content within the app shell,
/// which supplies the header. No create FAB yet either — that's #52's job,
/// additive later (this screen's own empty state handles "no todos" on its
/// own in the meantime, mirroring how the Journeys tab's own list shipped
/// ahead of some of its own create-related stories in the same epic
/// sequence).
///
/// **Why the route's filter is seeded HERE, from inside the mounted screen
/// (#658, D-35):** the filter/sort state lives in `autoDispose` providers
/// (todo_filters.dart), so a caller that wrote them before navigating
/// (`ref.read(...).state = ...; context.go('/todos')`) would have its value
/// thrown away — at that instant nothing listens to them, and the provider
/// is disposed before this screen ever subscribes. The filter therefore
/// travels as a query parameter on the route (the same way `/todos/new`
/// carries `?apiaryId=`) and is applied from inside this screen, once
/// mounted and watching, on every arrival at the tab
/// ([_TodosListScreenState._seedFiltersOnArrival]).
class TodosListScreen extends ConsumerStatefulWidget {
  const TodosListScreen({
    super.key,
    this.initialStatusFilter,
    this.initialDueFilter,
  });

  /// The status filter this screen was routed with (`?status=`, parsed by
  /// [todoStatusFilterFromName]), or null to keep the tab's own current
  /// selection — which is also what an unknown/garbage parameter value
  /// yields, so a bad deep link degrades to the default filter rather than
  /// throwing.
  final TodoStatusFilter? initialStatusFilter;

  /// The due-date filter this screen was routed with (`?due=`), same
  /// null-means-leave-alone contract as [initialStatusFilter].
  final TodoDueFilter? initialDueFilter;

  @override
  ConsumerState<TodosListScreen> createState() => _TodosListScreenState();
}

class _TodosListScreenState extends ConsumerState<TodosListScreen> {
  /// Whether this tab is the shell's visible branch — go_router disables
  /// [TickerMode] on the offstage branches of a
  /// [StatefulShellRoute.indexedStack], so this doubles as "am I the
  /// foreground tab" (the same signal apiaries_list_screen.dart gates its
  /// GPS polling on). Tracked from [didChangeDependencies], which re-runs on
  /// every tab switch because the value is inherited.
  bool _tabVisible = true;

  /// Whether the route's filter has already been applied during the CURRENT
  /// visit to this tab. Cleared whenever the tab goes offstage, so the next
  /// arrival re-applies it even when the URL is byte-for-byte the one this
  /// screen was last built with — see [_seedFiltersOnArrival].
  bool _seededThisVisit = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tabVisible = TickerMode.valuesOf(context).enabled;
    _seedFiltersOnArrival();
  }

  @override
  void didUpdateWidget(covariant TodosListScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A different parameter set is a new instruction even without leaving
    // the tab (a second deep link carrying another status), so it reopens
    // the seeding for this visit.
    if (widget.initialStatusFilter != oldWidget.initialStatusFilter ||
        widget.initialDueFilter != oldWidget.initialDueFilter) {
      _seededThisVisit = false;
    }
    _seedFiltersOnArrival();
  }

  /// Seeds once per ARRIVAL at this tab, not once per parameter CHANGE.
  ///
  /// The Todos branch stays mounted across tab switches (the shell's
  /// [StatefulShellRoute.indexedStack]), so this [State] — and with it the
  /// filter the user last chose — outlives any single visit and [initState]
  /// only ever runs once. Seeding on a changed parameter alone therefore
  /// missed the ordinary repeat: Home's "view all" → `?status=overdue`, the
  /// user widens the filter, goes back to Home, taps the SAME link — the new
  /// parameter equals the old one, nothing re-seeds, and the list contradicts
  /// the count that was just tapped. (The Todos tab's own bottom-nav
  /// destination hides this, because `goBranch(initialLocation: true)` resets
  /// the branch to a parameterless `/todos` first.)
  ///
  /// Keyed on tab visibility rather than on the URL: leaving the tab ends the
  /// visit, and the next time this branch comes onstage its parameters are
  /// applied again, whatever they are. An incidental rebuild — a provider
  /// update, or another branch navigating — neither ends the visit nor
  /// changes the parameters, so it still can't snap back a filter the user
  /// has since adjusted.
  ///
  /// Arriving with NO parameters (the bottom-nav `/todos`) deliberately
  /// leaves the current filter alone rather than resetting it: a route that
  /// says nothing about the filter makes no claim about it, and the filter
  /// bar shows the active selection either way. Filters chosen by hand
  /// survive a tab switch for the same reason.
  void _seedFiltersOnArrival() {
    if (!_tabVisible) {
      // Offstage: the visit is over, so the next one seeds again.
      _seededThisVisit = false;
      return;
    }
    if (_seededThisVisit) return;
    _seededThisVisit = true;
    // Scheduled rather than applied synchronously: both call sites run
    // inside the build phase, where mutating a provider is not allowed (the
    // same reason add_activity_screen.dart defers its own prefill). The
    // parameters are read in the callback, not captured here, so it always
    // applies the newest ones no matter which call site scheduled it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _seedFiltersFromRoute();
    });
  }

  /// Applies whichever filters the route carried onto the tab's own filter
  /// state. Deliberately a WRITE into the same providers the filter bar
  /// drives (rather than a parallel "route filter" the bar doesn't know
  /// about): the controls then visibly show the seeded selection, and
  /// "clear filters" clears it like any other.
  void _seedFiltersFromRoute() {
    final status = widget.initialStatusFilter;
    final due = widget.initialDueFilter;
    if (status != null) {
      ref.read(todoStatusFilterProvider.notifier).state = status;
    }
    if (due != null) {
      ref.read(todoDueFilterProvider.notifier).state = due;
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(todoStatusFilterProvider);
    final priority = ref.watch(todoPriorityFilterProvider);
    final due = ref.watch(todoDueFilterProvider);
    final sortField = ref.watch(todoSortFieldProvider);
    final sortDirection = ref.watch(todoSortDirectionProvider);
    final viewModel = ref.watch(todosViewModelProvider);

    return Column(
      children: [
        TodoFilterBar(
          status: status,
          priority: priority,
          due: due,
          sortField: sortField,
          sortDirection: sortDirection,
          onStatusChanged: (v) =>
              ref.read(todoStatusFilterProvider.notifier).state = v,
          onPriorityChanged: (v) =>
              ref.read(todoPriorityFilterProvider.notifier).state = v,
          onDueChanged: (v) =>
              ref.read(todoDueFilterProvider.notifier).state = v,
          onSortFieldChanged: (field) {
            // Switching the sort field resets the direction to that field's
            // own sensible default (todo_filters.dart's
            // `defaultSortDirectionFor`) rather than keeping whatever
            // direction the PREVIOUS field happened to be on — e.g. leaving
            // a lingering "descending" from priority when switching to due
            // date would silently show latest-due-first instead of the
            // expected soonest-first.
            ref.read(todoSortFieldProvider.notifier).state = field;
            ref.read(todoSortDirectionProvider.notifier).state =
                defaultSortDirectionFor(field);
          },
          onSortDirectionToggle: () =>
              ref
                  .read(todoSortDirectionProvider.notifier)
                  .state = sortDirection == SortDirection.ascending
              ? SortDirection.descending
              : SortDirection.ascending,
          onClearFilters: () {
            ref.read(todoStatusFilterProvider.notifier).state =
                TodoStatusFilter.all;
            ref.read(todoPriorityFilterProvider.notifier).state = null;
            ref.read(todoDueFilterProvider.notifier).state = TodoDueFilter.any;
          },
        ),
        Expanded(child: TodoListView(viewModel: viewModel)),
      ],
    );
  }
}
