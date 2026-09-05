import 'package:meta/meta.dart';

import '../model/enums.dart';

/// Immutable picture of the tenancy context at one instant.
@immutable
class LyeContextSnapshot {
  const LyeContextSnapshot({
    this.scope = LyeScope.none,
    this.partnerId = '',
    this.tenantId = '',
    this.actorRef = '',
    this.actorRole = '',
    this.sessionRef = '',
    this.route = '',
  });

  final LyeScope scope;
  final String partnerId;
  final String tenantId;
  final String actorRef;
  final String actorRole;
  final String sessionRef;
  final String route;
}

/// Mutable holder of the tenancy context of a recorder.
///
/// On the client it is updated on login, logout and tenant switch, and by
/// the navigator observer for the route. On the server a fresh context is
/// derived per request from the `ScopeContext` of `withScope`, so the same
/// recorder can serve concurrent requests through `LyeRecorder.withContext`.
class LyeContext {
  LyeContext([LyeContextSnapshot initial = const LyeContextSnapshot()])
    : _snapshot = initial;

  LyeContextSnapshot _snapshot;

  LyeContextSnapshot get snapshot => _snapshot;

  void update({
    LyeScope? scope,
    String? partnerId,
    String? tenantId,
    String? actorRef,
    String? actorRole,
    String? sessionRef,
    String? route,
  }) {
    _snapshot = LyeContextSnapshot(
      scope: scope ?? _snapshot.scope,
      partnerId: partnerId ?? _snapshot.partnerId,
      tenantId: tenantId ?? _snapshot.tenantId,
      actorRef: actorRef ?? _snapshot.actorRef,
      actorRole: actorRole ?? _snapshot.actorRole,
      sessionRef: sessionRef ?? _snapshot.sessionRef,
      route: route ?? _snapshot.route,
    );
  }

  /// Forgets actor, session and scope (logout). The route is kept.
  void clearIdentity() {
    _snapshot = LyeContextSnapshot(route: _snapshot.route);
  }
}
