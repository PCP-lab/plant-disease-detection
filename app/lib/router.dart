import 'package:go_router/go_router.dart';

import 'features/auth/sign_in_screen.dart';
import 'features/history/history_screen.dart';
import 'features/history/scan_detail_screen.dart';
import 'features/scan/result_screen.dart';
import 'features/scan/scan_screen.dart';

// TODO: redirect to /sign-in when FirebaseAuth.currentUser is null.
final router = GoRouter(
  initialLocation: '/',
  routes: [
    GoRoute(path: '/sign-in', builder: (_, _) => const SignInScreen()),
    GoRoute(path: '/', builder: (_, _) => const ScanScreen()),
    GoRoute(path: '/result', builder: (_, _) => const ResultScreen()),
    GoRoute(path: '/history', builder: (_, _) => const HistoryScreen()),
    GoRoute(
      path: '/history/:id',
      builder: (_, state) =>
          ScanDetailScreen(scanId: state.pathParameters['id']!),
    ),
  ],
);
