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
                if (!noLeaf) const ScanLegend(),
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
                  if (scan.framing != null && !scan.framing!.ok)
                    FramingWarning(framing: scan.framing!),
                  CoverageCard(coverage: scan.primary!),
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

/// Shown when the photo isn't one dominant leaf, the kind of photo the model is validated on.
class FramingWarning extends StatelessWidget {
  const FramingWarning({super.key, required this.framing});

  final Framing framing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (title, body) = switch (framing.issue) {
      'several_leaves' => (
        'More than one big leaf in the photo',
        'The result is for the largest leaf and may be less reliable. '
            'For the best result, retake with one leaf filling the box.',
      ),
      'small_leaf' => (
        'The leaf is small in the photo',
        'Tiny spots can be missed when the leaf fills only a small part of the photo. '
            'Move closer so the leaf fills the box.',
      ),
      _ => (
        'Photo may be less reliable',
        'For the best result, retake with one leaf filling the box.',
      ),
    };
    return Card(
      color: theme.colorScheme.tertiaryContainer,
      child: ListTile(
        leading: Icon(Icons.warning_amber_rounded, color: theme.colorScheme.onTertiaryContainer),
        title: Text(title, style: TextStyle(color: theme.colorScheme.onTertiaryContainer)),
        subtitle: Text(body, style: TextStyle(color: theme.colorScheme.onTertiaryContainer)),
      ),
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

class ScanLegend extends StatelessWidget {
  const ScanLegend({super.key});

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
