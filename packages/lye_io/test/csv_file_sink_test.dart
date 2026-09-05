import 'dart:io';

import 'package:lye_core/lye_core.dart';
import 'package:lye_io/lye_io.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late Directory dir;
  final signer = HmacSha256Signer.fromSecret('s3cret', keyId: 'test');

  setUp(() async => dir = await tempDir('sink'));
  tearDown(() async => dir.delete(recursive: true));

  test('writes rotated files with chained, signed manifests', () async {
    final store = MemoryLyeStore();
    final clock = FixedClock(DateTime.utc(2026, 9, 5, 23, 59, 55));
    final recorder = testRecorder(store: store, clock: clock);
    // 10 events across midnight: the day boundary forces a rotation.
    final events = await recordMany(recorder, 10, clock: clock);

    final sink = CsvFileSink(
      root: dir.path,
      streamId: recorder.streamId,
      signer: signer,
      clock: clock,
    );
    await sink.open();
    for (final event in events) {
      await sink.write(event);
    }
    await sink.close();

    expect(sink.written.length, 2);
    expect(sink.written[0].file, 'lye-20260905-0001.csv');
    expect(sink.written[1].file, 'lye-20260906-0001.csv');
    expect(sink.written[1].prevManifestHash, sink.written[0].manifestHash);
    expect(sink.written[0].prevManifestHash, HashChain.genesisHex);
    expect(sink.written[1].prevHash, sink.written[0].headHash);
    expect(
      sink.written.every((LyeManifest m) => m.verifySignature(signer)),
      isTrue,
    );

    final report = await DirectoryVerifier(signer: signer).verify(dir.path);
    expect(report.ok, isTrue, reason: report.render());
    expect(report.eventCount, 10);
    expect(report.streams.single.headHash, events.last.rowHash);
  });

  test('rotates by size', () async {
    final store = MemoryLyeStore();
    final recorder = testRecorder(store: store);
    final events = await recordMany(recorder, 20);
    final sink = CsvFileSink(
      root: dir.path,
      streamId: recorder.streamId,
      maxBytesPerFile: 2000,
    );
    await sink.open();
    for (final event in events) {
      await sink.write(event);
    }
    await sink.close();
    expect(sink.written.length, greaterThan(2));
    expect((await DirectoryVerifier().verify(dir.path)).ok, isTrue);
  });

  test('refuses events that do not continue the chain on disk', () async {
    final store = MemoryLyeStore();
    final recorder = testRecorder(store: store);
    final events = await recordMany(recorder, 5);
    final sink = CsvFileSink(root: dir.path, streamId: recorder.streamId);
    await sink.open();
    await sink.write(events[0]);
    expect(
      () => sink.write(events[2]),
      throwsA(isA<ChainIntegrityException>()),
    );
    await sink.write(events[1]);
    await sink.close();
    expect(sink.expectedSeq, 3);
  });

  test(
    'resumes after a clean close and recovers a file left without manifest',
    () async {
      final store = MemoryLyeStore();
      final recorder = testRecorder(store: store);
      final events = await recordMany(recorder, 9);

      final first = CsvFileSink(
        root: dir.path,
        streamId: recorder.streamId,
        signer: signer,
      );
      await first.open();
      for (final event in events.take(3)) {
        await first.write(event);
      }
      await first.close();

      // Simulate a crash: a second file written without its manifest.
      final streamDir = ExportLayout.streamPath(dir.path, recorder.streamId);
      await File(
        p.join(streamDir, 'lye-20260905-0002.csv'),
      ).writeAsString(LyeCsv.encode(events.sublist(3, 6)), flush: true);

      final resumed = CsvFileSink(
        root: dir.path,
        streamId: recorder.streamId,
        signer: signer,
      );
      await resumed.open();
      expect(resumed.expectedSeq, 7);
      expect(
        await File(
          p.join(streamDir, 'lye-20260905-0002.manifest.json'),
        ).exists(),
        isTrue,
        reason: 'the orphan file was verified and sealed',
      );
      for (final event in events.sublist(6)) {
        await resumed.write(event);
      }
      await resumed.close();
      expect(resumed.written.single.file, 'lye-20260905-0003.csv');

      final report = await DirectoryVerifier(signer: signer).verify(dir.path);
      expect(report.ok, isTrue, reason: report.render());
      expect(report.streams.single.files.length, 3);
    },
  );

  test('does not bless an orphan file that breaks the chain', () async {
    final store = MemoryLyeStore();
    final recorder = testRecorder(store: store);
    final events = await recordMany(recorder, 4);
    final streamDir = ExportLayout.streamPath(dir.path, recorder.streamId);
    await Directory(streamDir).create(recursive: true);
    // Orphan file starting at seq 3: seq 1..2 were never written.
    await File(
      p.join(streamDir, 'lye-20260905-0001.csv'),
    ).writeAsString(LyeCsv.encode(events.sublist(2)), flush: true);
    final sink = CsvFileSink(root: dir.path, streamId: recorder.streamId);
    await expectLater(sink.open(), throwsA(isA<ExportIntegrityException>()));
  });
}
