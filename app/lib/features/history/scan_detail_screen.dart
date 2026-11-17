import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../shared/api_client.dart';
import '../../shared/device_images.dart';
import '../plant/widgets/plant_result_view.dart';
import '../scan/widgets/scan_result_view.dart';
import 'history_providers.dart';

/// A single past scan (reuses the result widgets).
class ScanDetailScreen extends ConsumerStatefulWidget {
  const ScanDetailScreen({super.key, required this.scanId});

  final String scanId;

  @override
  ConsumerState<ScanDetailScreen> createState() => _ScanDetailScreenState();
}

class _ScanDetailScreenState extends ConsumerState<ScanDetailScreen> {
  bool _deleting = false;

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this scan?'),
        content: const Text(
          'The photos and the result will be removed permanently.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _deleting = true);
    try {
      await ref.read(apiClientProvider).deleteScan(widget.scanId);
      await ref.read(deviceImagesProvider).delete(widget.scanId);
      // Prototype mode has no live Firestore stream to pick up the delete.
      ref.invalidate(historyProvider);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Scan deleted')));
      context.canPop() ? context.pop() : context.go('/history');
    } catch (e) {
      if (!mounted) return;
      setState(() => _deleting = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(describeError(e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scan = ref.watch(scanByIdProvider(widget.scanId));

    return Scaffold(
      appBar: AppBar(
        title: Text(scan.value?.isPlant ?? false ? 'Plant scan' : 'Scan'),
        actions: [
          if (scan.value != null)
            _deleting
                ? const Padding(
                    padding: EdgeInsets.all(16),
                    child: SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : IconButton(
                    tooltip: 'Delete',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: _delete,
                  ),
        ],
      ),
      body: scan.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Could not load this scan.\n$e')),
        data: (scan) => scan == null
            ? const Center(child: Text('This scan no longer exists.'))
            : scan.isPlant
            ? PlantResultView(scan: scan)
            : ScanResultView(scan: scan),
      ),
    );
  }
}
