import 'package:meta/meta.dart';

import '../canonical/timestamp.dart';
import '../chain/hash_chain.dart';
import '../ids/hex.dart';
import 'csv_schema.dart';
import 'enums.dart';

/// One sealed row of a stream: immutable, hashed, chained.
///
/// Instances are produced by the recorder from a `LyeDraft`, or read back
/// from CSV/JSON by the verifier. The class knows how to render itself in
/// the canonical form and how to check its own row hash, and nothing else:
/// no I/O, no policy.
@immutable
class LyeEvent {
  const LyeEvent({
    required this.eventId,
    required this.streamId,
    required this.seq,
    required this.occurredAt,
    required this.origin,
    required this.platform,
    required this.app,
    required this.nodeId,
    required this.sessionRef,
    required this.traceId,
    required this.spanId,
    required this.parentSpanId,
    required this.operation,
    required this.phase,
    required this.category,
    required this.action,
    required this.outcome,
    required this.durationMs,
    required this.scope,
    required this.partnerId,
    required this.tenantId,
    required this.actorRef,
    required this.actorRole,
    required this.targetType,
    required this.targetId,
    required this.route,
    required this.component,
    required this.attrs,
    required this.payloadDigest,
    required this.auditRef,
    required this.errorClass,
    required this.errorDigest,
    required this.retention,
    required this.prevHash,
    required this.rowHash,
    this.receivedAt,
    this.schema = LyeCsvSchema.version,
  });

  /// Schema tag, `lye.v1`.
  final String schema;

  /// UUIDv7 of the event.
  final String eventId;

  /// `origin/node_id/epoch`: one chain per process start.
  final String streamId;

  /// Contiguous sequence number inside the stream, starting at 1.
  final int seq;

  /// When the action happened (producer clock, UTC).
  final DateTime occurredAt;

  final LyeOrigin origin;
  final LyePlatform platform;

  /// `appId@version+build`.
  final String app;

  /// Installation (client) or instance (server) identifier.
  final String nodeId;

  /// Pseudonymous session reference, never the session token.
  final String sessionRef;

  /// Correlation identifier of the whole operation across layers.
  final String traceId;

  /// 16 hex digits identifying this span.
  final String spanId;

  /// Parent span, empty at the root.
  final String parentSpanId;

  /// Logical operation the event belongs to (`ropa.entry.save`).
  final String operation;

  final LyePhase phase;
  final LyeCategory category;

  /// Action code, see `LyeActions`.
  final String action;

  final LyeOutcome outcome;

  /// Elapsed time for `end` phases, null otherwise.
  final int? durationMs;

  final LyeScope scope;

  /// Organisation identifiers; empty when not applicable.
  final String partnerId;
  final String tenantId;

  /// Pseudonymous actor (user UUID), never e-mail or name.
  final String actorRef;
  final String actorRole;

  /// Affected entity.
  final String targetType;
  final String targetId;

  /// Screen route on the client, `endpoint.method` on the server.
  final String route;

  /// Widget tag, provider name or server module.
  final String component;

  /// Canonical JSON of the minimised attributes.
  final String attrs;

  /// SHA-256 of the canonical attributes before minimisation, or empty.
  final String payloadDigest;

  /// `org_id:seq:row_hash` of the compliance-os audit event, or empty.
  final String auditRef;

  /// Exception type name, or empty.
  final String errorClass;

  /// SHA-256 of the exception message, or empty. The message itself is never
  /// stored: it may contain personal data.
  final String errorDigest;

  final LyeRetention retention;

  /// Hex of the previous row hash (genesis: 64 zeros).
  final String prevHash;

  /// Hex of `sha256(prev_hash || canonical)`.
  final String rowHash;

  /// Server receipt time for ingested client events; not hashed.
  final DateTime? receivedAt;

  /// The columns covered by the hash, in schema order.
  List<String> get hashedFields => <String>[
    schema,
    eventId,
    streamId,
    seq.toString(),
    formatTimestampUtc(occurredAt),
    origin.name,
    platform.name,
    app,
    nodeId,
    sessionRef,
    traceId,
    spanId,
    parentSpanId,
    operation,
    phase.name,
    category.name,
    action,
    outcome.name,
    durationMs?.toString() ?? '',
    scope.name,
    partnerId,
    tenantId,
    actorRef,
    actorRole,
    targetType,
    targetId,
    route,
    component,
    attrs,
    payloadDigest,
    auditRef,
    errorClass,
    errorDigest,
    retention.name,
  ];

  /// Canonical text entering the hash.
  String get canonical => HashChain.canonicalEventV1(hashedFields);

  /// Recomputes the row hash and compares it in constant time.
  bool get hasValidRowHash {
    if (!isSha256Hex(rowHash) || !isSha256Hex(prevHash)) return false;
    final expected = HashChain.rowHash(hexToBytes(prevHash), canonical);
    return constantTimeEquals(hexToBytes(rowHash), expected);
  }

  /// All CSV columns, in file order.
  List<String> toCsvFields() => <String>[
    ...hashedFields,
    prevHash,
    rowHash,
    receivedAt == null ? '' : formatTimestampUtc(receivedAt!),
  ];

  /// Copy with the server receipt time stamped in.
  LyeEvent withReceivedAt(DateTime time) => _copy(receivedAt: time.toUtc());

  /// Copy with the row hash set. Used by the recorder to seal a draft; any
  /// other use produces an event that fails verification.
  LyeEvent withRowHash(String hash) => _copy(rowHash: hash);

  LyeEvent _copy({DateTime? receivedAt, String? rowHash}) => LyeEvent(
    schema: schema,
    eventId: eventId,
    streamId: streamId,
    seq: seq,
    occurredAt: occurredAt,
    origin: origin,
    platform: platform,
    app: app,
    nodeId: nodeId,
    sessionRef: sessionRef,
    traceId: traceId,
    spanId: spanId,
    parentSpanId: parentSpanId,
    operation: operation,
    phase: phase,
    category: category,
    action: action,
    outcome: outcome,
    durationMs: durationMs,
    scope: scope,
    partnerId: partnerId,
    tenantId: tenantId,
    actorRef: actorRef,
    actorRole: actorRole,
    targetType: targetType,
    targetId: targetId,
    route: route,
    component: component,
    attrs: attrs,
    payloadDigest: payloadDigest,
    auditRef: auditRef,
    errorClass: errorClass,
    errorDigest: errorDigest,
    retention: retention,
    prevHash: prevHash,
    rowHash: rowHash ?? this.rowHash,
    receivedAt: receivedAt ?? this.receivedAt,
  );

  /// Reads an event back from its CSV columns. Throws [FormatException] on
  /// a wrong column count or malformed values; the row hash is not checked
  /// here (see `ChainVerifier`).
  static LyeEvent fromCsvFields(List<String> f) {
    if (f.length != LyeCsvSchema.columns.length) {
      throw FormatException(
        'Expected ${LyeCsvSchema.columns.length} columns, got ${f.length}',
      );
    }
    final durationText = f[18];
    final receivedText = f[36];
    return LyeEvent(
      schema: f[0],
      eventId: f[1],
      streamId: f[2],
      seq: int.parse(f[3]),
      occurredAt: parseTimestampUtc(f[4]),
      origin: enumFromWire(LyeOrigin.values, f[5], 'origin'),
      platform: enumFromWire(LyePlatform.values, f[6], 'platform'),
      app: f[7],
      nodeId: f[8],
      sessionRef: f[9],
      traceId: f[10],
      spanId: f[11],
      parentSpanId: f[12],
      operation: f[13],
      phase: enumFromWire(LyePhase.values, f[14], 'phase'),
      category: enumFromWire(LyeCategory.values, f[15], 'category'),
      action: f[16],
      outcome: enumFromWire(LyeOutcome.values, f[17], 'outcome'),
      durationMs: durationText.isEmpty ? null : int.parse(durationText),
      scope: enumFromWire(LyeScope.values, f[19], 'scope'),
      partnerId: f[20],
      tenantId: f[21],
      actorRef: f[22],
      actorRole: f[23],
      targetType: f[24],
      targetId: f[25],
      route: f[26],
      component: f[27],
      attrs: f[28],
      payloadDigest: f[29],
      auditRef: f[30],
      errorClass: f[31],
      errorDigest: f[32],
      retention: enumFromWire(LyeRetention.values, f[33], 'retention'),
      prevHash: f[34],
      rowHash: f[35],
      receivedAt: receivedText.isEmpty ? null : parseTimestampUtc(receivedText),
    );
  }

  /// JSON object keyed by CSV column name (the wire format of batches).
  Map<String, Object?> toJson() {
    final fields = toCsvFields();
    return <String, Object?>{
      for (var i = 0; i < fields.length; i++)
        LyeCsvSchema.columns[i]: fields[i],
    };
  }

  /// Inverse of [toJson]. Missing columns are treated as empty strings so a
  /// newer reader can still load older batches.
  static LyeEvent fromJson(Map<String, Object?> json) {
    final fields = <String>[
      for (final column in LyeCsvSchema.columns)
        (json[column] ?? '').toString(),
    ];
    return fromCsvFields(fields);
  }

  @override
  bool operator ==(Object other) =>
      other is LyeEvent && other.rowHash == rowHash && other.eventId == eventId;

  @override
  int get hashCode => Object.hash(eventId, rowHash);

  @override
  String toString() => 'LyeEvent($streamId#$seq $action ${outcome.name})';
}
