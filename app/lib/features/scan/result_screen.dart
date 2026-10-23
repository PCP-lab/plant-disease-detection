import 'package:flutter/material.dart';

/// Overlay image + coverage % per disease + severity, or "no leaf detected".
class ResultScreen extends StatelessWidget {
  const ResultScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // TODO: overlay image (tap to toggle original), CoverageCard
    return Scaffold(
      appBar: AppBar(title: const Text('Result')),
      body: const Center(child: Text('Result')),
    );
  }
}
