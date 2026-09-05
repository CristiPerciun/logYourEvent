import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lye_core/lye_core.dart';
import 'package:lye_flutter/lye_flutter.dart';

import 'support.dart';

void main() {
  late LyeBatch batch;

  setUp(() async {
    final recorder = testRecorder();
    for (var i = 0; i < 3; i++) {
      await recorder.point(
        LyeCategory.interaction,
        LyeActions.uiTap,
        component: 'b$i',
      );
    }
    batch = LyeBatch.fromEvents(
      await recorder.store.readPending(recorder.streamId),
    );
  });

  HttpBatchShipper shipperWith(
    Future<http.Response> Function(http.Request) handler,
  ) {
    return HttpBatchShipper(
      endpoint: Uri.parse('https://api.example.test/lye/ingest'),
      headers: () async => <String, String>{'authorization': 'Basic test-key'},
      client: MockClient(handler),
    );
  }

  test(
    'posts the batch JSON with the session header and accepts a 200',
    () async {
      http.Request? seen;
      final shipper = shipperWith((http.Request request) async {
        seen = request;
        return http.Response(
          jsonEncode(<String, Object?>{'code': 'accepted'}),
          200,
        );
      });
      final result = await shipper.ship(batch);
      expect(result.accepted, isTrue);
      expect(seen!.headers['authorization'], 'Basic test-key');
      expect(seen!.headers['content-type'], startsWith('application/json'));
      final body = jsonDecode(seen!.body) as Map<String, dynamic>;
      expect(body['schema'], LyeBatch.schemaVersion);
      expect(body['count'], 3);
    },
  );

  test('treats 5xx, 429 and transport errors as transient', () async {
    expect(
      (await shipperWith(
        (_) async => http.Response('', 503),
      ).ship(batch)).retryable,
      isTrue,
    );
    expect(
      (await shipperWith(
        (_) async => http.Response('', 429),
      ).ship(batch)).retryable,
      isTrue,
    );
    final broken = shipperWith(
      (_) async => throw http.ClientException('connection reset'),
    );
    final result = await broken.ship(batch);
    expect(result.accepted, isFalse);
    expect(result.retryable, isTrue);
    expect(result.reason, 'connection reset');
  });

  test(
    'treats other 4xx as definitive rejections carrying the server code',
    () async {
      final rejected = await shipperWith(
        (_) async => http.Response(
          jsonEncode(<String, Object?>{'code': 'chain_broken'}),
          409,
        ),
      ).ship(batch);
      expect(rejected.accepted, isFalse);
      expect(rejected.retryable, isFalse);
      expect(rejected.reason, 'chain_broken');
      final plain = await shipperWith(
        (_) async => http.Response('nope', 403),
      ).ship(batch);
      expect(plain.reason, 'http_403');
    },
  );
}
