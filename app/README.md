# App (Flutter: Android, iOS, web)

## Setup
```bash
dart pub global activate flutterfire_cli
flutterfire configure        # overwrites lib/firebase_options.dart with your project's values
flutter pub get
```
Until `lib/firebase_options.dart` is filled in, the app starts on a "Firebase is not configured" screen.

## Credentials to fill in
| What | Where | Needed for |
|---|---|---|
| Firebase options (apiKey, appId, projectId, …) | `lib/firebase_options.dart` (`flutterfire configure`) | Everything |
| Backend URL | `--dart-define=API_BASE_URL=…` | Scans |
| Web OAuth client ID | `--dart-define=GOOGLE_SERVER_CLIENT_ID=…` | Google sign-in on Android |
| iOS OAuth client ID | `--dart-define=GOOGLE_IOS_CLIENT_ID=…`, plus its reversed ID as a URL scheme in `ios/Runner/Info.plist` (`CFBundleURLTypes`) | Google sign-in on iOS |
| SHA-1 of the signing key | Firebase console → Project settings → Android app | Google sign-in on Android |
| Authorized domains | Firebase console → Authentication → Settings | Google sign-in on web (add your hosting domain) |

The backend's `CORS_ORIGINS` must include the web app's origin (e.g. `http://localhost:5000`).

## Run
```bash
flutter run -d chrome --web-port 5000 --dart-define=API_BASE_URL=http://localhost:8000
flutter run -d <android-device> --dart-define=API_BASE_URL=http://10.0.2.2:8000   # Android emulator → host
```
iOS builds need a Mac with Xcode.

## Structure
```
lib/
├── main.dart, router.dart, config.dart, firebase_options.dart
├── features/auth/      sign-in (email/password + Google), auth state
├── features/scan/      pick/capture → POST /scans → result (overlay + coverage chart)
├── features/history/   past scans (Firestore users/{uid}/scans) → detail, delete via DELETE /scans/{id}
└── shared/             API client, models, ScanImage (URL or Storage path)
```
