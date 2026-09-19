/// Closed enumerations of the event envelope.
///
/// Every enumeration is serialized with its Dart `name`, which is also the
/// value written in the CSV column. Values are added only at the end and are
/// never renamed: a CSV written by an older version must stay readable.
library;

/// Which process produced the event.
enum LyeOrigin {
  /// Flutter console (web, mobile, desktop).
  client,

  /// Serverpod request handling.
  server,

  /// Background worker (jobs, due-scanner, exports).
  worker,

  /// egov-gateway or other sidecar.
  gateway,
}

/// Runtime platform of the producer.
enum LyePlatform { web, android, ios, windows, macos, linux, vm, unknown }

/// Whether the event is instantaneous or one end of a span.
enum LyePhase { point, start, end }

/// Result of the action, when it has one.
enum LyeOutcome { ok, fail, denied, cancelled, none }

/// Functional family of the action. Drives the default retention class.
enum LyeCategory {
  lifecycle,
  navigation,
  interaction,
  state,
  rpc,
  db,
  audit,
  job,
  auth,
  security,
  export,
  system,
  error,
}

/// Tenancy scope active when the event was produced (§5.4 of the
/// architecture document: platform → partner → tenant).
enum LyeScope { none, platform, partner, tenant }

/// Retention class of the event (§6.6 of the architecture document):
/// application logs 6 months, access logs 12 months, security 24 months.
///
/// The class is also the second half of the chain key: a subject has one
/// chain per class, so an archive covers a contiguous range of one chain
/// and verifies on its own (ADR-008).
enum LyeRetention { application, access, security }

/// Who an event belongs to (ADR-008).
///
/// Resolution is deterministic and belongs to the trusted side: the actor
/// when there is one, else the tenant, else the partner, else the node.
/// A client never names its own subject.
enum LyeSubjectType {
  /// A person: the subject reference is the pseudonymous user identifier.
  user,

  /// An organisation: events produced with no actor, such as jobs.
  org,

  /// Neither: platform-wide machinery. The reference is the node.
  platform,
}

/// Verbosity level at which an event is emitted (ADR-010).
///
/// The level travels with the event, so a reader knows why an hour is
/// poorer than another. Ordering is by [rank]: an event is recorded when
/// its level rank is at most the rank of the level in force.
enum LyeLevel {
  /// Failures only: anything whose outcome is `fail` or `denied`.
  error(10),

  /// What happened: calls, audit appends, documents, exports, jobs,
  /// navigation, application lifecycle.
  standard(20),

  /// How it happened on screen: taps, intents, form fields, state
  /// mutations, scoped transactions, mutating or slow statements.
  verbose(30),

  /// Every function entered and left, every statement, every state
  /// transition. Granted per subject, with a reason and an expiry.
  forensic(40);

  const LyeLevel(this.rank);

  /// Order of the level; higher means more detail.
  final int rank;

  /// Whether an event of this level is recorded when [inForce] is active.
  bool isRecordedAt(LyeLevel inForce) => rank <= inForce.rank;
}

/// Parses an enumeration from its wire name, failing loudly on unknown values.
T enumFromWire<T extends Enum>(List<T> values, String wire, String field) {
  for (final value in values) {
    if (value.name == wire) return value;
  }
  throw FormatException('Unknown $field value "$wire"');
}
