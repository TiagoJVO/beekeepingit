import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/auth/auth_controller.dart';
import '../features/account/account_screen.dart';
import '../features/apiaries/apiaries_list_screen.dart';
import '../features/apiaries/apiary_form_screen.dart';
import '../features/auth/login_screen.dart';
import '../features/members/members_screen.dart';
import '../features/organization/organization_repository.dart';
import '../features/organization/organization_screen.dart';
import '../features/profile/profile_repository.dart';
import '../features/profile/profile_screen.dart';

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
      GoRoute(
        path: '/apiaries',
        name: 'apiaries',
        builder: (context, state) => const ApiariesListScreen(),
      ),
      GoRoute(
        path: '/apiaries/new',
        name: 'apiaryNew',
        builder: (context, state) => const ApiaryFormScreen(),
      ),
      GoRoute(
        path: '/apiaries/:id',
        name: 'apiaryEdit',
        builder: (context, state) =>
            ApiaryFormScreen(apiaryId: state.pathParameters['id']),
      ),
    ],
  );
});
