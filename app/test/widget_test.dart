import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:leaf_disease_app/config.dart';
import 'package:leaf_disease_app/features/auth/auth_providers.dart';
import 'package:leaf_disease_app/main.dart';

void main() {
  testWidgets('Signed-out users land on the sign-in screen', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          firebaseEnabledProvider.overrideWithValue(true),
          authStateProvider.overrideWith((ref) => Stream.value(null)),
        ],
        child: const LeafDiseaseApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Continue with Google'), findsOneWidget);
    expect(find.text('Scan a leaf'), findsNothing);
  });

  testWidgets('Prototype mode (no Firebase) skips sign-in', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: LeafDiseaseApp()));
    await tester.pumpAndSettle();

    expect(find.text('Scan a leaf'), findsOneWidget);
    expect(find.textContaining('Prototype mode'), findsOneWidget);
  });
}
