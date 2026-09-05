/// CSV schema `lye.v1`.
///
/// The column order is part of the contract: the first
/// [hashedColumnCount] columns, in this order, form the canonical event that
/// enters the hash chain; `prev_hash` and `row_hash` follow; `received_at` is
/// server metadata added at ingest and is not covered by the hash.
///
/// A schema change is a new version (`lye.v2`) with a new column list; old
/// files stay verifiable with the reader of their own version.
abstract final class LyeCsvSchema {
  /// Value of the `schema` column and of the manifest field.
  static const String version = 'lye.v1';

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
    'prev_hash',
    'row_hash',
    'received_at',
  ];

  /// Number of leading columns covered by the row hash.
  static const int hashedColumnCount = 34;

  /// Index of a column by name; throws on unknown names.
  static int indexOf(String column) {
    final index = columns.indexOf(column);
    if (index < 0) throw ArgumentError.value(column, 'column', 'unknown');
    return index;
  }
}
