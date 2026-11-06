import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'config.dart';
import 'firebase_options.dart';
import 'router.dart';
import 'shared/device_images.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // firebase_options.dart ships with blank values; until `flutterfire configure` fills them,
  // the app runs in prototype mode without Firebase.
  final options = DefaultFirebaseOptions.currentPlatform;
  final firebaseEnabled =
      options.apiKey.isNotEmpty && options.projectId.isNotEmpty;
  if (firebaseEnabled) await Firebase.initializeApp(options: options);
  final deviceImages = await DeviceImages.open();

  runApp(
    ProviderScope(
      overrides: [
        firebaseEnabledProvider.overrideWithValue(firebaseEnabled),
        deviceImagesProvider.overrideWithValue(deviceImages),
      ],
      child: const LeafDiseaseApp(),
    ),
  );
}

ThemeData _theme(Brightness brightness) => ThemeData(
  colorSchemeSeed: Colors.green,
  brightness: brightness,
  useMaterial3: true,
);

class LeafDiseaseApp extends ConsumerWidget {
  const LeafDiseaseApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp.router(
      title: 'Leaf Disease Detector',
      debugShowCheckedModeBanner: false,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      routerConfig: ref.watch(routerProvider),
    );
  }
}
