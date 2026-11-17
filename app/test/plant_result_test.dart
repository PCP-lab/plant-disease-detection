import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:leaf_disease_app/features/plant/widgets/plant_result_view.dart';
import 'package:leaf_disease_app/shared/models/scan_result.dart';

ScanResult plantScan() => ScanResult.fromJson({
  'id': 'p1',
  'created_at': '2026-11-17T10:00:00Z',
  'model_version': 'yolo26x-seg-lds-v2',
  'kind': 'plant',
  'status': 'ok',
  'primary': {
    'powdery_mildew_pct': 2.81,
    'leaf_spot_pct': 0.54,
    'healthy_pct': 96.67,
    'severity': {'powdery_mildew': 'moderate', 'leaf_spot': 'moderate'},
  },
  'leaves': [
    for (final i in [0, 1, 2, 3, 4, 5])
      {
        'powdery_mildew_pct': 1.0 + i,
        'leaf_spot_pct': 0.5,
        'healthy_pct': 98.5 - i,
        'severity': {'powdery_mildew': 'mild', 'leaf_spot': 'mild'},
        'index': i,
      },
  ],
  'plant': {
    'leaves_analysed': 6,
    'leaves_affected': {'powdery_mildew': 6, 'leaf_spot': 6},
    'spread': {'powdery_mildew': 1.0, 'leaf_spot': 1.0},
    'raised': ['powdery_mildew', 'leaf_spot'],
    'skipped': [],
    'cover': 5,
  },
  'leaf_images': [
    for (final i in [0, 1, 2, 3, 4, 5]) {'index': i, 'overlay_jpeg_b64': base64Encode([0])},
  ],
});

void main() {
  testWidgets('plant result renders at phone width without overflow', (tester) async {
    tester.view.physicalSize = const Size(360, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(home: Scaffold(body: PlantResultView(scan: plantScan()))),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('Whole plant · 6 leaves'), findsOneWidget);
    expect(find.text('The plant is moderately affected'), findsOneWidget);
    expect(find.text('avg 2.8% · on 6 of 6 leaves'), findsOneWidget);
    expect(find.textContaining('spreading through the plant'), findsOneWidget);
    expect(find.text('Leaf 6 · 6.5%'), findsNothing); // the strip scrolls; later leaves are off screen
    expect(find.text('Leaf 1 · 1.5%'), findsOneWidget);
  });
}
