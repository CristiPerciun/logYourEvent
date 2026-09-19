import 'package:meta/meta.dart';

import '../model/enums.dart';
import 'lye_context.dart';

/// The subject of an event: who it belongs to.
@immutable
class LyeSubject {
  const LyeSubject(this.type, this.ref);

  final LyeSubjectType type;
  final String ref;

  @override
  bool operator ==(Object other) =>
      other is LyeSubject && other.type == type && other.ref == ref;

  @override
  int get hashCode => Object.hash(type, ref);

  @override
  String toString() => '${type.name}:$ref';
}

/// Turns a tenancy context into the subject an event belongs to (ADR-008).
///
/// The rule is deterministic, and it gives every event **one** subject, so
/// no row ever lands in two archives:
///
/// 1. an actor is named       → that person;
/// 2. else a tenant is named  → that organisation;
/// 3. else a partner is named → that organisation;
/// 4. else                    → the platform node.
///
/// On the client the subject is written by the producer, because it enters
/// the hashed fields and the row is sealed there. That is not a hole: the
/// receiving side validates the claim against the authenticated principal
/// and refuses the batch when it does not match, exactly as it already does
/// for actor, partner and tenant. A client may write a subject; it cannot
/// make the server believe one.
@immutable
class SubjectResolver {
  const SubjectResolver();

  LyeSubject resolve(
    LyeContextSnapshot context, {
    required String platformRef,
    LyeSubjectType? overrideType,
    String? overrideRef,
  }) {
    if (overrideType != null || (overrideRef != null && overrideRef.isNotEmpty)) {
      final type = overrideType ?? LyeSubjectType.user;
      return LyeSubject(type, overrideRef ?? '');
    }
    if (context.actorRef.isNotEmpty) {
      return LyeSubject(LyeSubjectType.user, context.actorRef);
    }
    if (context.tenantId.isNotEmpty) {
      return LyeSubject(LyeSubjectType.org, context.tenantId);
    }
    if (context.partnerId.isNotEmpty) {
      return LyeSubject(LyeSubjectType.org, context.partnerId);
    }
    return LyeSubject(LyeSubjectType.platform, platformRef);
  }
}
