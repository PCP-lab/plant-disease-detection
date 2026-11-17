import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'plant_providers.dart';
import 'widgets/plant_result_view.dart';

/// Result of the whole-plant scan just uploaded from PlantCaptureScreen.
class PlantResultScreen extends ConsumerWidget {
  const PlantResultScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scan = ref.watch(plantUploadProvider)?.value;

    return Scaffold(
      appBar: AppBar(title: const Text('Plant result')),
      body: scan == null
          // Reached directly (e.g. web reload) with no upload in memory.
          ? Center(
              child: TextButton(
                onPressed: () => context.go('/plant'),
                child: const Text('No result yet. Scan a plant'),
              ),
            )
          : PlantResultView(
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
                        ref.read(plantUploadProvider.notifier).clear();
                        context.go('/');
                      },
                      icon: const Icon(Icons.home_outlined),
                      label: const Text('Done'),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}
