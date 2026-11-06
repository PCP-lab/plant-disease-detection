import 'package:flutter_test/flutter_test.dart';
import 'package:leaf_disease_app/shared/models/advice.dart';

void main() {
  test('Advice.fromJson parses the backend response', () {
    final advice = Advice.fromJson({
      'summary': 'Moderate powdery mildew.',
      'urgency': 'high',
      'actions': ['Remove worst leaves'],
      'treatments': [
        {
          'name': 'Sulfur (wettable)',
          'type': 'organic',
          'how': 'Morning spray',
          'frac_group': 'M2',
        },
        {'name': 'Prune', 'type': 'cultural', 'how': '', 'frac_group': null},
      ],
      'spray_timing': 'Today 08:00–18:00.',
      'prevention': ['Avoid excess nitrogen'],
      'weather': {
        'temperature_c': 19.5,
        'humidity_pct': 62,
        'wind_kmh': 4,
        'rain_expected_24h': false,
        'rain_mm_24h': 0,
        'max_wind_kmh_24h': 5,
        'spray_window': 'Today 08:00–18:00',
        'leaf_spot_pressure': 'low',
        'powdery_mildew_pressure': 'high',
      },
      'photo_observations': 'White powdery patches on the upper surface.',
      'photo_note': null,
      'model': 'gpt-oss:20b',
      'vision_model': 'qwen2.5vl:7b',
      'disclaimer': 'Check the label.',
    });

    expect(advice.urgency, Level.high);
    expect(advice.treatments.first.fracGroup, 'M2');
    expect(advice.treatments.last.type, TreatmentType.cultural);
    expect(advice.weather!.humidityPct, 62);
    expect(advice.weather!.powderyMildewPressure, Level.high);
    expect(advice.photoObservations, startsWith('White powdery'));
    expect(advice.visionModel, 'qwen2.5vl:7b');
  });

  test('Advice.fromJson tolerates missing weather and unknown enums', () {
    final advice = Advice.fromJson({
      'summary': 'ok',
      'urgency': 'extreme',
      'weather': null,
    });
    expect(advice.weather, isNull);
    expect(advice.urgency, Level.low);
    expect(advice.actions, isEmpty);
  });
}
