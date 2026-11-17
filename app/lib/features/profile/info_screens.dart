import 'package:flutter/material.dart';

/// Contact address shown in the privacy policy and used for feedback.
const supportEmail = 'precisioncrop.lab@gmail.com';

/// A titled section of icon + text points.
class _Section extends StatelessWidget {
  const _Section({required this.title, required this.points});

  final String title;
  final List<(IconData, String, String)> points;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
            child: Text(title, style: theme.textTheme.titleMedium?.copyWith(color: theme.colorScheme.primary)),
          ),
          Card(
            child: Column(
              children: [
                for (final (icon, head, body) in points)
                  ListTile(
                    leading: Icon(icon),
                    title: Text(head),
                    subtitle: body.isEmpty ? null : Text(body),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Page extends StatelessWidget {
  const _Page({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(title)),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: ListView(padding: const EdgeInsets.all(16), children: children),
      ),
    ),
  );
}

/// How to take photos that give reliable results.
class PhotoGuideScreen extends StatelessWidget {
  const PhotoGuideScreen({super.key});

  @override
  Widget build(BuildContext context) => const _Page(
    title: 'Taking good photos',
    children: [
      _Section(
        title: 'Every photo',
        points: [
          (Icons.filter_1_outlined, 'One leaf per photo', 'Fit the box around a single leaf; other leaves are ignored.'),
          (Icons.center_focus_strong_outlined, 'Fill the frame', 'Get close so the leaf fills most of the box. Tiny spots are missed on a small leaf.'),
          (Icons.wb_sunny_outlined, 'Even daylight', 'Avoid harsh sun and deep shadow; no flash.'),
          (Icons.flip_outlined, 'Upper side, flat', 'Photograph the top of the leaf, as flat as you can hold it.'),
          (Icons.blur_off_outlined, 'Sharp', 'Hold still and tap to focus. Blurry photos give unreliable results.'),
        ],
      ),
      _Section(
        title: 'Whole-plant scans',
        points: [
          (Icons.layers_outlined, 'Top, middle and bottom', 'Pick 3 to 6 different leaves from different heights of the same plant.'),
          (Icons.shuffle_outlined, "Don't pick only the bad ones", 'A fair mix gives a true picture of the whole plant.'),
          (Icons.do_not_disturb_on_outlined, 'Never the same leaf twice', 'Each photo should show a different leaf.'),
        ],
      ),
    ],
  );
}

/// Plain-language privacy policy, matching what the app actually does.
class PrivacyPolicyScreen extends StatelessWidget {
  const PrivacyPolicyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _Page(
      title: 'Privacy policy',
      children: [
        Text(
          'CropCare checks leaf photos for disease. This page explains what data that involves, where it goes, '
          'and how to delete it.',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 8),
        const _Section(
          title: 'What we store',
          points: [
            (Icons.person_outline, 'Your account', 'Name, email address and profile photo from your Google sign-in, kept by Firebase Authentication (Google).'),
            (Icons.analytics_outlined, 'Scan results', 'Disease percentages, severity and date of each scan, kept in Firebase Firestore so your history follows you.'),
            (Icons.phone_android_outlined, 'Photos stay on your phone', 'Leaf photos are saved only on this device. They are lost if you uninstall the app.'),
          ],
        ),
        const _Section(
          title: 'What is sent, and why',
          points: [
            (Icons.cloud_upload_outlined, 'Photos for analysis', 'Each photo is sent to the CropCare server to measure the disease, then discarded. The server does not keep it.'),
            (Icons.auto_awesome_outlined, 'AI management tips', 'When you ask for tips, the leaf photo and its results are sent to an AI service (Groq) to write them. Tips are not stored.'),
            (Icons.location_on_outlined, 'Location, for weather only', 'Your approximate position is sent to Open-Meteo to get the local weather forecast. CropCare never stores your location.'),
          ],
        ),
        const _Section(
          title: 'Your choices',
          points: [
            (Icons.delete_outline, 'Delete a scan', 'Open it in History and tap the bin.'),
            (Icons.no_accounts_outlined, 'Delete your account', 'Profile → Delete account removes your account, all scan results and the photos on this phone. This cannot be undone.'),
            (Icons.tune_outlined, 'Permissions', 'Camera and location can be turned off at any time in Profile → Permissions.'),
          ],
        ),
        const _Section(
          title: 'Contact',
          points: [(Icons.mail_outline, supportEmail, 'Questions about your data or this policy.')],
        ),
        Text(
          'We do not sell your data or use it for advertising.\nLast updated 17 November 2026.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }
}
