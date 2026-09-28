import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// The institution's server, fixed when the app is built (deploy/build-app.sh):
///   flutter build apk --dart-define=API_URL=https://attendance.example.edu
/// Users never see or change it.
const apiUrl = String.fromEnvironment('API_URL', defaultValue: 'http://10.0.2.2:8080');

class ApiException implements Exception {
  final int status;
  final String message;
  ApiException(this.status, this.message);
  bool get isOffline => status == 0;
  @override
  String toString() => message;
}

class Api {
  String? token;

  final String baseUrl = apiUrl;
  final http.Client _http = http.Client();

  Future<dynamic> get(String path) => _send('GET', path);
  Future<dynamic> post(String path, [Object? body]) => _send('POST', path, body);
  Future<dynamic> put(String path, [Object? body]) => _send('PUT', path, body);
  Future<dynamic> patch(String path, [Object? body]) => _send('PATCH', path, body);
  Future<dynamic> delete(String path) => _send('DELETE', path);

  Future<dynamic> _send(String method, String path, [Object? body]) async {
    final req = http.Request(method, Uri.parse('$baseUrl$path'));
    if (token != null) req.headers['authorization'] = 'Bearer $token';
    if (body != null) {
      req.headers['content-type'] = 'application/json';
      req.body = jsonEncode(body);
    }
    http.StreamedResponse res;
    try {
      res = await _http.send(req).timeout(const Duration(seconds: 15));
    } on TimeoutException {
      throw ApiException(0, 'No connection');
    } catch (_) {
      throw ApiException(0, 'No connection');
    }
    final text = await res.stream.bytesToString();
    final data = text.isEmpty ? null : jsonDecode(text);
    if (res.statusCode >= 400) {
      throw ApiException(res.statusCode, (data is Map ? data['error'] : null)?.toString() ?? 'Error ${res.statusCode}');
    }
    return data;
  }
}
