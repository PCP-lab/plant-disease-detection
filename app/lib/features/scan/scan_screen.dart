import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../config.dart';
import '../../shared/api_client.dart';
import '../auth/auth_providers.dart';
import 'camera_screen.dart';
import 'frame_leaf_screen.dart';
import 'scan_providers.dart';

/// Home: take a photo or pick one from the gallery, then upload it.
class ScanScreen extends ConsumerWidget {
  const ScanScreen({super.key});

  Future<XFile?> _pick(BuildContext context, ImageSource source) async {
    try {
      return await ImagePicker().pickImage(
        source: source,
        maxWidth: 2048,
        maxHeight: 2048,
        imageQuality: 90,
      );
    } catch (e) {
      if (context.mounted) {
        _snack(context, 'Could not open the camera/gallery: $e');
      }
      return null;
    }
  }

  /// Photo (in-app camera with a guide box on Android/iOS, else image_picker) → "box the leaf" → upload.
  /// "Retake" on the box screen goes back to the camera / gallery.
  Future<void> _scan(BuildContext context, WidgetRef ref, {required bool camera}) async {
    final nav = Navigator.of(context);
    while (true) {
      XFile? image;
      var start = defaultLeafBox;
      if (camera && !kIsWeb) {
        final out = await nav.push<CameraOutcome>(
          MaterialPageRoute(builder: (_) => const CameraScreen()),
        );
        if (out == null || !context.mounted) return;
        if (out.file != null) {
          image = out.file;
          start = out.guide!;
        } else {
          image = await _pick(
            context,
            out.fallback == CameraFallback.gallery ? ImageSource.gallery : ImageSource.camera,
          );
        }
      } else {
        image = await _pick(context, camera ? ImageSource.camera : ImageSource.gallery);
      }
      if (image == null || !context.mounted) return;

      final bytes = await image.readAsBytes();
      if (!context.mounted) return;
      final box = await nav.push<Rect>(
        MaterialPageRoute(
          builder: (_) => FrameLeafScreen(
            bytes: bytes,
            initialBox: start,
            retakeLabel: camera ? 'Retake' : 'Choose another',
          ),
        ),
      );
      if (!context.mounted) return;
      if (box == null) continue; // retake / choose another

      final result = await ref.read(scanUploadProvider.notifier).upload(image, crop: box);
      if (!context.mounted) return;
      if (result.hasError) {
        _snack(context, describeError(result.error!));
      } else {
        context.push('/result');
      }
      return;
    }
  }

  void _snack(BuildContext context, String message) =>
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(message)));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final uploading = ref.watch(scanUploadProvider)?.isLoading ?? false;
    final firebaseEnabled = ref.watch(firebaseEnabledProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Leaf Disease Detector'),
        actions: [
          IconButton(
            tooltip: 'History',
            icon: const Icon(Icons.history),
            onPressed: uploading ? null : () => context.push('/history'),
          ),
          if (firebaseEnabled)
            PopupMenuButton<String>(
              enabled: !uploading,
              onSelected: (value) {
                if (value == 'sign-out') {
                  ref.read(authServiceProvider).signOut();
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'sign-out', child: Text('Sign out')),
              ],
            ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: uploading
                  ? const _Analyzing()
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Icon(
                          Icons.energy_savings_leaf_outlined,
                          size: 96,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'Scan a leaf',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.headlineSmall,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Photograph one leaf so it fills most of the frame, then fit the box '
                          "around it. We'll measure how much of it is covered by powdery mildew "
                          'and leaf spot.',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 32),
                        FilledButton.icon(
                          onPressed: () => _scan(context, ref, camera: true),
                          icon: const Icon(Icons.photo_camera),
                          label: Text(
                            kIsWeb ? 'Take or choose a photo' : 'Take a photo',
                          ),
                          style: FilledButton.styleFrom(
                            minimumSize: const Size.fromHeight(52),
                          ),
                        ),
                        const SizedBox(height: 12),
                        OutlinedButton.icon(
                          onPressed: () => _scan(context, ref, camera: false),
                          icon: const Icon(Icons.photo_library_outlined),
                          label: const Text('Choose from gallery'),
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size.fromHeight(52),
                          ),
                        ),
                        const SizedBox(height: 32),
                        const _Tips(),
                        if (!firebaseEnabled) ...[
                          const SizedBox(height: 16),
                          Text(
                            'Prototype mode: no sign-in; scans are stored by the backend at $apiBaseUrl',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.outline,
                            ),
                          ),
                        ],
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Analyzing extends StatelessWidget {
  const _Analyzing();

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const CircularProgressIndicator(),
        const SizedBox(height: 24),
        Text('Analyzing leaf…', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        const Text('This can take a few seconds.'),
      ],
    );
  }
}

class _Tips extends StatelessWidget {
  const _Tips();

  @override
  Widget build(BuildContext context) {
    const tips = [
      (Icons.wb_sunny_outlined, 'Even daylight, no harsh shadows'),
      (
        Icons.center_focus_strong_outlined,
        'Leaf fills most of the frame, in focus',
      ),
      (Icons.flip_outlined, 'Upper side of the leaf, flat if possible'),
    ];
    return Card.outlined(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          children: [
            for (final (icon, text) in tips)
              ListTile(dense: true, leading: Icon(icon), title: Text(text)),
          ],
        ),
      ),
    );
  }
}
