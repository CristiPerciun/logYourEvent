import 'dart:io';

import 'package:lye_core/lye_core.dart';
import 'package:lye_io/lye_io.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late Directory dir;

  setUp(() async => dir = await tempDir('cli'));
  tearDown(() async => dir.delete(recursive: true));

  test(
    'demo produces a verifiable export whose timeline joins client and server',
    () async {
      final out = StringBuffer();
      expect(await runLye(<String>['demo', dir.path], out: out, err: out), 0);
      final digest = RegExp(
        r'call digest ([0-9a-f]{64})',
      ).firstMatch(out.toString())!.group(1)!;

      final verifyOut = StringBuffer();
      expect(
        await runLye(
          <String>[
            'verify',
            dir.path,
            '--key',
            'demo-secret',
            '--key-id',
            'demo',
          ],
          out: verifyOut,
          err: verifyOut,
        ),
        0,
        reason: verifyOut.toString(),
      );
      expect(verifyOut.toString(), contains('result: OK'));
      expect(verifyOut.toString(), contains('client/demo-browser/'));
      expect(verifyOut.toString(), contains('server/demo-app-1/'));

      final timeline = await Timeline.load(dir.path);
      final operation = timeline.operation(digest);
      final origins = operation.map((LyeEvent e) => e.origin).toSet();
      expect(
        origins,
        containsAll(<LyeOrigin>[LyeOrigin.client, LyeOrigin.server]),
      );
      final actions = operation.map((LyeEvent e) => e.action).toList();
      expect(
        actions,
        containsAll(<String>[
          LyeActions.uiIntent,
          LyeActions.rpcCall,
          LyeActions.rpcHandle,
          LyeActions.dbScope,
          LyeActions.dbStatement,
          LyeActions.auditAppend,
        ]),
      );
      expect(
        operation.map((LyeEvent e) => e.traceId).toSet().length,
        2,
        reason:
            'one client trace and one server trace, joined by the call digest',
      );
      for (var i = 1; i < operation.length; i++) {
        expect(
          operation[i].occurredAt.isBefore(operation[i - 1].occurredAt),
          isFalse,
        );
      }

      final timelineOut = StringBuffer();
      expect(
        await runLye(<String>[
          'timeline',
          dir.path,
          '--call',
          digest,
        ], out: timelineOut),
        0,
      );
      expect(timelineOut.toString(), contains('rpc.handle'));
      expect(timelineOut.toString(), contains('audit='));

      final byTrace = StringBuffer();
      expect(
        await runLye(<String>[
          'timeline',
          dir.path,
          '--trace',
          operation.first.traceId,
        ], out: byTrace),
        0,
      );
      expect(byTrace.toString(), contains('rpc.call'));
    },
  );

  test('demo --tamper is caught by verify with exit code 1', () async {
    final out = StringBuffer();
    expect(
      await runLye(<String>['demo', dir.path, '--tamper'], out: out, err: out),
      0,
    );
    expect(out.toString(), contains('tampered'));
    final verifyOut = StringBuffer();
    expect(
      await runLye(
        <String>['verify', dir.path],
        out: verifyOut,
        err: verifyOut,
      ),
      1,
    );
    expect(verifyOut.toString(), contains('hash_mismatch'));
    expect(verifyOut.toString(), contains('file_digest_mismatch'));
  });

  test('inspect summarises a file and usage errors return 2', () async {
    await runLye(<String>['demo', dir.path], out: StringBuffer());
    final csv = await Directory(dir.path)
        .list(recursive: true)
        .where(
          (FileSystemEntity e) => e is File && p.extension(e.path) == '.csv',
        )
        .first;
    final out = StringBuffer();
    expect(await runLye(<String>['inspect', csv.path], out: out), 0);
    expect(out.toString(), contains('chain:    OK'));
    expect(out.toString(), contains('actions:'));

    final err = StringBuffer();
    expect(await runLye(<String>[], err: err), 2);
    expect(await runLye(<String>['nope'], err: err), 2);
    expect(await runLye(<String>['verify'], err: err), 2);
    expect(await runLye(<String>['timeline', dir.path], err: err), 2);
    expect(err.toString(), contains('Commands:'));
  });

  test('timeline by actor filters on the window', () async {
    final store = MemoryLyeStore();
    final clock = FixedClock(DateTime.utc(2026, 9, 5, 10));
    final recorder = testRecorder(store: store, clock: clock);
    recorder.context.update(actorRef: 'u-1');
    await recordMany(recorder, 3, clock: clock);
    recorder.context.update(actorRef: 'u-2');
    await recordMany(recorder, 2, clock: clock);
    await StreamExporter(
      store: store,
      root: dir.path,
      clock: clock,
    ).exportPending();

    final timeline = await Timeline.load(dir.path);
    expect(timeline.byActor('u-1').length, 3);
    expect(timeline.byActor('u-2').length, 2);
    expect(
      timeline.byActor('u-1', from: DateTime.utc(2026, 9, 5, 10, 0, 1)).length,
      2,
    );
    expect(timeline.byTrace('missing'), isEmpty);
    expect(timeline.tracesForCall('nothing'), isEmpty);
  });
}
