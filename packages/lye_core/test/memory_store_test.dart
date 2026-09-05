import 'package:lye_core/lye_core.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('MemoryLyeStore', () {
    test(
      'refuses gaps, broken links, duplicates and foreign streams',
      () async {
        final store = MemoryLyeStore();
        final recorder = testRecorder(store: store);
        final events = await recordMany(recorder, 3);

        // Re-appending an existing event breaks contiguity.
        expect(
          () => store.append(events[2]),
          throwsA(isA<ChainIntegrityException>()),
        );

        // An event with the right seq but the wrong link.
        final fields = events[2].toCsvFields();
        fields[LyeCsvSchema.indexOf('seq')] = '4';
        final badLink = LyeEvent.fromCsvFields(fields);
        expect(
          () => store.append(badLink),
          throwsA(isA<ChainIntegrityException>()),
        );

        // A well-formed row of another stream cannot be appended to this one.
        final other = testRecorder(store: MemoryLyeStore(), nodeId: 'node-z');
        final foreign = (await recordMany(other, 1)).single;
        final head = await store.head(recorder.streamId);
        expect(
          () => assertContinues(head, foreign),
          throwsA(isA<ChainIntegrityException>()),
        );
      },
    );

    test('tracks pending and shipped events', () async {
      final store = MemoryLyeStore();
      final recorder = testRecorder(store: store);
      final events = await recordMany(recorder, 5);
      expect((await store.readPending(recorder.streamId)).length, 5);
      expect((await store.readPending(recorder.streamId, limit: 2)).length, 2);

      await store.markShipped(
        recorder.streamId,
        events.take(3).map((LyeEvent e) => e.eventId),
        DateTime.utc(2026, 9, 5, 10),
      );
      final pending = await store.readPending(recorder.streamId);
      expect(pending.map((LyeEvent e) => e.seq), <int>[4, 5]);

      final purged = await store.purgeShippedBefore(DateTime.utc(2027));
      expect(purged, 3);
      expect(store.length, 2);
      final range = await store.readRange(
        recorder.streamId,
        fromSeq: 1,
        toSeq: 10,
      );
      expect(range.map((LyeEvent e) => e.seq), <int>[4, 5]);
      // The head survives the purge: the chain can continue.
      expect((await store.head(recorder.streamId)).seq, 5);
    });

    test('evicts shipped events first and counts overflow', () async {
      final store = MemoryLyeStore(maxEvents: 4);
      final recorder = testRecorder(store: store);
      final first = await recordMany(recorder, 3);
      await store.markShipped(
        recorder.streamId,
        first.map((LyeEvent e) => e.eventId),
        DateTime.utc(2026),
      );
      await recordMany(recorder, 3);
      expect(store.length, lessThanOrEqualTo(4));
      expect(store.overflowCount, 0);
      final pending = await store.readPending(recorder.streamId);
      expect(pending.length, 3, reason: 'unshipped events are never evicted');

      await recordMany(recorder, 3);
      expect(store.overflowCount, greaterThan(0));
      expect((await store.readPending(recorder.streamId)).length, 6);
    });

    test('knows the latest epoch of a node', () async {
      final store = MemoryLyeStore();
      final a1 = testRecorder(
        store: store,
        epoch: '01924f3a-0000-7000-8000-000000000001',
      );
      final a2 = testRecorder(
        store: store,
        epoch: '01924f3a-0000-7000-8000-000000000002',
      );
      final b = testRecorder(
        store: store,
        nodeId: 'node-b',
        epoch: '01924f3a-0000-7000-8000-000000000009',
      );
      await recordMany(a1, 2);
      await recordMany(a2, 1);
      await recordMany(b, 1);
      final latest = await store.latestHeadForNode('client', 'node-a');
      expect(latest!.streamId, a2.streamId);
      expect(latest.seq, 1);
      expect(await store.latestHeadForNode('client', 'nobody'), isNull);
      expect(await store.streamIds(), hasLength(3));
    });
  });
}
