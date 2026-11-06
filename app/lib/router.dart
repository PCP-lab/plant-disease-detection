import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'config.dart';
import 'features/advice/advice_screen.dart';
import 'features/auth/auth_providers.dart';
import 'features/auth/sign_in_screen.dart';
import 'features/history/history_screen.dart';
import 'features/history/scan_detail_screen.dart';
import 'features/scan/result_screen.dart';
import 'features/scan/scan_screen.dart';

/// Routes are nested under `/` so the back button always leads home.
/// Signed-out users are sent to /sign-in; signed-in users never see it.
/// In prototype mode (no Firebase) there's no sign-in at all.
final routerProvider = Provider<GoRouter>((ref) {
  final authChanged = ValueNotifier(0);
  ref.listen(authStateProvider, (_, _) => authChanged.value++);
  ref.onDispose(authChanged.dispose);

  return GoRouter(
    initialLocation: '/',
    refreshListenable: authChanged,
    redirect: (_, state) {
      final onSignIn = state.matchedLocation == '/sign-in';
      if (!ref.read(firebaseEnabledProvider)) return onSignIn ? '/' : null;
      final auth = ref.read(authStateProvider);
      if (auth.isLoading && !auth.hasValue) return null;
      final signedIn = auth.value != null;
      if (!signedIn) return onSignIn ? null : '/sign-in';
      return onSignIn ? '/' : null;
    },
    routes: [
      GoRoute(path: '/sign-in', builder: (_, _) => const SignInScreen()),
      GoRoute(
        path: '/',
        builder: (_, _) => const ScanScreen(),
        routes: [
          GoRoute(path: 'result', builder: (_, _) => const ResultScreen()),
          GoRoute(
            path: 'advice/:id',
            builder: (_, state) =>
                AdviceScreen(scanId: state.pathParameters['id']!),
          ),
          GoRoute(
            path: 'history',
            builder: (_, _) => const HistoryScreen(),
            routes: [
              GoRoute(
                path: ':id',
                builder: (_, state) =>
                    ScanDetailScreen(scanId: state.pathParameters['id']!),
              ),
            ],
          ),
        ],
      ),
    ],
  );
});
