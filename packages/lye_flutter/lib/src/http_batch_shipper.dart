import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:lye_core/lye_core.dart';

/// Ships batches to the server's ingest route over HTTPS.
///
/// The route is a plain REST route on the server (see
/// `docs/integrazione_compliance_os.md`); [headers] supplies the session
/// header the app already uses for its Serverpod calls. Network errors,
/// timeouts, 429 and 5xx are transient; any other status is a definitive
/// rejection carrying the server's `code`.
class HttpBatchShipper implements BatchShipper {
  HttpBatchShipper({
    required this.endpoint,
    required this.headers,
    http.Client? client,
    this.timeout = const Duration(seconds: 15),
  }) : _client = client ?? http.Client();

  final Uri endpoint;
  final Future<Map<String, String>> Function() headers;
  final Duration timeout;
  final http.Client _client;

  @override
  Future<ShipResult> ship(LyeBatch batch) async {
    final http.Response response;
    try {
      response = await _client
          .post(
            endpoint,
            headers: <String, String>{
              'content-type': 'application/json',
              'accept': 'application/json',
              ...await headers(),
            },
            body: jsonEncode(batch.toJson()),
          )
          .timeout(timeout);
    } on TimeoutException {
      return const ShipResult.failed('timeout');
    } on http.ClientException catch (e) {
      return ShipResult.failed(e.message);
    }
    if (response.statusCode == 200) return const ShipResult.accepted();
    if (response.statusCode == 429 || response.statusCode >= 500) {
      return ShipResult.failed('http_${response.statusCode}');
    }
    return ShipResult.rejected(_codeOf(response));
  }

  static String _codeOf(http.Response response) {
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map && decoded['code'] is String) {
        return decoded['code'] as String;
      }
    } on FormatException {
      // Fall through to the status code.
    }
    return 'http_${response.statusCode}';
  }

  void close() => _client.close();
}
