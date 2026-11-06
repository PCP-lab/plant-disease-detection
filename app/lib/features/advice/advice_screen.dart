import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shared/location.dart';
import '../../shared/models/scan_result.dart';
import '../history/history_providers.dart';
import '../scan/scan_providers.dart';
import '../scan/widgets/coverage_card.dart';
import 'widgets/advice_card.dart';
import 'widgets/risk_forecast_card.dart';

/// Management tips for one scan: the 7-day disease-risk forecast (instant) and the AI tips
/// (photo + results + weather, on demand).
class AdviceScreen extends ConsumerStatefulWidget {
  const AdviceScreen({super.key, required this.scanId});

  final String scanId;

  @override
  ConsumerState<AdviceScreen> createState() => _AdviceScreenState();
}

class _AdviceScreenState extends ConsumerState<AdviceScreen> {
  late final AppLifecycleListener _lifecycle;
  bool _promptedForGps = false;

  @override
  void initState() {
    super.initState();
    // Coming back from the location / app settings screen: look again if the last lookup failed.
    // Not while a lookup is still running: Android's own "Turn on location?" dialog also pauses
    // the app, and restarting the lookup then would show that dialog again in a loop.
    _lifecycle = AppLifecycleListener(
      onResume: () {
        final location = ref.read(locationProvider);
        if (!location.isLoading && location.value?.problem != null) {
          ref.invalidate(locationProvider);
        }
      },
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scanId = widget.scanId;
    // GPS off: ask once per visit to turn it on (the forecast card keeps a button for later).
    ref.listen(locationProvider, (_, next) {
      if (_promptedForGps ||
          next.value?.problem != LocationProblem.serviceOff) {
        return;
      }
      _promptedForGps = true;
      showTurnOnLocationDialog(context, ref);
    });

    // The scan just uploaded is in memory (with its photo); otherwise load it like History does.
    final upload = ref.watch(scanUploadProvider)?.value;
    final AsyncValue<ScanResult?> scan = upload?.id == scanId
        ? AsyncData(upload)
        : ref.watch(scanByIdProvider(scanId));

    return Scaffold(
      appBar: AppBar(title: const Text('Management tips')),
      body: scan.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Could not load this scan.\n$e')),
        data: (scan) => scan == null
            ? const Center(child: Text('This scan no longer exists.'))
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 640),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _ScanSummary(scan: scan),
                          RiskForecastCard(scan: scan),
                          AdviceCard(key: ValueKey(scan.id), scan: scan),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

class _ScanSummary extends StatelessWidget {
  const _ScanSummary({required this.scan});

  final ScanResult scan;

  @override
  Widget build(BuildContext context) {
    final leaf = scan.primary;
    if (leaf == null) return const SizedBox.shrink();
    return Card(
      child: ListTile(
        leading: const Icon(Icons.eco),
        title: const Text('This scan'),
        subtitle: Text(
          'Mildew ${leaf.powderyMildewPct.toStringAsFixed(1)}% · '
          'Leaf spot ${leaf.leafSpotPct.toStringAsFixed(1)}% · '
          'Healthy ${leaf.healthyPct.toStringAsFixed(1)}%',
        ),
        trailing: SeverityChip(severity: leaf.worstSeverity),
      ),
    );
  }
}
