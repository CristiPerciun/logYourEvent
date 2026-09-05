import 'dart:math';

import 'package:lye_core/lye_core.dart';
import 'package:test/test.dart';

import 'support.dart';

class FakeShipper implements BatchShipper {
  final List<LyeBatch> received = <LyeBatch>[];
  ShipResult next = const ShipResult.accepted();
  bool throwOnShip = false;

  @override
  Future<ShipResult> ship(LyeBatch batch) async {
    if (throwOnShip) throw StateError('network down');
    received.add(batch);
    return next;
  }
}

void main() {
  group('LyeBatch', () {
    test('round-trips through JSON and validates its envelope', () async {
      final events = await recordMany(testRecorder(), 3);
      final batch = LyeBatch.fromEvents(events);
      final json = batch.toJson();
      expect(json['schema'], LyeBatch.schemaVersion);
      expect(json['count'], 3);
      final parsed = LyeBatch.fromJson(json);
      expect(parsed.fromSeq, 1);
      expect(parsed.toSeq, 3);
      expect(parsed.headHash, events.last.rowHash);

      json['to_seq'] = 9;
      expect(() => LyeBatch.fromJson(json), throwsFormatException);
    });

    test('refuses non-contiguous or mixed events', () async {
      final events = await recordMany(testRecorder(), 3);
      expect(
        () => LyeBatch.fromEvents(<LyeEvent>[events[0], events[2]]),
        throwsArgumentError,
      );
      final other = await recordMany(testRecorder(nodeId: 'other'), 1);
      expect(
        () => LyeBatch.fromEvents(<LyeEvent>[...events, ...other]),
        throwsArgumentError,
      );
      expect(() => LyeBatch.fromEvents(<LyeEvent>[]), throwsArgumentError);
    });
  });

  group('ShippingScheduler', () {
    test('ships pending events in batches and marks them shipped', () async {
      final recorder = testRecorder();
      final shipper = FakeShipper();
      final scheduler = ShippingScheduler(
        recorder: recorder,
        shipper: shipper,
        maxBatchSize: 4,
        random: Random(1),
      );
      await recordMany(recorder, 10);
      expect(await scheduler.flush(), FlushOutcome.shipped);
      expect(shipper.received.map((LyeBatch b) => b.count), <int>[4, 4, 2]);
      expect(scheduler.shippedCount, 10);
      expect(await recorder.store.readPending(recorder.streamId), isEmpty);
      expect(await scheduler.flush(), FlushOutcome.nothingToShip);
    });

    test('keeps events and backs off on transport failure', () async {
      final clock = FixedClock(DateTime.utc(2026, 9, 5));
      final recorder = testRecorder(clock: clock);
      final shipper = FakeShipper()..throwOnShip = true;
      final scheduler = ShippingScheduler(
        recorder: recorder,
        shipper: shipper,
        minBackoff: const Duration(seconds: 2),
        random: Random(1),
      );
      await recordMany(recorder, 2);
      expect(await scheduler.flush(), FlushOutcome.failed);
      expect(scheduler.failedAttempts, 1);
      expect(scheduler.backoff, const Duration(seconds: 2));
      expect(await scheduler.flush(), FlushOutcome.deferred);
      expect((await recorder.store.readPending(recorder.streamId)).length, 2);

      clock.advance(const Duration(seconds: 3));
      shipper.throwOnShip = false;
      expect(await scheduler.flush(), FlushOutcome.shipped);
      expect(scheduler.backoff, isNull);
    });

    test('stops after a definitive rejection and records it once', () async {
      final recorder = testRecorder();
      final shipper = FakeShipper()
        ..next = const ShipResult.rejected('chain_broken');
      final scheduler = ShippingScheduler(
        recorder: recorder,
        shipper: shipper,
        random: Random(1),
      );
      await recordMany(recorder, 2);
      expect(await scheduler.flush(), FlushOutcome.rejected);
      expect(scheduler.isRejected, isTrue);
      expect(await scheduler.flush(), FlushOutcome.rejected);
      expect(shipper.received.length, 1);
      await recorder.flush();
      final events = await recorder.store.readRange(
        recorder.streamId,
        fromSeq: 1,
        toSeq: 10,
      );
      expect(events.last.action, 'lye.ship.rejected');
      expect(events.last.attrs, contains('chain_broken'));

      scheduler.resetAfterRejection();
      shipper.next = const ShipResult.accepted();
      expect(await scheduler.flush(), FlushOutcome.shipped);
    });

    test('flushes automatically when the threshold is reached', () async {
      final recorder = testRecorder();
      final shipper = FakeShipper();
      final scheduler = ShippingScheduler(
        recorder: recorder,
        shipper: shipper,
        flushThreshold: 3,
        interval: const Duration(hours: 1),
        random: Random(1),
      );
      scheduler.start();
      await recordMany(recorder, 3);
      await Future<void>.delayed(Duration.zero);
      await scheduler.stop();
      expect(shipper.received, isNotEmpty);
      expect(scheduler.shippedCount, greaterThanOrEqualTo(3));
    });
  });

  group('CallCorrelation', () {
    test('is independent of key order and sensitive to method', () {
      final a = CallCorrelation.digest(
        endpoint: 'ropa',
        method: 'addEntry',
        jsonArgs: <String, Object?>{
          'entry': <String, Object?>{'x': 1, 'y': 2},
        },
      );
      final b = CallCorrelation.digest(
        endpoint: 'ropa',
        method: 'addEntry',
        jsonArgs: <String, Object?>{
          'entry': <String, Object?>{'y': 2, 'x': 1},
        },
      );
      final c = CallCorrelation.digest(
        endpoint: 'ropa',
        method: 'updateEntry',
        jsonArgs: <String, Object?>{
          'entry': <String, Object?>{'x': 1, 'y': 2},
        },
      );
      expect(a, b);
      expect(a, isNot(c));
      expect(isSha256Hex(a), isTrue);
    });

    test('strips the Serverpod envelope keys on the server side', () {
      final server = CallCorrelation.stripEnvelope(<Object?, Object?>{
        'method': 'addEntry',
        'entry': <String, Object?>{'x': 1},
      });
      final client = <String, Object?>{
        'entry': <String, Object?>{'x': 1},
      };
      expect(
        CallCorrelation.digest(
          endpoint: 'ropa',
          method: 'addEntry',
          jsonArgs: server,
        ),
        CallCorrelation.digest(
          endpoint: 'ropa',
          method: 'addEntry',
          jsonArgs: client,
        ),
      );
      expect(CallCorrelation.route('ropa', 'addEntry'), 'ropa.addEntry');
      expect(
        CallCorrelation.attrs(
          endpoint: 'ropa',
          method: 'addEntry',
          jsonArgs: client,
        ).keys,
        containsAll(<String>['endpoint', 'method', 'call_digest']),
      );
    });
  });
}
