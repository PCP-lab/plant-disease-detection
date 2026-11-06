import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:leaf_disease_app/features/advice/advice_providers.dart';
import 'package:leaf_disease_app/features/advice/widgets/risk_forecast_card.dart';
import 'package:leaf_disease_app/shared/models/advice.dart';
import 'package:leaf_disease_app/shared/models/scan_result.dart';

Map<String, dynamic> dayJson(int i, int mildew, int leaf, {double rain = 0}) {
  String level(int s) => s >= 67 ? 'high' : (s >= 34 ? 'medium' : 'low');
  const labels = ['Today', 'Tomorrow', 'Sat', 'Sun', 'Mon', 'Tue', 'Wed'];
  const weekdays = ['Thu', 'Fri', 'Sat', 'Sun', 'Mon', 'Tue', 'Wed'];
  return {
    'date': '2026-11-${(5 + i).toString().padLeft(2, '0')}',
    'label': labels[i],
    'weekday': weekdays[i],
    'powdery_mildew_risk': mildew,
    'powdery_mildew_level': level(mildew),
    'leaf_spot_risk': leaf,
    'leaf_spot_level': level(leaf),
    'rain_mm': rain,
    'rain_probability_max': rain > 0 ? 80 : 5,
    'temp_min_c': 16.0,
    'temp_max_c': 27.4,
    'humidity_mean_pct': 70,
    'spray_ok': rain == 0,
  };
}

final forecastJson = {
  'days': [
    dayJson(0, 90, 10),
    dayJson(1, 75, 20),
    dayJson(2, 40, 60, rain: 4),
    dayJson(3, 20, 95, rain: 12),
    dayJson(4, 15, 100, rain: 8),
    dayJson(5, 30, 70, rain: 2),
    dayJson(6, 55, 25),
  ],
  'trends': {
    'powdery_mildew': {
      'direction': 'falling',
      'peak_day': 'Today',
      'peak_risk': 90,
      'high_risk_days': ['Today', 'Tomorrow'],
    },
    'leaf_spot': {
      'direction': 'rising',
      'peak_day': 'Mon',
      'peak_risk': 100,
      'high_risk_days': ['Sun', 'Mon', 'Tue'],
    },
  },
};

final scan = ScanResult(
  id: 's1',
  createdAt: DateTime(2026, 11, 5),
  modelVersion: 'test',
  status: ScanStatus.ok,
  primary: const LeafCoverage(
    powderyMildewPct: 3.2,
    leafSpotPct: 0,
    healthyPct: 96.8,
    severity: {'powdery_mildew': Severity.mild, 'leaf_spot': Severity.none},
  ),
  leaves: const [],
);

Future<void> pumpCard(WidgetTester tester, {Brightness b = Brightness.light}) async {
  tester.view.physicalSize = const Size(360, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        riskForecastProvider.overrideWith(
          (ref) async => RiskForecast.fromJson(forecastJson),
        ),
      ],
      child: MaterialApp(
        theme: ThemeData(
          colorSchemeSeed: Colors.green,
          brightness: b,
        ),
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: RiskForecastCard(scan: scan),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  test('RiskForecast.fromJson', () {
    final f = RiskForecast.fromJson(forecastJson);
    expect(f.days, hasLength(7));
    expect(f.days[3].leafSpotLevel, Level.high);
    expect(f.days[3].sprayOk, isFalse);
    expect(f.leafSpot!.direction, TrendDirection.rising);
    expect(f.powderyMildew!.highRiskDays, ['Today', 'Tomorrow']);
  });

  testWidgets('risk card renders at phone width without overflow', (
    tester,
  ) async {
    await pumpCard(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('Disease risk · next 7 days'), findsOneWidget);
    // Trend lines name the disease and the days; the scan's own disease is flagged.
    expect(find.textContaining('Rising · peaks Mon'), findsOneWidget);
    expect(find.textContaining('on this leaf'), findsOneWidget);
    // Table: 7 day columns, mildew High on 2 days and leaf spot High on 3.
    expect(find.text('High'), findsNWidgets(5));
    expect(find.text('12 mm'), findsOneWidget);
  });

  testWidgets('risk card renders in dark mode', (tester) async {
    await pumpCard(tester, b: Brightness.dark);
    expect(tester.takeException(), isNull);
  });
}
