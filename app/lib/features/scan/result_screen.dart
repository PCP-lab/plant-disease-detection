import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'scan_providers.dart';
import 'widgets/scan_result_view.dart';

/// Result of the scan just uploaded from ScanScreen.
class ResultScreen extends ConsumerWidget {
  const ResultScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scan = ref.watch(scanUploadProvider)?.value;

    return Scaffold(
      appBar: AppBar(title: const Text('Result')),
      body: scan == null
          // Reached /result directly (e.g. web reload) with no upload in memory.
          ? Center(
              child: TextButton(
                onPressed: () => context.go('/'),
                child: const Text('No result yet. Scan a leaf'),
              ),
            )
          : ScanResultView(
              scan: scan,
              footer: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => context.go('/history'),
                      icon: const Icon(Icons.history),
                      label: const Text('History'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () {
                        ref.read(scanUploadProvider.notifier).clear();
                        context.go('/');
                      },
                      icon: const Icon(Icons.photo_camera),
                      label: const Text('Scan another'),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}
