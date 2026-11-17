// Whole-plant scan state: the leaf photos being collected (draft) and the latest upload's result.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shared/api_client.dart';
import '../../shared/device_images.dart';
import '../../shared/models/scan_result.dart';
import '../scan/capture_leaf.dart';

/// Must match the backend's settings.plant_min_leaves / plant_max_leaves.
const plantMinLeaves = 3;
const plantMaxLeaves = DeviceImages.maxLeaves;

/// The leaf photos collected so far for a whole-plant scan, in order.
final plantDraftProvider = NotifierProvider<PlantDraftNotifier, List<CapturedLeaf>>(
  PlantDraftNotifier.new,
);

class PlantDraftNotifier extends Notifier<List<CapturedLeaf>> {
  @override
  List<CapturedLeaf> build() => const [];

  bool get isFull => state.length >= plantMaxLeaves;

  void add(CapturedLeaf leaf) {
    if (!isFull) state = [...state, leaf];
  }

  void replace(int i, CapturedLeaf leaf) => state = [...state]..[i] = leaf;

  void remove(int i) => state = [...state]..removeAt(i);

  void clear() => state = const [];
}

final plantUploadProvider =
    NotifierProvider<PlantUploadNotifier, AsyncValue<ScanResult>?>(
      PlantUploadNotifier.new,
    );

class PlantUploadNotifier extends Notifier<AsyncValue<ScanResult>?> {
  @override
  AsyncValue<ScanResult>? build() => null;

  /// Uploads the draft's leaves. On success the draft is cleared and each leaf's images are kept on the device.
  Future<AsyncValue<ScanResult>> upload() async {
    final leaves = ref.read(plantDraftProvider);
    state = const AsyncLoading();
    final result = await AsyncValue.guard(() async {
      final scan = await ref
          .read(apiClientProvider)
          .createPlantScan([for (final l in leaves) (l.file, l.box)]);
      // Keep the images for History. If this fails the result is still shown from memory.
      try {
        for (final img in scan.leafImages ?? const <LeafImages>[]) {
          final original = img.imageBytes, overlay = img.overlayBytes;
          if (original == null || overlay == null) continue;
          await ref
              .read(deviceImagesProvider)
              .save(scan.id, original: original, overlay: overlay, leafIndex: img.index);
        }
      } catch (_) {}
      return scan;
    });
    state = result;
    if (result.hasValue) ref.read(plantDraftProvider.notifier).clear();
    return result;
  }

  void clear() => state = null;
}
