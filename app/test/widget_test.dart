import 'package:flutter/material.dart';
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
    expect(find.text('Single leaf'), findsNothing);
  });

  testWidgets('Prototype mode (no Firebase) skips sign-in', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: LeafDiseaseApp()));
    await tester.pumpAndSettle();

    expect(find.text('Single leaf'), findsOneWidget);
    expect(find.textContaining('Prototype mode'), findsOneWidget);
  });

  testWidgets('Home offers single-leaf and whole-plant scans', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: LeafDiseaseApp()));
    await tester.pumpAndSettle();

    expect(find.text('Single leaf'), findsOneWidget);
    expect(find.text('Whole plant'), findsOneWidget);
    expect(find.textContaining('3 to 6 different leaves'), findsOneWidget);

    await tester.tap(find.text('Whole plant'));
    await tester.pumpAndSettle();
    expect(find.text('Add first leaf'), findsOneWidget);
    expect(find.text('0 of 6 leaves · add 3 more'), findsOneWidget);
    final analyze = tester.widget<FilledButton>(
      find.ancestor(of: find.text('Analyze plant'), matching: find.byWidgetPredicate((w) => w is FilledButton)),
    );
    expect(analyze.onPressed, isNull); // needs at least 3 leaves
  });
}
