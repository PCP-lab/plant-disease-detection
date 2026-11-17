import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

/// A permission the app uses, and why.
class AppPermission {
  const AppPermission(this.permission, this.icon, this.title, this.reason);

  final Permission permission;
  final IconData icon;
  final String title;
  final String reason;
}

bool get _isIOS => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

/// Permissions that apply on this platform. On Android the gallery uses the system photo picker, which needs no
/// permission, so Photos is listed on iOS only (a "Not allowed" row there would be misleading).
List<AppPermission> get appPermissions => [
  const AppPermission(
    Permission.camera,
    Icons.photo_camera_outlined,
    'Camera',
    'Take leaf photos in the guided camera.',
  ),
  const AppPermission(
    Permission.locationWhenInUse,
    Icons.location_on_outlined,
    'Location',
    'Local weather for the disease-risk forecast and spray timing. Only used while you look at tips; never stored.',
  ),
  if (_isIOS)
    const AppPermission(
      Permission.photos,
      Icons.photo_library_outlined,
      'Photos',
      'Choose leaf photos from your library.',
    ),
];

/// Current status of each of [appPermissions]. Invalidate to check again (e.g. back from the system settings).
final permissionStatusesProvider = FutureProvider.autoDispose<Map<Permission, PermissionStatus>>((ref) async {
  if (kIsWeb) return const {};
  return {for (final p in appPermissions) p.permission: await p.permission.status};
});

/// Short label for a status.
String permissionLabel(PermissionStatus s) => switch (s) {
  PermissionStatus.granted => 'Allowed',
  PermissionStatus.limited => 'Limited',
  PermissionStatus.provisional => 'Allowed',
  PermissionStatus.permanentlyDenied => 'Blocked',
  PermissionStatus.restricted => 'Restricted',
  PermissionStatus.denied => 'Not allowed',
};

bool _ok(PermissionStatus s) => s.isGranted || s.isLimited || s.isProvisional;

/// One line for the profile screen, e.g. "Camera allowed · Location not allowed".
String permissionSummary(Map<Permission, PermissionStatus> statuses) {
  if (statuses.isEmpty) return 'Managed by your browser';
  return [
    for (final p in appPermissions)
      if (statuses[p.permission] case final s?) '${p.title} ${permissionLabel(s).toLowerCase()}',
  ].join(' · ');
}

class PermissionsScreen extends ConsumerStatefulWidget {
  const PermissionsScreen({super.key});

  @override
  ConsumerState<PermissionsScreen> createState() => _PermissionsScreenState();
}

class _PermissionsScreenState extends ConsumerState<PermissionsScreen> {
  // Back from the system settings: check again.
  late final _lifecycle = AppLifecycleListener(onResume: () => ref.invalidate(permissionStatusesProvider));

  @override
  void initState() {
    super.initState();
    _lifecycle; // start listening
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  Future<void> _change(AppPermission p, PermissionStatus status) async {
    if (status.isPermanentlyDenied || status.isRestricted || _ok(status)) {
      // Android/iOS only let the system settings change these (including taking a permission back).
      await openAppSettings();
    } else {
      await p.permission.request();
    }
    ref.invalidate(permissionStatusesProvider);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final statuses = ref.watch(permissionStatusesProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Permissions')),
      body: kIsWeb
          ? const Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'In the browser, camera and location access are managed by the browser. '
                'Use the site settings (the icon next to the address bar) to change them.',
              ),
            )
          : statuses.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('Could not read the permissions.\n$e')),
              data: (statuses) => ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Text(
                    'CropCare asks only for what it needs. You can change these at any time.',
                    style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 12),
                  for (final p in appPermissions)
                    _PermissionCard(
                      permission: p,
                      status: statuses[p.permission] ?? PermissionStatus.denied,
                      onChange: () => _change(p, statuses[p.permission] ?? PermissionStatus.denied),
                    ),
                  if (!_isIOS)
                    const Card(
                      child: ListTile(
                        leading: Icon(Icons.photo_library_outlined),
                        title: Text('Gallery'),
                        subtitle: Text('No permission needed: you pick photos in the system photo picker, '
                            'and CropCare only sees the ones you choose.'),
                      ),
                    ),
                  const SizedBox(height: 8),
                  TextButton.icon(
                    onPressed: openAppSettings,
                    icon: const Icon(Icons.settings_outlined),
                    label: const Text('Open app settings'),
                  ),
                ],
              ),
            ),
    );
  }
}

class _PermissionCard extends StatelessWidget {
  const _PermissionCard({required this.permission, required this.status, required this.onChange});

  final AppPermission permission;
  final PermissionStatus status;
  final VoidCallback onChange;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final ok = _ok(status);
    final (chipBg, chipFg) = ok
        ? (scheme.primaryContainer, scheme.onPrimaryContainer)
        : status.isPermanentlyDenied
        ? (scheme.errorContainer, scheme.onErrorContainer)
        : (scheme.surfaceContainerHighest, scheme.onSurfaceVariant);
    final action = ok
        ? 'Change in settings'
        : status.isPermanentlyDenied || status.isRestricted
        ? 'Open settings'
        : 'Allow';

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(permission.icon, color: scheme.primary),
                const SizedBox(width: 12),
                Expanded(child: Text(permission.title, style: theme.textTheme.titleMedium)),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(color: chipBg, borderRadius: BorderRadius.circular(999)),
                  child: Text(permissionLabel(status), style: theme.textTheme.labelMedium?.copyWith(color: chipFg)),
                ),
                const SizedBox(width: 8),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(left: 36, top: 4, right: 8),
              child: Text(
                permission.reason,
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
            if (status.isPermanentlyDenied)
              Padding(
                padding: const EdgeInsets.only(left: 36, top: 4, right: 8),
                child: Text(
                  'You chose "Don\'t allow" earlier, so the phone won\'t ask again. Turn it on in the app settings.',
                  style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
                ),
              ),
            Align(
              alignment: Alignment.centerRight,
              child: ok
                  ? TextButton(onPressed: onChange, child: Text(action))
                  : FilledButton.tonal(onPressed: onChange, child: Text(action)),
            ),
          ],
        ),
      ),
    );
  }
}
