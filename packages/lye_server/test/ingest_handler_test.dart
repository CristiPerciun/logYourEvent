import 'package:lye_core/lye_core.dart';
import 'package:lye_server/lye_server.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late MemoryLyeStore serverStore;
  late LyeRecorder server;
  late IngestHandler handler;
  late FixedClock clock;

  const principal = IngestPrincipal(
    actorRef: actorA,
    partnerId: partnerA,
    tenantId: tenantA,
    scope: LyeScope.tenant,
    actorRole: 'partner_staff',
  );

  setUp(() {
    clock = FixedClock(DateTime.utc(2026, 9, 5, 9));
    serverStore = MemoryLyeStore();
    server = testRecorder(
      store: serverStore,
      origin: LyeOrigin.server,
      nodeId: 'app-1',
      clock: clock,
    );
    handler = IngestHandler(store: serverStore, recorder: server, clock: clock);
  });

  Future<LyeRecorder> clientWith(int count, {String actor = actorA}) async {
    final client = testRecorder(store: MemoryLyeStore(), clock: clock);
    client.context.update(
      scope: LyeScope.tenant,
      partnerId: partnerA,
      tenantId: tenantA,
      actorRef: actor,
    );
    await recordMany(client, count);
    return client;
  }

  Future<IngestResult> ship(
    LyeRecorder client, {
    IngestPrincipal as = principal,
    int limit = 500,
  }) async {
    final pending = await client.store.readPending(
      client.streamId,
      limit: limit,
    );
    final json = LyeBatch.fromEvents(pending).toJson();
    return handler.handle(
      IngestRequest(principal: as, batchJson: json, bodyBytes: 1000),
    );
  }

  Future<List<LyeEvent>> serverEvents() async {
    await server.flush();
    return serverStore.readRange(server.streamId, fromSeq: 1, toSeq: 1000);
  }

  test(
    'accepts a valid batch, stores it with receipt time and records the acceptance',
    () async {
      final client = await clientWith(5);
      final result = await ship(client);
      expect(result.accepted, isTrue, reason: result.toJson().toString());
      expect(result.head!.seq, 5);
      final stored = await serverStore.readRange(
        client.streamId,
        fromSeq: 1,
        toSeq: 5,
      );
      expect(stored.length, 5);
      expect(stored.every((LyeEvent e) => e.receivedAt == clock.now()), isTrue);
      expect(stored.every((LyeEvent e) => e.hasValidRowHash), isTrue);
      final events = await serverEvents();
      expect(events.single.action, LyeActions.ingestAccepted);
      expect(events.single.actorRef, actorA);
      expect(events.single.route, 'lye.ingest');
      expect(result.toJson()['head_hash'], stored.last.rowHash);
    },
  );

  test('a replayed batch is idempotent, a rewritten one conflicts', () async {
    final client = await clientWith(3);
    final pending = await client.store.readPending(client.streamId);
    final json = LyeBatch.fromEvents(pending).toJson();
    expect(
      (await handler.handle(
        IngestRequest(principal: principal, batchJson: json, bodyBytes: 10),
      )).accepted,
      isTrue,
    );
    final replay = await handler.handle(
      IngestRequest(principal: principal, batchJson: json, bodyBytes: 10),
    );
    expect(replay.accepted, isTrue);
    expect(replay.code, 'already_accepted');

    // Same seqs, different content: a forgery attempt.
    final forged = List<LyeEvent>.of(pending);
    final fields = forged[1].toCsvFields();
    fields[LyeCsvSchema.indexOf('component')] = 'forged';
    fields[LyeCsvSchema.indexOf('row_hash')] = HashChain.rowHashHex(
      forged[1].prevHash,
      LyeEvent.fromCsvFields(fields).canonical,
    );
    forged[1] = LyeEvent.fromCsvFields(fields);
    final forgedJson = LyeBatch.fromEvents(<LyeEvent>[
      forged[0],
      forged[1],
    ]).toJson();
    final conflict = await handler.handle(
      IngestRequest(principal: principal, batchJson: forgedJson, bodyBytes: 10),
    );
    expect(conflict.statusCode, 409);
    expect(conflict.code, 'conflict');
    final events = await serverEvents();
    expect(events.last.action, LyeActions.ingestRejected);
    expect(events.last.category, LyeCategory.security);
    expect(events.last.retention, LyeRetention.security);
  });

  test('refuses gaps and broken chains', () async {
    final client = await clientWith(6);
    final all = await client.store.readPending(client.streamId);
    final skipping = await handler.handle(
      IngestRequest(
        principal: principal,
        batchJson: LyeBatch.fromEvents(all.sublist(2)).toJson(),
        bodyBytes: 10,
      ),
    );
    expect(skipping.code, 'gap');

    // Tamper one row in the middle: hash mismatch and broken link.
    final tampered = List<LyeEvent>.of(all);
    final fields = tampered[3].toCsvFields();
    fields[LyeCsvSchema.indexOf('actor_ref')] = actorA;
    fields[LyeCsvSchema.indexOf('attrs')] = '{"forged":true}';
    tampered[3] = LyeEvent.fromCsvFields(fields);
    final broken = await handler.handle(
      IngestRequest(
        principal: principal,
        batchJson: LyeBatch.fromEvents(tampered).toJson(),
        bodyBytes: 10,
      ),
    );
    expect(broken.code, 'chain_broken');
    expect(
      broken.problems.map((ChainProblem x) => x.code),
      contains('hash_mismatch'),
    );
    expect(
      (await serverStore.head(client.streamId)).seq,
      0,
      reason: 'nothing stored',
    );
  });

  test('binds a stream to its first actor and rejects others', () async {
    final client = await clientWith(2);
    expect((await ship(client)).accepted, isTrue);
    await recordMany(client, 1);
    const other = IngestPrincipal(actorRef: actorB, partnerId: partnerA);
    final hijack = await ship(client, as: other);
    expect(hijack.statusCode, 403);
    expect(hijack.code, 'stream_owned_by_other');
  });

  test('rejects events naming another actor, partner or tenant', () async {
    final impostor = await clientWith(2, actor: actorB);
    final result = await ship(impostor);
    expect(result.code, 'actor_mismatch');

    final otherTenant = testRecorder(store: MemoryLyeStore(), clock: clock);
    otherTenant.context.update(
      scope: LyeScope.tenant,
      partnerId: partnerA,
      tenantId: 'other-tenant',
      actorRef: actorA,
    );
    await recordMany(otherTenant, 1);
    expect((await ship(otherTenant)).code, 'tenant_mismatch');

    const partnerScoped = IngestPrincipal(
      actorRef: actorA,
      partnerId: partnerA,
      scope: LyeScope.partner,
    );
    final multi = testRecorder(store: MemoryLyeStore(), clock: clock);
    multi.context.update(
      scope: LyeScope.tenant,
      partnerId: partnerA,
      tenantId: 'any-tenant-of-partner',
      actorRef: actorA,
    );
    await recordMany(multi, 1);
    expect(
      (await ship(multi, as: partnerScoped)).accepted,
      isTrue,
      reason: 'a partner user may work on any tenant of the partner',
    );
  });

  test('applies size caps, origin check, clock skew and rate limit', () async {
    final client = await clientWith(3);
    final pending = await client.store.readPending(client.streamId);
    final json = LyeBatch.fromEvents(pending).toJson();

    final big = await handler.handle(
      IngestRequest(
        principal: principal,
        batchJson: json,
        bodyBytes: 10 * 1024 * 1024,
      ),
    );
    expect(big.statusCode, 413);

    final small = IngestHandler(
      store: serverStore,
      recorder: server,
      maxEvents: 2,
      clock: clock,
    );
    expect(
      (await small.handle(
        IngestRequest(principal: principal, batchJson: json, bodyBytes: 10),
      )).code,
      'too_many_events',
    );

    final serverOrigin = testRecorder(
      store: MemoryLyeStore(),
      origin: LyeOrigin.server,
      nodeId: 'x',
      clock: clock,
    );
    await recordMany(serverOrigin, 1);
    final foreign = LyeBatch.fromEvents(
      await serverOrigin.store.readPending(serverOrigin.streamId),
    ).toJson();
    expect(
      (await handler.handle(
        IngestRequest(principal: principal, batchJson: foreign, bodyBytes: 10),
      )).code,
      'foreign_origin',
    );

    clock.advance(const Duration(days: 3));
    expect(
      (await handler.handle(
        IngestRequest(principal: principal, batchJson: json, bodyBytes: 10),
      )).code,
      'clock_skew',
    );

    final limited = IngestHandler(
      store: serverStore,
      recorder: server,
      rateLimiter: RateLimiter(capacity: 1, refillPerMinute: 1, clock: clock),
      clock: clock,
    );
    await limited.handle(
      IngestRequest(principal: principal, batchJson: json, bodyBytes: 10),
    );
    final throttled = await limited.handle(
      IngestRequest(principal: principal, batchJson: json, bodyBytes: 10),
    );
    expect(throttled.statusCode, 429);
    expect(throttled.retryable, isTrue);

    expect(
      (await handler.handle(
        const IngestRequest(
          principal: principal,
          batchJson: <String, Object?>{'schema': 'x'},
          bodyBytes: 10,
        ),
      )).code,
      'malformed',
    );
  });
}
