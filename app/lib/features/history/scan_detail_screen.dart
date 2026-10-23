import 'package:flutter/material.dart';

/// A single past scan (reuses the result widgets).
class ScanDetailScreen extends StatelessWidget {
  const ScanDetailScreen({super.key, required this.scanId});

  final String scanId;

  @override
  Widget build(BuildContext context) {
    // TODO: load scan by id, show overlay + CoverageCard, delete action
    return Scaffold(
      appBar: AppBar(title: const Text('Scan')),
      body: Center(child: Text(scanId)),
    );
  }
}
