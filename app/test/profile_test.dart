import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';

import 'package:leaf_disease_app/features/profile/permissions_screen.dart';
import 'package:leaf_disease_app/features/profile/profile_providers.dart';
import 'package:leaf_disease_app/features/profile/profile_screen.dart';

Widget profileApp(ProviderContainer container) => UncontrolledProviderScope(
  container: container,
  child: Consumer(
    builder: (context, ref, _) => MaterialApp(
      themeMode: ref.watch(themeModeProvider),
      home: const ProfileScreen(),
    ),
  ),
);

ProviderContainer container() => ProviderContainer(
  overrides: [
    profileStatsProvider.overrideWith(
      (ref) async => ProfileStats(scans: 12, plantScans: 3, lastScan: DateTime(2026, 11, 17)),
    ),
    permissionStatusesProvider.overrideWith(
      (ref) async => {
        Permission.camera: PermissionStatus.granted,
        Permission.locationWhenInUse: PermissionStatus.denied,
      },
    ),
  ],
);

void main() {
  testWidgets('profile renders at phone width with all sections', (tester) async {
    tester.view.physicalSize = const Size(360, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = container();
    addTearDown(c.dispose);

    await tester.pumpWidget(profileApp(c));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Guest'), findsOneWidget);
    expect(find.text('Prototype mode · no sign-in'), findsOneWidget);
    expect(find.text('12'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    for (final title in [
      'Scan history',
      'Permissions',
      'Appearance',
      'How to take good photos',
      'Privacy policy',
      'Send feedback',
      'About CropCare',
    ]) {
      expect(find.text(title), findsOneWidget, reason: title);
    }
    expect(find.text('Camera allowed · Location not allowed'), findsOneWidget);
    // No account to sign out of or delete in prototype mode.
    expect(find.text('Delete account'), findsNothing);
  });

  testWidgets('appearance switches the theme and remembers it', (tester) async {
    tester.view.physicalSize = const Size(360, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = container();
    addTearDown(c.dispose);

    await tester.pumpWidget(profileApp(c));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Appearance'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dark'));
    await tester.pumpAndSettle();

    expect(c.read(themeModeProvider), ThemeMode.dark);
    expect(c.read(settingsStoreProvider).get('theme_mode'), 'dark');
    expect(find.text('Dark'), findsOneWidget); // the Appearance subtitle
  });

  testWidgets('delete account needs DELETE typed', (tester) async {
    bool? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async =>
                result = await showDialog<bool>(context: context, builder: (_) => const DeleteAccountDialog()),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    FilledButton button() => tester.widget<FilledButton>(
      find.ancestor(of: find.text('Delete account'), matching: find.byWidgetPredicate((w) => w is FilledButton)),
    );
    expect(button().onPressed, isNull);
    await tester.enterText(find.byType(TextField), 'delet');
    await tester.pump();
    expect(button().onPressed, isNull);
    await tester.enterText(find.byType(TextField), 'DELETE');
    await tester.pump();
    expect(button().onPressed, isNotNull);

    await tester.tap(find.text('Delete account'));
    await tester.pumpAndSettle();
    expect(result, isTrue);
  });
}
