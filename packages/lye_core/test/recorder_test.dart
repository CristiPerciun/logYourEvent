import 'dart:async';

import 'package:lye_core/lye_core.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('LyeRecorder', () {
    test('seals events with contiguous sequence and linked hashes', () async {
      final recorder = testRecorder();
      final events = await recordMany(recorder, 5);
      expect(events.map((LyeEvent e) => e.seq), <int>[1, 2, 3, 4, 5]);
      expect(events.first.prevHash, HashChain.genesisHex);
      for (var i = 1; i < events.length; i++) {
        expect(events[i].prevHash, events[i - 1].rowHash);
      }
      for (final event in events) {
        expect(event.hasValidRowHash, isTrue);
        expect(event.streamId, recorder.streamId);
        expect(event.retention, LyeRetention.application);
      }
      expect(ChainVerifier.verify(events).ok, isTrue);
    });

    test('serialises concurrent callers', () async {
      final recorder = testRecorder();
      final futures = <Future<LyeEvent>>[
        for (var i = 0; i < 300; i++)
          recorder.point(
            LyeCategory.state,
            LyeActions.stateUpdate,
            component: 'p$i',
          ),
      ];
      final events = await Future.wait(futures);
      final seqs = events.map((LyeEvent e) => e.seq).toList()..sort();
      expect(seqs, List<int>.generate(300, (int i) => i + 1));
      expect(recorder.sealedCount, 300);
      expect(recorder.head!.seq, 300);
    });

    test('fills tenancy context and sanitises free text', () async {
      final recorder = testRecorder();
      recorder.context.update(
        scope: LyeScope.tenant,
        partnerId: '11111111-1111-1111-1111-111111111111',
        tenantId: '22222222-2222-2222-2222-222222222222',
        actorRef: '55555555-5555-5555-5555-555555555555',
        actorRole: 'partner_staff',
        sessionRef: 'sess-1',
        route: '/ropa',
      );
      final event = await recorder.point(
        LyeCategory.interaction,
        LyeActions.uiIntent,
        component: '=SUM(A1)\nsave',
        attrs: <String, Object?>{'email': 'x@y.md', 'rows': 2},
      );
      expect(event.scope, LyeScope.tenant);
      expect(event.tenantId, '22222222-2222-2222-2222-222222222222');
      expect(event.actorRole, 'partner_staff');
      expect(event.route, '/ropa');
      expect(event.component, "'=SUM(A1)\\nsave");
      expect(event.attrs, '{"email":"[redacted:key]","rows":2}');
      expect(
        event.payloadDigest,
        HashChain.digestHex('{"email":"x@y.md","rows":2}'),
      );
      expect(event.hasValidRowHash, isTrue);
    });

    test('zone context overrides the process context per request', () async {
      final recorder = testRecorder(origin: LyeOrigin.server);
      recorder.context.update(scope: LyeScope.none);
      const requestA = LyeContextSnapshot(
        scope: LyeScope.partner,
        partnerId: 'p-a',
        actorRef: 'u-a',
      );
      const requestB = LyeContextSnapshot(
        scope: LyeScope.tenant,
        partnerId: 'p-b',
        tenantId: 't-b',
        actorRef: 'u-b',
      );
      final results = await Future.wait(<Future<LyeEvent>>[
        recorder.withContext(
          requestA,
          () => recorder.point(LyeCategory.rpc, LyeActions.rpcHandle),
        ),
        recorder.withContext(
          requestB,
          () => recorder.point(LyeCategory.rpc, LyeActions.rpcHandle),
        ),
        recorder.point(LyeCategory.rpc, LyeActions.rpcHandle),
      ]);
      expect(results[0].partnerId, 'p-a');
      expect(results[0].scope, LyeScope.partner);
      expect(results[1].tenantId, 't-b');
      expect(results[2].scope, LyeScope.none);
      expect(results[2].actorRef, '');
    });

    test(
      'span records start and end, propagates trace to nested events',
      () async {
        final recorder = testRecorder();
        final clock = recorder.clock as FixedClock;
        final value = await recorder.span<int>(
          'ropa.entry.save',
          category: LyeCategory.interaction,
          route: '/ropa',
          body: (LyeSpan span) async {
            await recorder.point(LyeCategory.rpc, LyeActions.rpcCall);
            await recorder.span<void>(
              'ropa.entry.validate',
              category: LyeCategory.state,
              body: (LyeSpan child) async {
                expect(child.traceId, span.traceId);
                expect(child.parentSpanId, span.spanId);
                clock.advance(const Duration(milliseconds: 30));
              },
            );
            return 42;
          },
        );
        expect(value, 42);
        await recorder.flush();
        final events = await recorder.store.readRange(
          recorder.streamId,
          fromSeq: 1,
          toSeq: 100,
        );
        expect(
          events.map((LyeEvent e) => '${e.action}/${e.phase.name}'),
          <String>[
            'ropa.entry.save/start',
            'rpc.call/point',
            'ropa.entry.validate/start',
            'ropa.entry.validate/end',
            'ropa.entry.save/end',
          ],
        );
        final traceIds = events.map((LyeEvent e) => e.traceId).toSet();
        expect(traceIds.length, 1, reason: 'one operation, one trace');
        expect(events[1].spanId, events[0].spanId);
        expect(events[2].parentSpanId, events[0].spanId);
        expect(events[4].outcome, LyeOutcome.ok);
        expect(events[4].durationMs, isNotNull);
        expect(events[4].operation, 'ropa.entry.save');
      },
    );

    test(
      'span records failures with class and digest, then rethrows',
      () async {
        final recorder = testRecorder();
        await expectLater(
          recorder.span<void>(
            'doc.generate',
            category: LyeCategory.rpc,
            body: (_) async => throw StateError('boom with ion@example.md'),
          ),
          throwsStateError,
        );
        await recorder.flush();
        final events = await recorder.store.readRange(
          recorder.streamId,
          fromSeq: 1,
          toSeq: 10,
        );
        final end = events.last;
        expect(end.phase, LyePhase.end);
        expect(end.outcome, LyeOutcome.fail);
        expect(end.errorClass, 'StateError');
        expect(
          end.errorDigest,
          HashChain.digestHex(
            StateError('boom with ion@example.md').toString(),
          ),
        );
        expect(end.canonical, isNot(contains('example.md')));
      },
    );

    test('denied exceptions end the span with outcome denied', () async {
      final recorder = testRecorder();
      await expectLater(
        recorder.span<void>(
          'admin.break_glass',
          category: LyeCategory.security,
          body: (_) async => throw LyeDeniedException('no grant'),
        ),
        throwsA(isA<LyeDeniedException>()),
      );
      await recorder.flush();
      final events = await recorder.store.readRange(
        recorder.streamId,
        fromSeq: 1,
        toSeq: 10,
      );
      expect(events.last.outcome, LyeOutcome.denied);
      expect(events.last.retention, LyeRetention.security);
    });

    test('rejects malformed action codes without breaking the chain', () async {
      final recorder = testRecorder();
      await expectLater(
        recorder.point(LyeCategory.system, 'Not A Code'),
        throwsA(isA<LyeDraftException>()),
      );
      final ok = await recorder.point(LyeCategory.system, 'x.custom.event');
      expect(ok.seq, 1);
      expect(recorder.failedCount, 1);
    });

    test('start links a new epoch to the previous head of the node', () async {
      final store = MemoryLyeStore();
      final first = testRecorder(
        store: store,
        epoch: '01924f3a-0000-7000-8000-000000000001',
      );
      await recordMany(first, 3);
      await first.close();

      final second = testRecorder(
        store: store,
        epoch: '01924f3a-0000-7000-8000-000000000002',
      );
      final start = await second.start();
      expect(start.action, LyeActions.streamStart);
      expect(start.seq, 1);
      expect(start.attrs, contains('"prev_stream_id":"${first.streamId}"'));
      expect(start.attrs, contains('"prev_seq":3'));
      expect(start.attrs, contains('"prev_head":"${first.head!.headHash}"'));
    });

    test('publishes sealed events to listeners in order', () async {
      final recorder = testRecorder();
      final seen = <int>[];
      final sub = recorder.events.listen((LyeEvent e) => seen.add(e.seq));
      await recordMany(recorder, 4);
      await sub.cancel();
      expect(seen, <int>[1, 2, 3, 4]);
    });

    test('refuses to record after close', () async {
      final recorder = testRecorder();
      await recorder.close();
      expect(() => recorder.point(LyeCategory.system, 'x.a'), throwsStateError);
    });
  });
}
