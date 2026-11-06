import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../../shared/models/scan_result.dart';

/// Class colors, matching backend/app/overlay.py. Powdery mildew is drawn near-white on the
/// overlay; a darker lavender is used here so it stays visible on a light background.
const leafSpotColor = Color.fromARGB(255, 180, 95, 6);
const powderyMildewColor = Color(0xFF9C95D0);
const healthyColor = Color.fromARGB(255, 46, 160, 67);

Color severityColor(Severity s) => switch (s) {
  Severity.none => healthyColor,
  Severity.mild => const Color(0xFFE0A800),
  Severity.moderate => const Color(0xFFE8710A),
  Severity.severe => const Color(0xFFD93025),
};

String severityLabel(Severity s) => switch (s) {
  Severity.none => 'None',
  Severity.mild => 'Mild',
  Severity.moderate => 'Moderate',
  Severity.severe => 'Severe',
};

/// Per-disease coverage bars, severity chips and healthy %.
class CoverageCard extends StatelessWidget {
  const CoverageCard({
    super.key,
    required this.coverage,
    this.title = 'Leaf coverage',
  });

  final LeafCoverage coverage;
  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rows = [
      (
        'Powdery mildew',
        coverage.powderyMildewPct,
        powderyMildewColor,
        coverage.powderyMildewSeverity,
      ),
      (
        'Leaf spot',
        coverage.leafSpotPct,
        leafSpotColor,
        coverage.leafSpotSeverity,
      ),
      ('Healthy', coverage.healthyPct, healthyColor, null),
    ];

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(title, style: theme.textTheme.titleMedium),
                ),
                SeverityChip(
                  severity: coverage.worstSeverity,
                  prefix: 'Overall',
                ),
              ],
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 180,
              child: BarChart(
                BarChartData(
                  minY: 0,
                  maxY: 100,
                  alignment: BarChartAlignment.spaceAround,
                  borderData: FlBorderData(show: false),
                  gridData: FlGridData(
                    drawVerticalLine: false,
                    horizontalInterval: 25,
                    getDrawingHorizontalLine: (_) => FlLine(
                      color: theme.colorScheme.outlineVariant,
                      strokeWidth: 1,
                    ),
                  ),
                  barTouchData: BarTouchData(
                    touchTooltipData: BarTouchTooltipData(
                      getTooltipColor: (_) => theme.colorScheme.inverseSurface,
                      getTooltipItem: (group, _, rod, _) => BarTooltipItem(
                        '${rod.toY.toStringAsFixed(1)}%',
                        TextStyle(color: theme.colorScheme.onInverseSurface),
                      ),
                    ),
                  ),
                  titlesData: FlTitlesData(
                    topTitles: const AxisTitles(),
                    rightTitles: const AxisTitles(),
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 40,
                        interval: 25,
                        getTitlesWidget: (value, meta) => SideTitleWidget(
                          meta: meta,
                          child: Text(
                            '${value.toInt()}%',
                            style: theme.textTheme.labelSmall,
                          ),
                        ),
                      ),
                    ),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 28,
                        getTitlesWidget: (value, meta) => SideTitleWidget(
                          meta: meta,
                          child: Text(
                            rows[value.toInt()].$1,
                            style: theme.textTheme.labelSmall,
                          ),
                        ),
                      ),
                    ),
                  ),
                  barGroups: [
                    for (final (i, row) in rows.indexed)
                      BarChartGroupData(
                        x: i,
                        barRods: [
                          BarChartRodData(
                            toY: row.$2.clamp(0, 100).toDouble(),
                            color: row.$3,
                            width: 28,
                            borderRadius: const BorderRadius.vertical(
                              top: Radius.circular(6),
                            ),
                            backDrawRodData: BackgroundBarChartRodData(
                              show: true,
                              toY: 100,
                              color: theme.colorScheme.surfaceContainerHighest,
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            for (final (label, pct, color, severity) in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(child: Text(label)),
                    Text(
                      '${pct.toStringAsFixed(1)}%',
                      style: theme.textTheme.titleSmall,
                    ),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 92,
                      child: severity == null
                          ? const SizedBox.shrink()
                          : Align(
                              alignment: Alignment.centerRight,
                              child: SeverityChip(severity: severity),
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

class SeverityChip extends StatelessWidget {
  const SeverityChip({super.key, required this.severity, this.prefix});

  final Severity severity;
  final String? prefix;

  @override
  Widget build(BuildContext context) {
    final color = severityColor(severity);
    final label = severityLabel(severity);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        prefix == null ? label : '$prefix: $label',
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
          color: Color.lerp(
            color,
            Theme.of(context).colorScheme.onSurface,
            0.35,
          ),
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
