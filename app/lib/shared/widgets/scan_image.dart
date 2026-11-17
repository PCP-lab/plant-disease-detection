import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../config.dart';
import '../device_images.dart';

/// Download URL for a Cloud Storage path, cached per path.
final storageUrlProvider = FutureProvider.family<String, String>(
  (ref, path) => FirebaseStorage.instance.ref(path).getDownloadURL(),
);

/// Shows one scan image, from the first source that has it: [bytes] (a fresh upload), this
/// device's copy ([scanId] + [kind]), a URL (API results) or a Storage path (Firestore docs).
class ScanImage extends ConsumerWidget {
  const ScanImage({
    super.key,
    required this.scanId,
    required this.kind,
    this.bytes,
    this.url,
    this.storagePath,
    this.leafIndex,
    this.fit = BoxFit.contain,
  });

  final String scanId;
  final ScanImageKind kind;

  /// Whole-plant scans: which leaf photo; null for a single-leaf scan.
  final int? leafIndex;
  final Uint8List? bytes;
  final String? url;
  final String? storagePath;
  final BoxFit fit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (bytes != null) return _memory(context, bytes!);
    return ref
        .watch(deviceImageProvider((scanId, kind, leafIndex)))
        .when(
          data: (local) =>
              local != null ? _memory(context, local) : _remote(context, ref),
          loading: _loading,
          error: (_, _) => _remote(context, ref),
        );
  }

  Widget _remote(BuildContext context, WidgetRef ref) {
    final u = url;
    if (u != null && u.isNotEmpty) return _network(context, u);
    if (storagePath == null) return _notOnDevice(context);
    return ref
        .watch(storageUrlProvider(storagePath!))
        .when(
          data: (u) => _network(context, u),
          loading: _loading,
          error: (_, _) => _broken(context),
        );
  }

  Widget _memory(BuildContext context, Uint8List data) => Image.memory(
    data,
    fit: fit,
    gaplessPlayback: true,
    errorBuilder: (_, _, _) => _broken(context),
  );

  Widget _network(BuildContext context, String u) => CachedNetworkImage(
    // Prototype-mode backends return paths relative to the API, e.g. /files/scans/...
    imageUrl: u.startsWith('/') ? '$apiBaseUrl$u' : u,
    // Signed URLs change on every fetch; cache by the stable part.
    cacheKey: Uri.tryParse(u)?.replace(query: '').toString() ?? u,
    fit: fit,
    placeholder: (_, _) => _loading(),
    errorWidget: (_, _, _) => _broken(context),
  );

  Widget _loading() =>
      const Center(child: CircularProgressIndicator(strokeWidth: 2));

  Widget _broken(BuildContext context) => Center(
    child: Icon(
      Icons.broken_image_outlined,
      color: Theme.of(context).colorScheme.outline,
    ),
  );

  /// Images are kept only on the device that made the scan.
  Widget _notOnDevice(BuildContext context) => Tooltip(
    message: 'Image is on the device that made this scan',
    child: Center(
      child: Icon(
        Icons.image_not_supported_outlined,
        color: Theme.of(context).colorScheme.outline,
      ),
    ),
  );
}
