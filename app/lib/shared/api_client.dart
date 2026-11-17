// Backend client. Every request carries the signed-in user's Firebase ID token.

import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:dio/dio.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../config.dart';
import 'models/advice.dart';
import 'models/scan_result.dart';

final apiClientProvider = Provider<ApiClient>(
  (ref) => ApiClient(sendIdToken: ref.watch(firebaseEnabledProvider)),
);

class ApiClient {
  /// [sendIdToken] is false in prototype mode, where the backend doesn't check auth.
  ApiClient({Dio? dio, bool sendIdToken = true})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              baseUrl: apiBaseUrl,
              connectTimeout: const Duration(seconds: 15),
              // Inference on a cold Cloud Run instance can take a while.
              receiveTimeout: const Duration(seconds: 90),
            ),
          ) {
    if (!sendIdToken) return;
    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          final token = await FirebaseAuth.instance.currentUser?.getIdToken();
          if (token != null) options.headers['Authorization'] = 'Bearer $token';
          handler.next(options);
        },
      ),
    );
  }

  final Dio _dio;

  /// Uploads a leaf photo and returns the coverage result. [crop] is the box the user drew around the leaf,
  /// as fractions (0–1) of the upright photo; the backend crops to it before analysing.
  Future<ScanResult> createScan(XFile image, {Rect? crop}) async {
    // Bytes rather than a path so this also works on web.
    final form = FormData.fromMap({
      'image': MultipartFile.fromBytes(
        await image.readAsBytes(),
        filename: image.name,
        contentType: DioMediaType.parse(image.mimeType ?? 'image/jpeg'),
      ),
      if (crop != null) 'crop': _cropField(crop),
    });
    final res = await _dio.post<Map<String, dynamic>>('/scans', data: form);
    return ScanResult.fromJson(res.data!);
  }

  /// Whole-plant scan: one photo per leaf (3–6 different leaves of one plant), each with the box the user drew
  /// around its leaf. A 422 means too few leaves were found; [failedPhotos] says which photos to retake.
  Future<ScanResult> createPlantScan(List<(XFile, Rect)> leaves) async {
    final form = FormData();
    for (final (image, crop) in leaves) {
      form.files.add(
        MapEntry(
          'images',
          MultipartFile.fromBytes(
            await image.readAsBytes(),
            filename: image.name,
            contentType: DioMediaType.parse(image.mimeType ?? 'image/jpeg'),
          ),
        ),
      );
      form.fields.add(MapEntry('crops', _cropField(crop)));
    }
    final res = await _dio.post<Map<String, dynamic>>(
      '/scans/plant',
      data: form,
      // Up to 6 leaves, two model passes each.
      options: Options(receiveTimeout: const Duration(seconds: 150)),
    );
    return ScanResult.fromJson(res.data!);
  }

  static String _cropField(Rect crop) =>
      [crop.left, crop.top, crop.right, crop.bottom]
          .map((v) => v.clamp(0.0, 1.0).toStringAsFixed(4))
          .join(',');

  /// Newest first. [cursor] is the id of the last scan of the previous page.
  Future<List<ScanResult>> listScans({int limit = 50, String? cursor}) async {
    final res = await _dio.get<List<dynamic>>(
      '/scans',
      queryParameters: {'limit': limit, 'cursor': ?cursor},
    );
    return [
      for (final json in res.data!)
        ScanResult.fromJson(json as Map<String, dynamic>),
    ];
  }

  /// Null if the scan doesn't exist.
  Future<ScanResult?> getScan(String id) async {
    try {
      final res = await _dio.get<Map<String, dynamic>>('/scans/$id');
      return ScanResult.fromJson(res.data!);
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return null;
      rethrow;
    }
  }

  /// AI management tips for a scan, from its [image] (the original photo), its results and the
  /// weather at [lat]/[lon]. Each is optional; the advice says what it couldn't use.
  Future<Advice> getAdvice(
    String scanId, {
    Uint8List? image,
    double? lat,
    double? lon,
    String? crop,
  }) async {
    final res = await _dio.post<Map<String, dynamic>>(
      '/scans/$scanId/advice',
      data: {
        'lat': ?lat,
        'lon': ?lon,
        'crop': ?crop,
        if (image != null) 'image_jpeg_b64': base64Encode(image),
      },
      // An open-source LLM on a CPU can take a minute or two.
      options: Options(receiveTimeout: const Duration(seconds: 150)),
    );
    return Advice.fromJson(res.data!);
  }

  /// 7-day weather risk of each disease spreading at [lat]/[lon].
  Future<RiskForecast> getRiskForecast(double lat, double lon) async {
    final res = await _dio.get<Map<String, dynamic>>(
      '/risk-forecast',
      queryParameters: {'lat': lat, 'lon': lon},
    );
    return RiskForecast.fromJson(res.data!);
  }

  /// Bytes of a scan image URL (absolute, or relative to the API in prototype mode); null on failure.
  Future<Uint8List?> downloadImage(String url) async {
    try {
      final res = await _dio.get<List<int>>(
        url,
        options: Options(responseType: ResponseType.bytes),
      );
      return res.data == null ? null : Uint8List.fromList(res.data!);
    } on DioException {
      return null;
    }
  }

  /// Deletes the Firestore doc and any server-side images. The device copies are deleted separately.
  Future<void> deleteScan(String id) => _dio.delete<void>('/scans/$id');

  /// Deletes the signed-in user's account: all their scans and their login. The device copies of the photos
  /// are deleted separately.
  Future<void> deleteAccount() => _dio.delete<void>('/account');
}

/// Whole-plant scans: the photo indexes (0-based) where no leaf was found, from a 422; null for other errors.
List<int>? failedPhotos(Object error) {
  if (error is! DioException || error.response?.statusCode != 422) return null;
  final data = error.response?.data;
  final detail = data is Map ? data['detail'] : null;
  final failed = detail is Map ? detail['failed'] : null;
  return failed is List ? [for (final i in failed) (i as num).toInt()] : null;
}

/// A message suitable for a snackbar.
String describeError(Object error) {
  if (error is DioException) {
    final status = error.response?.statusCode;
    final detail = error.response?.data is Map
        ? (error.response!.data as Map)['detail']
        : null;
    if (status == 401) return 'Your session expired. Please sign in again.';
    if (detail is String) return detail;
    if (detail is Map && detail['message'] is String) return detail['message'] as String;
    if (status != null) return 'Server error ($status). Please try again.';
    return switch (error.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.receiveTimeout ||
      DioExceptionType.sendTimeout => 'The server took too long to respond.',
      _ => 'Could not reach the server. Check your connection.',
    };
  }
  if (error is FirebaseAuthException) return error.message ?? error.code;
  return 'Something went wrong: $error';
}
