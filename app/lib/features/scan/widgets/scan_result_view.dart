import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../shared/device_images.dart';
import '../../../shared/models/scan_result.dart';
import '../../../shared/widgets/scan_image.dart';
import 'coverage_card.dart';

/// Overlay image (tap to toggle original) + coverage, or a "no leaf detected" message.
/// Shared by ResultScreen and ScanDetailScreen.
class ScanResultView extends StatefulWidget {
  const ScanResultView({super.key, required this.scan, this.footer});

  final ScanResult scan;
  final Widget? footer;

  @override
  State<ScanResultView> createState() => _ScanResultViewState();
}

class _ScanResultViewState extends State<ScanResultView> {
  bool _showOriginal = false;

  @override
  Widget build(BuildContext context) {
    final scan = widget.scan;
    final theme = Theme.of(context);
    final noLeaf =
        scan.status == ScanStatus.noLeafDetected || scan.primary == null;
    final otherLeaves = scan.leaves.length > 1
        ? scan.leaves
        : const <LeafCoverage>[];

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                GestureDetector(
                  onTap: () => setState(() => _showOriginal = !_showOriginal),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: ColoredBox(
                      color: theme.colorScheme.surfaceContainerHighest,
                      child: AspectRatio(
                        aspectRatio: 1,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            _showOriginal || noLeaf
                                ? ScanImage(
                                    scanId: scan.id,
                                    kind: ScanImageKind.original,
                                    bytes: scan.imageBytes,
                                    url: scan.imageUrl,
                                    storagePath: scan.imagePath,
                                  )
                                : ScanImage(
                                    scanId: scan.id,
                                    kind: ScanImageKind.overlay,
                                    bytes: scan.overlayBytes,
                                    url: scan.overlayUrl,
                                    storagePath: scan.overlayPath,
                                  ),
                            if (!noLeaf)
                              Positioned(
                                left: 8,
                                bottom: 8,
                                child: _Pill(
                                  _showOriginal
                                      ? 'Original · tap for overlay'
                                      : 'Overlay · tap for original',
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                if (!noLeaf) const _Legend(),
                const SizedBox(height: 16),
                if (noLeaf)
                  Card(
                    child: ListTile(
                      leading: Icon(
                        Icons.search_off,
                        color: theme.colorScheme.error,
                      ),
                      title: const Text('No leaf detected'),
                      subtitle: const Text(
                        'Try again with the leaf filling more of the frame, '
                        'in focus and evenly lit.',
                      ),
                    ),
                  )
                else ...[
                  CoverageCard(
                    coverage: scan.primary!,
                    title: otherLeaves.isEmpty
                        ? 'Leaf coverage'
                        : 'Largest leaf',
                  ),
                  if (otherLeaves.isNotEmpty)
                    Card(
                      clipBehavior: Clip.antiAlias,
                      child: ExpansionTile(
                        title: Text('All ${otherLeaves.length} leaves'),
                        children: [
                          for (final (i, leaf) in otherLeaves.indexed)
                            ListTile(
                              dense: true,
                              title: Text('Leaf ${i + 1}'),
                              subtitle: Text(
                                'Mildew ${leaf.powderyMildewPct.toStringAsFixed(1)}% · '
                                'Spot ${leaf.leafSpotPct.toStringAsFixed(1)}% · '
                                'Healthy ${leaf.healthyPct.toStringAsFixed(1)}%',
                              ),
                              trailing: SeverityChip(
                                severity: leaf.worstSeverity,
                              ),
                            ),
                        ],
                      ),
                    ),
                  Card(
                    clipBehavior: Clip.antiAlias,
                    child: ListTile(
                      leading: Icon(
                        Icons.eco_outlined,
                        color: theme.colorScheme.primary,
                      ),
                      title: const Text('Management tips & disease risk'),
                      subtitle: const Text(
                        '7-day risk forecast and AI treatment advice',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => context.push('/advice/${scan.id}'),
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                Text(
                  '${MaterialLocalizations.of(context).formatMediumDate(scan.createdAt)} '
                  '${TimeOfDay.fromDateTime(scan.createdAt).format(context)}'
                  '${scan.modelVersion.isEmpty ? '' : ' · model ${scan.modelVersion}'}',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                if (widget.footer != null) ...[
                  const SizedBox(height: 16),
                  widget.footer!,
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(
      color: Colors.black54,
      borderRadius: BorderRadius.circular(999),
    ),
    child: Text(
      text,
      style: const TextStyle(color: Colors.white, fontSize: 12),
    ),
  );
}

class _Legend extends StatelessWidget {
  const _Legend();

  @override
  Widget build(BuildContext context) {
    const items = [
      ('Leaf', healthyColor),
      ('Leaf spot', leafSpotColor),
      ('Powdery mildew', powderyMildewColor),
    ];
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 16,
      children: [
        for (final (label, color) in items)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 6),
              Text(label, style: Theme.of(context).textTheme.labelMedium),
            ],
          ),
      ],
    );
  }
}
