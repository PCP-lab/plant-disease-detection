// Build-time settings, passed with `--dart-define=NAME=value`. The API URL and the Android sign-in client ID
// default to the shared AWS deployment, so a plain `flutter run` works; override them per build as needed.

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The shared backend on AWS (EC2 + Caddy HTTPS).
const cloudApiBaseUrl = 'https://3-149-87-65.sslip.io';

/// Backend base URL. Defaults to the AWS backend ([cloudApiBaseUrl]). To use a backend on this PC instead:
/// `--dart-define=API_BASE_URL=http://10.0.2.2:8000` (Android emulator: 10.0.2.2 is the PC) or
/// `--dart-define=API_BASE_URL=http://localhost:8000` (web / desktop).
const apiBaseUrl = String.fromEnvironment('API_BASE_URL', defaultValue: cloudApiBaseUrl);

/// True once lib/firebase_options.dart is filled in (see main.dart). When false the app runs in
/// prototype mode: no sign-in, and history comes from the backend API instead of Firestore.
final firebaseEnabledProvider = Provider<bool>((ref) => false);

/// OAuth client ID of the iOS app (from GoogleService-Info.plist → CLIENT_ID).
/// Only needed for Google sign-in on iOS.
const googleIosClientId = String.fromEnvironment('GOOGLE_IOS_CLIENT_ID');

/// OAuth *web* client ID of the Firebase project (Firebase console → Authentication →
/// Sign-in method → Google → Web SDK configuration). Needed for Google sign-in on Android.
/// Defaults to the leaf-dis-seg project's (public: it's also in android/app/google-services.json).
const googleServerClientId = String.fromEnvironment(
  'GOOGLE_SERVER_CLIENT_ID',
  defaultValue: '636095579619-99mbhvrvi4j7f4kafj8en0eib1gjk6et.apps.googleusercontent.com',
);
