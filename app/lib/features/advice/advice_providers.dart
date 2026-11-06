import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shared/api_client.dart';
import '../../shared/location.dart';
import '../../shared/models/advice.dart';

/// 7-day disease-risk forecast at the device location; null when location is unavailable.
final riskForecastProvider = FutureProvider.autoDispose<RiskForecast?>((
  ref,
) async {
  final position = (await ref.watch(locationProvider.future)).position;
  if (position == null) return null;
  return ref
      .watch(apiClientProvider)
      .getRiskForecast(position.latitude, position.longitude);
});
