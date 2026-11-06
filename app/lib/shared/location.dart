// Best-effort device location, used only to look up local weather for management tips.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

/// Why there is no position.
enum LocationProblem {
  /// Location services (GPS) are switched off on the device.
  serviceOff,

  /// The user declined the permission prompt; asking again is possible.
  denied,

  /// Permission is permanently denied; only the app's system settings can change it.
  deniedForever,

  /// Only approximate location is allowed and Wi-Fi/cell gave no fix. Android won't use GPS for an
  /// approximate-only app, so precise location is needed here.
  approximateOnly,

  /// Everything is allowed, but no fix arrived in time and there is no last known position.
  noFix,
}

/// A position, or the reason there isn't one.
class LocationLookup {
  const LocationLookup.found(Position this.position) : problem = null;
  const LocationLookup.failed(LocationProblem this.problem) : position = null;

  final Position? position;
  final LocationProblem? problem;
}

/// The device location, looked up once per screen visit (shared by the risk forecast and the tips).
/// Invalidate it to look again, e.g. after the user turns location on.
final locationProvider = FutureProvider.autoDispose<LocationLookup>(
  (ref) => lookUpLocation(),
);

/// Coarse position, or the reason it isn't available. Callers carry on without weather then.
Future<LocationLookup> lookUpLocation() async {
  try {
    // On Android, getCurrentPosition itself shows Google Play services' "Turn on location?"
    // dialog when location is off, so only bail out early elsewhere.
    final android = !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
    if (!android && !await Geolocator.isLocationServiceEnabled()) {
      return const LocationLookup.failed(LocationProblem.serviceOff);
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.deniedForever) {
      return const LocationLookup.failed(LocationProblem.deniedForever);
    }
    if (permission == LocationPermission.denied) {
      return const LocationLookup.failed(LocationProblem.denied);
    }
    return LocationLookup.found(await _currentPosition());
  } on LocationServiceDisabledException {
    return const LocationLookup.failed(LocationProblem.serviceOff);
  } catch (_) {
    // Timeout, or no fix: fall back to the last known position (not available on web).
    try {
      final last = await Geolocator.getLastKnownPosition();
      if (last != null) return LocationLookup.found(last);
    } catch (_) {}
    if (!await _serviceEnabled()) {
      return const LocationLookup.failed(LocationProblem.serviceOff);
    }
    if (await _approximateOnly()) {
      return const LocationLookup.failed(LocationProblem.approximateOnly);
    }
    return const LocationLookup.failed(LocationProblem.noFix);
  }
}

/// A recent cached fix if there is one, else Wi-Fi/cell location, else GPS.
///
/// Wi-Fi/cell alone is not enough: Android's low-power and balanced modes never switch on GPS, so
/// in a field with no Wi-Fi (or on an emulator) they time out with no fix. With coarse permission
/// Android still blurs a GPS fix to ~2 km, which is all the weather lookup needs.
Future<Position> _currentPosition() async {
  if (!kIsWeb) {
    final last = await Geolocator.getLastKnownPosition();
    if (last != null &&
        DateTime.now().difference(last.timestamp) < const Duration(minutes: 30)) {
      return last;
    }
  }
  try {
    return await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.medium,
        timeLimit: Duration(seconds: 8),
      ),
    );
  } on TimeoutException {
    // Approximate-only apps never get GPS, so waiting for it would just add 25 s.
    if (await _approximateOnly()) rethrow;
    return Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        timeLimit: Duration(seconds: 25),
      ),
    );
  }
}

Future<bool> _approximateOnly() async {
  if (kIsWeb) return false;
  try {
    return await Geolocator.getLocationAccuracy() == LocationAccuracyStatus.reduced;
  } catch (_) {
    return false;
  }
}

Future<bool> _serviceEnabled() async {
  try {
    return await Geolocator.isLocationServiceEnabled();
  } catch (_) {
    return true;
  }
}

/// What to tell the user about [problem], and the button that fixes it.
({String message, String action}) locationProblemText(LocationProblem problem) =>
    switch (problem) {
      LocationProblem.serviceOff => (
        message:
            'Location (GPS) is turned off. Turn it on to see the disease risk and weather-based '
            'spray timing for your area.',
        action: 'Turn on location',
      ),
      LocationProblem.denied => (
        message:
            'Allow location access to see the disease risk and weather-based spray timing for '
            'your area.',
        action: 'Allow location',
      ),
      LocationProblem.deniedForever => (
        message:
            'Location access is blocked for this app. Allow it in the app settings to see the '
            'disease risk for your area.',
        action: 'Open app settings',
      ),
      LocationProblem.approximateOnly => (
        message:
            'Your approximate location isn\'t available here (no Wi-Fi or mobile network '
            'location). Allow precise location so the app can use GPS.',
        action: 'Allow precise location',
      ),
      LocationProblem.noFix => (
        message: 'Could not find your location. Make sure GPS has a signal, then try again.',
        action: 'Try again',
      ),
    };

/// Takes the user to whatever fixes [problem]: a fresh lookup (which re-shows the system prompt) or a
/// settings screen. After a settings screen, the advice screen looks again when the app resumes.
Future<void> fixLocationProblem(WidgetRef ref, LocationProblem problem) async {
  final android = !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  switch (problem) {
    // Android: a new lookup shows Google Play services' one-tap "Turn on location?" dialog.
    case LocationProblem.serviceOff when !android && !kIsWeb:
      await Geolocator.openLocationSettings();
    case LocationProblem.deniedForever when !kIsWeb:
      await Geolocator.openAppSettings();
    case LocationProblem.approximateOnly:
      // Android shows its "upgrade to precise" prompt; if the user has dismissed it before and it
      // no longer appears, the app's settings page is the only way.
      await Geolocator.requestPermission();
      if (await _approximateOnly()) {
        await Geolocator.openAppSettings();
      } else {
        ref.invalidate(locationProvider);
      }
    default:
      ref.invalidate(locationProvider); // re-asks for permission / service
  }
}

/// Asks the user to turn on location services. Shown once when the management tips open with GPS off.
Future<void> showTurnOnLocationDialog(BuildContext context, WidgetRef ref) async {
  final turnOn = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      icon: const Icon(Icons.location_off_outlined),
      title: const Text('Turn on location?'),
      content: const Text(
        'The disease-risk forecast and spray timing use the weather where you are. '
        'Turn on location (GPS) to get advice for your area.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Not now'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Turn on'),
        ),
      ],
    ),
  );
  if (turnOn == true) await fixLocationProblem(ref, LocationProblem.serviceOff);
}
