@Tags(<String>['realm'])
library;

import 'dart:io';
import 'dart:math';

import 'package:lye_core/lye_core.dart';
import 'package:lye_realm/lye_realm.dart';
import 'package:path/path.dart' as p;
import 'package:realm_dart/realm.dart';
import 'package:test/test.dart';

int _seed = 500;

LyeRecorder recorderOn(LyeStore store, {String? epoch, FixedClock? clock}) {
  return LyeRecorder(
    config: LyeConfig(
      origin: LyeOrigin.server,
      platform: LyePlatform.windows,
      appId: 'cos_server',
      appVersion: '1.0.0+1',
      nodeId: 'app-1',
    ),
    store: store,
    clock: clock ?? FixedClock(DateTime.utc(2026, 9, 5, 9)),
    random: Random(_seed++),
    epoch: epoch,
  );
}

Future<List<LyeEvent>> recordMany(LyeRecorder recorder, int count) async {
  return <LyeEvent>[
    for (var i = 0; i < count; i++)
      await recorder.point(
        LyeCategory.db,
        LyeActions.dbStatement,
        component: 't$i',
      ),
  ];
}

void main() {
  late Directory dir;

  setUp(() async => dir = await Directory.systemTemp.createTemp('lye_realm_'));
  tearDown(() async {
    try {
      await dir.delete(recursive: true);
    } on FileSystemException {
      // Realm may keep lock files open for a moment on Windows.
    }
  });

  test(
    'appends, reads, marks and purges through the LyeStore contract',
    () async {
      final store = RealmLyeStore.open(path: p.join(dir.path, 'lye.realm'));
      final recorder = recorderOn(store);
      final events = await recordMany(recorder, 5);
      expect(store.length, 5);
      expect((await store.head(recorder.streamId)).seq, 5);
      expect(
        (await store.readPending(
          recorder.streamId,
          limit: 2,
        )).map((LyeEvent e) => e.seq),
        <int>[1, 2],
      );

      await store.markShipped(
        recorder.streamId,
        events.take(3).map((LyeEvent e) => e.eventId),
        DateTime.utc(2026, 9, 5, 10),
      );
      expect(
        (await store.readPending(recorder.streamId)).map((LyeEvent e) => e.seq),
        <int>[4, 5],
      );
      final range = await store.readRange(
        recorder.streamId,
        fromSeq: 2,
        toSeq: 4,
      );
      expect(range.map((LyeEvent e) => e.seq), <int>[2, 3, 4]);
      expect(range.every((LyeEvent e) => e.hasValidRowHash), isTrue);
      expect(range.first.toCsvFields(), events[1].toCsvFields());

      expect(await store.purgeShippedBefore(DateTime.utc(2027)), 3);
      expect(store.length, 2);
      expect(
        (await store.head(recorder.streamId)).seq,
        5,
        reason: 'the head survives the purge',
      );
      expect(await store.streamIds(), <String>[recorder.streamId]);
      await recorder.close();
      await store.close();
    },
  );

  test('refuses discontinuities atomically', () async {
    final store = RealmLyeStore.open(path: p.join(dir.path, 'lye.realm'));
    final recorder = recorderOn(store);
    final events = await recordMany(recorder, 3);
    await expectLater(
      store.append(events[1]),
      throwsA(isA<ChainIntegrityException>()),
    );
    expect(store.length, 3);
    // The store holds many streams (server + ingested clients): the first
    // event of a new stream is a valid append and opens a second chain...
    final other = recorderOn(MemoryLyeStore());
    final foreign = (await recordMany(other, 1)).single;
    await store.append(foreign);
    expect((await store.streamIds()).length, 2);
    // ...but it can never continue the chain of another stream.
    final head = await store.head(recorder.streamId);
    expect(
      () => assertContinues(head, foreign),
      throwsA(isA<ChainIntegrityException>()),
    );
    await store.close();
  });

  test('persists the head across restarts and links epochs', () async {
    final path = p.join(dir.path, 'lye.realm');
    final first = RealmLyeStore.open(path: path);
    final r1 = recorderOn(first, epoch: '01924f3a-0000-7000-8000-000000000001');
    await r1.start();
    await recordMany(r1, 4);
    await r1.close();
    await first.close();

    final second = RealmLyeStore.open(path: path);
    final r2 = recorderOn(
      second,
      epoch: '01924f3a-0000-7000-8000-000000000002',
    );
    final start = await r2.start();
    expect(start.attrs, contains('"prev_stream_id":"${r1.streamId}"'));
    expect(start.attrs, contains('"prev_seq":5'));
    expect(start.attrs, contains('"prev_head":"${r1.head!.headHash}"'));
    expect((await second.head(r1.streamId)).seq, 5);
    expect(
      (await second.latestHeadForNode('server', 'app-1'))!.streamId,
      r2.streamId,
    );
    await r2.close();
    await second.close();
  });

  test('a row rewritten inside the file is caught by the verifier', () async {
    final store = RealmLyeStore.open(path: p.join(dir.path, 'lye.realm'));
    final recorder = recorderOn(store);
    final events = await recordMany(recorder, 3);
    final path = store.path;
    await recorder.close();
    await store.close();
    // Someone with write access to the file rewrites the JSON of row 2 while
    // the server is down.
    final realm = Realm(
      Configuration.local(
        <SchemaObject>[LyeEventRow.schema, LyeChainHeadRow.schema],
        path: path,
        schemaVersion: RealmLyeStore.defaultSchemaVersion,
      ),
    );
    realm.write(() {
      final row = realm.find<LyeEventRow>(events[1].eventId)!;
      row.rowJson = row.rowJson.replaceFirst(
        '"component":"t1"',
        '"component":"forged"',
      );
    });
    realm.close();
    final reopened = RealmLyeStore.open(path: path);
    final rows = await reopened.readRange(
      recorder.streamId,
      fromSeq: 1,
      toSeq: 3,
    );
    final report = ChainVerifier.verify(rows);
    expect(report.ok, isFalse);
    expect(
      report.problems.map((ChainProblem x) => x.code),
      contains('hash_mismatch'),
    );
    expect(report.problems.first.seq, 2);
    await reopened.close();
  });

  test('an encrypted file cannot be opened without its key', () async {
    final path = p.join(dir.path, 'enc.realm');
    final key = RealmKeys.fromSecret('a-long-enough-secret-for-tests');
    final store = RealmLyeStore.open(path: path, encryptionKey: key);
    await recordMany(recorderOn(store), 2);
    await store.close();
    expect(
      () => RealmLyeStore.open(path: path),
      throwsA(isA<RealmException>()),
    );
    expect(
      () => RealmLyeStore.open(
        path: path,
        encryptionKey: RealmKeys.fromSecret('another-long-secret-value'),
      ),
      throwsA(isA<RealmException>()),
    );
    final reopened = RealmLyeStore.open(path: path, encryptionKey: key);
    expect(reopened.length, 2);
    await reopened.close();
    expect(
      () => RealmKeys.validate(List<int>.filled(10, 0)),
      throwsArgumentError,
    );
  });

  test('in-memory store works for tests', () async {
    final store = RealmLyeStore.inMemory('unit');
    await recordMany(recorderOn(store), 2);
    expect(store.length, 2);
    await store.close();
  });
}
