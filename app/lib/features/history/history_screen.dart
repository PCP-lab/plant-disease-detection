import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../shared/device_images.dart';
import '../../shared/models/scan_result.dart';
import '../../shared/widgets/scan_image.dart';
import '../scan/widgets/coverage_card.dart';
import 'history_providers.dart';

/// The user's past scans, newest first.
class HistoryScreen extends ConsumerWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(historyProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('History')),
      body: history.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'Could not load your scans.\n$e',
              textAlign: TextAlign.center,
            ),
          ),
        ),
        data: (scans) => scans.isEmpty
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.history, size: 48),
                    const SizedBox(height: 12),
                    const Text('No scans yet'),
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: () => context.go('/'),
                      child: const Text('Scan a leaf'),
                    ),
                  ],
                ),
              )
            : ListView.separated(
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: scans.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, i) => _ScanTile(scan: scans[i]),
              ),
      ),
    );
  }
}

class _ScanTile extends StatelessWidget {
  const _ScanTile({required this.scan});

  final ScanResult scan;

  @override
  Widget build(BuildContext context) {
    final primary = scan.primary;
    final date =
        '${MaterialLocalizations.of(context).formatMediumDate(scan.createdAt)}, '
        '${TimeOfDay.fromDateTime(scan.createdAt).format(context)}';

    return ListTile(
      onTap: () => context.push('/history/${scan.id}'),
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: SizedBox.square(
          dimension: 56,
          child: ScanImage(
            scanId: scan.id,
            kind: ScanImageKind.overlay,
            storagePath: scan.overlayPath ?? scan.imagePath,
            url: scan.overlayUrl ?? scan.imageUrl,
            fit: BoxFit.cover,
          ),
        ),
      ),
      title: Text(date),
      subtitle: Text(
        primary == null
            ? 'No leaf detected'
            : 'Mildew ${primary.powderyMildewPct.toStringAsFixed(1)}% · '
                  'Spot ${primary.leafSpotPct.toStringAsFixed(1)}%',
      ),
      trailing: primary == null
          ? null
          : SeverityChip(severity: primary.worstSeverity),
    );
  }
}
