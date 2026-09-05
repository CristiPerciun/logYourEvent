import 'dart:io';

import 'package:lye_core/lye_core.dart';
import 'package:lye_io/lye_io.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late Directory dir;
  final signer = HmacSha256Signer.fromSecret('s3cret', keyId: 'test');

  setUp(() async => dir = await tempDir('export'));
  tearDown(() async => dir.delete(recursive: true));

  group('StreamExporter', () {
    test('exports pending events of every stream and marks them', () async {
      final store = MemoryLyeStore();
      final a = testRecorder(store: store);
      final b = testRecorder(
        store: store,
        origin: LyeOrigin.server,
        nodeId: 'srv-1',
      );
      await recordMany(a, 5);
      await recordMany(b, 3);

      final exporter = StreamExporter(
        store: store,
        root: dir.path,
        signer: signer,
      );
      final run = await exporter.exportPending();
      expect(run.eventsWritten, 8);
      expect(run.manifests.length, 2);
      expect(await store.readPending(a.streamId), isEmpty);
      expect(await store.readPending(b.streamId), isEmpty);

      // A second run appends only the new events, in a new part.
      await recordMany(a, 2);
      final second = await exporter.exportPending();
      expect(second.eventsWritten, 2);
      expect(second.manifests.single.file, 'lye-20260905-0002.csv');

      final report = await DirectoryVerifier(signer: signer).verify(dir.path);
      expect(report.ok, isTrue, reason: report.render());
      expect(report.streams.length, 2);
      expect(report.eventCount, 10);
    });

    test('skips events already on disk after an interrupted run', () async {
      final store = MemoryLyeStore();
      final a = testRecorder(store: store);
      final events = await recordMany(a, 4);
      // First two events reached the disk but were never marked.
      final sink = CsvFileSink(root: dir.path, streamId: a.streamId);
      await sink.open();
      await sink.write(events[0]);
      await sink.write(events[1]);
      await sink.close();

      final run = await StreamExporter(
        store: store,
        root: dir.path,
      ).exportPending();
      expect(run.eventsSkipped, 2);
      expect(run.eventsWritten, 2);
      expect((await DirectoryVerifier().verify(dir.path)).ok, isTrue);
    });
  });

  group('DirectoryVerifier', () {
    late String streamId;
    late List<LyeEvent> events;

    Future<void> export(int count) async {
      final store = MemoryLyeStore();
      final clock = FixedClock(DateTime.utc(2026, 9, 5, 12));
      final recorder = testRecorder(store: store, clock: clock);
      streamId = recorder.streamId;
      await recorder.start();
      events = await recordMany(recorder, count, clock: clock);
      await StreamExporter(
        store: store,
        root: dir.path,
        signer: signer,
        maxBytesPerFile: 1500,
        clock: clock,
      ).exportPending();
    }

    test('detects a rewritten row', () async {
      await export(6);
      final files = await CsvFileSink.listCsvFiles(
        Directory(ExportLayout.streamPath(dir.path, streamId)),
      );
      final target = files.first;
      final text = await target.readAsString();
      final forged = text.replaceFirst('button-1', 'button-X');
      expect(forged, isNot(text));
      await target.writeAsString(forged, flush: true);

      final report = await DirectoryVerifier(signer: signer).verify(dir.path);
      expect(report.ok, isFalse);
      final codes = report.streams.single.allProblems
          .map((ChainProblem x) => x.code)
          .toSet();
      expect(
        codes,
        containsAll(<String>['file_digest_mismatch', 'hash_mismatch']),
      );
      expect(report.render(), contains('BROKEN'));
    });

    test('detects a removed file in the middle of a stream', () async {
      await export(8);
      final streamDir = Directory(ExportLayout.streamPath(dir.path, streamId));
      final files = await CsvFileSink.listCsvFiles(streamDir);
      expect(files.length, greaterThan(2), reason: 'need at least three parts');
      final victim = files[1];
      await victim.delete();
      await File(
        p.join(
          streamDir.path,
          ExportLayout.manifestNameFor(p.basename(victim.path)),
        ),
      ).delete();

      final report = await DirectoryVerifier(signer: signer).verify(dir.path);
      expect(report.ok, isFalse);
      final codes = report.streams.single.allProblems
          .map((ChainProblem x) => x.code)
          .toSet();
      expect(
        codes,
        containsAll(<String>[
          'manifest_link_mismatch',
          'file_seq_gap',
          'file_link_mismatch',
        ]),
      );
    });

    test(
      'detects a manifest signed with another key and a missing manifest',
      () async {
        await export(3);
        final wrongKey = HmacSha256Signer.fromSecret('other', keyId: 'test');
        final report = await DirectoryVerifier(
          signer: wrongKey,
        ).verify(dir.path);
        expect(
          report.streams.single.allProblems.map((ChainProblem x) => x.code),
          contains('signature_invalid'),
        );

        final streamDir = Directory(
          ExportLayout.streamPath(dir.path, streamId),
        );
        final files = await CsvFileSink.listCsvFiles(streamDir);
        await File(
          p.join(
            streamDir.path,
            ExportLayout.manifestNameFor(p.basename(files.first.path)),
          ),
        ).delete();
        final noManifest = await DirectoryVerifier().verify(dir.path);
        expect(
          noManifest.streams.single.allProblems.map((ChainProblem x) => x.code),
          contains('manifest_missing'),
        );
      },
    );

    test(
      'reports a truncated tail as a partial view, and checks epoch links',
      () async {
        await export(4);
        final ok = await DirectoryVerifier(signer: signer).verify(dir.path);
        expect(ok.ok, isTrue);
        expect(ok.streams.single.headHash, events.last.rowHash);

        // A second epoch of the same node that claims a different previous head.
        final store = MemoryLyeStore();
        final clock = FixedClock(DateTime.utc(2026, 9, 6, 12));
        final next = testRecorder(
          store: store,
          clock: clock,
          epoch: '01924f3a-ffff-7000-8000-000000000002',
        );
        await next.record(
          LyeDraft(
            category: LyeCategory.lifecycle,
            action: LyeActions.streamStart,
            outcome: LyeOutcome.ok,
            attrs: <String, Object?>{
              'prev_stream_id': streamId,
              'prev_seq': events.last.seq,
              'prev_head': 'ab' * 32,
            },
          ),
        );
        await StreamExporter(
          store: store,
          root: dir.path,
          signer: signer,
          clock: clock,
        ).exportPending();
        final linked = await DirectoryVerifier(signer: signer).verify(dir.path);
        expect(
          linked.problems.map((ChainProblem x) => x.code),
          contains('epoch_link_mismatch'),
        );
      },
    );
  });
}
