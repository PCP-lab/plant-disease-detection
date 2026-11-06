// Build-time settings, passed with `--dart-define=NAME=value`.
// Everything except the API URL is left blank here and filled in per deployment.

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

const _apiBaseUrlOverride = String.fromEnvironment('API_BASE_URL');

/// Backend base URL: `--dart-define=API_BASE_URL=https://<cloud-run-url>`.
/// Defaults to the dev machine: 10.0.2.2 is the host as seen from the Android emulator.
String get apiBaseUrl {
  if (_apiBaseUrlOverride.isNotEmpty) return _apiBaseUrlOverride;
  final androidEmulator =
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  return androidEmulator ? 'http://10.0.2.2:8000' : 'http://localhost:8000';
}

/// True once lib/firebase_options.dart is filled in (see main.dart). When false the app runs in
/// prototype mode: no sign-in, and history comes from the backend API instead of Firestore.
final firebaseEnabledProvider = Provider<bool>((ref) => false);

/// OAuth client ID of the iOS app (from GoogleService-Info.plist → CLIENT_ID).
/// Only needed for Google sign-in on iOS.
const googleIosClientId = String.fromEnvironment('GOOGLE_IOS_CLIENT_ID');

/// OAuth *web* client ID of the Firebase project (Firebase console → Authentication →
/// Sign-in method → Google → Web SDK configuration). Needed for Google sign-in on Android.
const googleServerClientId = String.fromEnvironment('GOOGLE_SERVER_CLIENT_ID');
