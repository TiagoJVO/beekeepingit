import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/auth/auth_controller.dart';
import '../features/apiaries/apiaries_list_screen.dart';
import '../features/apiaries/apiary_form_screen.dart';
import '../features/auth/login_screen.dart';

/// App routing for the walking-skeleton slice. Unauthenticated users are sent
/// to /login; once logged in, the apiaries list is home. Exposed as a provider
/// so widget tests can override auth.
final routerProvider = Provider<GoRouter>((ref) {
  // Re-evaluate redirects whenever auth changes (login/logout/refresh).
  final refresh = ValueNotifier<int>(0);
  ref.onDispose(refresh.dispose);
  ref.listen(isAuthenticatedProvider, (_, __) => refresh.value++);

  return GoRouter(
    initialLocation: '/apiaries',
    refreshListenable: refresh,
    redirect: (context, state) {
      final authed = ref.read(isAuthenticatedProvider);
      final atLogin = state.matchedLocation == '/login';
      if (!authed) return atLogin ? null : '/login';
      if (atLogin) return '/apiaries';
      return null;
    },
    routes: [
      GoRoute(
        path: '/login',
        name: 'login',
        builder: (context, state) => const LoginScreen(),
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
