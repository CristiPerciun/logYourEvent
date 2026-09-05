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
enum LyeRetention { application, access, security }

/// Parses an enumeration from its wire name, failing loudly on unknown values.
T enumFromWire<T extends Enum>(List<T> values, String wire, String field) {
  for (final value in values) {
    if (value.name == wire) return value;
  }
  throw FormatException('Unknown $field value "$wire"');
}
