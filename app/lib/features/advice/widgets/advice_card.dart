import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/api_client.dart';
import '../../../shared/device_images.dart';
import '../../../shared/location.dart';
import '../../../shared/models/advice.dart';
import '../../../shared/models/scan_result.dart';
import '../../scan/widgets/coverage_card.dart';

/// On-demand management tips: the leaf photo + this scan's results + local weather → open-source
/// LLMs on the backend. Generated fresh each time (the weather changes), not stored.
class AdviceCard extends ConsumerStatefulWidget {
  const AdviceCard({super.key, required this.scan});

  final ScanResult scan;

  @override
  ConsumerState<AdviceCard> createState() => _AdviceCardState();
}

class _AdviceCardState extends ConsumerState<AdviceCard> {
  final _crop = TextEditingController();
  bool _loading = false;
  String? _error;
  Advice? _advice;

  @override
  void dispose() {
    _crop.dispose();
    super.dispose();
  }

  /// The scan's original photo: fresh upload → copy on this device → server URL. Null if none.
  Future<Uint8List?> _originalPhoto(ApiClient api) async {
    final scan = widget.scan;
    if (scan.imageBytes != null) return scan.imageBytes;
    final onDevice = await ref
        .read(deviceImagesProvider)
        .read(scan.id, ScanImageKind.original);
    if (onDevice != null) return onDevice;
    final url = scan.imageUrl;
    return url == null ? null : api.downloadImage(url);
  }

  Future<void> _fetch() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = ref.read(apiClientProvider);
      final (image, location) = await (
        _originalPhoto(api),
        ref.read(locationProvider.future),
      ).wait;
      final position = location.position;
      final crop = _crop.text.trim();
      final advice = await api.getAdvice(
        widget.scan.id,
        image: image,
        lat: position?.latitude,
        lon: position?.longitude,
        crop: crop.isEmpty ? null : crop,
      );
      if (mounted) setState(() => _advice = advice);
    } catch (e) {
      if (mounted) setState(() => _error = describeError(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final advice = _advice;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.eco_outlined, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'AI management tips',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                if (advice != null && !_loading) ...[
                  LevelChip(level: advice.urgency, prefix: 'Urgency'),
                  IconButton(
                    tooltip: 'Refresh',
                    icon: const Icon(Icons.refresh),
                    onPressed: _fetch,
                  ),
                ],
              ],
            ),
            const SizedBox(height: 12),
            if (_loading)
              const _Loading()
            else if (advice != null)
              _AdviceBody(advice: advice)
            else ...[
              Text(
                'Get AI treatment and spray-timing advice from this photo, '
                'its scan results and your local weather.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _crop,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _fetch(),
                decoration: const InputDecoration(
                  labelText: 'Crop (optional)',
                  hintText: 'e.g. tomato, grape, cucumber',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              if (_error != null) ...[
                Text(
                  _error!,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
                const SizedBox(height: 8),
              ],
              FilledButton.tonalIcon(
                onPressed: _fetch,
                icon: const Icon(Icons.auto_awesome),
                label: Text(
                  _error == null ? 'Get management tips' : 'Try again',
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 24),
    child: Column(
      children: [
        const CircularProgressIndicator(),
        const SizedBox(height: 12),
        Text(
          'Looking at the photo, checking the weather & asking the AI…\n'
          'This can take up to a minute.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    ),
  );
}

class _AdviceBody extends StatelessWidget {
  const _AdviceBody({required this.advice});

  final Advice advice;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    final weather = advice.weather;
    // Short version first (headline, ≤ 3 steps, spray/rain chips); everything else is one tap away.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(advice.summary, style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w500)),
        if (advice.actions.isNotEmpty) ...[
          const SizedBox(height: 8),
          for (final (i, action) in advice.actions.indexed)
            _IconLine(number: i + 1, text: action),
        ],
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            if (advice.sprayTiming.isNotEmpty)
              _InfoChip(icon: Icons.schedule, text: advice.sprayTiming),
            if (weather != null)
              _InfoChip(
                icon: weather.rainExpected24h ? Icons.umbrella_outlined : Icons.wb_sunny_outlined,
                text: weather.rainExpected24h ? 'Rain in 24 h' : 'Dry next 24 h',
              )
            else
              _InfoChip(icon: Icons.location_off_outlined, text: 'No local weather'),
          ],
        ),
        const SizedBox(height: 4),
        if (advice.treatments.isNotEmpty || advice.prevention.isNotEmpty)
          _Details(
            title: 'Treatment details (${advice.treatments.length})',
            children: [
              for (final type in TreatmentType.values)
                if (advice.treatments.any((t) => t.type == type)) ...[
                  _SectionTitle(switch (type) {
                    TreatmentType.cultural => 'Cultural practices',
                    TreatmentType.organic => 'Organic / low-toxicity',
                    TreatmentType.conventional => 'Conventional fungicide',
                  }),
                  for (final t in advice.treatments.where((t) => t.type == type))
                    _TreatmentTile(treatment: t),
                ],
              // Older backends still send a prevention list.
              if (advice.prevention.isNotEmpty) ...[
                const _SectionTitle('Prevention'),
                for (final tip in advice.prevention)
                  _IconLine(icon: Icons.shield_outlined, text: tip),
              ],
            ],
          ),
        _Details(
          title: 'Photo check · weather',
          children: [
            if (advice.photoObservations != null)
              _IconLine(icon: Icons.image_search, text: advice.photoObservations!)
            else if (advice.photoNote != null)
              _IconLine(icon: Icons.hide_image_outlined, text: advice.photoNote!, style: muted),
            const SizedBox(height: 8),
            if (weather != null)
              _WeatherPanel(weather: weather)
            else
              Text(
                'Weather unavailable (location off or denied), so timing advice is general.',
                style: muted,
              ),
          ],
        ),
        _Details(
          title: 'AI advice · check the product label',
          icon: Icons.info_outline,
          children: [
            Text(advice.disclaimer, style: muted),
            if (advice.model.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                'Generated by ${advice.model}'
                '${advice.visionModel == null ? '' : ' · photo read by ${advice.visionModel}'}',
                style: muted,
              ),
            ],
          ],
        ),
      ],
    );
  }
}

/// A collapsed "tap to open" row inside the tips card.
class _Details extends StatelessWidget {
  const _Details({required this.title, required this.children, this.icon});

  final String title;
  final List<Widget> children;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(bottom: 8),
      dense: true,
      shape: const Border(),
      collapsedShape: const Border(),
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      leading: icon == null ? null : Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
      title: Text(title, style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      children: children,
    );
  }
}

class _InfoChip extends StatelessWidget {
  const _InfoChip({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Text(text, style: theme.textTheme.labelMedium),
        ],
      ),
    );
  }
}

class _WeatherPanel extends StatelessWidget {
  const _WeatherPanel({required this.weather});

  final WeatherSummary weather;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    String fmt(double? v, String unit) =>
        v == null ? '–' : '${v.toStringAsFixed(0)}$unit';

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 16,
            runSpacing: 4,
            children: [
              _Stat(Icons.thermostat, fmt(weather.temperatureC, ' °C')),
              _Stat(Icons.water_drop_outlined, fmt(weather.humidityPct, ' %')),
              _Stat(Icons.air, fmt(weather.windKmh, ' km/h')),
              _Stat(
                Icons.umbrella_outlined,
                weather.rainExpected24h
                    ? 'Rain in 24 h (${weather.rainMm24h.toStringAsFixed(1)} mm)'
                    : 'Dry next 24 h',
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            weather.sprayWindow == null
                ? 'No good spray window in the next 48 h'
                : 'Best spray window: ${weather.sprayWindow}',
            style: theme.textTheme.labelLarge,
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              LevelChip(
                level: weather.powderyMildewPressure,
                prefix: 'Mildew risk',
              ),
              LevelChip(
                level: weather.leafSpotPressure,
                prefix: 'Leaf spot risk',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.icon, this.text);

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 16),
      const SizedBox(width: 4),
      Text(text, style: Theme.of(context).textTheme.bodySmall),
    ],
  );
}

class _TreatmentTile extends StatelessWidget {
  const _TreatmentTile({required this.treatment});

  final Treatment treatment;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(treatment.name, style: theme.textTheme.titleSmall),
              ),
              if (treatment.fracGroup != null)
                Tooltip(
                  message: 'FRAC group: rotate between groups to slow resistance',
                  child: Text(
                    'FRAC ${treatment.fracGroup}',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ),
          if (treatment.how.isNotEmpty)
            Text(treatment.how, style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 16, bottom: 4),
    child: Text(text, style: Theme.of(context).textTheme.titleSmall),
  );
}

/// A bullet line led by an icon or a step number.
class _IconLine extends StatelessWidget {
  const _IconLine({this.icon, this.number, required this.text, this.style});

  final IconData? icon;
  final int? number;
  final String text;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 28,
            child: number != null
                ? Text('$number.', style: theme.textTheme.titleSmall)
                : Icon(icon, size: 18, color: theme.colorScheme.primary),
          ),
          Expanded(child: Text(text, style: style ?? theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }
}

Color levelColor(Level level) => switch (level) {
  Level.low => healthyColor,
  Level.medium => const Color(0xFFE8710A),
  Level.high => const Color(0xFFD93025),
};

/// "Prefix: Low/Medium/High" pill, tinted by level (the text carries the meaning, not the colour).
class LevelChip extends StatelessWidget {
  const LevelChip({super.key, required this.level, required this.prefix});

  final Level level;
  final String prefix;

  @override
  Widget build(BuildContext context) {
    final color = levelColor(level);
    final label = switch (level) {
      Level.low => 'Low',
      Level.medium => 'Medium',
      Level.high => 'High',
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        '$prefix: $label',
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
          color: Color.lerp(color, Theme.of(context).colorScheme.onSurface, 0.35),
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
