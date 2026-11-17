// Scan images kept on this device: Hive files on Android/iOS, IndexedDB on web.
// Without a Cloud Storage bucket these are the only copies; Firestore holds just the results.
// They're lost if the app is uninstalled or its data cleared, and don't sync to other devices.

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';

enum ScanImageKind { original, overlay }

class DeviceImages {
  DeviceImages._(this._box);

  /// Not persisted; the default until main() opens the real store, and for tests.
  DeviceImages.inMemory() : _box = null;

  /// Lazy box: images are read from disk on demand rather than all loaded at startup.
  static Future<DeviceImages> open() async {
    await Hive.initFlutter();
    return DeviceImages._(await Hive.openLazyBox<Uint8List>('scan_images'));
  }

  final LazyBox<Uint8List>? _box;
  final _memory = <String, Uint8List>{};

  /// Whole-plant scans have up to this many leaf photos ([leafIndex] 0 to 5).
  static const maxLeaves = 6;

  /// [leafIndex]: the leaf photo of a whole-plant scan; null for a single-leaf scan.
  static String _key(String scanId, ScanImageKind kind, [int? leafIndex]) =>
      leafIndex == null
      ? '$scanId/${kind.name}'
      : '$scanId/leaf$leafIndex/${kind.name}';

  Future<void> save(
    String scanId, {
    required Uint8List original,
    required Uint8List overlay,
    int? leafIndex,
  }) async {
    final entries = {
      _key(scanId, ScanImageKind.original, leafIndex): original,
      _key(scanId, ScanImageKind.overlay, leafIndex): overlay,
    };
    final box = _box;
    box == null ? _memory.addAll(entries) : await box.putAll(entries);
  }

  Future<Uint8List?> read(
    String scanId,
    ScanImageKind kind, {
    int? leafIndex,
  }) async {
    final key = _key(scanId, kind, leafIndex);
    final box = _box;
    return box == null ? _memory[key] : box.get(key);
  }

  /// Deletes the scan's images, including every leaf photo of a whole-plant scan.
  Future<void> delete(String scanId) async {
    final keys = [
      for (final kind in ScanImageKind.values) ...[
        _key(scanId, kind),
        for (var i = 0; i < maxLeaves; i++) _key(scanId, kind, i),
      ],
    ];
    final box = _box;
    box == null ? keys.forEach(_memory.remove) : await box.deleteAll(keys);
  }
}

extension DeviceImagesClear on DeviceImages {
  /// Deletes every image on this device, e.g. after the account is deleted.
  Future<void> clear() async {
    final box = _box;
    box == null ? _memory.clear() : await box.clear();
  }
}

/// Overridden in main() with [DeviceImages.open].
final deviceImagesProvider = Provider<DeviceImages>(
  (ref) => DeviceImages.inMemory(),
);

/// One stored image (scan id, kind, leaf index for whole-plant scans); null if this device doesn't have it
/// (e.g. scanned on another device).
final deviceImageProvider = FutureProvider.autoDispose
    .family<Uint8List?, (String, ScanImageKind, int?)>(
      (ref, arg) => ref
          .watch(deviceImagesProvider)
          .read(arg.$1, arg.$2, leafIndex: arg.$3),
    );
