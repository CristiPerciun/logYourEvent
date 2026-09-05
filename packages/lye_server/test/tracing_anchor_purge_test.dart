import 'dart:convert';
import 'dart:io';

import 'package:lye_core/lye_core.dart';
import 'package:lye_io/lye_io.dart';
import 'package:lye_server/lye_server.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('SqlTemplate', () {
    test('normalises, classifies and digests without leaking values', () {
      const sql = """
        UPDATE ropa_entries SET status = 'archived', updated_at = clock_timestamp()
        WHERE id = @id::uuid AND version = 42
      """;
      expect(SqlTemplate.kindOf(sql), 'UPDATE');
      expect(SqlTemplate.tableOf(sql), 'ropa_entries');
      final normalized = SqlTemplate.normalize(sql);
      expect(normalized, isNot(contains('archived')));
      expect(normalized, isNot(contains('42')));
      expect(normalized, contains('@id::uuid'));
      expect(
        SqlTemplate.digest(sql),
        SqlTemplate.digest(
          'UPDATE   ropa_entries SET status = \'x\', updated_at = clock_timestamp() WHERE id = @id::uuid AND version = 7',
        ),
      );
      expect(SqlTemplate.kindOf('  select 1'), 'SELECT');
      expect(
        SqlTemplate.tableOf('INSERT INTO audit.events (a) VALUES (1)'),
        'audit.events',
      );
    });
  });

  group('ServerTracing', () {
    test(
      'traces a call, its scoped transaction, statements and audit link in one trace',
      () async {
        final store = MemoryLyeStore();
        final clock = FixedClock(DateTime.utc(2026, 9, 5, 9));
        final server = testRecorder(
          store: store,
          origin: LyeOrigin.server,
          nodeId: 'app-1',
          clock: clock,
        );
        final tracing = ServerTracing(server);
        final args = <String, Object?>{
          'entry': <String, Object?>{'tenantId': tenantA, 'activityName': 'HR'},
        };

        final answer = await tracing.handleCall<String>(
          endpoint: 'ropa',
          method: 'addEntry',
          jsonArgs: CallCorrelation.stripEnvelope(<Object?, Object?>{
            'method': 'addEntry',
            ...args,
          }),
          context: tracing.contextFor(
            scope: 'tenant',
            partnerId: partnerA,
            tenantId: tenantA,
            actorId: actorA,
            actorRole: 'partner_staff',
          ),
          body: () => tracing.scopedTransaction<String>(
            scope: 'tenant',
            partnerId: partnerA,
            tenantId: tenantA,
            body: () async {
              final rows = await tracing.statement<List<int>>(
                'INSERT INTO ropa_entries (tenant_id) VALUES (@tenantId::uuid) RETURNING id',
                run: () async => <int>[1],
                rowCount: (List<int> r) => r.length,
              );
              await tracing.auditAppended(
                orgId: tenantA,
                action: 'ropa.entry.added',
                rowHash: List<int>.filled(32, 0xab),
                seq: 17,
                targetType: 'ropa_entry',
                targetId: 'e-1',
              );
              return 'ok-${rows.length}';
            },
          ),
        );
        expect(answer, 'ok-1');
        await server.flush();
        final events = await store.readRange(
          server.streamId,
          fromSeq: 1,
          toSeq: 100,
        );
        expect(
          events.map((LyeEvent e) => '${e.action}/${e.phase.name}'),
          <String>[
            'rpc.handle/start',
            'db.scope/start',
            'db.statement/point',
            'audit.append/point',
            'db.scope/end',
            'rpc.handle/end',
          ],
        );
        expect(events.map((LyeEvent e) => e.traceId).toSet().length, 1);
        expect(
          events.every(
            (LyeEvent e) => e.actorRef == actorA && e.tenantId == tenantA,
          ),
          isTrue,
        );
        expect(events.first.route, 'ropa.addEntry');
        final digest = CallCorrelation.digest(
          endpoint: 'ropa',
          method: 'addEntry',
          jsonArgs: args,
        );
        expect(events.first.attrs, contains(digest));
        expect(
          events.first.attrs,
          isNot(contains('HR')),
          reason: 'arguments never enter the trace',
        );
        final statement = events[2];
        expect(statement.component, 'ropa_entries');
        expect(statement.attrs, contains('"kind":"INSERT"'));
        expect(statement.attrs, contains('"rows":1'));
        expect(events[3].auditRef, '$tenantA:17:${'ab' * 32}');
        expect(events[4].outcome, LyeOutcome.ok);
      },
    );

    test(
      'a failing statement is recorded with class and digest and the scope ends with fail',
      () async {
        final store = MemoryLyeStore();
        final server = testRecorder(
          store: store,
          origin: LyeOrigin.server,
          nodeId: 'app-1',
        );
        final tracing = ServerTracing(server);
        await expectLater(
          tracing.scopedTransaction<void>(
            scope: 'partner',
            partnerId: partnerA,
            body: () => tracing.statement<void>(
              'SELECT * FROM secret_table',
              run: () async =>
                  throw StateError('permission denied for ion@example.md'),
            ),
          ),
          throwsStateError,
        );
        await server.flush();
        final events = await store.readRange(
          server.streamId,
          fromSeq: 1,
          toSeq: 10,
        );
        expect(events[1].action, LyeActions.dbStatement);
        expect(events[1].outcome, LyeOutcome.fail);
        expect(events[1].errorClass, 'StateError');
        expect(events[1].canonical, isNot(contains('example.md')));
        expect(events[2].action, LyeActions.dbScope);
        expect(events[2].outcome, LyeOutcome.fail);
      },
    );

    test(
      'jobs, documents and break-glass produce the expected codes',
      () async {
        final store = MemoryLyeStore();
        final server = testRecorder(
          store: store,
          origin: LyeOrigin.worker,
          nodeId: 'w-1',
        );
        final tracing = ServerTracing(server);
        await tracing.jobEnqueued(
          queue: 'render_pdf',
          jobId: 'j-1',
          singletonKey: 'doc:1',
        );
        await tracing.runJob<void>(
          queue: 'render_pdf',
          jobId: 'j-1',
          attempt: 1,
          body: () async {},
        );
        await tracing.documentAccessed(
          documentId: 'd-1',
          kind: 'pdfa',
          download: true,
        );
        await tracing.breakGlass(
          partnerId: partnerA,
          expiresAt: DateTime.utc(2026, 9, 5, 10),
          granted: false,
        );
        await server.flush();
        final events = await store.readRange(
          server.streamId,
          fromSeq: 1,
          toSeq: 10,
        );
        expect(events.map((LyeEvent e) => e.action), <String>[
          LyeActions.jobEnqueue,
          'job.run',
          'job.run',
          LyeActions.documentDownload,
          LyeActions.securityBreakGlass,
        ]);
        expect(events.last.outcome, LyeOutcome.denied);
        expect(events.last.retention, LyeRetention.security);
        expect(events[3].retention, LyeRetention.access);
      },
    );
  });

  group('AnchorService and RetentionPurger', () {
    late Directory dir;
    final signer = HmacSha256Signer.fromSecret('anchor-key', keyId: 'a1');

    setUp(() async => dir = await tempDir('anchor'));
    tearDown(() async => dir.delete(recursive: true));

    test(
      'anchors heads, detects later truncation, purges only expired files',
      () async {
        final store = MemoryLyeStore();
        final clock = FixedClock(DateTime.utc(2026, 1, 10, 12));
        final recorder = testRecorder(store: store, clock: clock);
        // Three days of application events, then one security event.
        for (var day = 0; day < 3; day++) {
          await recordMany(recorder, 2);
          clock.advance(const Duration(days: 1));
        }
        await recorder.point(
          LyeCategory.security,
          LyeActions.securityScopeViolation,
          outcome: LyeOutcome.denied,
        );
        final exportRoot = p.join(dir.path, 'export');
        await StreamExporter(
          store: store,
          root: exportRoot,
          signer: signer,
          clock: clock,
        ).exportPending();

        final blobs = LocalDirectoryBlobStore(p.join(dir.path, 'blobs'));
        final anchors = AnchorService(
          blobStore: blobs,
          signer: signer,
          clock: clock,
        );
        final record = await anchors.anchor(exportRoot);
        expect(record.streams.single.lastSeq, 7);
        expect(record.streams.single.ok, isTrue);
        expect(record.verifySignature(signer), isTrue);
        expect((await blobs.list('lye/anchors')).length, 2);
        final latest = AnchorRecord.fromJsonText(
          utf8.decode((await blobs.get('lye/anchors/latest.json'))!),
        );
        expect(latest.anchorHash, record.anchorHash);
        expect(await anchors.checkAgainstLatest(exportRoot), isEmpty);

        // Purge: 200 days later only the first days (application only) expire;
        // the last file holds a security row and must survive.
        final purgeClock = FixedClock(
          DateTime.utc(2026, 1, 13).add(const Duration(days: 200)),
        );
        final purger = RetentionPurger(
          root: exportRoot,
          clock: purgeClock,
          recorder: recorder,
        );
        final plan = await purger.plan();
        expect(plan.where((PurgeDecision d) => d.expired).length, 3);
        expect(plan.where((PurgeDecision d) => !d.expired).length, 1);
        await purger.purge();
        final after = await DirectoryVerifier(
          signer: signer,
        ).verify(exportRoot);
        expect(after.ok, isTrue, reason: after.render());
        expect(after.streams.single.files.length, 1);
        expect(
          after.streams.single.warnings.map((ChainProblem w) => w.code),
          contains('partial_stream'),
        );
        // The anchor still matches the surviving tail.
        expect(await anchors.checkAgainstLatest(exportRoot), isEmpty);

        // Now truncate the tail: the anchor exposes it.
        final files = await CsvFileSink.listCsvFiles(
          Directory(ExportLayout.streamPath(exportRoot, recorder.streamId)),
        );
        await files.last.delete();
        final problems = await anchors.checkAgainstLatest(exportRoot);
        expect(
          problems.map((ChainProblem x) => x.code),
          contains('anchored_stream_missing'),
        );
      },
    );
  });
}
