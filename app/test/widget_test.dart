import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:leaf_disease_app/main.dart';

void main() {
  testWidgets('App starts on the scan screen', (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: LeafDiseaseApp()));
    await tester.pumpAndSettle();

    expect(find.text('Scan a leaf'), findsOneWidget);
  });
}
