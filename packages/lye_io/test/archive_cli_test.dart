import 'dart:io';

import 'package:lye_archive/lye_archive.dart';
import 'package:lye_core/lye_core.dart';
import 'package:lye_io/lye_io.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('lye-archive-cli-');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  Future<File> writeArchive({bool tamper = false}) async {
    final recorder = testRecorder(
      store: MemoryLyeStore(),
      origin: LyeOrigin.server,
      nodeId: 'app-1',
    );
    recorder.context.update(
      scope: LyeScope.tenant,
      partnerId: '11111111-1111-1111-1111-111111111111',
      tenantId: '22222222-2222-2222-2222-222222222222',
      actorRef: '3f2a91c4-1111-7000-8000-000000000001',
    );
    final rows = <ArchiveRow>[];
    for (var i = 0; i < 8; i++) {
      final event = await recorder.point(
        LyeCategory.rpc,
        LyeActions.rpcHandle,
        outcome: LyeOutcome.ok,
        route: 'ropa.save',
        attrs: <String, Object?>{'i': i},
      );
      rows.add(ArchiveRow(chainSeq: i + 1, event: event!));
    }
    final built = ArchiveBuilder().build(
      rows: rows,
      cut: ArchiveCut(
        subjectType: LyeSubjectType.user,
        subjectRef: '3f2a91c4-1111-7000-8000-000000000001',
        retention: LyeRetention.access,
        day: '2026-09-19',
        cutAt: DateTime.utc(2026, 9, 20, 0, 10),
      ),
    ).single;
    final file = File('${dir.path}/${built.fileName}');
    final bytes = List<int>.of(built.bytes);
    if (tamper) {
      // Flip one byte in the middle of the compressed stream.
      final at = bytes.length ~/ 2;
      bytes[at] = bytes[at] ^ 0xFF;
    }
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  test('verify-archive accepts a sound package', () async {
    final file = await writeArchive();
    final out = StringBuffer();
    final err = StringBuffer();
    final code = await runLye(
      <String>['verify-archive', file.path, '--from-seq', '1'],
      out: out,
      err: err,
    );
    expect(code, 0, reason: '$out$err');
    expect(out.toString(), contains('result: OK'));
    expect(out.toString(), contains('#1..#8'));
  });

  test('verify-archive refuses a damaged package', () async {
    final file = await writeArchive(tamper: true);
    final out = StringBuffer();
    final code = await runLye(
      <String>['verify-archive', file.path],
      out: out,
      err: StringBuffer(),
    );
    expect(code, 1);
  });

  test('timeline reads an archive without a directory', () async {
    final file = await writeArchive();
    final opened = ArchiveVerifier.open(await file.readAsBytes());
    final trace = opened.events.first.traceId;
    final out = StringBuffer();
    final code = await runLye(
      <String>['timeline', '--archive', file.path, '--trace', trace],
      out: out,
      err: StringBuffer(),
    );
    expect(code, 0);
    expect(out.toString(), contains('rpc.handle'));
  });

  test('verify-archive reports a usage error without a file', () async {
    final code = await runLye(
      <String>['verify-archive'],
      out: StringBuffer(),
      err: StringBuffer(),
    );
    expect(code, 2);
  });
}
