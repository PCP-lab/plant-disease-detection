import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../shared/api_client.dart';
import '../scan/capture_leaf.dart';
import 'plant_providers.dart';

/// Whole-plant scan, step 1: collect 3–6 boxed photos of different leaves of one plant, then analyse them together.
class PlantCaptureScreen extends ConsumerStatefulWidget {
  const PlantCaptureScreen({super.key});

  @override
  ConsumerState<PlantCaptureScreen> createState() => _PlantCaptureScreenState();
}

class _PlantCaptureScreenState extends ConsumerState<PlantCaptureScreen> {
  /// Draft positions where the backend found no leaf (from a 422), to retake.
  Set<int> _failed = {};

  PlantDraftNotifier get _draft => ref.read(plantDraftProvider.notifier);

  void _snack(String message) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));

  Future<void> _addLeaf() async {
    final camera = await showPhotoSourceSheet(context, title: 'Add a leaf');
    if (camera == null || !mounted) return;
    if (camera) {
      final leaf = await captureLeaf(context, camera: true, confirmLabel: 'Add leaf');
      if (leaf != null) _draft.add(leaf);
      return;
    }
    final remaining = plantMaxLeaves - ref.read(plantDraftProvider).length;
    final files = await pickGalleryImages(context, limit: remaining);
    for (final (i, file) in files.indexed) {
      if (!mounted) return;
      final bytes = await file.readAsBytes();
      if (!mounted) return;
      final box = await boxLeaf(
        context,
        bytes,
        retakeLabel: 'Skip',
        confirmLabel: files.length > 1 ? 'Add leaf (${i + 1}/${files.length})' : 'Add leaf',
      );
      if (box != null) _draft.add(CapturedLeaf(file, bytes, box));
    }
  }

  Future<void> _editLeaf(int i) async {
    final leaf = ref.read(plantDraftProvider)[i];
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Leaf ${i + 1}', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            ListTile(
              leading: const Icon(Icons.crop_free),
              title: const Text('Adjust the box'),
              onTap: () => Navigator.pop(context, 'box'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera),
              title: const Text('Retake this leaf'),
              onTap: () => Navigator.pop(context, 'retake'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Remove'),
              onTap: () => Navigator.pop(context, 'remove'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    switch (action) {
      case 'box':
        final box = await boxLeaf(context, leaf.bytes, initialBox: leaf.box, retakeLabel: 'Cancel', confirmLabel: 'Save');
        if (box != null) {
          _draft.replace(i, CapturedLeaf(leaf.file, leaf.bytes, box));
          setState(() => _failed.remove(i));
        }
      case 'retake':
        final next = await captureLeaf(context, camera: true, confirmLabel: 'Use this leaf');
        if (next != null) {
          _draft.replace(i, next);
          setState(() => _failed.remove(i));
        }
      case 'remove':
        _draft.remove(i);
        // Positions after i shift down by one.
        setState(() => _failed = {for (final f in _failed) if (f != i) f > i ? f - 1 : f});
    }
  }

  Future<void> _analyze() async {
    final result = await ref.read(plantUploadProvider.notifier).upload();
    if (!mounted) return;
    if (result.hasError) {
      final failed = failedPhotos(result.error!);
      if (failed != null) setState(() => _failed = failed.toSet());
      _snack(describeError(result.error!));
      return;
    }
    setState(() => _failed = {});
    context.pushReplacement('/plant-result');
  }

  Future<void> _confirmClear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Start over?'),
        content: const Text('The leaf photos you added will be removed.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Start over')),
        ],
      ),
    );
    if (ok == true) {
      _draft.clear();
      setState(() => _failed = {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final leaves = ref.watch(plantDraftProvider);
    final uploading = ref.watch(plantUploadProvider)?.isLoading ?? false;
    final count = leaves.length;
    final canAnalyze = count >= plantMinLeaves && !uploading;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Whole plant'),
        actions: [
          if (count > 0 && !uploading)
            IconButton(tooltip: 'Start over', icon: const Icon(Icons.restart_alt), onPressed: _confirmClear),
        ],
      ),
      body: SafeArea(
        child: uploading
            ? _Analyzing(count: count)
            : Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      Text(
                        'Photograph $plantMinLeaves to $plantMaxLeaves different leaves of the same plant: one '
                        'leaf per photo. Pick leaves from the top, middle and bottom of the plant for a fair picture.',
                        style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      ),
                      const SizedBox(height: 16),
                      GridView.count(
                        crossAxisCount: 3,
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        mainAxisSpacing: 8,
                        crossAxisSpacing: 8,
                        children: [
                          for (final (i, leaf) in leaves.indexed)
                            _LeafTile(
                              number: i + 1,
                              leaf: leaf,
                              failed: _failed.contains(i),
                              onTap: () => _editLeaf(i),
                            ),
                          if (count < plantMaxLeaves) _AddTile(onTap: _addLeaf, first: count == 0),
                        ],
                      ),
                      const SizedBox(height: 12),
                      if (_failed.isNotEmpty)
                        Card(
                          color: theme.colorScheme.errorContainer,
                          child: ListTile(
                            leading: Icon(Icons.search_off, color: theme.colorScheme.onErrorContainer),
                            title: Text(
                              'No leaf found in the marked photos. Tap them to retake or remove.',
                              style: TextStyle(color: theme.colorScheme.onErrorContainer),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
      ),
      bottomNavigationBar: uploading
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      count < plantMinLeaves
                          ? '$count of $plantMaxLeaves leaves · add ${plantMinLeaves - count} more'
                          : '$count of $plantMaxLeaves leaves',
                      style: theme.textTheme.labelLarge,
                    ),
                    const SizedBox(height: 8),
                    FilledButton.icon(
                      onPressed: canAnalyze ? _analyze : null,
                      icon: const Icon(Icons.analytics_outlined),
                      label: const Text('Analyze plant'),
                      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}

class _LeafTile extends StatelessWidget {
  const _LeafTile({required this.number, required this.leaf, required this.failed, required this.onTap});

  final int number;
  final CapturedLeaf leaf;
  final bool failed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: failed ? BorderSide(color: scheme.error, width: 3) : BorderSide.none,
      ),
      child: InkWell(
        onTap: onTap,
        child: Stack(
          fit: StackFit.expand,
          children: [
            _BoxedThumbnail(leaf: leaf),
            Positioned(
              left: 6,
              top: 6,
              child: CircleAvatar(
                radius: 12,
                backgroundColor: failed ? scheme.error : Colors.black54,
                child: Text(
                  '$number',
                  style: TextStyle(fontSize: 12, color: failed ? scheme.onError : Colors.white),
                ),
              ),
            ),
            if (failed)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  color: scheme.error,
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(
                    'No leaf found',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 11, color: scheme.onError),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _BoxedThumbnail extends StatelessWidget {
  const _BoxedThumbnail({required this.leaf});

  final CapturedLeaf leaf;

  @override
  Widget build(BuildContext context) =>
      Image.memory(leaf.bytes, fit: BoxFit.cover, cacheWidth: 400, gaplessPlayback: true);
}

class _AddTile extends StatelessWidget {
  const _AddTile({required this.onTap, required this.first});

  final VoidCallback onTap;
  final bool first;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.primaryContainer,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.add_a_photo_outlined, color: scheme.onPrimaryContainer),
            const SizedBox(height: 6),
            Text(first ? 'Add first leaf' : 'Add leaf', style: TextStyle(color: scheme.onPrimaryContainer)),
          ],
        ),
      ),
    );
  }
}

class _Analyzing extends StatelessWidget {
  const _Analyzing({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const CircularProgressIndicator(),
        const SizedBox(height: 24),
        Text('Analyzing $count leaves…', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        const Text('This can take up to half a minute.'),
      ],
    ),
  );
}
