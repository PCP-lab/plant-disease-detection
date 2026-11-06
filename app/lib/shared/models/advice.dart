// Mirrors backend/app/schemas.py (Advice, Treatment, WeatherSummary).

enum Level {
  low,
  medium,
  high;

  static Level parse(Object? value) =>
      Level.values.firstWhere((l) => l.name == value, orElse: () => Level.low);
}

enum TreatmentType {
  cultural,
  organic,
  conventional;

  static TreatmentType parse(Object? value) => TreatmentType.values.firstWhere(
    (t) => t.name == value,
    orElse: () => TreatmentType.cultural,
  );
}

class WeatherSummary {
  const WeatherSummary({
    this.temperatureC,
    this.humidityPct,
    this.windKmh,
    required this.rainExpected24h,
    required this.rainMm24h,
    this.maxWindKmh24h,
    this.sprayWindow,
    required this.leafSpotPressure,
    required this.powderyMildewPressure,
  });

  final double? temperatureC;
  final double? humidityPct;
  final double? windKmh;
  final bool rainExpected24h;
  final double rainMm24h;
  final double? maxWindKmh24h;

  /// e.g. "Today 08:00–18:00"; null when there's no good window in the next 48 h.
  final String? sprayWindow;
  final Level leafSpotPressure;
  final Level powderyMildewPressure;

  factory WeatherSummary.fromJson(Map<String, dynamic> json) => WeatherSummary(
    temperatureC: (json['temperature_c'] as num?)?.toDouble(),
    humidityPct: (json['humidity_pct'] as num?)?.toDouble(),
    windKmh: (json['wind_kmh'] as num?)?.toDouble(),
    rainExpected24h: json['rain_expected_24h'] as bool? ?? false,
    rainMm24h: (json['rain_mm_24h'] as num? ?? 0).toDouble(),
    maxWindKmh24h: (json['max_wind_kmh_24h'] as num?)?.toDouble(),
    sprayWindow: json['spray_window'] as String?,
    leafSpotPressure: Level.parse(json['leaf_spot_pressure']),
    powderyMildewPressure: Level.parse(json['powdery_mildew_pressure']),
  );
}

/// One day of the weather risk forecast. Risks are 0–100: how favourable that day's
/// weather is for the disease to infect and spread (not how much disease there is).
class DayRisk {
  const DayRisk({
    required this.date,
    required this.label,
    required this.weekday,
    required this.powderyMildewRisk,
    required this.powderyMildewLevel,
    required this.leafSpotRisk,
    required this.leafSpotLevel,
    required this.rainMm,
    required this.rainProbabilityMax,
    this.tempMinC,
    this.tempMaxC,
    this.humidityMeanPct,
    required this.sprayOk,
  });

  final DateTime date;

  /// "Today", "Tomorrow", "Sat".
  final String label;

  /// "Fri".
  final String weekday;
  final int powderyMildewRisk;
  final Level powderyMildewLevel;
  final int leafSpotRisk;
  final Level leafSpotLevel;
  final double rainMm;
  final int rainProbabilityMax;
  final double? tempMinC;
  final double? tempMaxC;
  final int? humidityMeanPct;

  /// Has a ≥ 4 h dry, calm daylight window for spraying.
  final bool sprayOk;

  factory DayRisk.fromJson(Map<String, dynamic> json) => DayRisk(
    date: DateTime.parse(json['date'] as String),
    label: json['label'] as String? ?? '',
    weekday: json['weekday'] as String? ?? '',
    powderyMildewRisk: (json['powdery_mildew_risk'] as num? ?? 0).toInt(),
    powderyMildewLevel: Level.parse(json['powdery_mildew_level']),
    leafSpotRisk: (json['leaf_spot_risk'] as num? ?? 0).toInt(),
    leafSpotLevel: Level.parse(json['leaf_spot_level']),
    rainMm: (json['rain_mm'] as num? ?? 0).toDouble(),
    rainProbabilityMax: (json['rain_probability_max'] as num? ?? 0).toInt(),
    tempMinC: (json['temp_min_c'] as num?)?.toDouble(),
    tempMaxC: (json['temp_max_c'] as num?)?.toDouble(),
    humidityMeanPct: (json['humidity_mean_pct'] as num?)?.toInt(),
    sprayOk: json['spray_ok'] as bool? ?? false,
  );
}

enum TrendDirection {
  rising,
  falling,
  steady;

  static TrendDirection parse(Object? value) => TrendDirection.values
      .firstWhere((t) => t.name == value, orElse: () => TrendDirection.steady);
}

class DiseaseTrend {
  const DiseaseTrend({
    required this.direction,
    this.peakDay,
    required this.peakRisk,
    required this.highRiskDays,
  });

  final TrendDirection direction;
  final String? peakDay;
  final int peakRisk;
  final List<String> highRiskDays;

  factory DiseaseTrend.fromJson(Map<String, dynamic> json) => DiseaseTrend(
    direction: TrendDirection.parse(json['direction']),
    peakDay: json['peak_day'] as String?,
    peakRisk: (json['peak_risk'] as num? ?? 0).toInt(),
    highRiskDays: [
      for (final d in (json['high_risk_days'] as List? ?? const []))
        d.toString(),
    ],
  );
}

/// Mirrors backend/app/schemas.py RiskForecast (GET /risk-forecast).
class RiskForecast {
  const RiskForecast({required this.days, required this.trends});

  final List<DayRisk> days;

  /// Keyed "powdery_mildew", "leaf_spot".
  final Map<String, DiseaseTrend> trends;

  DiseaseTrend? get powderyMildew => trends['powdery_mildew'];
  DiseaseTrend? get leafSpot => trends['leaf_spot'];

  factory RiskForecast.fromJson(Map<String, dynamic> json) => RiskForecast(
    days: [
      for (final d in (json['days'] as List? ?? const []))
        DayRisk.fromJson(Map<String, dynamic>.from(d as Map)),
    ],
    trends: {
      for (final e in (json['trends'] as Map? ?? const {}).entries)
        e.key as String: DiseaseTrend.fromJson(
          Map<String, dynamic>.from(e.value as Map),
        ),
    },
  );
}

class Treatment {
  const Treatment({
    required this.name,
    required this.type,
    this.how = '',
    this.fracGroup,
  });

  final String name;
  final TreatmentType type;
  final String how;

  /// FRAC resistance-management code (e.g. "3", "M2"); null for cultural practices.
  final String? fracGroup;

  factory Treatment.fromJson(Map<String, dynamic> json) => Treatment(
    name: json['name'] as String? ?? '',
    type: TreatmentType.parse(json['type']),
    how: json['how'] as String? ?? '',
    fracGroup: json['frac_group'] as String?,
  );
}

class Advice {
  const Advice({
    required this.summary,
    required this.urgency,
    required this.actions,
    required this.treatments,
    required this.sprayTiming,
    required this.prevention,
    this.weather,
    this.photoObservations,
    this.photoNote,
    required this.model,
    this.visionModel,
    required this.disclaimer,
  });

  final String summary;
  final Level urgency;
  final List<String> actions;
  final List<Treatment> treatments;
  final String sprayTiming;
  final List<String> prevention;

  /// Null when no location was sent or the weather lookup failed.
  final WeatherSummary? weather;

  /// What the vision model saw in the photo; null when it wasn't analysed.
  final String? photoObservations;

  /// Why the photo wasn't used (e.g. vision model not installed); null when it was.
  final String? photoNote;
  final String model;
  final String? visionModel;
  final String disclaimer;

  factory Advice.fromJson(Map<String, dynamic> json) => Advice(
    summary: json['summary'] as String? ?? '',
    urgency: Level.parse(json['urgency']),
    actions: _strings(json['actions']),
    treatments: [
      for (final t in (json['treatments'] as List? ?? const []))
        Treatment.fromJson(Map<String, dynamic>.from(t as Map)),
    ],
    sprayTiming: json['spray_timing'] as String? ?? '',
    prevention: _strings(json['prevention']),
    weather: json['weather'] == null
        ? null
        : WeatherSummary.fromJson(
            Map<String, dynamic>.from(json['weather'] as Map),
          ),
    photoObservations: json['photo_observations'] as String?,
    photoNote: json['photo_note'] as String?,
    model: json['model'] as String? ?? '',
    visionModel: json['vision_model'] as String?,
    disclaimer: json['disclaimer'] as String? ?? '',
  );

  static List<String> _strings(Object? value) => [
    for (final v in (value as List? ?? const [])) v.toString(),
  ];
}
