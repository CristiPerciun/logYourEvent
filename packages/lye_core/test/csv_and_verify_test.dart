import 'package:lye_core/lye_core.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late LyeRecorder recorder;
  late List<LyeEvent> events;

  setUp(() async {
    recorder = testRecorder();
    recorder.context.update(
      scope: LyeScope.tenant,
      partnerId: '11111111-1111-1111-1111-111111111111',
      tenantId: '22222222-2222-2222-2222-222222222222',
      actorRef: '55555555-5555-5555-5555-555555555555',
    );
    events = await recordMany(recorder, 6);
  });

  group('LyeCsv', () {
    test('writes the schema header and one row per event', () {
      final text = LyeCsv.encode(events);
      final lines = text.split('\r\n')..removeLast();
      expect(lines.length, 7);
      expect(lines.first, LyeCsvSchema.columns.join(','));
      expect(LyeCsvSchema.columns.length, 37);
      expect(LyeCsvSchema.hashedColumnCount, 34);
    });

    test('round-trips every column and keeps hashes valid', () {
      final decoded = LyeCsv.decode(LyeCsv.encode(events));
      expect(decoded.length, events.length);
      for (var i = 0; i < events.length; i++) {
        expect(decoded[i].toCsvFields(), events[i].toCsvFields());
        expect(decoded[i].hasValidRowHash, isTrue);
      }
      expect(ChainVerifier.verify(decoded).ok, isTrue);
    });

    test('round-trips through JSON as well', () {
      for (final event in events) {
        expect(
          LyeEvent.fromJson(event.toJson()).toCsvFields(),
          event.toCsvFields(),
        );
      }
    });

    test('rejects a foreign header', () {
      expect(() => LyeCsv.decode('a,b,c\r\n1,2,3\r\n'), throwsFormatException);
      final wrongName = LyeCsv.header.replaceFirst('event_id', 'id');
      expect(() => LyeCsv.decode(wrongName), throwsFormatException);
    });
  });

  group('ChainVerifier', () {
    test('accepts an intact chain', () {
      final report = ChainVerifier.verify(events);
      expect(report.ok, isTrue);
      expect(report.eventsChecked, 6);
      expect(report.headHash, events.last.rowHash);
    });

    test('detects a rewritten column', () {
      final tampered = List<LyeEvent>.of(events);
      tampered[2] = tamperColumn(
        events[2],
        'actor_ref',
        '99999999-9999-9999-9999-999999999999',
      );
      final report = ChainVerifier.verify(tampered);
      expect(report.ok, isFalse);
      expect(
        report.problems.map((ChainProblem p) => p.code),
        contains('hash_mismatch'),
      );
      expect(report.problems.first.seq, 3);
    });

    test('detects a deleted row', () {
      final tampered = List<LyeEvent>.of(events)..removeAt(3);
      final codes = ChainVerifier.verify(
        tampered,
      ).problems.map((ChainProblem p) => p.code).toList();
      expect(codes, containsAll(<String>['seq_gap', 'link_mismatch']));
    });

    test('detects reordering', () {
      final tampered = List<LyeEvent>.of(events);
      final tmp = tampered[1];
      tampered[1] = tampered[2];
      tampered[2] = tmp;
      expect(ChainVerifier.verify(tampered).ok, isFalse);
    });

    test('detects a truncated tail through the expected head', () {
      final truncated = events.sublist(0, 4);
      final report = ChainVerifier.verify(truncated);
      expect(report.ok, isTrue, reason: 'a prefix is internally consistent...');
      expect(
        report.headHash,
        isNot(events.last.rowHash),
        reason: '...which is why heads are anchored outside the file',
      );
    });

    test('verifies a continuation against a known head', () {
      final tail = events.sublist(3);
      final ok = ChainVerifier.verifyContinuation(
        tail,
        streamId: recorder.streamId,
        headSeq: 3,
        headHash: events[2].rowHash,
      );
      expect(ok.ok, isTrue);
      final wrong = ChainVerifier.verifyContinuation(
        tail,
        streamId: recorder.streamId,
        headSeq: 2,
        headHash: events[1].rowHash,
      );
      expect(wrong.ok, isFalse);
    });

    test('flags rows of another stream', () async {
      final other = testRecorder(nodeId: 'node-b');
      final foreign = await recordMany(other, 1);
      final report = ChainVerifier.verify(<LyeEvent>[...events, ...foreign]);
      expect(
        report.problems.map((ChainProblem p) => p.code),
        contains('stream_mismatch'),
      );
    });
  });
}
