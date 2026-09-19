/// CSV schema `lye.v2`.
///
/// The column order is part of the contract: the first
/// [hashedColumnCount] columns, in this order, form the canonical event that
/// enters the hash chain; `prev_hash` and `row_hash` follow; `received_at` is
/// server metadata added at ingest and is not covered by the hash.
///
/// A schema change is a new version with a new column list; old files stay
/// verifiable with the reader of their own version. `lye.v2` appends three
/// columns to the hashed block of `lye.v1` — `subject_type`, `subject_ref`
/// and `level` — so that an archive can be cut per subject and can explain
/// by itself why an hour is poorer than another (ADR-008, ADR-010).
abstract final class LyeCsvSchema {
  /// Value of the `schema` column and of the manifest field.
  static const String version = 'lye.v2';

  /// Schema versions this reader understands.
  static const List<String> knownVersions = <String>['lye.v1', 'lye.v2'];

  /// Column names, in file order.
  static const List<String> columns = <String>[
    'schema',
    'event_id',
    'stream_id',
    'seq',
    'occurred_at',
    'origin',
    'platform',
    'app',
    'node_id',
    'session_ref',
    'trace_id',
    'span_id',
    'parent_span_id',
    'operation',
    'phase',
    'category',
    'action',
    'outcome',
    'duration_ms',
    'scope',
    'partner_id',
    'tenant_id',
    'actor_ref',
    'actor_role',
    'target_type',
    'target_id',
    'route',
    'component',
    'attrs',
    'payload_digest',
    'audit_ref',
    'error_class',
    'error_digest',
    'retention',
    'subject_type',
    'subject_ref',
    'level',
    'prev_hash',
    'row_hash',
    'received_at',
  ];

  /// Number of leading columns covered by the row hash.
  static const int hashedColumnCount = 37;

  /// Columns of `lye.v1`, kept so that an archive written before 0.2.0 stays
  /// readable: the three columns added in `lye.v2` sit between `retention`
  /// and `prev_hash`, so the older layout is not a prefix of this one.
  static const List<String> columnsV1 = <String>[
    ...<String>[
      'schema',
      'event_id',
      'stream_id',
      'seq',
      'occurred_at',
      'origin',
      'platform',
      'app',
      'node_id',
      'session_ref',
      'trace_id',
      'span_id',
      'parent_span_id',
      'operation',
      'phase',
      'category',
      'action',
      'outcome',
      'duration_ms',
      'scope',
      'partner_id',
      'tenant_id',
      'actor_ref',
      'actor_role',
      'target_type',
      'target_id',
      'route',
      'component',
      'attrs',
      'payload_digest',
      'audit_ref',
      'error_class',
      'error_digest',
      'retention',
    ],
    'prev_hash',
    'row_hash',
    'received_at',
  ];

  /// Number of leading columns covered by the row hash in `lye.v1`.
  static const int hashedColumnCountV1 = 34;

  /// The column list of a schema version.
  static List<String> columnsOf(String schemaVersion) => switch (schemaVersion) {
    'lye.v2' => columns,
    'lye.v1' => columnsV1,
    _ => throw FormatException('Unknown schema version "$schemaVersion"'),
  };

  /// Index of a column by name; throws on unknown names.
  static int indexOf(String column) {
    final index = columns.indexOf(column);
    if (index < 0) throw ArgumentError.value(column, 'column', 'unknown');
    return index;
  }
}
