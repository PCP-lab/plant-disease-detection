// Getting one boxed leaf photo: the in-app camera with its guide box (Android/iOS) or image_picker, then
// "box the leaf". Shared by the single-leaf scan (ScanScreen) and the whole-plant scan (PlantCaptureScreen).

import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'camera_screen.dart';
import 'frame_leaf_screen.dart';

/// A photo and the box the user fitted around its leaf (fractions of the upright photo).
class CapturedLeaf {
  const CapturedLeaf(this.file, this.bytes, this.box);

  final XFile file;
  final Uint8List bytes;
  final Rect box;
}

const _maxSide = 2048.0;
const _quality = 90;

void _snack(BuildContext context, String message) =>
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));

Future<XFile?> _pick(BuildContext context, ImageSource source) async {
  try {
    return await ImagePicker().pickImage(
      source: source,
      maxWidth: _maxSide,
      maxHeight: _maxSide,
      imageQuality: _quality,
    );
  } catch (e) {
    if (context.mounted) _snack(context, 'Could not open the camera/gallery: $e');
    return null;
  }
}

/// Several gallery photos at once, at most [limit]. Empty if cancelled.
Future<List<XFile>> pickGalleryImages(BuildContext context, {required int limit}) async {
  try {
    final picked = await ImagePicker().pickMultiImage(
      maxWidth: _maxSide,
      maxHeight: _maxSide,
      imageQuality: _quality,
      limit: limit < 2 ? null : limit,
    );
    if (picked.length > limit && context.mounted) {
      _snack(context, 'Only the first $limit photos were added.');
    }
    return picked.take(limit).toList();
  } catch (e) {
    if (context.mounted) _snack(context, 'Could not open the gallery: $e');
    return const [];
  }
}

/// Bottom sheet: true = camera, false = gallery, null = dismissed.
Future<bool?> showPhotoSourceSheet(BuildContext context, {required String title}) =>
    showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(title, style: Theme.of(context).textTheme.titleMedium),
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera),
              title: Text(kIsWeb ? 'Take or choose a photo' : 'Take a photo'),
              subtitle: kIsWeb ? null : const Text('Guided camera: fit the leaf in the box'),
              onTap: () => Navigator.pop(context, true),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose from gallery'),
              onTap: () => Navigator.pop(context, false),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );

/// The "box the leaf" screen for [bytes]. Null on retake / back.
Future<Rect?> boxLeaf(
  BuildContext context,
  Uint8List bytes, {
  Rect initialBox = defaultLeafBox,
  String retakeLabel = 'Retake',
  String confirmLabel = 'Analyze',
}) => Navigator.of(context).push<Rect>(
  MaterialPageRoute(
    builder: (_) => FrameLeafScreen(
      bytes: bytes,
      initialBox: initialBox,
      retakeLabel: retakeLabel,
      confirmLabel: confirmLabel,
    ),
  ),
);

/// One leaf photo, boxed: the guided camera ([camera], Android/iOS; image_picker on web) or the gallery, then the
/// box screen. "Retake" / "Choose another" on the box screen goes back to the camera / gallery.
/// Null if the user backs out.
Future<CapturedLeaf?> captureLeaf(
  BuildContext context, {
  required bool camera,
  String confirmLabel = 'Analyze',
}) async {
  final nav = Navigator.of(context);
  while (true) {
    XFile? image;
    var start = defaultLeafBox;
    if (camera && !kIsWeb) {
      final out = await nav.push<CameraOutcome>(
        MaterialPageRoute(builder: (_) => const CameraScreen()),
      );
      if (out == null || !context.mounted) return null;
      if (out.file != null) {
        image = out.file;
        start = out.guide!;
      } else {
        image = await _pick(
          context,
          out.fallback == CameraFallback.gallery ? ImageSource.gallery : ImageSource.camera,
        );
      }
    } else {
      image = await _pick(context, camera ? ImageSource.camera : ImageSource.gallery);
    }
    if (image == null || !context.mounted) return null;

    final bytes = await image.readAsBytes();
    if (!context.mounted) return null;
    final box = await boxLeaf(
      context,
      bytes,
      initialBox: start,
      retakeLabel: camera ? 'Retake' : 'Choose another',
      confirmLabel: confirmLabel,
    );
    if (!context.mounted) return null;
    if (box != null) return CapturedLeaf(image, bytes, box);
  }
}
