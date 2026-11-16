import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Starting box for photos that didn't come through the camera guide box (gallery, web, system camera).
const defaultLeafBox = Rect.fromLTRB(0.1, 0.1, 0.9, 0.9);

/// Smallest box side, as a share of the photo (the backend accepts down to 0.05).
const minBoxSide = 0.1;

enum BoxHandle { move, topLeft, topRight, bottomLeft, bottomRight }

double _clamp(double v, double lo, double hi) => v < lo ? lo : (v > hi ? hi : v);

/// [box] (fractions of the photo) kept inside the photo and at least [minBoxSide] on each side.
Rect clampBox(Rect box) {
  final l = _clamp(box.left, 0, 1 - minBoxSide);
  final t = _clamp(box.top, 0, 1 - minBoxSide);
  return Rect.fromLTRB(
    l,
    t,
    _clamp(box.right, l + minBoxSide, 1),
    _clamp(box.bottom, t + minBoxSide, 1),
  );
}

/// Moves [box] by [delta] (fractions of the photo) without leaving the photo or changing its size.
Rect moveBox(Rect box, Offset delta) => box.shift(
  Offset(
    _clamp(delta.dx, -box.left, 1 - box.right),
    _clamp(delta.dy, -box.top, 1 - box.bottom),
  ),
);

/// Drags one corner of [box] by [delta]; the opposite corner stays put.
Rect resizeBox(Rect box, BoxHandle handle, Offset delta) {
  var l = box.left, t = box.top, r = box.right, b = box.bottom;
  final left = handle == BoxHandle.topLeft || handle == BoxHandle.bottomLeft;
  final top = handle == BoxHandle.topLeft || handle == BoxHandle.topRight;
  if (handle == BoxHandle.move) return moveBox(box, delta);
  if (left) {
    l = _clamp(l + delta.dx, 0, r - minBoxSide);
  } else {
    r = _clamp(r + delta.dx, l + minBoxSide, 1);
  }
  if (top) {
    t = _clamp(t + delta.dy, 0, b - minBoxSide);
  } else {
    b = _clamp(b + delta.dy, t + minBoxSide, 1);
  }
  return Rect.fromLTRB(l, t, r, b);
}

/// Which part of the on-screen box [boxPx] a touch at [p] grabs: a corner within [radius], else the inside.
BoxHandle? handleAt(Rect boxPx, Offset p, {double radius = 32}) {
  final corners = {
    BoxHandle.topLeft: boxPx.topLeft,
    BoxHandle.topRight: boxPx.topRight,
    BoxHandle.bottomLeft: boxPx.bottomLeft,
    BoxHandle.bottomRight: boxPx.bottomRight,
  };
  BoxHandle? best;
  var bestDist = radius;
  for (final e in corners.entries) {
    final d = (e.value - p).distance;
    if (d <= bestDist) {
      best = e.key;
      bestDist = d;
    }
  }
  return best ?? (boxPx.contains(p) ? BoxHandle.move : null);
}

/// Shows the photo with a box the user fits around the one leaf to check. Pops the box (fractions of the
/// upright photo) on "Analyze", or null on "Retake" / back.
class FrameLeafScreen extends StatefulWidget {
  const FrameLeafScreen({
    super.key,
    required this.bytes,
    this.initialBox = defaultLeafBox,
    this.retakeLabel = 'Retake',
  });

  final Uint8List bytes;
  final Rect initialBox;
  final String retakeLabel;

  @override
  State<FrameLeafScreen> createState() => _FrameLeafScreenState();
}

class _FrameLeafScreenState extends State<FrameLeafScreen> {
  late Rect _box = clampBox(widget.initialBox);
  Size? _imageSize;
  BoxHandle? _drag;

  @override
  void initState() {
    super.initState();
    _loadSize();
  }

  /// The photo's size as Flutter displays it, needed to place the box exactly on the photo.
  Future<void> _loadSize() async {
    final codec = await ui.instantiateImageCodec(widget.bytes);
    final frame = await codec.getNextFrame();
    final size = Size(frame.image.width.toDouble(), frame.image.height.toDouble());
    frame.image.dispose();
    codec.dispose();
    if (mounted) setState(() => _imageSize = size);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Box the leaf'),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
      ),
      body: SafeArea(
        child: Column(
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: Text(
                'Drag the corners so the box fits around the one leaf to check.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70),
              ),
            ),
            Expanded(
              child: _imageSize == null
                  ? const Center(child: CircularProgressIndicator())
                  : LayoutBuilder(
                      builder: (context, c) {
                        final area = Offset.zero & c.biggest;
                        final fitted = applyBoxFit(BoxFit.contain, _imageSize!, c.biggest);
                        final photo = Alignment.center.inscribe(fitted.destination, area);
                        final boxPx = Rect.fromLTRB(
                          photo.left + _box.left * photo.width,
                          photo.top + _box.top * photo.height,
                          photo.left + _box.right * photo.width,
                          photo.top + _box.bottom * photo.height,
                        );
                        return GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onPanStart: (d) => _drag = handleAt(boxPx, d.localPosition),
                          onPanUpdate: (d) {
                            final handle = _drag;
                            if (handle == null) return;
                            final delta = Offset(d.delta.dx / photo.width, d.delta.dy / photo.height);
                            setState(() => _box = resizeBox(_box, handle, delta));
                          },
                          onPanEnd: (_) => _drag = null,
                          child: Stack(
                            children: [
                              Positioned.fromRect(
                                rect: photo,
                                child: Image.memory(widget.bytes, fit: BoxFit.fill, gaplessPlayback: true),
                              ),
                              Positioned.fill(
                                child: CustomPaint(
                                  painter: _BoxPainter(
                                    photo: photo,
                                    box: boxPx,
                                    color: theme.colorScheme.primaryContainer,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.refresh),
                      label: Text(widget.retakeLabel),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: const BorderSide(color: Colors.white54),
                        minimumSize: const Size.fromHeight(48),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _imageSize == null ? null : () => Navigator.pop(context, _box),
                      icon: const Icon(Icons.check),
                      label: const Text('Analyze'),
                      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                    ),
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

/// Dims the photo outside the box and draws the box with corner handles.
class _BoxPainter extends CustomPainter {
  _BoxPainter({required this.photo, required this.box, required this.color});

  final Rect photo;
  final Rect box;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawPath(
      Path.combine(PathOperation.difference, Path()..addRect(photo), Path()..addRect(box)),
      Paint()..color = Colors.black54,
    );
    canvas.drawRect(
      box,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    final handle = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round;
    const len = 22.0;
    for (final (corner, sx, sy) in [
      (box.topLeft, 1.0, 1.0),
      (box.topRight, -1.0, 1.0),
      (box.bottomLeft, 1.0, -1.0),
      (box.bottomRight, -1.0, -1.0),
    ]) {
      canvas.drawLine(corner, corner.translate(sx * len, 0), handle);
      canvas.drawLine(corner, corner.translate(0, sy * len), handle);
    }
  }

  @override
  bool shouldRepaint(_BoxPainter old) => old.box != box || old.photo != photo || old.color != color;
}
