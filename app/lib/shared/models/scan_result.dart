// Mirrors backend/app/schemas.py (ScanResult, LeafCoverage).

import 'dart:convert';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';

enum Severity {
  none,
  mild,
  moderate,
  severe;

  static Severity parse(Object? value) => Severity.values.firstWhere(
    (s) => s.name == value,
    orElse: () => Severity.none,
  );
}

enum ScanStatus {
  ok,
  noLeafDetected;

  static ScanStatus parse(Object? value) =>
      value == 'no_leaf_detected' ? ScanStatus.noLeafDetected : ScanStatus.ok;
}

class LeafCoverage {
  const LeafCoverage({
    required this.powderyMildewPct,
    required this.leafSpotPct,
    required this.healthyPct,
    required this.severity,
  });

  final double powderyMildewPct;
  final double leafSpotPct;
  final double healthyPct;

  /// Keyed by class name: `powdery_mildew`, `leaf_spot`.
  final Map<String, Severity> severity;

  Severity get powderyMildewSeverity =>
      severity['powdery_mildew'] ?? Severity.none;
  Severity get leafSpotSeverity => severity['leaf_spot'] ?? Severity.none;

  /// The worse of the two disease severities.
  Severity get worstSeverity =>
      powderyMildewSeverity.index >= leafSpotSeverity.index
      ? powderyMildewSeverity
      : leafSpotSeverity;

  factory LeafCoverage.fromJson(Map<String, dynamic> json) => LeafCoverage(
    powderyMildewPct: (json['powdery_mildew_pct'] as num? ?? 0).toDouble(),
    leafSpotPct: (json['leaf_spot_pct'] as num? ?? 0).toDouble(),
    healthyPct: (json['healthy_pct'] as num? ?? 0).toDouble(),
    severity: {
      for (final e in (json['severity'] as Map? ?? {}).entries)
        e.key as String: Severity.parse(e.value),
    },
  );
}

class ScanResult {
  const ScanResult({
    required this.id,
    required this.createdAt,
    required this.modelVersion,
    required this.status,
    required this.primary,
    required this.leaves,
    this.imageUrl,
    this.overlayUrl,
    this.imagePath,
    this.overlayPath,
    this.imageBytes,
    this.overlayBytes,
  });

  final String id;
  final DateTime createdAt;
  final String modelVersion;
  final ScanStatus status;

  /// Coverage of the largest leaf; null when no leaf was detected.
  final LeafCoverage? primary;
  final List<LeafCoverage> leaves;

  /// Signed URLs, set when the scan comes from the API.
  final String? imageUrl;
  final String? overlayUrl;

  /// Cloud Storage paths, set when the scan comes from Firestore and the backend has a bucket.
  final String? imagePath;
  final String? overlayPath;

  /// JPEG bytes, only in a fresh `POST /scans` response; saved to the device (DeviceImages).
  final Uint8List? imageBytes;
  final Uint8List? overlayBytes;

  /// From the API response (`POST /scans`, `GET /scans/{id}`).
  factory ScanResult.fromJson(Map<String, dynamic> json) => ScanResult(
    id: json['id'] as String,
    createdAt: _parseDate(json['created_at']),
    modelVersion: json['model_version'] as String? ?? '',
    status: ScanStatus.parse(json['status']),
    primary: json['primary'] == null
        ? null
        : LeafCoverage.fromJson(json['primary'] as Map<String, dynamic>),
    leaves: _parseLeaves(json['leaves']),
    imageUrl: json['image_url'] as String?,
    overlayUrl: json['overlay_url'] as String?,
    imageBytes: _decodeBase64(json['image_jpeg_b64']),
    overlayBytes: _decodeBase64(json['overlay_jpeg_b64']),
  );

  static Uint8List? _decodeBase64(Object? value) =>
      value is String && value.isNotEmpty ? base64Decode(value) : null;

  /// From a Firestore doc at `users/{uid}/scans/{scanId}`.
  factory ScanResult.fromFirestore(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? const {};
    return ScanResult(
      id: doc.id,
      createdAt: _parseDate(data['created_at']),
      modelVersion: data['model_version'] as String? ?? '',
      status: ScanStatus.parse(data['status']),
      primary: data['primary'] == null
          ? null
          : LeafCoverage.fromJson(
              Map<String, dynamic>.from(data['primary'] as Map),
            ),
      leaves: _parseLeaves(data['leaves']),
      imagePath: data['image_path'] as String?,
      overlayPath: data['overlay_path'] as String?,
    );
  }

  static List<LeafCoverage> _parseLeaves(Object? value) => [
    for (final leaf in (value as List? ?? const []))
      LeafCoverage.fromJson(Map<String, dynamic>.from(leaf as Map)),
  ];

  static DateTime _parseDate(Object? value) => switch (value) {
    Timestamp t => t.toDate(),
    String s => DateTime.parse(s).toLocal(),
    _ => DateTime.fromMillisecondsSinceEpoch(0),
  };
}
