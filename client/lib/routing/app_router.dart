import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/auth/auth_controller.dart';
import '../features/apiaries/apiaries_list_screen.dart';
import '../features/apiaries/apiary_form_screen.dart';
import '../features/auth/login_screen.dart';
import '../features/profile/profile_repository.dart';
import '../features/profile/profile_screen.dart';

/// App routing for the walking-skeleton slice plus profile onboarding
/// enforcement (FR-ONB-1, #25). Unauthenticated users are sent to /login;
/// once logged in, an incomplete profile is routed to /profile and blocked
/// from everything else (AC bullet 3); once complete, the apiaries list is
/// home. Exposed as a provider so widget tests can override auth/profile.
final routerProvider = Provider<GoRouter>((ref) {
  // Re-evaluate redirects whenever auth or the profile fetch itself changes
  // (listening to profileProvider directly, not the derived completeness
  // bool, so a loading->resolved transition always re-triggers redirect even
  // when the resolved value happens to equal the loading-time default).
  final refresh = ValueNotifier<int>(0);
  ref.onDispose(refresh.dispose);
  ref.listen(isAuthenticatedProvider, (_, __) => refresh.value++);
  ref.listen(profileProvider, (_, __) => refresh.value++);

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
