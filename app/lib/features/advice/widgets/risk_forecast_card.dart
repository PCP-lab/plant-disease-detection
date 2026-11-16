import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/api_client.dart';
import '../../../shared/location.dart';
import '../../../shared/models/advice.dart';
import '../../../shared/models/scan_result.dart';
import '../../scan/widgets/coverage_card.dart' show leafSpotSeriesColor, mildewSeriesColor;
import '../advice_providers.dart';
import 'advice_card.dart';

/// Thresholds matching backend/app/weather.py risk_level.
const _mediumRisk = 34.0;
const _highRisk = 67.0;

/// 7-day weather risk of powdery mildew and leaf spot spreading: trend summary, line chart and a
/// day-by-day table. No AI involved, so it loads in a second or two.
class RiskForecastCard extends ConsumerWidget {
  const RiskForecastCard({super.key, required this.scan});

  final ScanResult scan;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final forecast = ref.watch(riskForecastProvider);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.show_chart, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Disease risk · next 7 days',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'How favourable your local weather is for each disease to spread.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            forecast.when(
              loading: () => const Padding(
                padding: EdgeInsets.symmetric(vertical: 32),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (e, _) => _Retry(
                message: describeError(e),
                onRetry: () => ref.invalidate(riskForecastProvider),
              ),
              data: (f) {
                if (f != null) return _ForecastBody(forecast: f, scan: scan);
                final problem =
                    ref.watch(locationProvider).value?.problem ??
                    LocationProblem.noFix;
                final text = locationProblemText(problem);
                return _Retry(
                  icon: problem == LocationProblem.noFix
                      ? Icons.refresh
                      : Icons.location_on_outlined,
                  message: text.message,
                  action: text.action,
                  onRetry: () => fixLocationProblem(ref, problem),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _Retry extends StatelessWidget {
  const _Retry({
    required this.message,
    required this.onRetry,
    this.action = 'Try again',
    this.icon = Icons.refresh,
  });

  final String message;
  final VoidCallback onRetry;
  final String action;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Text(message, textAlign: TextAlign.center),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        onPressed: onRetry,
        icon: Icon(icon),
        label: Text(action),
      ),
    ],
  );
}

class _ForecastBody extends StatelessWidget {
  const _ForecastBody({required this.forecast, required this.scan});

  final RiskForecast forecast;
  final ScanResult scan;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final b = theme.brightness;
    final found = scan.primary;
    final series = [
      (
        'Powdery mildew',
        mildewSeriesColor(b),
        forecast.powderyMildew,
        (found?.powderyMildewSeverity ?? Severity.none) != Severity.none,
      ),
      (
        'Leaf spot',
        leafSpotSeriesColor(b),
        forecast.leafSpot,
        (found?.leafSpotSeverity ?? Severity.none) != Severity.none,
      ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Legend + trend: identity never relies on colour alone.
        for (final (name, color, trend, onLeaf) in series)
          _TrendLine(
            name: name,
            color: color,
            trend: trend,
            onLeaf: onLeaf,
            dayCount: forecast.days.length,
          ),
        const SizedBox(height: 16),
        SizedBox(height: 200, child: _RiskChart(days: forecast.days)),
        const SizedBox(height: 16),
        _DayTable(days: forecast.days),
        const SizedBox(height: 12),
        Text(
          'Leaf spot risk counts hours of wet leaves (rain or humidity ≥ 90 %). '
          'Powdery mildew risk counts warm (15–28 °C), humid but dry hours. '
          'Spray days have ≥ 4 dry, calm daylight hours.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _TrendLine extends StatelessWidget {
  const _TrendLine({
    required this.name,
    required this.color,
    required this.trend,
    required this.onLeaf,
    required this.dayCount,
  });

  final String name;
  final Color color;
  final DiseaseTrend? trend;
  final bool onLeaf;
  final int dayCount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = trend;
    final (icon, word) = switch (t?.direction) {
      TrendDirection.rising => (Icons.trending_up, 'Rising'),
      TrendDirection.falling => (Icons.trending_down, 'Falling'),
      _ => (Icons.trending_flat, 'Steady'),
    };
    final details = [
      if (t?.peakDay != null && t!.peakRisk >= _mediumRisk)
        'peaks ${t.peakDay}',
      if (t != null && t.highRiskDays.length == dayCount)
        'high all week'
      else if (t != null && t.highRiskDays.isNotEmpty)
        'high on ${t.highRiskDays.join(', ')}'
      else if (t != null)
        'no high-risk days',
    ].join(' · ');

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Container(
              width: 16,
              height: 4,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: name,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  if (onLeaf)
                    TextSpan(
                      text: ' (on this leaf)',
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  const TextSpan(text: '\n'),
                  WidgetSpan(
                    alignment: PlaceholderAlignment.middle,
                    child: Icon(icon, size: 16),
                  ),
                  TextSpan(text: ' $word${details.isEmpty ? '' : ' · $details'}'),
                ],
              ),
              style: theme.textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}

class _RiskChart extends StatelessWidget {
  const _RiskChart({required this.days});

  final List<DayRisk> days;

  String _dayShort(int i) => i == 0 ? 'Today' : days[i].weekday;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final b = theme.brightness;
    final muted = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    LineChartBarData line(Color color, int Function(DayRisk) value) =>
        LineChartBarData(
          spots: [
            for (final (i, d) in days.indexed)
              FlSpot(i.toDouble(), value(d).toDouble()),
          ],
          isCurved: true,
          curveSmoothness: 0.25,
          preventCurveOverShooting: true,
          color: color,
          barWidth: 2,
          dotData: FlDotData(
            getDotPainter: (_, _, _, _) => FlDotCirclePainter(
              radius: 4,
              color: color,
              strokeWidth: 2,
              strokeColor: theme.colorScheme.surfaceContainerLow,
            ),
          ),
        );

    HorizontalLine zone(double y, String label) => HorizontalLine(
      y: y,
      color: theme.colorScheme.outlineVariant,
      strokeWidth: 1,
      dashArray: [4, 4],
      label: HorizontalLineLabel(
        show: true,
        alignment: Alignment.topRight,
        padding: const EdgeInsets.only(right: 2, bottom: 2),
        style: muted,
        labelResolver: (_) => label,
      ),
    );

    return LineChart(
      LineChartData(
        minX: 0,
        maxX: (days.length - 1).toDouble(),
        minY: 0,
        maxY: 100,
        borderData: FlBorderData(show: false),
        gridData: const FlGridData(show: false),
        extraLinesData: ExtraLinesData(
          horizontalLines: [
            zone(_mediumRisk, 'Medium'),
            zone(_highRisk, 'High risk'),
          ],
        ),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(),
          rightTitles: const AxisTitles(),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 36,
              interval: 50,
              getTitlesWidget: (value, meta) => SideTitleWidget(
                meta: meta,
                child: Text('${value.toInt()}', style: muted),
              ),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 24,
              interval: 1,
              getTitlesWidget: (value, meta) {
                final i = value.toInt();
                if (i != value || i < 0 || i >= days.length) {
                  return const SizedBox.shrink();
                }
                return SideTitleWidget(
                  meta: meta,
                  child: Text(_dayShort(i), style: muted),
                );
              },
            ),
          ),
        ),
        lineTouchData: LineTouchData(
          touchTooltipData: LineTouchTooltipData(
            getTooltipColor: (_) => theme.colorScheme.inverseSurface,
            fitInsideHorizontally: true,
            fitInsideVertically: true,
            getTooltipItems: (spots) {
              final ink = TextStyle(color: theme.colorScheme.onInverseSurface);
              return [
                for (final s in spots)
                  () {
                    final d = days[s.x.toInt()];
                    final (name, level) = s.barIndex == 0
                        ? ('Mildew', d.powderyMildewLevel)
                        : ('Leaf spot', d.leafSpotLevel);
                    final header = s == spots.first ? '${d.label}\n' : '';
                    return LineTooltipItem(
                      '$header$name ${s.y.toInt()} · ${_levelWord(level)}',
                      ink,
                    );
                  }(),
              ];
            },
          ),
        ),
        lineBarsData: [
          line(mildewSeriesColor(b), (d) => d.powderyMildewRisk),
          line(leafSpotSeriesColor(b), (d) => d.leafSpotRisk),
        ],
      ),
    );
  }
}

String _levelWord(Level l) => switch (l) {
  Level.low => 'Low',
  Level.medium => 'Medium',
  Level.high => 'High',
};

/// The same forecast as a table: which days are risky, wet, or good for spraying.
class _DayTable extends StatelessWidget {
  const _DayTable({required this.days});

  final List<DayRisk> days;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final small = theme.textTheme.labelSmall;
    final muted = small?.copyWith(color: theme.colorScheme.onSurfaceVariant);

    Widget cell(Widget child) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 1),
      child: Center(child: child),
    );
    Widget rowLabel(String text) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Text(text, style: small?.copyWith(fontWeight: FontWeight.w600)),
    );

    return Table(
      columnWidths: const {0: FixedColumnWidth(64)},
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      children: [
        TableRow(
          children: [
            const SizedBox.shrink(),
            for (final (i, d) in days.indexed)
              cell(
                Text(
                  i == 0 ? 'Today' : d.weekday,
                  style: small?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
          ],
        ),
        TableRow(
          children: [
            rowLabel('Mildew'),
            for (final d in days) cell(_LevelCell(level: d.powderyMildewLevel)),
          ],
        ),
        TableRow(
          children: [
            rowLabel('Leaf spot'),
            for (final d in days) cell(_LevelCell(level: d.leafSpotLevel)),
          ],
        ),
        TableRow(
          children: [
            rowLabel('Rain'),
            for (final d in days)
              cell(
                Text(
                  d.rainMm >= 0.5 ? '${d.rainMm.toStringAsFixed(0)} mm' : '–',
                  style: d.rainMm >= 0.5 ? small : muted,
                ),
              ),
          ],
        ),
        TableRow(
          children: [
            rowLabel('Max °C'),
            for (final d in days)
              cell(
                Text(
                  d.tempMaxC == null ? '–' : '${d.tempMaxC!.round()}°',
                  style: small,
                ),
              ),
          ],
        ),
        TableRow(
          children: [
            rowLabel('Spray'),
            for (final d in days)
              cell(
                d.sprayOk
                    ? Tooltip(
                        message: 'Good spray window',
                        child: Icon(
                          Icons.check_circle,
                          size: 18,
                          color: theme.colorScheme.primary,
                        ),
                      )
                    : Text('–', style: muted),
              ),
          ],
        ),
      ],
    );
  }
}

class _LevelCell extends StatelessWidget {
  const _LevelCell({required this.level});

  final Level level;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = levelColor(level);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: level == Level.low ? 0.10 : 0.22),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        switch (level) {
          Level.low => 'Low',
          Level.medium => 'Med',
          Level.high => 'High',
        },
        textAlign: TextAlign.center,
        style: theme.textTheme.labelSmall?.copyWith(
          fontWeight: FontWeight.w700,
          color: Color.lerp(color, theme.colorScheme.onSurface, 0.45),
        ),
      ),
    );
  }
}
