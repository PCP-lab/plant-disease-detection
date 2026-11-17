import 'package:cached_network_image/cached_network_image.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../config.dart';
import '../../shared/api_client.dart';
import '../../shared/device_images.dart';
import '../auth/auth_providers.dart';
import 'info_screens.dart';
import 'permissions_screen.dart';
import 'profile_providers.dart';

final packageInfoProvider = FutureProvider<PackageInfo>((ref) => PackageInfo.fromPlatform());

/// The user's display name: their name, else the part of the email before @, else "Guest".
String displayNameOf(User? user) {
  final name = user?.displayName?.trim();
  if (name != null && name.isNotEmpty) return name;
  final email = user?.email;
  if (email != null && email.contains('@')) return email.split('@').first;
  return 'Guest';
}

/// Round profile picture: the Google photo, else the initial on a coloured circle.
class ProfileAvatar extends StatelessWidget {
  const ProfileAvatar({super.key, required this.user, this.radius = 18});

  final User? user;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final photo = user?.photoURL;
    final name = displayNameOf(user);
    return CircleAvatar(
      radius: radius,
      backgroundColor: scheme.primaryContainer,
      foregroundImage: photo == null || photo.isEmpty ? null : CachedNetworkImageProvider(photo),
      child: user == null
          ? Icon(Icons.person_outline, size: radius, color: scheme.onPrimaryContainer)
          : Text(
              name.characters.first.toUpperCase(),
              style: TextStyle(fontSize: radius * 0.9, color: scheme.onPrimaryContainer, fontWeight: FontWeight.w600),
            ),
    );
  }
}

class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  static const _themeLabels = {ThemeMode.system: 'System default', ThemeMode.light: 'Light', ThemeMode.dark: 'Dark'};

  Future<void> _chooseTheme(BuildContext context, WidgetRef ref) async {
    final current = ref.read(themeModeProvider);
    final picked = await showModalBottomSheet<ThemeMode>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Appearance', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            for (final (mode, icon) in const [
              (ThemeMode.system, Icons.brightness_auto_outlined),
              (ThemeMode.light, Icons.light_mode_outlined),
              (ThemeMode.dark, Icons.dark_mode_outlined),
            ])
              ListTile(
                leading: Icon(icon),
                title: Text(_themeLabels[mode]!),
                trailing: mode == current ? Icon(Icons.check, color: Theme.of(context).colorScheme.primary) : null,
                onTap: () => Navigator.pop(context, mode),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (picked != null) await ref.read(themeModeProvider.notifier).set(picked);
  }

  Future<void> _sendFeedback(BuildContext context, WidgetRef ref) async {
    final info = ref.read(packageInfoProvider).value;
    final platform = kIsWeb ? 'Web' : defaultTargetPlatform.name;
    final subject = 'CropCare feedback (v${info?.version ?? '?'}, $platform)';
    // Spaces as %20, not "+": mail apps show "+" literally.
    final uri = Uri.parse('mailto:$supportEmail?subject=${Uri.encodeComponent(subject)}');
    var opened = false;
    try {
      opened = await launchUrl(uri);
    } catch (_) {}
    if (!opened && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No email app found. Write to us at $supportEmail')),
      );
    }
  }

  void _about(BuildContext context, WidgetRef ref) {
    final info = ref.read(packageInfoProvider).value;
    showAboutDialog(
      context: context,
      applicationName: 'CropCare',
      applicationVersion: info == null ? null : 'Version ${info.version} (${info.buildNumber})',
      applicationIcon: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Image.asset('assets/icon/icon.png', width: 56, height: 56),
      ),
      applicationLegalese: '© 2026 Precision Crop Protection Lab',
      children: const [
        SizedBox(height: 16),
        Text(
          'CropCare measures powdery mildew and leaf spot on leaf photos with an AI segmentation model, '
          'and gives management tips based on the result and your local weather.\n\n'
          'Results are a guide, not a diagnosis: check with a local agronomist before treating.',
        ),
      ],
    );
  }

  Future<void> _signOut(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sign out?'),
        content: const Text('Your scans stay in your account. Sign in again to see them.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Sign out')),
        ],
      ),
    );
    if (ok == true) await ref.read(authServiceProvider).signOut();
  }

  Future<void> _deleteAccount(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(context: context, builder: (_) => const DeleteAccountDialog());
    if (confirmed != true || !context.mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    final nav = Navigator.of(context, rootNavigator: true);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const PopScope(
        canPop: false,
        child: AlertDialog(
          content: Row(
            children: [
              CircularProgressIndicator(),
              SizedBox(width: 20),
              Expanded(child: Text('Deleting your account…')),
            ],
          ),
        ),
      ),
    );
    try {
      await ref.read(apiClientProvider).deleteAccount();
      await ref.read(deviceImagesProvider).clear();
      nav.pop();
      await ref.read(authServiceProvider).signOut(); // the router then shows the sign-in screen
      messenger.showSnackBar(const SnackBar(content: Text('Your account and all your data were deleted.')));
    } catch (e) {
      nav.pop();
      messenger.showSnackBar(SnackBar(content: Text('Could not delete the account. ${describeError(e)}')));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final firebaseEnabled = ref.watch(firebaseEnabledProvider);
    final user = ref.watch(authStateProvider).value;
    final themeMode = ref.watch(themeModeProvider);
    final permissions = ref.watch(permissionStatusesProvider).value;
    final version = ref.watch(packageInfoProvider).value;

    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              _Header(user: user, prototype: !firebaseEnabled),
              const _SectionTitle('Activity'),
              _Group(
                children: [
                  ListTile(
                    leading: const Icon(Icons.history),
                    title: const Text('Scan history'),
                    subtitle: const Text('Every leaf and plant you have checked'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => context.push('/history'),
                  ),
                ],
              ),
              const _SectionTitle('Settings'),
              _Group(
                children: [
                  ListTile(
                    leading: const Icon(Icons.verified_user_outlined),
                    title: const Text('Permissions'),
                    subtitle: Text(permissions == null ? 'Camera, location' : permissionSummary(permissions)),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () async {
                      await context.push('/profile/permissions');
                      ref.invalidate(permissionStatusesProvider);
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.palette_outlined),
                    title: const Text('Appearance'),
                    subtitle: Text(_themeLabels[themeMode]!),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _chooseTheme(context, ref),
                  ),
                ],
              ),
              const _SectionTitle('Help & legal'),
              _Group(
                children: [
                  ListTile(
                    leading: const Icon(Icons.photo_camera_outlined),
                    title: const Text('How to take good photos'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => context.push('/profile/guide'),
                  ),
                  ListTile(
                    leading: const Icon(Icons.privacy_tip_outlined),
                    title: const Text('Privacy policy'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => context.push('/profile/privacy'),
                  ),
                  ListTile(
                    leading: const Icon(Icons.feedback_outlined),
                    title: const Text('Send feedback'),
                    subtitle: const Text('Report a problem or suggest an idea'),
                    trailing: const Icon(Icons.open_in_new, size: 20),
                    onTap: () => _sendFeedback(context, ref),
                  ),
                  ListTile(
                    leading: const Icon(Icons.info_outline),
                    title: const Text('About CropCare'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _about(context, ref),
                  ),
                ],
              ),
              if (firebaseEnabled && user != null) ...[
                const _SectionTitle('Account'),
                _Group(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.logout),
                      title: const Text('Sign out'),
                      onTap: () => _signOut(context, ref),
                    ),
                    ListTile(
                      leading: Icon(Icons.delete_forever_outlined, color: theme.colorScheme.error),
                      title: Text('Delete account', style: TextStyle(color: theme.colorScheme.error)),
                      subtitle: const Text('Permanently remove your account and all scans'),
                      onTap: () => _deleteAccount(context, ref),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 24),
              Text(
                version == null ? 'CropCare' : 'CropCare ${version.version} (${version.buildNumber})',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends ConsumerWidget {
  const _Header({required this.user, required this.prototype});

  final User? user;
  final bool prototype;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final stats = ref.watch(profileStatsProvider);
    final created = user?.metadata.creationTime;
    final loc = MaterialLocalizations.of(context);

    return Card(
      color: scheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              children: [
                ProfileAvatar(user: user, radius: 32),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        displayNameOf(user),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleLarge?.copyWith(color: scheme.onPrimaryContainer),
                      ),
                      if (user?.email != null)
                        Text(
                          user!.email!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onPrimaryContainer),
                        ),
                      const SizedBox(height: 2),
                      Text(
                        prototype
                            ? 'Prototype mode · no sign-in'
                            : created == null
                            ? ''
                            : 'Member since ${loc.formatMonthYear(created)}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onPrimaryContainer.withValues(alpha: 0.75),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                _Stat(label: 'Scans', value: stats.value?.scans.toString()),
                _Stat(label: 'Whole-plant', value: stats.value?.plantScans.toString()),
                _Stat(
                  label: 'Last scan',
                  value: stats.hasValue
                      ? (stats.value!.lastScan == null ? '—' : loc.formatShortMonthDay(stats.value!.lastScan!))
                      : null,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});

  final String label;

  /// Null while loading.
  final String? value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Expanded(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 4),
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(color: scheme.surface.withValues(alpha: 0.6), borderRadius: BorderRadius.circular(12)),
        child: Column(
          children: [
            Text(
              value ?? '…',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
            ),
            Text(label, style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(8, 20, 8, 6),
    child: Text(
      text.toUpperCase(),
      style: Theme.of(context).textTheme.labelMedium?.copyWith(
        color: Theme.of(context).colorScheme.primary,
        letterSpacing: 0.8,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}

class _Group extends StatelessWidget {
  const _Group({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Card(
    clipBehavior: Clip.antiAlias,
    margin: EdgeInsets.zero,
    child: Column(
      children: [
        for (final (i, child) in children.indexed) ...[
          if (i > 0) const Divider(height: 1, indent: 56),
          child,
        ],
      ],
    ),
  );
}

/// Confirms account deletion: lists what is deleted, and the button only works after typing DELETE.
class DeleteAccountDialog extends StatefulWidget {
  const DeleteAccountDialog({super.key});

  @override
  State<DeleteAccountDialog> createState() => _DeleteAccountDialogState();
}

class _DeleteAccountDialogState extends State<DeleteAccountDialog> {
  final _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ok = _text.text.trim().toUpperCase() == 'DELETE';
    return AlertDialog(
      icon: Icon(Icons.warning_amber_rounded, color: scheme.error),
      title: const Text('Delete your account?'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('This permanently deletes:'),
            const SizedBox(height: 8),
            const Text('•  your CropCare account and sign-in\n'
                '•  all your scan results and history\n'
                '•  the leaf photos saved on this phone'),
            const SizedBox(height: 12),
            const Text('This cannot be undone. Type DELETE to confirm.'),
            const SizedBox(height: 8),
            TextField(
              controller: _text,
              autofocus: true,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(hintText: 'DELETE', border: OutlineInputBorder(), isDense: true),
              onChanged: (_) => setState(() {}),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: scheme.error, foregroundColor: scheme.onError),
          onPressed: ok ? () => Navigator.pop(context, true) : null,
          child: const Text('Delete account'),
        ),
      ],
    );
  }
}
