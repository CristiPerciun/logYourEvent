import 'dart:async';
import 'dart:math';

import '../chain/hash_chain.dart';
import '../ids/uuid_v7.dart';
import '../model/enums.dart';
import '../model/lye_actions.dart';
import '../model/lye_draft.dart';
import '../model/lye_event.dart';
import '../privacy/redactor.dart';
import '../privacy/text_sanitizer.dart';
import '../store/lye_store.dart';
import '../version.dart';
import 'lye_clock.dart';
import 'lye_config.dart';
import 'lye_context.dart';
import 'lye_span.dart';

/// Raised when a draft cannot be sealed.
class LyeDraftException implements Exception {
  LyeDraftException(this.message);

  final String message;

  @override
  String toString() => 'LyeDraftException: $message';
}

/// The single writer of a stream.
///
/// A recorder owns one stream (`origin/node_id/epoch`), seals drafts into
/// events in strict order through an internal queue, appends them to the
/// store and publishes them on [events]. Concurrent callers are serialised:
/// two `record` calls issued back to back always get consecutive sequence
/// numbers, whatever the store latency.
///
/// Tenancy context comes from [context], or from the zone-local snapshot set
/// with [withContext] (per request on the server). Trace context comes from
/// the current [LyeSpan].
class LyeRecorder {
  LyeRecorder({
    required this.config,
    required this.store,
    LyeClock? clock,
    Redactor? redactor,
    Random? random,
    String? epoch,
  }) : clock = clock ?? const SystemClock(),
       redactor = redactor ?? const Redactor(),
       _random = random ?? Random.secure() {
    _uuid = UuidV7(random: _random, clock: this.clock);
    _spanIds = SpanIdGenerator(_random);
    this.epoch = epoch ?? _uuid.generate();
    streamId = '${config.origin.name}/${config.nodeId}/${this.epoch}';
  }

  final LyeConfig config;
  final LyeStore store;
  final LyeClock clock;
  final Redactor redactor;
  final Random _random;
  late final UuidV7 _uuid;
  late final SpanIdGenerator _spanIds;

  /// Identifier of this process start (UUIDv7).
  late final String epoch;

  /// `origin/node_id/epoch`.
  late final String streamId;

  /// Process-wide tenancy context.
  final LyeContext context = LyeContext();

  final StreamController<LyeEvent> _events =
      StreamController<LyeEvent>.broadcast(sync: true);
  Future<void> _queue = Future<void>.value();
  StreamHead? _head;
  int _sealed = 0;
  int _failed = 0;
  bool _closed = false;

  /// Zone key under which [withContext] stores its snapshot.
  static const Symbol contextZoneKey = #lye_context;

  /// Every sealed event, in order, as it is appended.
  Stream<LyeEvent> get events => _events.stream;

  /// Events sealed so far by this recorder.
  int get sealedCount => _sealed;

  /// Drafts that could not be sealed (store failure, malformed draft).
  int get failedCount => _failed;

  /// Last known head of the stream, null before the first record.
  StreamHead? get head => _head;

  bool get isClosed => _closed;

  /// The context in force for the calling zone.
  LyeContextSnapshot get effectiveContext =>
      (Zone.current[contextZoneKey] as LyeContextSnapshot?) ?? context.snapshot;

  /// Runs [body] with [snapshot] as the tenancy context of every event
  /// recorded inside it, without touching the process-wide [context].
  R withContext<R>(LyeContextSnapshot snapshot, R Function() body) {
    return runZoned<R>(
      body,
      zoneValues: <Object?, Object?>{contextZoneKey: snapshot},
    );
  }

  /// Mints a new span identifier.
  String newSpanId() => _spanIds.next();

  /// Mints a new trace identifier.
  String newTraceId() => _uuid.generate();

  /// Records the first event of the stream, linking it to the previous
  /// epoch of the same node when the store remembers one.
  Future<LyeEvent> start({
    Map<String, Object?> attrs = const <String, Object?>{},
  }) async {
    final previous = await store.latestHeadForNode(
      config.origin.name,
      config.nodeId,
    );
    return record(
      LyeDraft(
        category: LyeCategory.lifecycle,
        action: LyeActions.streamStart,
        outcome: LyeOutcome.ok,
        attrs: <String, Object?>{
          'lye_version': lyeVersion,
          'epoch': epoch,
          'app': config.app,
          if (previous != null) 'prev_stream_id': previous.streamId,
          if (previous != null) 'prev_seq': previous.seq,
          if (previous != null) 'prev_head': previous.headHash,
          ...attrs,
        },
      ),
    );
  }

  /// Seals and stores [draft]. Completes with the sealed event, or with a
  /// [LyeDraftException] / store error. Never throws synchronously once the
  /// recorder is open.
  Future<LyeEvent> record(LyeDraft draft) {
    if (_closed) {
      throw StateError('LyeRecorder for $streamId is closed');
    }
    // Capture what depends on the caller's zone before queueing.
    final snapshot = effectiveContext;
    final span = LyeSpan.current;
    final occurredAt = draft.occurredAt?.toUtc() ?? clock.now();
    final completer = Completer<LyeEvent>();
    _queue = _queue.then((_) async {
      try {
        final event = await _seal(draft, snapshot, span, occurredAt);
        completer.complete(event);
      } catch (error, stackTrace) {
        _failed++;
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  /// Convenience for a point event.
  Future<LyeEvent> point(
    LyeCategory category,
    String action, {
    LyeOutcome outcome = LyeOutcome.none,
    String? operation,
    String? route,
    String? component,
    String? targetType,
    String? targetId,
    String? auditRef,
    Map<String, Object?> attrs = const <String, Object?>{},
  }) {
    return record(
      LyeDraft(
        category: category,
        action: action,
        outcome: outcome,
        operation: operation,
        route: route,
        component: component,
        targetType: targetType,
        targetId: targetId,
        auditRef: auditRef,
        attrs: attrs,
      ),
    );
  }

  /// Runs [body] as a span: records a `start` event, runs the body with the
  /// span as the current one (so nested records inherit the trace), then
  /// records an `end` event with the duration and the outcome. Exceptions
  /// are recorded as `fail` with their class and digest, and rethrown.
  ///
  /// A root span mints a new trace id unless [traceId] continues one.
  Future<T> span<T>(
    String operation, {
    required LyeCategory category,
    required Future<T> Function(LyeSpan span) body,
    String? action,
    String? traceId,
    String? route,
    String? component,
    String? targetType,
    String? targetId,
    Map<String, Object?> attrs = const <String, Object?>{},
  }) async {
    final parent = LyeSpan.current;
    final now = clock.now();
    final span = parent != null
        ? parent.child(operation, spanId: _spanIds.next(), now: now)
        : LyeSpan(
            traceId: traceId ?? _uuid.generate(),
            spanId: _spanIds.next(),
            parentSpanId: '',
            operation: operation,
            startedAt: now,
          );
    final code = action ?? operation;
    final base = LyeDraft(
      category: category,
      action: code,
      operation: operation,
      route: route,
      component: component,
      targetType: targetType,
      targetId: targetId,
      attrs: attrs,
    );
    final stopwatch = Stopwatch()..start();
    await LyeSpan.run(
      span,
      () => record(base.copyWith(phase: LyePhase.start, occurredAt: now)),
    );
    try {
      final result = await LyeSpan.run(span, () => body(span));
      stopwatch.stop();
      await LyeSpan.run(
        span,
        () => record(
          base.copyWith(
            phase: LyePhase.end,
            outcome: LyeOutcome.ok,
            durationMs: stopwatch.elapsedMilliseconds,
            attrs: const <String, Object?>{},
          ),
        ),
      );
      return result;
    } catch (error) {
      stopwatch.stop();
      await LyeSpan.run(
        span,
        () => record(
          base.copyWith(
            phase: LyePhase.end,
            outcome: error is LyeDeniedException
                ? LyeOutcome.denied
                : LyeOutcome.fail,
            durationMs: stopwatch.elapsedMilliseconds,
            errorClass: error.runtimeType.toString(),
            errorDigest: HashChain.digestHex(error.toString()),
            attrs: const <String, Object?>{},
          ),
        ),
      );
      rethrow;
    }
  }

  /// Waits until every queued draft has been sealed or failed.
  Future<void> flush() => _queue;

  /// Flushes, then closes the event stream. The store is not closed: it may
  /// be shared with a scheduler or an exporter.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _queue;
    await _events.close();
  }

  Future<LyeEvent> _seal(
    LyeDraft draft,
    LyeContextSnapshot ctx,
    LyeSpan? span,
    DateTime occurredAt,
  ) async {
    if (!LyeActions.isWellFormed(draft.action)) {
      throw LyeDraftException('Malformed action code "${draft.action}"');
    }
    final head = _head ??= await store.head(streamId);
    final redaction = redactor.redact(draft.attrs);
    final maxLength = config.maxFieldLength;
    String clean(String? value) =>
        value == null ? '' : LyeText.sanitize(value, maxLength: maxLength);

    final unsealed = LyeEvent(
      eventId: _uuid.generate(),
      streamId: streamId,
      seq: head.seq + 1,
      occurredAt: occurredAt,
      origin: config.origin,
      platform: config.platform,
      app: clean(config.app),
      nodeId: clean(config.nodeId),
      sessionRef: clean(draft.sessionRef ?? ctx.sessionRef),
      traceId: clean(draft.traceId ?? span?.traceId ?? _uuid.generate()),
      spanId: clean(draft.spanId ?? span?.spanId),
      parentSpanId: clean(draft.parentSpanId ?? span?.parentSpanId),
      operation: clean(draft.operation ?? span?.operation),
      phase: draft.phase,
      category: draft.category,
      action: draft.action,
      outcome: draft.outcome,
      durationMs: draft.durationMs,
      scope: draft.scope ?? ctx.scope,
      partnerId: clean(draft.partnerId ?? ctx.partnerId),
      tenantId: clean(draft.tenantId ?? ctx.tenantId),
      actorRef: clean(draft.actorRef ?? ctx.actorRef),
      actorRole: clean(draft.actorRole ?? ctx.actorRole),
      targetType: clean(draft.targetType),
      targetId: clean(draft.targetId),
      route: clean(draft.route ?? ctx.route),
      component: clean(draft.component),
      attrs: redaction.attrsCanonical,
      payloadDigest: redaction.payloadDigest,
      auditRef: clean(draft.auditRef),
      errorClass: clean(draft.errorClass),
      errorDigest: clean(draft.errorDigest),
      retention: draft.retention ?? config.retention.classify(draft.category),
      prevHash: head.headHash,
      rowHash: '',
    );
    final event = unsealed.withRowHash(
      HashChain.rowHashHex(head.headHash, unsealed.canonical),
    );
    await store.append(event);
    _head = StreamHead(
      streamId: streamId,
      seq: event.seq,
      headHash: event.rowHash,
    );
    _sealed++;
    if (_events.hasListener) {
      _events.add(event);
    }
    return event;
  }
}

/// Marker exception: a span body can throw it (or a subclass) to have the
/// span end with outcome `denied` rather than `fail`.
class LyeDeniedException implements Exception {
  LyeDeniedException([this.message = 'denied']);

  final String message;

  @override
  String toString() => 'LyeDeniedException: $message';
}
