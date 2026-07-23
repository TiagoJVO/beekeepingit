import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/auth/auth_controller.dart';
import '../core/sync/powersync_schema.dart';
import '../features/account/account_screen.dart';
import '../features/activities/activities_list_screen.dart';
import '../features/activities/activity_detail_screen.dart';
import '../features/activities/add_activity_screen.dart';
import '../features/apiaries/apiaries_list_screen.dart';
import '../features/apiaries/apiary_activities_screen.dart';
import '../features/apiaries/apiary_detail_screen.dart';
import '../features/apiaries/apiary_form_screen.dart';
import '../features/auth/login_screen.dart';
import '../features/history/history_screen.dart';
import '../features/journeys/journey_detail_screen.dart';
import '../features/journeys/journey_form_screen.dart';
import '../features/journeys/journey_stats_detail_screen.dart';
import '../features/journeys/journeys_list_screen.dart';
import '../features/members/members_screen.dart';
import '../features/organization/organization_repository.dart';
import '../features/organization/organization_screen.dart';
import '../features/profile/profile_repository.dart';
import '../features/profile/profile_screen.dart';
import '../features/sync/sync_needs_fix_screen.dart';
import '../features/todos/todo_detail_screen.dart';
import '../features/todos/todo_form_screen.dart';
import '../features/todos/todos_list_screen.dart';
import '../l10n/gen/app_localizations.dart';
import '../shell/app_shell.dart';
import '../shell/coming_soon_screen.dart';

final _apiariesBranchKey = GlobalKey<NavigatorState>(
  debugLabel: 'apiariesBranch',
);
final _activitiesBranchKey = GlobalKey<NavigatorState>(
  debugLabel: 'activitiesBranch',
);
final _journeysBranchKey = GlobalKey<NavigatorState>(
  debugLabel: 'journeysBranch',
);
final _todosBranchKey = GlobalKey<NavigatorState>(debugLabel: 'todosBranch');
final _assistantBranchKey = GlobalKey<NavigatorState>(
  debugLabel: 'assistantBranch',
);

/// App routing for the walking-skeleton slice plus profile (FR-ONB-1, #25),
/// organization (FR-ONB-2, FR-TEN-2, NFR-ROL-1, #26) onboarding enforcement,
/// and account settings (FR-AU-1, #29). Unauthenticated users are sent to
/// /login; once logged in, an incomplete profile is routed to /profile; once
/// the profile is complete but there's no organization yet, /organization/new;
/// both gates block every other route (AC bullet 3) until satisfied. Once both
/// are done, the apiaries list is home. /organization/members (#27,
/// admin-only server-side) and /account (#29) are reachable once onboarded —
/// neither is part of the onboarding gate itself, just normal authenticated
/// routes. Exposed as a provider so widget tests can override
/// auth/profile/organization.
final routerProvider = Provider<GoRouter>((ref) {
  // Re-evaluate redirects whenever auth, the profile fetch, or the
  // organization fetch itself changes (listening to the raw providers, not
  // their derived completeness bools, so a loading->resolved transition
  // always re-triggers redirect even when the resolved value happens to
  // equal the loading-time default — see profileProvider's own note).
  final refresh = ValueNotifier<int>(0);
  ref.onDispose(refresh.dispose);
  ref.listen(isAuthenticatedProvider, (_, __) => refresh.value++);
  ref.listen(profileProvider, (_, __) => refresh.value++);
  ref.listen(organizationProvider, (_, __) => refresh.value++);

  return GoRouter(
    initialLocation: '/apiaries',
    refreshListenable: refresh,
    redirect: (context, state) {
      final authed = ref.read(isAuthenticatedProvider);
      final atLogin = state.matchedLocation == '/login';
      if (!authed) return atLogin ? null : '/login';
      if (atLogin) return '/apiaries';

      final atProfile = state.matchedLocation == '/profile';
      final profileAsync = ref.read(profileProvider);
      // Don't gate on an unresolved fetch — wait for the real answer rather
      // than bouncing to /profile (or getting stuck there) on a loading
      // flicker; the listen above re-runs this once the fetch settles.
      if (profileAsync.isLoading) return null;
      final profileComplete = profileAsync.value?.profileComplete ?? false;
      if (!profileComplete) return atProfile ? null : '/profile';

      final atOrganization = state.matchedLocation == '/organization/new';
      final organizationAsync = ref.read(organizationProvider);
      // Same "don't gate on loading" rule as the profile check above: only
      // react once the fetch has actually resolved, one way or the other.
      if (organizationAsync.isLoading) return null;
      final hasOrganization = organizationAsync.value != null;
      if (!hasOrganization) {
        return atOrganization ? null : '/organization/new';
      }
      if (atOrganization) return '/apiaries';

      return null;
    },
    routes: [
      GoRoute(
        path: '/login',
        name: 'login',
        builder: (context, state) => const LoginScreen(),
      ),
      GoRoute(
        path: '/profile',
        name: 'profile',
        builder: (context, state) => const ProfileScreen(),
      ),
      GoRoute(
        path: '/organization/new',
        name: 'organizationNew',
        builder: (context, state) => const OrganizationScreen(),
      ),
      GoRoute(
        path: '/organization/members',
        name: 'organizationMembers',
        builder: (context, state) => const MembersScreen(),
      ),
      GoRoute(
        path: '/account',
        name: 'account',
        builder: (context, state) => const AccountScreen(),
      ),
      // The needs-fix list (EPIC-06 #7, D-12 notify-and-fix): offline writes
      // the server permanently rejected, retained in the local dead-letter so
      // the user can fix & re-queue them. A normal authenticated route (not
      // part of the onboarding gate), reached from the account screen, the
      // header badge, and the rejection toast's "Fix" action.
      GoRoute(
        path: '/sync-needs-fix',
        name: 'syncNeedsFix',
        builder: (context, state) => const SyncNeedsFixScreen(),
      ),
      // The app shell (FR-UX-2, #197): 5-tab bottom nav, each tab its own
      // navigation stack via StatefulShellRoute.indexedStack. Only Apiaries
      // has real screens this milestone (M2) — Activities/Journeys/Todos are
      // M3/M4/M5, Assistant is M8 (docs/design/prototype.md's feature->
      // backlog map), so those four branches host a single honest
      // ComingSoonScreen placeholder rather than faked functionality.
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) =>
            AppShell(navigationShell: navigationShell),
        branches: [
          StatefulShellBranch(
            navigatorKey: _apiariesBranchKey,
            routes: [
              GoRoute(
                path: '/apiaries',
                name: 'apiaries',
                builder: (context, state) => const ApiariesListScreen(),
                routes: [
                  GoRoute(
                    path: 'new',
                    name: 'apiaryNew',
                    builder: (context, state) => const ApiaryFormScreen(),
                  ),
                  GoRoute(
                    path: ':id',
                    name: 'apiaryDetail',
                    builder: (context, state) => ApiaryDetailScreen(
                      apiaryId: state.pathParameters['id']!,
                    ),
                    routes: [
                      GoRoute(
                        path: 'edit',
                        name: 'apiaryEdit',
                        builder: (context, state) => ApiaryFormScreen(
                          apiaryId: state.pathParameters['id'],
                        ),
                      ),
                      // Full per-apiary activities list (#42, FR-AC-5):
                      // reached from the detail page's embedded preview once
                      // it caps. A properly-virtualized full-height list, so
                      // it scales to however many activities an apiary has —
                      // unlike the shrink-wrapped preview it links out from.
                      GoRoute(
                        path: 'activities',
                        name: 'apiaryActivities',
                        builder: (context, state) => ApiaryActivitiesScreen(
                          apiaryId: state.pathParameters['id']!,
                        ),
                      ),
                      // Add-activity entry point (#39, FR-AC-2): reachable
                      // from the apiary detail page.
                      GoRoute(
                        path: 'activities/new',
                        name: 'activityNew',
                        builder: (context, state) => AddActivityScreen(
                          apiaryId: state.pathParameters['id']!,
                        ),
                      ),
                      // Activity detail (#310, FR-AC-3/5/6, FR-TEN-2): the
                      // read-only view a tappable list row (per-apiary section
                      // or the main Activities tab) now opens, from which
                      // Edit/Delete are reached. Edit/delete themselves shipped
                      // earlier (#40/#41) reachable by direct route only; the
                      // edit form stays nested UNDER this detail route so its
                      // full path (`.../activities/:activityId/edit`) and
                      // `activityEdit` name are unchanged — no existing deep
                      // link breaks.
                      // Full per-apiary change history (#60, FR-HIS-1): the
                      // uncapped counterpart of the detail page's embedded
                      // HistorySection, same preview-then-full-screen split
                      // as `activities` above and for the same reason (a
                      // shrink-wrapped preview can't virtualize).
                      GoRoute(
                        path: 'history',
                        name: 'apiaryHistory',
                        builder: (context, state) => HistoryScreen(
                          entityType: apiaryEntityType,
                          entityId: state.pathParameters['id']!,
                        ),
                      ),
                      GoRoute(
                        path: 'activities/:activityId',
                        name: 'activityDetail',
                        builder: (context, state) => ActivityDetailScreen(
                          apiaryId: state.pathParameters['id']!,
                          activityId: state.pathParameters['activityId']!,
                        ),
                        routes: [
                          GoRoute(
                            path: 'edit',
                            name: 'activityEdit',
                            builder: (context, state) => AddActivityScreen(
                              apiaryId: state.pathParameters['id']!,
                              activityId: state.pathParameters['activityId']!,
                            ),
                          ),
                          // Per-activity change history (#60, FR-HIS-1) —
                          // the same generic screen the apiary route above
                          // uses, differing only in the entity type it is
                          // pointed at.
                          GoRoute(
                            path: 'history',
                            name: 'activityHistory',
                            builder: (context, state) => HistoryScreen(
                              entityType: activityEntityType,
                              entityId: state.pathParameters['activityId']!,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            navigatorKey: _activitiesBranchKey,
            routes: [
              // The main Activities tab (#43, FR-AC-6): every activity
              // across every apiary in the org, filterable by type/date
              // range. Per-apiary activity lists (#42) render on the apiary
              // detail page instead (apiaries branch above), not here.
              GoRoute(
                path: '/activities',
                name: 'activities',
                builder: (context, state) => const ActivitiesListScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            navigatorKey: _journeysBranchKey,
            routes: [
              // The main Journeys tab (#45, FR-JO-4): every journey in the
              // org, unfiltered (date-range/type filtering is #47). Replaces
              // the M4 ComingSoonScreen placeholder.
              GoRoute(
                path: '/journeys',
                name: 'journeys',
                builder: (context, state) => const JourneysListScreen(),
                routes: [
                  GoRoute(
                    path: 'new',
                    name: 'journeyNew',
                    builder: (context, state) => const JourneyFormScreen(),
                  ),
                  // Journey detail (#48, FR-JO-3, D-21): apiaries visited,
                  // per-apiary activities (attributed via stored journey_id),
                  // and the #49 stats section — reached by tapping a list
                  // row. Edit/close/delete stay on the existing form, nested
                  // UNDER this route so its full path
                  // (`.../:id/edit`) and `journeyEdit` name are unchanged —
                  // no existing deep link breaks (mirrors activityDetail's
                  // own edit-nesting precedent above).
                  GoRoute(
                    path: ':id',
                    name: 'journeyDetail',
                    builder: (context, state) => JourneyDetailScreen(
                      journeyId: state.pathParameters['id']!,
                    ),
                    routes: [
                      GoRoute(
                        path: 'edit',
                        name: 'journeyEdit',
                        builder: (context, state) => JourneyFormScreen(
                          journeyId: state.pathParameters['id']!,
                        ),
                      ),
                      // "More stats" per-apiary breakdown (#391) — a sibling
                      // of `edit`, same nesting precedent (full path
                      // `.../:id/stats`, reached from the #49 stats
                      // section's own "More stats" button).
                      GoRoute(
                        path: 'stats',
                        name: 'journeyStats',
                        builder: (context, state) => JourneyStatsDetailScreen(
                          journeyId: state.pathParameters['id']!,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            navigatorKey: _todosBranchKey,
            routes: [
              GoRoute(
                path: '/todos',
                name: 'todos',
                builder: (context, state) => const TodosListScreen(),
                routes: [
                  // Standalone create entry point (#293): reachable by
                  // direct navigation/deep-linking. #52's own quick-create
                  // is a bottom sheet, not a route, so there is no naming
                  // collision — this route exists independently of that
                  // story's own Todos-tab FAB.
                  GoRoute(
                    path: 'new',
                    name: 'todoNew',
                    builder: (context, state) => const TodoFormScreen(),
                  ),
                  // Todo detail (#293, FR-TD-1, FR-HIS-1): every field,
                  // read-only, plus a complete/reopen toggle — reached by
                  // tapping a row on the main Todos tab. Edit stays nested
                  // UNDER this route (mirrors activityDetail's/
                  // journeyDetail's own edit-nesting precedent above) so its
                  // full path (`.../:id/edit`) and `todoEdit` name are
                  // stable.
                  GoRoute(
                    path: ':id',
                    name: 'todoDetail',
                    builder: (context, state) =>
                        TodoDetailScreen(todoId: state.pathParameters['id']!),
                    routes: [
                      GoRoute(
                        path: 'edit',
                        name: 'todoEdit',
                        builder: (context, state) =>
                            TodoFormScreen(todoId: state.pathParameters['id']),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            navigatorKey: _assistantBranchKey,
            routes: [
              GoRoute(
                path: '/assistant',
                name: 'assistant',
                builder: (context, state) => ComingSoonScreen(
                  icon: Icons.forum_outlined,
                  title: AppLocalizations.of(context).assistantComingSoon,
                ),
              ),
            ],
          ),
        ],
      ),
    ],
  );
});
