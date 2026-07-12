import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/auth/auth_controller.dart';
import '../features/account/account_screen.dart';
import '../features/apiaries/apiaries_list_screen.dart';
import '../features/apiaries/apiary_form_screen.dart';
import '../features/apiaries/apiary_map_screen.dart';
import '../features/auth/login_screen.dart';
import '../features/members/members_screen.dart';
import '../features/organization/organization_repository.dart';
import '../features/organization/organization_screen.dart';
import '../features/profile/profile_repository.dart';
import '../features/profile/profile_screen.dart';
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
                    path: 'map',
                    name: 'apiaryMap',
                    builder: (context, state) => const ApiaryMapScreen(),
                  ),
                  GoRoute(
                    path: ':id',
                    name: 'apiaryEdit',
                    builder: (context, state) =>
                        ApiaryFormScreen(apiaryId: state.pathParameters['id']),
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            navigatorKey: _activitiesBranchKey,
            routes: [
              GoRoute(
                path: '/activities',
                name: 'activities',
                builder: (context, state) => ComingSoonScreen(
                  icon: Icons.event_note_outlined,
                  title: AppLocalizations.of(context).activitiesComingSoon,
                ),
              ),
            ],
          ),
          StatefulShellBranch(
            navigatorKey: _journeysBranchKey,
            routes: [
              GoRoute(
                path: '/journeys',
                name: 'journeys',
                builder: (context, state) => ComingSoonScreen(
                  icon: Icons.route_outlined,
                  title: AppLocalizations.of(context).journeysComingSoon,
                ),
              ),
            ],
          ),
          StatefulShellBranch(
            navigatorKey: _todosBranchKey,
            routes: [
              GoRoute(
                path: '/todos',
                name: 'todos',
                builder: (context, state) => ComingSoonScreen(
                  icon: Icons.task_alt_outlined,
                  title: AppLocalizations.of(context).todosComingSoon,
                ),
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
