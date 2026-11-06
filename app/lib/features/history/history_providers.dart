// History providers: read straight from Firestore (users/{uid}/scans), which the rules allow
// for the owner. Writes and deletes go through the backend.
// In prototype mode (no Firebase) they read from the backend API instead; callers invalidate
// them after an upload or delete since there's no live stream.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../config.dart';
import '../../shared/api_client.dart';
import '../../shared/models/scan_result.dart';
import '../auth/auth_providers.dart';

const historyPageSize = 50;

CollectionReference<Map<String, dynamic>> _scans(String uid) =>
    FirebaseFirestore.instance.collection('users').doc(uid).collection('scans');

/// The signed-in user's scans, newest first.
final historyProvider = StreamProvider.autoDispose<List<ScanResult>>((ref) {
  if (!ref.watch(firebaseEnabledProvider)) {
    return Stream.fromFuture(
      ref.watch(apiClientProvider).listScans(limit: historyPageSize),
    );
  }
  final uid = ref.watch(authStateProvider).value?.uid;
  if (uid == null) return Stream.value(const []);
  return _scans(uid)
      .orderBy('created_at', descending: true)
      .limit(historyPageSize)
      .snapshots()
      .map((snap) => snap.docs.map(ScanResult.fromFirestore).toList());
});

/// One scan by id; null once it's deleted or if it doesn't exist.
final scanByIdProvider = StreamProvider.autoDispose.family<ScanResult?, String>(
  (ref, id) {
    if (!ref.watch(firebaseEnabledProvider)) {
      return Stream.fromFuture(ref.watch(apiClientProvider).getScan(id));
    }
    final uid = ref.watch(authStateProvider).value?.uid;
    if (uid == null) return Stream.value(null);
    return _scans(uid)
        .doc(id)
        .snapshots()
        .map((doc) => doc.exists ? ScanResult.fromFirestore(doc) : null);
  },
);
