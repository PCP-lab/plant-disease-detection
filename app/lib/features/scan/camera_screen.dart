import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

/// What the camera screen hands back: a photo plus the guide box it was framed in, or a request to use another
/// source instead.
class CameraOutcome {
  const CameraOutcome.photo(XFile this.file, Rect this.guide) : fallback = null;
  const CameraOutcome.fallback(CameraFallback this.fallback) : file = null, guide = null;

  final XFile? file;

  /// The guide box as fractions of the photo (the preview is shown uncropped, so it maps 1:1).
  final Rect? guide;
  final CameraFallback? fallback;
}

enum CameraFallback { gallery, systemCamera }

/// The guide box for a preview of [preview] size, as fractions of it: 80 % wide, 3:4, centred, at most 85 % tall.
Rect guideBoxFor(Size preview) {
  final w = 0.8 * preview.width;
  final h = math.min(w * 4 / 3, 0.85 * preview.height);
  final r = Rect.fromCenter(center: preview.center(Offset.zero), width: w, height: h);
  return Rect.fromLTRB(
    r.left / preview.width,
    r.top / preview.height,
    r.right / preview.width,
    r.bottom / preview.height,
  );
}

/// In-app camera with a guide box, so photos look like what the model is validated on: one leaf filling the frame.
class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> with WidgetsBindingObserver {
  CameraController? _controller;
  String? _error;
  bool _busy = false;
  FlashMode _flash = FlashMode.off;
  Rect _guide = const Rect.fromLTRB(0.1, 0.1, 0.9, 0.9);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _start();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }

  // Release the camera while the app is in the background; reopen it on return.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive) {
      final c = _controller;
      if (c != null) {
        setState(() => _controller = null);
        c.dispose();
      }
    } else if (state == AppLifecycleState.resumed && _controller == null && _error == null) {
      _start();
    }
  }

  Future<void> _start() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        if (mounted) setState(() => _error = 'No camera found on this device.');
        return;
      }
      final camera = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final c = CameraController(
        camera,
        ResolutionPreset.veryHigh,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      await c.initialize();
      try {
        await c.setFlashMode(_flash);
      } on CameraException {
        // no flash on this camera
      }
      if (!mounted) {
        await c.dispose();
        return;
      }
      setState(() => _controller = c);
    } on CameraException catch (e) {
      final denied = e.code.startsWith('CameraAccessDenied') || e.code.contains('ermission');
      if (mounted) {
        setState(
          () => _error = denied
              ? 'Camera permission was denied.'
              : 'Could not start the camera (${e.description ?? e.code}).',
        );
      }
    }
  }

  Future<void> _capture() async {
    final c = _controller;
    if (c == null || _busy || c.value.isTakingPicture) return;
    setState(() => _busy = true);
    try {
      final file = await c.takePicture();
      if (mounted) Navigator.pop(context, CameraOutcome.photo(file, _guide));
    } on CameraException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not take the photo (${e.description ?? e.code}).')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggleFlash() async {
    final next = switch (_flash) {
      FlashMode.off => FlashMode.auto,
      FlashMode.auto => FlashMode.always,
      _ => FlashMode.off,
    };
    try {
      await _controller?.setFlashMode(next);
      setState(() => _flash = next);
    } on CameraException {
      // no flash on this camera
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Photograph one leaf'),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
      ),
      body: SafeArea(
        child: _error != null
            ? _CameraError(message: _error!)
            : c == null || !c.value.isInitialized
            ? const Center(child: CircularProgressIndicator())
            : Column(
                children: [
                  Expanded(
                    child: Center(
                      child: CameraPreview(
                        c,
                        child: LayoutBuilder(
                          builder: (context, box) {
                            _guide = guideBoxFor(box.biggest);
                            return CustomPaint(
                              painter: _GuidePainter(_guide),
                              child: const Align(
                                alignment: Alignment.topCenter,
                                child: Padding(
                                  padding: EdgeInsets.only(top: 10),
                                  child: _Hint(),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        IconButton(
                          tooltip: 'Choose from gallery',
                          iconSize: 30,
                          color: Colors.white,
                          onPressed: _busy
                              ? null
                              : () => Navigator.pop(context, const CameraOutcome.fallback(CameraFallback.gallery)),
                          icon: const Icon(Icons.photo_library_outlined),
                        ),
                        Semantics(
                          button: true,
                          label: 'Take photo',
                          child: GestureDetector(
                            onTap: _capture,
                            child: Container(
                              width: 74,
                              height: 74,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(color: Colors.white, width: 4),
                              ),
                              padding: const EdgeInsets.all(5),
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: _busy ? Colors.white38 : Colors.white,
                                ),
                              ),
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Flash: ${_flash.name}',
                          iconSize: 30,
                          color: Colors.white,
                          onPressed: _toggleFlash,
                          icon: Icon(switch (_flash) {
                            FlashMode.off => Icons.flash_off,
                            FlashMode.auto => Icons.flash_auto,
                            _ => Icons.flash_on,
                          }),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint();

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(999)),
    child: const Text(
      'Fill the box with ONE leaf · upper side · in focus',
      style: TextStyle(color: Colors.white, fontSize: 13),
    ),
  );
}

class _CameraError extends StatelessWidget {
  const _CameraError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.no_photography_outlined, color: Colors.white70, size: 48),
          const SizedBox(height: 12),
          Text(message, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white)),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: () => Navigator.pop(context, const CameraOutcome.fallback(CameraFallback.systemCamera)),
            icon: const Icon(Icons.photo_camera),
            label: const Text("Use the phone's camera"),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: () => Navigator.pop(context, const CameraOutcome.fallback(CameraFallback.gallery)),
            style: TextButton.styleFrom(foregroundColor: Colors.white),
            child: const Text('Choose from gallery'),
          ),
        ],
      ),
    ),
  );
}

/// Dims the preview outside the guide box and draws a rounded frame around it.
class _GuidePainter extends CustomPainter {
  _GuidePainter(this.guide);

  final Rect guide;

  @override
  void paint(Canvas canvas, Size size) {
    final box = RRect.fromRectAndRadius(
      Rect.fromLTRB(guide.left * size.width, guide.top * size.height, guide.right * size.width, guide.bottom * size.height),
      const Radius.circular(18),
    );
    canvas.drawPath(
      Path.combine(PathOperation.difference, Path()..addRect(Offset.zero & size), Path()..addRRect(box)),
      Paint()..color = Colors.black45,
    );
    canvas.drawRRect(
      box,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );
  }

  @override
  bool shouldRepaint(_GuidePainter old) => old.guide != guide;
}
