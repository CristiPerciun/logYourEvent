import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:lye_archive/lye_archive.dart';
import 'package:lye_core/lye_core.dart';
import 'package:test/test.dart';

const String subjectRef = '3f2a91c4-1111-7000-8000-000000000001';
const String orgId = '22222222-2222-2222-2222-222222222222';
const String partnerId = '11111111-1111-1111-1111-111111111111';

final DateTime cutAt = DateTime.utc(2026, 9, 20, 0, 10);

/// A recorder whose events all belong to one subject and one class.
LyeRecorder recorderFor({
  required LyeStore store,
  String nodeId = 'app-1',
  int seed = 7,
}) {
  final recorder = LyeRecorder(
    config: LyeConfig(
      origin: LyeOrigin.server,
      platform: LyePlatform.vm,
      appId: 'cos_server',
      appVersion: '1.0.0+1',
      nodeId: nodeId,
    ),
    store: store,
    clock: FixedClock(DateTime.utc(2026, 9, 19, 9)),
    random: Random(seed),
    level: LyeLevel.forensic,
  );
  recorder.context.update(
    scope: LyeScope.tenant,
    partnerId: partnerId,
    tenantId: orgId,
    actorRef: subjectRef,
    actorRole: 'partner_staff',
  );
  return recorder;
}

/// [count] events of the `access` class (rpc), in chain order.
Future<List<ArchiveRow>> rowsOf(
  LyeRecorder recorder,
  int count, {
  int from = 1,
}) async {
  final rows = <ArchiveRow>[];
  for (var i = 0; i < count; i++) {
    final event = await recorder.point(
      LyeCategory.rpc,
      LyeActions.rpcHandle,
      outcome: LyeOutcome.ok,
      route: 'license.listFleetLicenses',
      attrs: <String, Object?>{'index': i, 'ms': 12},
    );
    rows.add(ArchiveRow(chainSeq: from + i, event: event!));
  }
  return rows;
}

ArchiveCut cutFor({
  int archiveSeq = 1,
  int part = 1,
  String prevArchiveHash = HashChain.genesisHex,
  String prevChainHash = SubjectChain.genesisHex,
}) {
  return ArchiveCut(
    subjectType: LyeSubjectType.user,
    subjectRef: subjectRef,
    retention: LyeRetention.access,
    homeOrgId: orgId,
    partnerId: partnerId,
    day: '2026-09-19',
    cutAt: cutAt,
    archiveSeq: archiveSeq,
    part: part,
    prevArchiveHash: prevArchiveHash,
    prevChainHash: prevChainHash,
    expiresAt: DateTime.utc(2027, 9, 20),
  );
}

void main() {
  late LyeRecorder recorder;

  setUp(() {
    recorder = recorderFor(store: MemoryLyeStore());
  });

  test('a day without activity produces no archive at all', () {
    final built = ArchiveBuilder().build(
      rows: const <ArchiveRow>[],
      cut: cutFor(),
    );
    expect(built, isEmpty);
  });

  test('one archive carries the subject, the class and the range', () async {
    final rows = await rowsOf(recorder, 20);
    final built = ArchiveBuilder().build(rows: rows, cut: cutFor());
    expect(built.length, 1);
    final archive = built.single;
    final m = archive.manifest;
    expect(m.subjectType, LyeSubjectType.user);
    expect(m.subjectRef, subjectRef);
    expect(m.retention, LyeRetention.access);
    expect(m.fromSeq, 1);
    expect(m.toSeq, 20);
    expect(m.eventCount, 20);
    expect(m.archiveSeq, 1);
    expect(m.part, 1);
    expect(m.prevChainHash, SubjectChain.genesisHex);
    expect(m.chainHash, SubjectChain.foldEvents(rows.map((r) => r.event)));
    expect(m.organizations, <String>[partnerId, orgId]..sort());
    expect(m.levels['standard'], 20);
    expect(m.streams.single.streamId, recorder.streamId);
    expect(archive.fileName, 'jurnal_access_u3f2a91c4_20260919_01.zip');
    expect(archive.compressedSize, lessThan(archive.uncompressedSize));
  });

  test('the package verifies on its own, without a database', () async {
    final rows = await rowsOf(recorder, 30);
    final archive = ArchiveBuilder().build(rows: rows, cut: cutFor()).single;
    final report = ArchiveVerifier().verify(
      archive.bytes,
      expectedFromSeq: 1,
      expectedPrevArchiveHash: HashChain.genesisHex,
      expectedZipSha256: archive.zipSha256,
    );
    expect(report.ok, isTrue, reason: report.render());
    expect(report.eventCount, 30);
  });

  test('the manifest is signed and the signature is checked', () async {
    final signer = HmacSha256Signer.fromSecret('shhh', keyId: 'k1');
    final rows = await rowsOf(recorder, 5);
    final archive = ArchiveBuilder(
      signer: signer,
    ).build(rows: rows, cut: cutFor()).single;
    expect(archive.manifest.signature, isNotNull);
    expect(
      ArchiveVerifier(signer: signer).verify(archive.bytes).ok,
      isTrue,
    );
    final other = HmacSha256Signer.fromSecret('wrong', keyId: 'k1');
    final report = ArchiveVerifier(signer: other).verify(archive.bytes);
    expect(
      report.problems.map((ChainProblem p) => p.code),
      contains('signature_invalid'),
    );
  });

  test('rotation: a cap smaller than the content opens further parts', () async {
    final rows = await rowsOf(recorder, 400);
    final built = ArchiveBuilder(
      maxBytes: ArchiveBuilder.minMaxBytes,
    ).build(rows: rows, cut: cutFor());

    expect(built.length, greaterThan(1), reason: 'the cap must have bitten');
    for (final archive in built) {
      expect(
        archive.compressedSize,
        lessThanOrEqualTo(ArchiveBuilder.minMaxBytes),
        reason: '${archive.fileName} passed the cap',
      );
    }

    // No loss, no duplication: the ranges touch and cover everything once.
    expect(built.first.manifest.fromSeq, 1);
    expect(built.last.manifest.toSeq, 400);
    for (var i = 1; i < built.length; i++) {
      expect(
        built[i].manifest.fromSeq,
        built[i - 1].manifest.toSeq + 1,
        reason: 'part ${i + 1} does not continue part $i',
      );
      expect(built[i].manifest.part, built[i - 1].manifest.part + 1);
      expect(built[i].manifest.archiveSeq, built[i - 1].manifest.archiveSeq + 1);
      expect(
        built[i].manifest.prevArchiveHash,
        built[i - 1].manifest.archiveHash,
        reason: 'part ${i + 1} does not link to part $i',
      );
      expect(
        built[i].manifest.prevChainHash,
        built[i - 1].manifest.chainHash,
        reason: 'the subject chain breaks between the parts',
      );
    }
    final total = built.fold<int>(
      0,
      (int sum, BuiltArchive a) => sum + a.manifest.eventCount,
    );
    expect(total, 400);

    // And the whole sequence ends where a single package would have.
    expect(
      built.last.manifest.chainHash,
      SubjectChain.foldEvents(rows.map((ArchiveRow r) => r.event)),
    );
  });

  test('every part verifies against the one before it', () async {
    final rows = await rowsOf(recorder, 300);
    final built = ArchiveBuilder(
      maxBytes: ArchiveBuilder.minMaxBytes,
    ).build(rows: rows, cut: cutFor());
    final verifier = ArchiveVerifier();
    var expectedFrom = 1;
    var expectedPrev = HashChain.genesisHex;
    for (final archive in built) {
      final report = verifier.verify(
        archive.bytes,
        expectedFromSeq: expectedFrom,
        expectedPrevArchiveHash: expectedPrev,
      );
      expect(report.ok, isTrue, reason: report.render());
      expectedFrom = archive.manifest.toSeq + 1;
      expectedPrev = archive.manifest.archiveHash;
    }
  });

  test('the build is reproducible byte for byte', () async {
    final rows = await rowsOf(recorder, 40);
    const fixedId = 'aaaaaaaa-0000-7000-8000-000000000000';
    Uint8List once() => ArchiveBuilder(
      newArchiveId: () => fixedId,
    ).build(rows: rows, cut: cutFor()).single.bytes;
    expect(once(), equals(once()));
  });

  test('a rewritten row is caught by its own hash', () async {
    final rows = await rowsOf(recorder, 12);
    final archive = ArchiveBuilder().build(rows: rows, cut: cutFor()).single;
    final tampered = _rewriteFirstDataRow(
      archive.bytes,
      (List<String> fields) {
        fields[LyeCsvSchema.indexOf('route')] = 'license.deleteEverything';
        return fields;
      },
    );
    final report = ArchiveVerifier().verify(tampered);
    expect(report.ok, isFalse);
    expect(
      report.problems.map((ChainProblem p) => p.code),
      containsAll(<String>['member_digest_mismatch', 'row_hash_mismatch']),
    );
  });

  test('a removed row breaks the subject chain', () async {
    final rows = await rowsOf(recorder, 12);
    final archive = ArchiveBuilder().build(rows: rows, cut: cutFor()).single;
    final shortened = _dropSecondDataRow(archive.bytes);
    final report = ArchiveVerifier().verify(shortened);
    expect(report.ok, isFalse);
    expect(
      report.problems.map((ChainProblem p) => p.code),
      containsAll(<String>['count_mismatch', 'chain_hash_mismatch']),
    );
  });

  test('an archive of another subject or class is refused at build', () async {
    final rows = await rowsOf(recorder, 3);
    expect(
      () => ArchiveBuilder().build(
        rows: rows,
        cut: ArchiveCut(
          subjectType: LyeSubjectType.user,
          subjectRef: 'someone-else',
          retention: LyeRetention.access,
          day: '2026-09-19',
          cutAt: cutAt,
        ),
      ),
      throwsA(isA<ArchiveBuildException>()),
    );
    expect(
      () => ArchiveBuilder().build(
        rows: <ArchiveRow>[rows.first, rows[2]],
        cut: cutFor(),
      ),
      throwsA(isA<ArchiveBuildException>()),
    );
  });

  test('late events are declared in the manifest', () async {
    final rows = await rowsOf(recorder, 4);
    final built = ArchiveBuilder().build(
      rows: rows,
      cut: ArchiveCut(
        subjectType: LyeSubjectType.user,
        subjectRef: subjectRef,
        retention: LyeRetention.access,
        day: '2026-09-19',
        cutAt: cutAt,
        previousCutAt: DateTime.utc(2026, 9, 19, 12),
      ),
    );
    expect(built.single.manifest.lateEventCount, 4);
    expect(built.single.manifest.lateOldestOccurredAt, isNotNull);
  });

  test('the README explains how to verify, in both languages', () async {
    final rows = await rowsOf(recorder, 2);
    final archive = ArchiveBuilder().build(rows: rows, cut: cutFor()).single;
    final opened = ArchiveVerifier.open(archive.bytes);
    expect(opened.readme, contains('lye verify-archive'));
    expect(opened.readme, contains('RO'));
    expect(opened.readme, contains('RU'));
  });
}

/// Rewrites the first data row of the single CSV member, keeping the ZIP
/// readable: what a forger with write access to the file would do.
Uint8List _rewriteFirstDataRow(
  Uint8List zipBytes,
  List<String> Function(List<String>) edit,
) {
  return _rewriteCsv(zipBytes, (List<LyeEvent> events) {
    final fields = edit(events.first.toCsvFields());
    return <LyeEvent>[LyeEvent.fromCsvFields(fields), ...events.skip(1)];
  });
}

Uint8List _dropSecondDataRow(Uint8List zipBytes) {
  return _rewriteCsv(
    zipBytes,
    (List<LyeEvent> events) => <LyeEvent>[events.first, ...events.skip(2)],
  );
}

Uint8List _rewriteCsv(
  Uint8List zipBytes,
  List<LyeEvent> Function(List<LyeEvent>) edit,
) {
  final source = ZipDecoder().decodeBytes(zipBytes);
  final rebuilt = Archive();
  for (final file in source.files) {
    if (!file.isFile) continue;
    final data = Uint8List.fromList(file.readBytes() ?? <int>[]);
    if (file.name.endsWith('.csv')) {
      final events = edit(LyeCsv.decode(utf8.decode(data)));
      rebuilt.add(ArchiveFile.string(file.name, LyeCsv.encode(events)));
    } else {
      rebuilt.add(ArchiveFile.bytes(file.name, data));
    }
  }
  return ZipEncoder().encodeBytes(rebuilt);
}
