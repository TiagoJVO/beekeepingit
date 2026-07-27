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
/// this is the Todos tab's root content within the app shell
/// (app_router.dart wires it in place of the placeholder ComingSoonScreen),
/// which supplies the header. No create FAB yet either — that's #52's job,
/// additive later (this screen's own empty state handles "no todos" on its
/// own in the meantime, mirroring how the Journeys tab's own list shipped
/// ahead of some of its own create-related stories in the same epic
/// sequence).
class TodosListScreen extends ConsumerWidget {
  const TodosListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
