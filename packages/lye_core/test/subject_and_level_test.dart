import 'package:lye_core/lye_core.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('subject resolution', () {
    test('the actor wins, then the tenant, then the partner, then the node', () {
      const resolver = SubjectResolver();
      const platformRef = 'node-a';

      expect(
        resolver.resolve(
          const LyeContextSnapshot(
            actorRef: 'u-1',
            tenantId: 't-1',
            partnerId: 'p-1',
          ),
          platformRef: platformRef,
        ),
        const LyeSubject(LyeSubjectType.user, 'u-1'),
      );
      expect(
        resolver.resolve(
          const LyeContextSnapshot(tenantId: 't-1', partnerId: 'p-1'),
          platformRef: platformRef,
        ),
        const LyeSubject(LyeSubjectType.org, 't-1'),
      );
      expect(
        resolver.resolve(
          const LyeContextSnapshot(partnerId: 'p-1'),
          platformRef: platformRef,
        ),
        const LyeSubject(LyeSubjectType.org, 'p-1'),
      );
      expect(
        resolver.resolve(
          const LyeContextSnapshot(),
          platformRef: platformRef,
        ),
        const LyeSubject(LyeSubjectType.platform, 'node-a'),
      );
    });

    test('the recorder stamps the subject on every event', () async {
      final recorder = testRecorder();
      recorder.context.update(
        scope: LyeScope.tenant,
        partnerId: 'p-1',
        tenantId: 't-1',
        actorRef: 'u-1',
      );
      final event = await recorder.mustPoint(LyeCategory.rpc, 'rpc.handle');
      expect(event.subjectType, LyeSubjectType.user);
      expect(event.subjectRef, 'u-1');
      expect(event.hasValidRowHash, isTrue);
    });

    test('an event can name another account as its subject', () async {
      // An operator creates an account: the actor is the operator, the
      // subject is the account that was created.
      final recorder = testRecorder();
      recorder.context.update(actorRef: 'operator-1', scope: LyeScope.platform);
      final event = await recorder.mustPoint(
        LyeCategory.auth,
        'auth.signup',
        subjectType: LyeSubjectType.user,
        subjectRef: 'new-account',
      );
      expect(event.actorRef, 'operator-1');
      expect(event.subjectRef, 'new-account');
    });

    test('the subject is inside the signature', () async {
      final recorder = testRecorder();
      recorder.context.update(actorRef: 'u-1');
      final event = await recorder.mustPoint(LyeCategory.rpc, 'rpc.handle');
      final fields = event.toCsvFields();
      fields[LyeCsvSchema.indexOf('subject_ref')] = 'someone-else';
      expect(LyeEvent.fromCsvFields(fields).hasValidRowHash, isFalse);
    });
  });

  group('verbosity levels', () {
    test('the policy places each family where ADR-010 says', () {
      const policy = LyeLevelPolicy.standard;
      expect(
        policy.levelFor(category: LyeCategory.rpc, action: 'rpc.handle'),
        LyeLevel.standard,
      );
      expect(
        policy.levelFor(category: LyeCategory.interaction, action: 'ui.tap'),
        LyeLevel.verbose,
      );
      expect(
        policy.levelFor(category: LyeCategory.db, action: 'db.statement'),
        LyeLevel.forensic,
      );
      expect(
        policy.levelFor(category: LyeCategory.db, action: 'db.scope'),
        LyeLevel.verbose,
      );
      expect(
        policy.levelFor(category: LyeCategory.system, action: 'fn.enter'),
        LyeLevel.forensic,
      );
      expect(
        policy.levelFor(
          category: LyeCategory.rpc,
          action: 'rpc.handle',
          outcome: LyeOutcome.fail,
        ),
        LyeLevel.error,
        reason: 'a failure is always worth recording',
      );
    });

    test('security and authentication survive every level, even off', () {
      const policy = LyeLevelPolicy.standard;
      for (final level in <LyeLevel?>[null, ...LyeLevel.values]) {
        expect(
          policy.isRecorded(
            category: LyeCategory.security,
            action: 'security.break_glass',
            inForce: level,
          ),
          isTrue,
        );
        expect(
          policy.isRecorded(
            category: LyeCategory.auth,
            action: 'auth.login',
            inForce: level,
          ),
          isTrue,
        );
        expect(
          policy.isRecorded(
            category: LyeCategory.lifecycle,
            action: 'lye.stream.start',
            inForce: level,
          ),
          isTrue,
        );
      }
    });

    test('dropping happens before sealing, so the chain has no holes', () async {
      final recorder = testRecorder(level: LyeLevel.standard);
      await recorder.mustPoint(LyeCategory.rpc, 'rpc.handle');
      expect(
        await recorder.point(LyeCategory.interaction, LyeActions.uiTap),
        isNull,
        reason: 'a tap is verbose, the level in force is standard',
      );
      expect(
        await recorder.point(LyeCategory.db, LyeActions.dbStatement),
        isNull,
      );
      await recorder.mustPoint(LyeCategory.rpc, 'rpc.handle');
      await recorder.flush();

      expect(recorder.droppedCount, 2);
      expect(recorder.sealedCount, 2);
      final stored = await recorder.store.readRange(
        recorder.streamId,
        fromSeq: 1,
        toSeq: 100,
      );
      expect(stored.map((LyeEvent e) => e.seq), <int>[1, 2]);
      expect(ChainVerifier.verify(stored).ok, isTrue);
    });

    test('switching the level leaves a trace of the change', () async {
      final recorder = testRecorder(level: LyeLevel.standard);
      final event = await recorder.applyLevel(
        LyeLevel.forensic,
        source: 'grant',
        changedBy: 'auditor-1',
        reason: 'ticket 4711',
      );
      expect(event, isNotNull);
      expect(event!.action, LyeActions.policyApplied);
      expect(event.attrs, contains('"level":"forensic"'));
      expect(event.attrs, contains('"previous":"standard"'));
      expect(event.attrs, contains('"source":"grant"'));
      expect(recorder.level, LyeLevel.forensic);
      // And now a tap is admitted.
      expect(
        await recorder.point(LyeCategory.interaction, LyeActions.uiTap),
        isNotNull,
      );
    });

    test('a level switched off keeps only what the law requires', () async {
      final recorder = testRecorder(level: null);
      expect(await recorder.point(LyeCategory.rpc, 'rpc.handle'), isNull);
      expect(
        await recorder.point(LyeCategory.auth, LyeActions.authLogin),
        isNotNull,
      );
      expect(
        await recorder.point(
          LyeCategory.security,
          LyeActions.securityBreakGlass,
        ),
        isNotNull,
      );
    });

    test('the level travels with the event', () async {
      final recorder = testRecorder();
      final tap = await recorder.mustPoint(
        LyeCategory.interaction,
        LyeActions.uiTap,
      );
      expect(tap.level, LyeLevel.verbose);
      expect(tap.toCsvFields()[LyeCsvSchema.indexOf('level')], 'verbose');
    });
  });

  group('subject chain', () {
    test('folds the row hashes and keeps the key', () async {
      final recorder = testRecorder();
      recorder.context.update(actorRef: 'u-1');
      final events = <LyeEvent>[
        for (var i = 0; i < 5; i++)
          await recorder.mustPoint(LyeCategory.rpc, 'rpc.handle'),
      ];
      var hash = SubjectChain.genesisHex;
      for (final event in events) {
        hash = SubjectChain.next(hash, event.rowHash);
      }
      expect(SubjectChain.foldEvents(events), hash);
      expect(
        SubjectChain.keyOf(events.first).id,
        'user:u-1:access',
        reason: 'rpc events are access logs (DTA 6.6)',
      );
    });

    test('a head advances one event at a time', () {
      const key = SubjectChainKey(
        subjectType: LyeSubjectType.user,
        subjectRef: 'u-1',
        retention: LyeRetention.access,
      );
      final head = SubjectChainHead.genesis(key);
      expect(head.seq, 0);
      final next = head.append('a' * 64).append('b' * 64);
      expect(next.seq, 2);
      expect(
        next.chainHash,
        SubjectChain.fold(<String>['a' * 64, 'b' * 64]),
      );
    });

    test('two classes of the same account are two chains', () async {
      final recorder = testRecorder();
      recorder.context.update(actorRef: 'u-1');
      final access = await recorder.mustPoint(LyeCategory.rpc, 'rpc.handle');
      final application = await recorder.mustPoint(
        LyeCategory.interaction,
        LyeActions.uiTap,
      );
      expect(SubjectChain.keyOf(access).id, isNot(
        SubjectChain.keyOf(application).id,
      ));
    });
  });

  group('lye.v1 compatibility', () {
    test('an archive written before 0.2.0 still verifies', () {
      // A row exactly as lye.v1 wrote it: 37 columns, no subject, no level.
      const genesis = HashChain.genesisHex;
      final hashed = <String>[
        'lye.v1',
        '01924f3a-0000-7000-8000-000000000001',
        'server/app-1/01924f3a-0000-7000-8000-0000000000ff',
        '1',
        '2026-09-05T09:00:00.000000Z',
        'server',
        'vm',
        'cos_server@1.0.0+1',
        'app-1',
        '',
        '01924f3a-0000-7000-8000-000000000002',
        '',
        '',
        '',
        'point',
        'rpc',
        'rpc.handle',
        'ok',
        '',
        'none',
        '',
        '',
        '',
        '',
        '',
        '',
        'ropa.save',
        '',
        '{}',
        '',
        '',
        '',
        '',
        'access',
      ];
      final rowHash = HashChain.rowHashHex(
        genesis,
        HashChain.canonicalEventV1(hashed),
      );
      final event = LyeEvent.fromCsvFields(<String>[
        ...hashed,
        genesis,
        rowHash,
        '',
      ]);

      expect(event.schema, 'lye.v1');
      expect(event.isLegacyV1, isTrue);
      expect(event.hashedFields.length, 34);
      expect(
        event.hasValidRowHash,
        isTrue,
        reason: 'the canonical form of a v1 row must not gain three columns',
      );
      expect(event.toCsvFields().length, 37);
      expect(event.subjectType, LyeSubjectType.platform);
      expect(event.level, LyeLevel.standard);
    });

    test('a v2 row carries three more columns and still verifies', () async {
      final event = await testRecorder().mustPoint(
        LyeCategory.rpc,
        'rpc.handle',
      );
      expect(event.schema, 'lye.v2');
      expect(event.hashedFields.length, 37);
      expect(event.toCsvFields().length, 40);
      expect(event.hasValidRowHash, isTrue);
      expect(LyeEvent.fromJson(event.toJson()).rowHash, event.rowHash);
    });
  });
}
