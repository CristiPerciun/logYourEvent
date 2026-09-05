import 'package:lye_core/lye_core.dart';
import 'package:meta/meta.dart';

import 'rate_limiter.dart';
import 'stream_ownership.dart';

/// The authenticated caller of the ingest route, as the server resolved it
/// from the session (never from the request body).
@immutable
class IngestPrincipal {
  const IngestPrincipal({
    required this.actorRef,
    required this.partnerId,
    this.tenantId = '',
    this.scope = LyeScope.partner,
    this.actorRole = '',
    this.sessionRef = '',
  });

  final String actorRef;
  final String partnerId;
  final String tenantId;
  final LyeScope scope;
  final String actorRole;
  final String sessionRef;
}

/// One ingest call.
@immutable
class IngestRequest {
  const IngestRequest({
    required this.principal,
    required this.batchJson,
    required this.bodyBytes,
    this.rateLimitKey,
  });

  final IngestPrincipal principal;

  /// Decoded JSON body (a `lye.batch.v1` object).
  final Map<String, Object?> batchJson;

  /// Size of the raw body, for the size cap.
  final int bodyBytes;

  /// Key for rate limiting; defaults to the actor.
  final String? rateLimitKey;
}

/// Answer of the ingest handler, ready to be serialised as HTTP.
@immutable
class IngestResult {
  const IngestResult._({
    required this.statusCode,
    required this.code,
    required this.message,
    this.head,
    this.problems = const <ChainProblem>[],
  });

  const IngestResult.accepted(StreamHead head, {String code = 'accepted'})
    : this._(statusCode: 200, code: code, message: 'batch stored', head: head);

  const IngestResult.badRequest(String code, String message)
    : this._(statusCode: 400, code: code, message: message);

  const IngestResult.forbidden(String code, String message)
    : this._(statusCode: 403, code: code, message: message);

  const IngestResult.conflict(
    String code,
    String message, {
    StreamHead? head,
    List<ChainProblem> problems = const <ChainProblem>[],
  }) : this._(
         statusCode: 409,
         code: code,
         message: message,
         head: head,
         problems: problems,
       );

  const IngestResult.tooLarge(String code, String message)
    : this._(statusCode: 413, code: code, message: message);

  const IngestResult.tooMany()
    : this._(
        statusCode: 429,
        code: 'rate_limited',
        message: 'too many batches',
      );

  final int statusCode;
  final String code;
  final String message;

  /// Head of the stream after the call (accepted, replayed or conflicting).
  final StreamHead? head;
  final List<ChainProblem> problems;

  bool get accepted => statusCode == 200;

  /// Whether the client should retry later (transient) or stop (definitive).
  bool get retryable => statusCode == 429;

  Map<String, Object?> toJson() => <String, Object?>{
    'code': code,
    'message': message,
    if (head != null) 'stream_id': head!.streamId,
    if (head != null) 'head_seq': head!.seq,
    if (head != null) 'head_hash': head!.headHash,
    if (problems.isNotEmpty)
      'problems': <Object?>[for (final p in problems) '${p.seq}:${p.code}'],
  };
}

/// Receives client batches, verifies them and appends them to the server
/// store; every refusal becomes a `security` event of the server stream.
///
/// Checks, in order: body size, rate limit, batch structure, origin (only
/// `client` streams), stream ownership, actor and organisation of every
/// event against the principal, clock skew, replay (idempotent), gap, and
/// the full chain continuation against the stored head.
class IngestHandler {
  IngestHandler({
    required this.store,
    required this.recorder,
    StreamOwnership? ownership,
    RateLimiter? rateLimiter,
    this.maxEvents = 500,
    this.maxBodyBytes = 1024 * 1024,
    this.maxClockSkew = const Duration(hours: 24),
    LyeClock? clock,
  }) : ownership = ownership ?? MemoryStreamOwnership(),
       rateLimiter = rateLimiter ?? RateLimiter(),
       clock = clock ?? recorder.clock;

  /// Where client events are stored (shared with the server stream).
  final LyeStore store;

  /// Server recorder: ingest outcomes are events too.
  final LyeRecorder recorder;
  final StreamOwnership ownership;
  final RateLimiter rateLimiter;
  final int maxEvents;
  final int maxBodyBytes;
  final Duration maxClockSkew;
  final LyeClock clock;

  Future<IngestResult> handle(IngestRequest request) async {
    final principal = request.principal;
    final context = LyeContextSnapshot(
      scope: principal.scope,
      partnerId: principal.partnerId,
      tenantId: principal.tenantId,
      actorRef: principal.actorRef,
      actorRole: principal.actorRole,
      sessionRef: principal.sessionRef,
      route: 'lye.ingest',
    );
    return recorder.withContext(context, () => _handle(request));
  }

  Future<IngestResult> _handle(IngestRequest request) async {
    final principal = request.principal;
    if (request.bodyBytes > maxBodyBytes) {
      return _reject(
        const IngestResult.tooLarge(
          'body_too_large',
          'batch body exceeds the limit',
        ),
        streamId: request.batchJson['stream_id']?.toString() ?? '',
      );
    }
    if (!rateLimiter.tryAcquire(request.rateLimitKey ?? principal.actorRef)) {
      await recorder.point(
        LyeCategory.security,
        LyeActions.securityRateLimited,
        outcome: LyeOutcome.denied,
        attrs: const <String, Object?>{'route': 'lye.ingest'},
      );
      return const IngestResult.tooMany();
    }

    final LyeBatch batch;
    try {
      batch = LyeBatch.fromJson(request.batchJson);
    } on FormatException catch (e) {
      return _reject(
        IngestResult.badRequest('malformed', e.message),
        streamId: request.batchJson['stream_id']?.toString() ?? '',
      );
    }
    if (batch.count > maxEvents) {
      return _reject(
        IngestResult.tooLarge(
          'too_many_events',
          'batch has ${batch.count} events, max $maxEvents',
        ),
        streamId: batch.streamId,
      );
    }
    if (!batch.streamId.startsWith('${LyeOrigin.client.name}/')) {
      return _reject(
        const IngestResult.badRequest(
          'foreign_origin',
          'only client streams can be ingested',
        ),
        streamId: batch.streamId,
      );
    }

    final owner = await ownership.ownerOf(batch.streamId);
    if (owner == null) {
      await ownership.bind(batch.streamId, principal.actorRef);
    } else if (owner != principal.actorRef) {
      return _reject(
        const IngestResult.forbidden(
          'stream_owned_by_other',
          'stream is bound to another actor',
        ),
        streamId: batch.streamId,
      );
    }

    final now = clock.now();
    for (final event in batch.events) {
      if (event.actorRef.isNotEmpty && event.actorRef != principal.actorRef) {
        return _reject(
          IngestResult.forbidden(
            'actor_mismatch',
            'event ${event.seq} names another actor',
          ),
          streamId: batch.streamId,
        );
      }
      if (event.partnerId.isNotEmpty &&
          event.partnerId != principal.partnerId) {
        return _reject(
          IngestResult.forbidden(
            'partner_mismatch',
            'event ${event.seq} names another partner',
          ),
          streamId: batch.streamId,
        );
      }
      if (principal.scope == LyeScope.tenant &&
          event.tenantId.isNotEmpty &&
          event.tenantId != principal.tenantId) {
        return _reject(
          IngestResult.forbidden(
            'tenant_mismatch',
            'event ${event.seq} names another tenant',
          ),
          streamId: batch.streamId,
        );
      }
      if (event.occurredAt.difference(now).abs() > maxClockSkew) {
        return _reject(
          IngestResult.badRequest(
            'clock_skew',
            'event ${event.seq} is too far from server time',
          ),
          streamId: batch.streamId,
        );
      }
    }

    final head = await store.head(batch.streamId);
    if (batch.toSeq <= head.seq) {
      // Everything already known: idempotent when identical.
      final stored = await store.readRange(
        batch.streamId,
        fromSeq: batch.fromSeq,
        toSeq: batch.toSeq,
      );
      final identical =
          stored.length == batch.count &&
          List<bool>.generate(
            stored.length,
            (int i) => stored[i].rowHash == batch.events[i].rowHash,
          ).every((bool same) => same);
      if (identical) {
        return IngestResult.accepted(head, code: 'already_accepted');
      }
      return _reject(
        IngestResult.conflict(
          'conflict',
          'batch rewrites stored events',
          head: head,
        ),
        streamId: batch.streamId,
      );
    }
    if (batch.fromSeq <= head.seq) {
      // Partial overlap: a retry after a half-applied batch is impossible
      // because appends are atomic per event and the client marks only on
      // success, so an overlap means the client and the server disagree.
      return _reject(
        IngestResult.conflict(
          'overlap',
          'batch overlaps stored events',
          head: head,
        ),
        streamId: batch.streamId,
      );
    }
    if (batch.fromSeq > head.seq + 1) {
      return _reject(
        IngestResult.conflict(
          'gap',
          'batch starts at ${batch.fromSeq}, head is ${head.seq}',
          head: head,
        ),
        streamId: batch.streamId,
      );
    }

    final report = ChainVerifier.verifyContinuation(
      batch.events,
      streamId: batch.streamId,
      headSeq: head.seq,
      headHash: head.headHash,
    );
    if (!report.ok) {
      return _reject(
        IngestResult.conflict(
          'chain_broken',
          'batch does not verify',
          head: head,
          problems: report.problems,
        ),
        streamId: batch.streamId,
      );
    }

    for (final event in batch.events) {
      await store.append(event.withReceivedAt(now));
    }
    final newHead = StreamHead(
      streamId: batch.streamId,
      seq: batch.toSeq,
      headHash: batch.headHash,
    );
    await recorder.point(
      LyeCategory.system,
      LyeActions.ingestAccepted,
      outcome: LyeOutcome.ok,
      attrs: <String, Object?>{
        'stream_id': batch.streamId,
        'from_seq': batch.fromSeq,
        'to_seq': batch.toSeq,
        'count': batch.count,
        'head_hash': batch.headHash,
      },
    );
    return IngestResult.accepted(newHead);
  }

  Future<IngestResult> _reject(
    IngestResult result, {
    required String streamId,
  }) async {
    await recorder.point(
      LyeCategory.security,
      LyeActions.ingestRejected,
      outcome: LyeOutcome.denied,
      attrs: <String, Object?>{
        'stream_id': streamId,
        'code': result.code,
        'status': result.statusCode,
        if (result.problems.isNotEmpty)
          'problems': <Object?>[
            for (final p in result.problems.take(10)) '${p.seq}:${p.code}',
          ],
      },
    );
    return result;
  }
}
