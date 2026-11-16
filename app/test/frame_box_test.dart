import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:leaf_disease_app/features/scan/camera_screen.dart';
import 'package:leaf_disease_app/features/scan/frame_leaf_screen.dart';

void expectRect(Rect actual, Rect expected) {
  for (final (a, e) in [
    (actual.left, expected.left),
    (actual.top, expected.top),
    (actual.right, expected.right),
    (actual.bottom, expected.bottom),
  ]) {
    expect(a, closeTo(e, 1e-9));
  }
}

void main() {
  const box = Rect.fromLTRB(0.2, 0.2, 0.6, 0.7);

  test('moving keeps the size and stays inside the photo', () {
    expectRect(moveBox(box, const Offset(0.1, -0.1)), const Rect.fromLTRB(0.3, 0.1, 0.7, 0.6));
    // pushed past the right / bottom edge: stops at the edge
    expectRect(moveBox(box, const Offset(0.9, 0.9)), const Rect.fromLTRB(0.6, 0.5, 1.0, 1.0));
    // pushed past the left / top edge
    expectRect(moveBox(box, const Offset(-0.9, -0.9)), const Rect.fromLTRB(0.0, 0.0, 0.4, 0.5));
  });

  test('dragging a corner moves only that corner', () {
    expectRect(
      resizeBox(box, BoxHandle.bottomRight, const Offset(0.1, 0.1)),
      const Rect.fromLTRB(0.2, 0.2, 0.7, 0.8),
    );
    expectRect(
      resizeBox(box, BoxHandle.topLeft, const Offset(-0.5, -0.5)),
      const Rect.fromLTRB(0.0, 0.0, 0.6, 0.7),
    );
  });

  test('a corner cannot cross the opposite edge or make the box too small', () {
    final r = resizeBox(box, BoxHandle.topRight, const Offset(-1, 1));
    expect(r.width, closeTo(minBoxSide, 1e-9));
    expect(r.height, closeTo(minBoxSide, 1e-9));
    expect(r.left, closeTo(0.2, 1e-9)); // the opposite (bottom-left) corner stays put
    expect(r.bottom, closeTo(0.7, 1e-9));
  });

  test('clampBox fixes boxes outside the photo or too small', () {
    expectRect(clampBox(const Rect.fromLTRB(-0.2, -0.1, 1.3, 1.1)), const Rect.fromLTRB(0, 0, 1, 1));
    final tiny = clampBox(const Rect.fromLTRB(0.5, 0.5, 0.51, 0.52));
    expect(tiny.width, closeTo(minBoxSide, 1e-9));
    expect(tiny.height, closeTo(minBoxSide, 1e-9));
  });

  test('a touch grabs the nearest corner, else the inside, else nothing', () {
    const px = Rect.fromLTRB(100, 100, 300, 400);
    expect(handleAt(px, const Offset(110, 95)), BoxHandle.topLeft);
    expect(handleAt(px, const Offset(290, 395)), BoxHandle.bottomRight);
    expect(handleAt(px, const Offset(200, 250)), BoxHandle.move);
    expect(handleAt(px, const Offset(20, 20)), isNull);
  });

  testWidgets('the box screen returns the box on Analyze and null on Retake', (tester) async {
    // 1×1 transparent PNG
    final png = Uint8List.fromList([
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
      0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
      0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
      0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
      0x42, 0x60, 0x82,
    ]);
    const start = Rect.fromLTRB(0.2, 0.2, 0.8, 0.8);
    final results = <Rect?>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => results.add(
              await Navigator.push<Rect>(
                context,
                MaterialPageRoute(builder: (_) => FrameLeafScreen(bytes: png, initialBox: start)),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );

    Future<void> open() async {
      await tester.tap(find.text('open'));
      await tester.pump(); // (no pumpAndSettle while the decode spinner is showing: it never settles)
      await tester.pump(const Duration(milliseconds: 500)); // route transition
      for (var i = 0; i < 20 && find.byType(CircularProgressIndicator).evaluate().isNotEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50))); // real image decode
        await tester.pump();
      }
      expect(find.byType(CircularProgressIndicator), findsNothing);
    }

    await open();
    await tester.tap(find.text('Analyze'));
    await tester.pumpAndSettle();
    await open();
    await tester.tap(find.text('Retake'));
    await tester.pumpAndSettle();
    expect(results, [start, null]);
  });

  test('guide box is centred, 80 % wide, 3:4 and fits the preview', () {
    final g = guideBoxFor(const Size(1080, 1920)); // portrait preview
    expect(g.left, closeTo(0.1, 1e-9));
    expect(g.right, closeTo(0.9, 1e-9));
    expect(g.height * 1920 / (g.width * 1080), closeTo(4 / 3, 1e-9));
    expect((g.top + g.bottom) / 2, closeTo(0.5, 1e-9));

    final wide = guideBoxFor(const Size(1920, 1080)); // landscape: height-limited
    expect(wide.height, closeTo(0.85, 1e-9));
    expect(wide.left, greaterThan(0));
  });
}
