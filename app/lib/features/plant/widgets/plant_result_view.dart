import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../shared/device_images.dart';
import '../../../shared/models/scan_result.dart';
import '../../../shared/widgets/scan_image.dart';
import '../../scan/widgets/coverage_card.dart';
import '../../scan/widgets/scan_result_view.dart';

const _diseaseLabels = {'powdery_mildew': 'Powdery mildew', 'leaf_spot': 'Leaf spot'};

/// Result of a whole-plant scan: the overall plant situation, the average coverage, and each leaf.
/// Shared by PlantResultScreen and ScanDetailScreen.
class PlantResultView extends StatelessWidget {
  const PlantResultView({super.key, required this.scan, this.footer});

  final ScanResult scan;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final plant = scan.plant;
    final primary = scan.primary;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (primary != null && plant != null) _PlantSummaryCard(primary: primary, plant: plant),
                const SizedBox(height: 4),
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 12, 4, 8),
                  child: Text('Leaves · tap one for details', style: theme.textTheme.titleSmall),
                ),
                SizedBox(
                  height: 146,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: scan.leaves.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 8),
                    itemBuilder: (context, i) => _LeafThumb(
                      scan: scan,
                      leaf: scan.leaves[i],
                      isCover: scan.leaves[i].index == plant?.cover,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                const ScanLegend(),
                if (plant != null && plant.skipped.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      'No leaf was found in photo ${plant.skipped.map((i) => i + 1).join(', ')}, '
                      'so it was left out.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ),
                const SizedBox(height: 16),
                if (primary != null) CoverageCard(coverage: primary, title: 'Average across the leaves'),
                Card(
                  clipBehavior: Clip.antiAlias,
                  child: ListTile(
                    leading: Icon(Icons.eco_outlined, color: theme.colorScheme.primary),
                    title: const Text('Management tips & disease risk'),
                    subtitle: const Text('7-day risk forecast and AI treatment advice for the plant'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => context.push('/advice/${scan.id}'),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '${MaterialLocalizations.of(context).formatMediumDate(scan.createdAt)} '
                  '${TimeOfDay.fromDateTime(scan.createdAt).format(context)}'
                  '${scan.modelVersion.isEmpty ? '' : ' · model ${scan.modelVersion}'}',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                if (footer != null) ...[const SizedBox(height: 16), footer!],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// The overall plant situation: worst plant-level severity, then per disease the average and how many leaves
/// have it.
class _PlantSummaryCard extends StatelessWidget {
  const _PlantSummaryCard({required this.primary, required this.plant});

  final LeafCoverage primary;
  final PlantSummary plant;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final n = plant.leavesAnalysed;
    final worst = primary.worstSeverity;
    final headline = switch (worst) {
      Severity.none => 'No disease found on the plant',
      Severity.mild => 'Early signs of disease',
      Severity.moderate => 'The plant is moderately affected',
      Severity.severe => 'The plant is severely affected',
    };
    final pct = {'powdery_mildew': primary.powderyMildewPct, 'leaf_spot': primary.leafSpotPct};
    final severity = {'powdery_mildew': primary.powderyMildewSeverity, 'leaf_spot': primary.leafSpotSeverity};

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.local_florist_outlined, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(child: Text('Whole plant · $n leaves', style: theme.textTheme.titleMedium)),
                SeverityChip(severity: worst),
              ],
            ),
            const SizedBox(height: 8),
            Text(headline, style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),
            for (final d in _diseaseLabels.keys) ...[
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_diseaseLabels[d]!, style: theme.textTheme.bodyMedium),
                        Text(
                          'avg ${pct[d]!.toStringAsFixed(1)}% · on ${plant.leavesAffected[d] ?? 0} of $n leaves',
                          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  SeverityChip(severity: severity[d]!),
                ],
              ),
              const SizedBox(height: 8),
            ],
            if (plant.raised.isNotEmpty)
              Text(
                '${plant.raised.map((d) => _diseaseLabels[d] ?? d).join(' and ')} '
                '${plant.raised.length == 1 ? 'is' : 'are'} on at least half of the leaves, so '
                '${plant.raised.length == 1 ? 'its' : 'their'} level is raised one step: '
                '${plant.raised.length == 1 ? 'it is' : 'they are'} spreading through the plant.',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
          ],
        ),
      ),
    );
  }
}

class _LeafThumb extends StatelessWidget {
  const _LeafThumb({required this.scan, required this.leaf, required this.isCover});

  final ScanResult scan;
  final LeafCoverage leaf;
  final bool isCover;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final images = scan.leafImagesAt(leaf.index);
    return SizedBox(
      width: 100,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => showLeafDetail(context, scan, leaf),
        child: Column(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox.square(
                dimension: 100,
                child: ScanImage(
                  scanId: scan.id,
                  kind: ScanImageKind.overlay,
                  leafIndex: leaf.index,
                  bytes: images?.overlayBytes,
                  url: images?.overlayUrl,
                  storagePath: images?.overlayPath,
                  fit: BoxFit.cover,
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Leaf ${(leaf.index ?? 0) + 1} · ${leaf.diseasedPct.toStringAsFixed(1)}%',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                fontWeight: isCover ? FontWeight.bold : null,
                color: isCover ? theme.colorScheme.error : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One leaf of a whole-plant scan in a bottom sheet: its overlay (tap for the original) and its own coverage.
Future<void> showLeafDetail(BuildContext context, ScanResult scan, LeafCoverage leaf) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (context) => DraggableScrollableSheet(
    expand: false,
    initialChildSize: 0.85,
    maxChildSize: 0.95,
    builder: (context, controller) => _LeafDetail(scan: scan, leaf: leaf, controller: controller),
  ),
);

class _LeafDetail extends StatefulWidget {
  const _LeafDetail({required this.scan, required this.leaf, required this.controller});

  final ScanResult scan;
  final LeafCoverage leaf;
  final ScrollController controller;

  @override
  State<_LeafDetail> createState() => _LeafDetailState();
}

class _LeafDetailState extends State<_LeafDetail> {
  bool _showOriginal = false;

  @override
  Widget build(BuildContext context) {
    final leaf = widget.leaf;
    final images = widget.scan.leafImagesAt(leaf.index);
    final kind = _showOriginal ? ScanImageKind.original : ScanImageKind.overlay;
    return ListView(
      controller: widget.controller,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      children: [
        Text('Leaf ${(leaf.index ?? 0) + 1}', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 12),
        GestureDetector(
          onTap: () => setState(() => _showOriginal = !_showOriginal),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: ColoredBox(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: AspectRatio(
                aspectRatio: 1,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ScanImage(
                      key: ValueKey(kind),
                      scanId: widget.scan.id,
                      kind: kind,
                      leafIndex: leaf.index,
                      bytes: _showOriginal ? images?.imageBytes : images?.overlayBytes,
                      url: _showOriginal ? images?.imageUrl : images?.overlayUrl,
                      storagePath: _showOriginal ? images?.imagePath : images?.overlayPath,
                    ),
                    Positioned(
                      left: 8,
                      bottom: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(999)),
                        child: Text(
                          _showOriginal ? 'Original · tap for overlay' : 'Overlay · tap for original',
                          style: const TextStyle(color: Colors.white, fontSize: 12),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        const ScanLegend(),
        const SizedBox(height: 12),
        if (leaf.framing != null && !leaf.framing!.ok) FramingWarning(framing: leaf.framing!),
        CoverageCard(coverage: leaf, title: 'This leaf'),
      ],
    );
  }
}
