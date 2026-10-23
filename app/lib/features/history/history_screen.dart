import 'package:flutter/material.dart';

/// The user's past scans, newest first.
class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // TODO: list from historyProvider → tap → /history/:id
    return Scaffold(
      appBar: AppBar(title: const Text('History')),
      body: const Center(child: Text('No scans yet')),
    );
  }
}
