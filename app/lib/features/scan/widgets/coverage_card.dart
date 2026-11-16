import 'package:flutter/material.dart';

import '../../../shared/models/scan_result.dart';

/// Class colors, matching backend/app/overlay.py. Powdery mildew is drawn near-white on the
/// overlay; a darker lavender is used here so it stays visible on a light background.
const leafSpotColor = Color.fromARGB(255, 180, 95, 6);
const powderyMildewColor = Color(0xFF9C95D0);
const healthyColor = Color.fromARGB(255, 46, 160, 67);

/// Chart colours per disease. Validated (lightness, chroma, colour-blind separation, contrast) against the light and
/// dark surfaces; the lavender above reads too grey for a chart mark.
Color mildewSeriesColor(Brightness b) =>
    b == Brightness.dark ? const Color(0xFF9378E0) : const Color(0xFF7B5FC9);
Color leafSpotSeriesColor(Brightness b) =>
    b == Brightness.dark ? const Color(0xFFCC7620) : const Color(0xFFB45F06);

/// Severity band edges in % of leaf area: backend/app/config.py severity_mild_max / severity_moderate_max.
const mildMax = 5.0;
const moderateMax = 25.0;

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

/// Position (0–1) of [pct] on the severity scale: each band (mild 0–5 %, moderate 5–25 %, severe 25–100 %) gets a
/// third of the width, so a 2 % patch is clearly visible instead of being a sliver of a 0–100 % axis.
double severityScalePos(double pct) {
  final p = pct.clamp(0.0, 100.0);
  if (p <= mildMax) return p / mildMax / 3;
  if (p <= moderateMax) return 1 / 3 + (p - mildMax) / (moderateMax - mildMax) / 3;
  return 2 / 3 + (p - moderateMax) / (100 - moderateMax) / 3;
}

/// Disease coverage of the leaf, shown against the severity bands (not against "healthy", which is almost always
/// ~95 % and made the old bar chart look like there was nothing wrong).
class CoverageCard extends StatelessWidget {
  const CoverageCard({super.key, required this.coverage, this.title = 'Leaf coverage'});

  final LeafCoverage coverage;
  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final b = theme.brightness;
    final diseased = (100 - coverage.healthyPct).clamp(0.0, 100.0);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(title, style: theme.textTheme.titleMedium)),
                SeverityChip(severity: coverage.worstSeverity, prefix: 'Overall'),
              ],
            ),
            const SizedBox(height: 16),
            _SeverityGauge(
              label: 'Powdery mildew',
              pct: coverage.powderyMildewPct,
              severity: coverage.powderyMildewSeverity,
              color: mildewSeriesColor(b),
            ),
            const SizedBox(height: 18),
            _SeverityGauge(
              label: 'Leaf spot',
              pct: coverage.leafSpotPct,
              severity: coverage.leafSpotSeverity,
              color: leafSpotSeriesColor(b),
            ),
            const SizedBox(height: 16),
            Text(
              diseased <= 0
                  ? 'No disease found on this leaf.'
                  : '${_fmt(diseased)} % of the leaf shows disease; the rest looks healthy.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 4),
            Text(
              'Severity bands: mild under ${mildMax.toInt()} %, moderate ${mildMax.toInt()}–${moderateMax.toInt()} %, '
              'severe above ${moderateMax.toInt()} % of the leaf.',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

String _fmt(double pct) => pct >= 10 ? pct.toStringAsFixed(0) : pct.toStringAsFixed(1);

/// One disease: name, "x % of leaf", severity chip, and a bar on the mild / moderate / severe scale.
class _SeverityGauge extends StatelessWidget {
  const _SeverityGauge({required this.label, required this.pct, required this.severity, required this.color});

  final String label;
  final double pct;
  final Severity severity;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return Semantics(
      label: '$label: ${_fmt(pct)} percent of the leaf, ${severityLabel(severity)}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: theme.textTheme.titleSmall),
                    Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(text: '${_fmt(pct)} %', style: theme.textTheme.titleMedium),
                          TextSpan(text: '  of the leaf', style: muted),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              SeverityChip(severity: severity),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 14,
            child: LayoutBuilder(
              builder: (context, c) => CustomPaint(
                size: Size(c.maxWidth, 14),
                painter: _GaugePainter(
                  pos: severityScalePos(pct),
                  hasDisease: pct > 0,
                  fill: color,
                  track: theme.colorScheme.surfaceContainerHighest,
                  divider: theme.colorScheme.surface,
                ),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              for (final band in const ['Mild', 'Moderate', 'Severe'])
                Expanded(child: Text(band, style: muted, textAlign: TextAlign.center)),
            ],
          ),
        ],
      ),
    );
  }
}

class _GaugePainter extends CustomPainter {
  _GaugePainter({required this.pos, required this.hasDisease, required this.fill, required this.track, required this.divider});

  final double pos;
  final bool hasDisease;
  final Color fill;
  final Color track;
  final Color divider;

  @override
  void paint(Canvas canvas, Size size) {
    final r = Radius.circular(size.height / 2);
    final whole = RRect.fromRectAndRadius(Offset.zero & size, r);
    canvas.drawRRect(whole, Paint()..color = track);
    if (hasDisease) {
      // at least the bar's height, so a 0.1 % patch is still visible
      final w = (pos * size.width).clamp(size.height, size.width);
      canvas.save();
      canvas.clipRRect(whole);
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(0, 0, w, size.height), r), Paint()..color = fill);
      canvas.restore();
    }
    // band edges at 5 % and 25 %: 2-px surface gaps
    final gap = Paint()
      ..color = divider
      ..strokeWidth = 2;
    for (final x in [size.width / 3, 2 * size.width / 3]) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), gap);
    }
  }

  @override
  bool shouldRepaint(_GaugePainter old) =>
      old.pos != pos || old.hasDisease != hasDisease || old.fill != fill || old.track != track;
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
          color: Color.lerp(color, Theme.of(context).colorScheme.onSurface, 0.35),
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
