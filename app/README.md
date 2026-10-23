# App (Flutter: Android, iOS, web)

## Setup
```bash
dart pub global activate flutterfire_cli
flutterfire configure        # generates lib/firebase_options.dart; then enable Firebase.initializeApp in main.dart
flutter pub get
```

## Run
```bash
flutter run -d chrome --dart-define=API_BASE_URL=http://localhost:8000
flutter run -d <android-device> --dart-define=API_BASE_URL=http://10.0.2.2:8000   # Android emulator → host
```
iOS builds need a Mac with Xcode.

## Structure
```
lib/
├── main.dart, router.dart, config.dart
├── features/auth/      sign-in (email + Google)
├── features/scan/      pick/capture → upload → result
├── features/history/   past scans (Firestore) → detail
└── shared/             API client, models
```
