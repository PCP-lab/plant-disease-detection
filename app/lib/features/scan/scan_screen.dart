import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../config.dart';
import '../../shared/api_client.dart';
import '../auth/auth_providers.dart';
import '../profile/profile_screen.dart';
import 'capture_leaf.dart';
import 'scan_providers.dart';

/// Home: choose a single-leaf scan (one photo → result) or a whole-plant scan (3–6 leaf photos → /plant).
class ScanScreen extends ConsumerWidget {
  const ScanScreen({super.key});

  /// Single leaf: photo (guided camera or gallery) → "box the leaf" → upload → result.
  Future<void> _scan(BuildContext context, WidgetRef ref, {required bool camera}) async {
    final leaf = await captureLeaf(context, camera: camera);
    if (leaf == null || !context.mounted) return;
    final result = await ref.read(scanUploadProvider.notifier).upload(leaf.file, crop: leaf.box);
    if (!context.mounted) return;
    if (result.hasError) {
      _snack(context, describeError(result.error!));
    } else {
      context.push('/result');
    }
  }

  /// Single leaf: camera or gallery?
  Future<void> _chooseSingleSource(BuildContext context, WidgetRef ref) async {
    final camera = await showPhotoSourceSheet(context, title: 'Scan one leaf');
    if (camera != null && context.mounted) await _scan(context, ref, camera: camera);
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
        title: const Text('CropCare'),
        actions: [
          IconButton(
            tooltip: 'History',
            icon: const Icon(Icons.history),
            onPressed: uploading ? null : () => context.push('/history'),
          ),
          IconButton(
            tooltip: 'Profile',
            onPressed: uploading ? null : () => context.push('/profile'),
            icon: ProfileAvatar(user: ref.watch(authStateProvider).value, radius: 15),
          ),
          const SizedBox(width: 4),
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
                          size: 72,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'What would you like to check?',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.headlineSmall,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'We measure how much of each leaf is covered by powdery mildew and leaf spot.',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 24),
                        _ModeCard(
                          icon: Icons.eco_outlined,
                          title: 'Single leaf',
                          badge: '1 photo',
                          description:
                              "A quick check of one leaf. Best when you've spotted a problem on a "
                              'specific leaf.',
                          primary: true,
                          onTap: () => _chooseSingleSource(context, ref),
                        ),
                        const SizedBox(height: 12),
                        _ModeCard(
                          icon: Icons.local_florist_outlined,
                          title: 'Whole plant',
                          badge: '3–6 photos',
                          description:
                              'Photograph 3 to 6 different leaves of the same plant (top, middle and '
                              'bottom). We combine them into an overall health check of the plant.',
                          onTap: () => context.push('/plant'),
                        ),
                        const SizedBox(height: 24),
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

/// One of the two scan options on the home screen.
class _ModeCard extends StatelessWidget {
  const _ModeCard({
    required this.icon,
    required this.title,
    required this.badge,
    required this.description,
    required this.onTap,
    this.primary = false,
  });

  final IconData icon;
  final String title;
  final String badge;
  final String description;
  final VoidCallback onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final bg = primary ? scheme.primaryContainer : scheme.secondaryContainer;
    final fg = primary ? scheme.onPrimaryContainer : scheme.onSecondaryContainer;
    return Card(
      color: bg,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 36, color: fg),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          title,
                          style: theme.textTheme.titleMedium?.copyWith(color: fg, fontWeight: FontWeight.w600),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: fg.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(badge, style: theme.textTheme.labelSmall?.copyWith(color: fg)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(description, style: theme.textTheme.bodySmall?.copyWith(color: fg)),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: fg),
            ],
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
