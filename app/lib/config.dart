/// Backend base URL, set at build time:
/// `flutter run --dart-define=API_BASE_URL=https://<cloud-run-url>`
const apiBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'http://localhost:8000',
);
