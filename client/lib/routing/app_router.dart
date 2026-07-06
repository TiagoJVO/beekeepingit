import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/apiary_detail/apiary_detail_screen.dart';
import '../features/home/home_screen.dart';

const homeRouteName = 'home';
const apiaryDetailRouteName = 'apiaryDetail';

/// App-level routing (AC: "at least a placeholder home and detail route").
/// Exposed as a provider (not a top-level const) so widget tests can override
/// it with a scoped router / initial location.
final routerProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    routes: [
      GoRoute(
        path: '/',
        name: homeRouteName,
        builder: (context, state) => const HomeScreen(),
      ),
      GoRoute(
        path: '/apiaries/:id',
        name: apiaryDetailRouteName,
        builder: (context, state) =>
            ApiaryDetailScreen(apiaryId: state.pathParameters['id']!),
      ),
    ],
  );
});
