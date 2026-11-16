import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:leaf_disease_app/shared/device_images.dart';
import 'package:leaf_disease_app/shared/models/scan_result.dart';

void main() {
  test('parses an API ScanResult', () {
    final scan = ScanResult.fromJson({
      'id': 'abc',
      'created_at': '2026-10-26T10:00:00Z',
      'model_version': 'rfdetr-seg-m-v1',
      'status': 'ok',
      'primary': {
        'powdery_mildew_pct': 12.5,
        'leaf_spot_pct': 3,
        'healthy_pct': 84.5,
        'severity': {'powdery_mildew': 'moderate', 'leaf_spot': 'mild'},
      },
      'leaves': [],
      'image_url': 'https://example.com/original.jpg',
      'overlay_url': 'https://example.com/overlay.png',
    });

    expect(scan.status, ScanStatus.ok);
    expect(scan.primary!.leafSpotPct, 3.0);
    expect(scan.primary!.worstSeverity, Severity.moderate);
    expect(scan.createdAt.toUtc(), DateTime.utc(2026, 10, 26, 10));
  });

  test('parses the photo check (framing)', () {
    final base = {
      'id': 'f',
      'created_at': '2026-11-13T10:00:00Z',
      'model_version': 'v2',
      'status': 'ok',
      'primary': null,
      'leaves': [],
    };
    final warn = ScanResult.fromJson({
      ...base,
      'framing': {'ok': false, 'issue': 'several_leaves', 'leaf_frac': 0.31, 'dominance': 1.2},
    }).framing!;
    expect(warn.ok, isFalse);
    expect(warn.issue, 'several_leaves');
    expect(warn.leafFrac, 0.31);
    expect(warn.dominance, 1.2);

    final single = ScanResult.fromJson({
      ...base,
      'framing': {'ok': true, 'issue': null, 'leaf_frac': 0.6, 'dominance': null},
    }).framing!;
    expect(single.ok, isTrue);
    expect(single.dominance, isNull);

    // Scans saved before the check existed have no framing.
    expect(ScanResult.fromJson(base).framing, isNull);
  });

  test('parses no_leaf_detected', () {
    final scan = ScanResult.fromJson({
      'id': 'x',
      'created_at': '2026-10-26T10:00:00Z',
      'model_version': '',
      'status': 'no_leaf_detected',
      'primary': null,
      'leaves': [],
      'image_url': '',
      'overlay_url': '',
    });

    expect(scan.status, ScanStatus.noLeafDetected);
    expect(scan.primary, isNull);
    expect(scan.overlayBytes, isNull);
  });

  test('decodes the inline images of a fresh upload', () {
    final scan = ScanResult.fromJson({
      'id': 'x',
      'created_at': '2026-10-26T10:00:00Z',
      'model_version': '',
      'status': 'ok',
      'primary': null,
      'leaves': [],
      'image_url': null,
      'overlay_url': null,
      'image_jpeg_b64': base64Encode([0xff, 0xd8]),
      'overlay_jpeg_b64': base64Encode([0xff, 0xd9]),
    });

    expect(scan.imageBytes, [0xff, 0xd8]);
    expect(scan.overlayBytes, [0xff, 0xd9]);
    expect(scan.imageUrl, isNull);
  });

  test('device images round trip', () async {
    final store = DeviceImages.inMemory();
    await store.save(
      'scan1',
      original: Uint8List.fromList([1]),
      overlay: Uint8List.fromList([2]),
    );
    expect(await store.read('scan1', ScanImageKind.overlay), [2]);

    await store.delete('scan1');
    expect(await store.read('scan1', ScanImageKind.original), isNull);
  });
}
