// Scan upload state: the latest upload's result, shown by ResultScreen.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../shared/api_client.dart';
import '../../shared/device_images.dart';
import '../../shared/models/scan_result.dart';

final scanUploadProvider =
    NotifierProvider<ScanUploadNotifier, AsyncValue<ScanResult>?>(
      ScanUploadNotifier.new,
    );

class ScanUploadNotifier extends Notifier<AsyncValue<ScanResult>?> {
  @override
  AsyncValue<ScanResult>? build() => null;

  /// Uploads [image]; the new state is also returned so callers can react to it.
  Future<AsyncValue<ScanResult>> upload(XFile image) async {
    state = const AsyncLoading();
    final result = await AsyncValue.guard(() async {
      final scan = await ref.read(apiClientProvider).createScan(image);
      final original = scan.imageBytes, overlay = scan.overlayBytes;
      if (original != null && overlay != null) {
        // Keep the images for History. If this fails the result is still shown from memory.
        try {
          await ref
              .read(deviceImagesProvider)
              .save(scan.id, original: original, overlay: overlay);
        } catch (_) {}
      }
      return scan;
    });
    state = result;
    return result;
  }

  void clear() => state = null;
}
