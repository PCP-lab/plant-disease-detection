// Profile screen state: scan statistics and app settings kept on the device (theme).

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';

import '../../config.dart';
import '../../shared/api_client.dart';
import '../../shared/models/scan_result.dart';
import '../auth/auth_providers.dart';

class ProfileStats {
  const ProfileStats({required this.scans, required this.plantScans, this.lastScan});

  final int scans;
  final int plantScans;
  final DateTime? lastScan;
}

/// Totals for the profile header. Firestore count queries, so they're exact even past History's 50-scan page.
final profileStatsProvider = FutureProvider.autoDispose<ProfileStats>((ref) async {
  if (!ref.watch(firebaseEnabledProvider)) {
    final scans = await ref.watch(apiClientProvider).listScans(limit: 100);
    return ProfileStats(
      scans: scans.length,
      plantScans: scans.where((s) => s.isPlant).length,
      lastScan: scans.firstOrNull?.createdAt,
    );
  }
  final uid = ref.watch(authStateProvider).value?.uid;
  if (uid == null) return const ProfileStats(scans: 0, plantScans: 0);
  final col = FirebaseFirestore.instance.collection('users').doc(uid).collection('scans');
  final (all, plants, latest) = await (
    col.count().get(),
    col.where('kind', isEqualTo: 'plant').count().get(),
    col.orderBy('created_at', descending: true).limit(1).get(),
  ).wait;
  return ProfileStats(
    scans: all.count ?? 0,
    plantScans: plants.count ?? 0,
    lastScan: latest.docs.isEmpty ? null : ScanResult.fromFirestore(latest.docs.first).createdAt,
  );
});

/// Small key-value settings kept on this device (a Hive box). In memory until main() opens the real one.
class SettingsStore {
  SettingsStore._(this._box);

  SettingsStore.inMemory() : _box = null;

  /// Hive must already be initialised (DeviceImages.open() does that).
  static Future<SettingsStore> open() async => SettingsStore._(await Hive.openBox<String>('settings'));

  final Box<String>? _box;
  final _memory = <String, String>{};

  String? get(String key) => _box == null ? _memory[key] : _box.get(key);

  Future<void> put(String key, String value) async =>
      _box == null ? _memory[key] = value : await _box.put(key, value);
}

/// Overridden in main() with [SettingsStore.open].
final settingsStoreProvider = Provider<SettingsStore>((ref) => SettingsStore.inMemory());

/// Light / dark / follow the phone; remembered on the device.
final themeModeProvider = NotifierProvider<ThemeModeNotifier, ThemeMode>(ThemeModeNotifier.new);

class ThemeModeNotifier extends Notifier<ThemeMode> {
  static const _key = 'theme_mode';

  @override
  ThemeMode build() {
    final saved = ref.watch(settingsStoreProvider).get(_key);
    return ThemeMode.values.firstWhere((m) => m.name == saved, orElse: () => ThemeMode.system);
  }

  Future<void> set(ThemeMode mode) async {
    state = mode;
    await ref.read(settingsStoreProvider).put(_key, mode.name);
  }
}
