import 'package:lye_core/lye_core.dart';

import 'sql_template.dart';

/// Helpers that turn the server's own building blocks into spans and points.
///
/// The consuming server calls these from the places where it already
/// concentrates behaviour: the endpoint (one `handleCall` per method), the
/// `withScope` helper (one `scopedTransaction` per transaction), the
/// `DbTransaction` decorator (one `statement` per query), the audit service
/// (one `auditAppended` per append) and the job engine.
class ServerTracing {
  const ServerTracing(this.recorder);

  final LyeRecorder recorder;

  /// Builds the tenancy context of a request from the values the server's
  /// scope resolver produced. Identifiers are UUIDs, never personal data.
  LyeContextSnapshot contextFor({
    required String scope,
    String? partnerId,
    String? tenantId,
    String? actorId,
    String? actorRole,
    String? sessionRef,
    String? route,
  }) {
    return LyeContextSnapshot(
      scope: _scopeFrom(scope),
      partnerId: partnerId ?? '',
      tenantId: tenantId ?? '',
      actorRef: actorId ?? '',
      actorRole: actorRole ?? '',
      sessionRef: sessionRef ?? '',
      route: route ?? '',
    );
  }

  static LyeScope _scopeFrom(String scope) {
    switch (scope) {
      case 'platform':
        return LyeScope.platform;
      case 'partner':
        return LyeScope.partner;
      case 'tenant':
        return LyeScope.tenant;
      default:
        return LyeScope.none;
    }
  }

  /// Wraps the handling of one endpoint method: `rpc.handle` span with the
  /// call digest that the client computed on its side.
  ///
  /// [jsonArgs] are the decoded arguments without the Serverpod envelope
  /// (`CallCorrelation.stripEnvelope`). They enter the digest only.
  Future<T> handleCall<T>({
    required String endpoint,
    required String method,
    required Map<String, Object?> jsonArgs,
    required LyeContextSnapshot context,
    required Future<T> Function() body,
  }) {
    final route = CallCorrelation.route(endpoint, method);
    final snapshot = LyeContextSnapshot(
      scope: context.scope,
      partnerId: context.partnerId,
      tenantId: context.tenantId,
      actorRef: context.actorRef,
      actorRole: context.actorRole,
      sessionRef: context.sessionRef,
      route: route,
    );
    return recorder.withContext(
      snapshot,
      () => recorder.span<T>(
        'rpc.$route',
        category: LyeCategory.rpc,
        action: LyeActions.rpcHandle,
        route: route,
        attrs: CallCorrelation.attrs(
          endpoint: endpoint,
          method: method,
          jsonArgs: jsonArgs,
        ),
        body: (_) => body(),
      ),
    );
  }

  /// Wraps a scoped transaction (`withScope`): `db.scope` span whose end is
  /// `ok` on commit and `fail` on rollback.
  Future<T> scopedTransaction<T>({
    required String scope,
    String? partnerId,
    String? tenantId,
    required Future<T> Function() body,
  }) {
    return recorder.span<T>(
      LyeActions.dbScope,
      category: LyeCategory.db,
      attrs: <String, Object?>{
        'scope': scope,
        'partner_id': partnerId ?? '',
        'tenant_id': tenantId ?? '',
      },
      body: (_) => body(),
    );
  }

  /// Runs one statement and records `db.statement` with kind, table, template
  /// digest, row count and duration. Parameters never enter the trace.
  Future<T> statement<T>(
    String sql, {
    required Future<T> Function() run,
    int Function(T result)? rowCount,
  }) async {
    final stopwatch = Stopwatch()..start();
    try {
      final result = await run();
      stopwatch.stop();
      await recorder.point(
        LyeCategory.db,
        LyeActions.dbStatement,
        outcome: LyeOutcome.ok,
        component: SqlTemplate.tableOf(sql),
        attrs: <String, Object?>{
          'kind': SqlTemplate.kindOf(sql),
          'sql_digest': SqlTemplate.digest(sql),
          'rows': rowCount?.call(result),
          'ms': stopwatch.elapsedMilliseconds,
        },
      );
      return result;
    } catch (error) {
      stopwatch.stop();
      await recorder.record(
        LyeDraft.error(
          error,
          action: LyeActions.dbStatement,
          category: LyeCategory.db,
          component: SqlTemplate.tableOf(sql),
          attrs: <String, Object?>{
            'kind': SqlTemplate.kindOf(sql),
            'sql_digest': SqlTemplate.digest(sql),
            'ms': stopwatch.elapsedMilliseconds,
          },
        ),
      );
      rethrow;
    }
  }

  /// Links the trace to the compliance-os audit chain: `audit.append` with
  /// `audit_ref = org_id:seq:row_hash`.
  Future<LyeEvent> auditAppended({
    required String orgId,
    required String action,
    required List<int> rowHash,
    int? seq,
    String? targetType,
    String? targetId,
  }) {
    return recorder.point(
      LyeCategory.audit,
      LyeActions.auditAppend,
      outcome: LyeOutcome.ok,
      targetType: targetType,
      targetId: targetId,
      auditRef: '$orgId:${seq ?? ''}:${bytesToHex(rowHash)}',
      attrs: <String, Object?>{'action': action},
    );
  }

  /// A document was displayed or downloaded (§5.6: reads fire no trigger).
  Future<LyeEvent> documentAccessed({
    required String documentId,
    required String kind,
    bool download = false,
  }) {
    return recorder.point(
      LyeCategory.export,
      download ? LyeActions.documentDownload : LyeActions.documentView,
      outcome: LyeOutcome.ok,
      targetType: 'document',
      targetId: documentId,
      attrs: <String, Object?>{'kind': kind},
    );
  }

  /// A job entered the queue (inside the domain transaction: outbox).
  Future<LyeEvent> jobEnqueued({
    required String queue,
    required String jobId,
    String? singletonKey,
  }) {
    return recorder.point(
      LyeCategory.job,
      LyeActions.jobEnqueue,
      outcome: LyeOutcome.ok,
      targetType: 'job',
      targetId: jobId,
      attrs: <String, Object?>{'queue': queue, 'singleton_key': ?singletonKey},
    );
  }

  /// Runs a job handler as a span: `job.run` with attempt number; failure
  /// records class and digest and rethrows so the queue can retry.
  Future<T> runJob<T>({
    required String queue,
    required String jobId,
    required int attempt,
    required Future<T> Function() body,
  }) {
    return recorder.span<T>(
      'job.$queue',
      category: LyeCategory.job,
      action: 'job.run',
      targetType: 'job',
      targetId: jobId,
      attrs: <String, Object?>{'queue': queue, 'attempt': attempt},
      body: (_) => body(),
    );
  }

  /// A break-glass elevation (§6.3): always `security`, always with the
  /// partner concerned so the notification has an addressee.
  Future<LyeEvent> breakGlass({
    required String partnerId,
    required DateTime expiresAt,
    required bool granted,
  }) {
    return recorder.point(
      LyeCategory.security,
      LyeActions.securityBreakGlass,
      outcome: granted ? LyeOutcome.ok : LyeOutcome.denied,
      attrs: <String, Object?>{
        'partner_id': partnerId,
        'expires_at': expiresAt,
      },
    );
  }
}
