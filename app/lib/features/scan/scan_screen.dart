import 'package:flutter/material.dart';

/// Home: take a photo or pick one from the gallery, then upload it.
class ScanScreen extends StatelessWidget {
  const ScanScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // TODO: camera / gallery buttons (image_picker) → POST /scans → /result
    return Scaffold(
      appBar: AppBar(title: const Text('Leaf Disease Detector')),
      body: const Center(child: Text('Scan a leaf')),
    );
  }
}
