import 'package:meta/meta.dart';

import '../chain/hash_chain.dart';
import 'enums.dart';
import 'lye_actions.dart';

/// What an adapter knows about an action before the recorder seals it.
///
/// A draft carries no sequence number, no hashes and no stream identity:
/// those are assigned by the recorder, in order, from a single writer.
/// Context fields (scope, actor, trace...) are optional overrides; when null
/// the recorder fills them from its `LyeContext` and from the current span.
@immutable
class LyeDraft {
  const LyeDraft({
    required this.category,
    required this.action,
    this.phase = LyePhase.point,
    this.outcome = LyeOutcome.none,
    this.operation,
    this.occurredAt,
    this.durationMs,
    this.targetType,
    this.targetId,
    this.route,
    this.component,
    this.attrs = const <String, Object?>{},
    this.auditRef,
    this.errorClass,
    this.errorDigest,
    this.retention,
    this.scope,
    this.partnerId,
    this.tenantId,
    this.actorRef,
    this.actorRole,
    this.sessionRef,
    this.traceId,
    this.spanId,
    this.parentSpanId,
  });

  /// Draft describing a caught exception. The message is digested, never
  /// stored; the type name is kept because it carries no personal data.
  factory LyeDraft.error(
    Object error, {
    String action = LyeActions.errorHandled,
    LyeCategory category = LyeCategory.error,
    String? operation,
    String? route,
    String? component,
    Map<String, Object?> attrs = const <String, Object?>{},
    LyeRetention? retention,
  }) {
    return LyeDraft(
      category: category,
      action: action,
      outcome: LyeOutcome.fail,
      operation: operation,
      route: route,
      component: component,
      attrs: attrs,
      errorClass: error.runtimeType.toString(),
      errorDigest: HashChain.digestHex(error.toString()),
      retention: retention,
    );
  }

  final LyeCategory category;
  final String action;
  final LyePhase phase;
  final LyeOutcome outcome;
  final String? operation;
  final DateTime? occurredAt;
  final int? durationMs;
  final String? targetType;
  final String? targetId;
  final String? route;
  final String? component;

  /// Raw attributes; the recorder minimises them and keeps a digest.
  final Map<String, Object?> attrs;
  final String? auditRef;
  final String? errorClass;
  final String? errorDigest;
  final LyeRetention? retention;

  // Context overrides.
  final LyeScope? scope;
  final String? partnerId;
  final String? tenantId;
  final String? actorRef;
  final String? actorRole;
  final String? sessionRef;
  final String? traceId;
  final String? spanId;
  final String? parentSpanId;

  /// Copy with some fields replaced.
  LyeDraft copyWith({
    LyePhase? phase,
    LyeOutcome? outcome,
    String? operation,
    DateTime? occurredAt,
    int? durationMs,
    Map<String, Object?>? attrs,
    String? errorClass,
    String? errorDigest,
    String? traceId,
    String? spanId,
    String? parentSpanId,
    String? route,
    String? component,
  }) {
    return LyeDraft(
      category: category,
      action: action,
      phase: phase ?? this.phase,
      outcome: outcome ?? this.outcome,
      operation: operation ?? this.operation,
      occurredAt: occurredAt ?? this.occurredAt,
      durationMs: durationMs ?? this.durationMs,
      targetType: targetType,
      targetId: targetId,
      route: route ?? this.route,
      component: component ?? this.component,
      attrs: attrs ?? this.attrs,
      auditRef: auditRef,
      errorClass: errorClass ?? this.errorClass,
      errorDigest: errorDigest ?? this.errorDigest,
      retention: retention,
      scope: scope,
      partnerId: partnerId,
      tenantId: tenantId,
      actorRef: actorRef,
      actorRole: actorRole,
      sessionRef: sessionRef,
      traceId: traceId ?? this.traceId,
      spanId: spanId ?? this.spanId,
      parentSpanId: parentSpanId ?? this.parentSpanId,
    );
  }
}
