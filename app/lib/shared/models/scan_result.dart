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

/// `leaf`: one photo. `plant`: 3–6 leaves of one plant; [ScanResult.primary] is then the plant level.
enum ScanKind {
  leaf,
  plant;

  static ScanKind parse(Object? value) =>
      value == 'plant' ? ScanKind.plant : ScanKind.leaf;
}

class LeafCoverage {
  const LeafCoverage({
    required this.powderyMildewPct,
    required this.leafSpotPct,
    required this.healthyPct,
    required this.severity,
    this.index,
    this.framing,
  });

  final double powderyMildewPct;
  final double leafSpotPct;
  final double healthyPct;

  /// Keyed by class name: `powdery_mildew`, `leaf_spot`.
  final Map<String, Severity> severity;

  /// Whole-plant scans only: which photo (0-based) this leaf came from, and that photo's check.
  final int? index;
  final Framing? framing;

  /// Share of the leaf with any disease.
  double get diseasedPct => 100 - healthyPct;

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
    index: (json['index'] as num?)?.toInt(),
    framing: Framing.fromJson(json['framing']),
  );
}

/// Whole-plant scans: how the leaves were combined.
class PlantSummary {
  const PlantSummary({
    required this.leavesAnalysed,
    required this.leavesAffected,
    required this.raised,
    required this.skipped,
    this.cover,
  });

  final int leavesAnalysed;

  /// Per disease (`powdery_mildew`, `leaf_spot`): leaves with any of it.
  final Map<String, int> leavesAffected;

  /// Diseases whose plant level went up a step because they're on at least half of the leaves.
  final List<String> raised;

  /// Photo indexes where no leaf was found (left out).
  final List<int> skipped;

  /// Photo index of the most affected leaf.
  final int? cover;

  static PlantSummary? fromJson(Object? json) {
    if (json is! Map) return null;
    return PlantSummary(
      leavesAnalysed: (json['leaves_analysed'] as num? ?? 0).toInt(),
      leavesAffected: {
        for (final e in (json['leaves_affected'] as Map? ?? {}).entries)
          e.key as String: (e.value as num).toInt(),
      },
      raised: [for (final d in (json['raised'] as List? ?? const [])) d as String],
      skipped: [
        for (final i in (json['skipped'] as List? ?? const [])) (i as num).toInt(),
      ],
      cover: (json['cover'] as num?)?.toInt(),
    );
  }
}

/// One leaf photo of a whole-plant scan: bytes in a fresh upload, URLs/paths when the backend stores images.
class LeafImages {
  const LeafImages({
    required this.index,
    this.imageUrl,
    this.overlayUrl,
    this.imagePath,
    this.overlayPath,
    this.imageBytes,
    this.overlayBytes,
  });

  final int index;
  final String? imageUrl;
  final String? overlayUrl;
  final String? imagePath;
  final String? overlayPath;
  final Uint8List? imageBytes;
  final Uint8List? overlayBytes;

  static List<LeafImages>? listFromJson(Object? json) {
    if (json is! List) return null;
    return [
      for (final m in json.whereType<Map>())
        LeafImages(
          index: (m['index'] as num).toInt(),
          imageUrl: m['image_url'] as String?,
          overlayUrl: m['overlay_url'] as String?,
          imagePath: m['image_path'] as String?,
          overlayPath: m['overlay_path'] as String?,
          imageBytes: ScanResult._decodeBase64(m['image_jpeg_b64']),
          overlayBytes: ScanResult._decodeBase64(m['overlay_jpeg_b64']),
        ),
    ];
  }
}

/// Photo check from the backend: is this one dominant leaf, the kind of photo the model is validated on?
class Framing {
  const Framing({
    required this.ok,
    this.issue,
    required this.leafFrac,
    this.dominance,
  });

  final bool ok;

  /// `several_leaves` (no clear main leaf) or `small_leaf` (the leaf fills too little of the photo).
  final String? issue;

  /// The main leaf's share of the photo (0–1).
  final double leafFrac;

  /// Main leaf area / second-largest leaf area; null when there is only one leaf.
  final double? dominance;

  static Framing? fromJson(Object? json) {
    if (json is! Map) return null;
    return Framing(
      ok: json['ok'] as bool? ?? true,
      issue: json['issue'] as String?,
      leafFrac: (json['leaf_frac'] as num? ?? 0).toDouble(),
      dominance: (json['dominance'] as num?)?.toDouble(),
    );
  }
}

class ScanResult {
  const ScanResult({
    required this.id,
    required this.createdAt,
    required this.modelVersion,
    required this.status,
    required this.primary,
    required this.leaves,
    this.kind = ScanKind.leaf,
    this.framing,
    this.plant,
    this.leafImages,
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

  final ScanKind kind;

  /// Coverage of the largest leaf (plant scans: the plant level); null when no leaf was detected.
  final LeafCoverage? primary;

  /// Plant scans: one per analysed leaf.
  final List<LeafCoverage> leaves;

  /// Photo check; null for no leaf, plant scans and scans saved before the check existed.
  final Framing? framing;

  /// Plant scans only.
  final PlantSummary? plant;
  final List<LeafImages>? leafImages;

  bool get isPlant => kind == ScanKind.plant;

  /// Plant scans: the images of the leaf from photo [index], if known.
  LeafImages? leafImagesAt(int? index) =>
      leafImages?.where((l) => l.index == index).firstOrNull;

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
    kind: ScanKind.parse(json['kind']),
    status: ScanStatus.parse(json['status']),
    primary: json['primary'] == null
        ? null
        : LeafCoverage.fromJson(json['primary'] as Map<String, dynamic>),
    leaves: _parseLeaves(json['leaves']),
    framing: Framing.fromJson(json['framing']),
    plant: PlantSummary.fromJson(json['plant']),
    leafImages: LeafImages.listFromJson(json['leaf_images']),
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
      kind: ScanKind.parse(data['kind']),
      status: ScanStatus.parse(data['status']),
      primary: data['primary'] == null
          ? null
          : LeafCoverage.fromJson(
              Map<String, dynamic>.from(data['primary'] as Map),
            ),
      leaves: _parseLeaves(data['leaves']),
      framing: Framing.fromJson(data['framing']),
      plant: PlantSummary.fromJson(data['plant']),
      // Backend doc field `leaf_files`: {index, image_path?, overlay_path?} per leaf.
      leafImages: LeafImages.listFromJson(data['leaf_files']),
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
