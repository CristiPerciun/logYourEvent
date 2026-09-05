import 'package:realm_dart/realm.dart';

part 'models.realm.dart';

/// One sealed event. The full row travels as canonical JSON (`rowJson`,
/// the `LyeEvent.toJson` form) so the Realm schema never has to follow the
/// CSV schema; the indexed columns exist only for the queries the store
/// runs (pending by stream, ranges by seq, purge by time).
@RealmModel()
class _LyeEventRow {
  @PrimaryKey()
  late String eventId;

  @Indexed()
  late String streamId;

  late int seq;

  /// `occurred_at` as microseconds since epoch (UTC), for range purges.
  @Indexed()
  late int occurredAtMicros;

  @Indexed()
  late bool shipped;

  late String? shippedAt;

  late String rowHash;

  late String rowJson;
}

/// Head of a stream, updated in the same write as the append.
@RealmModel()
class _LyeChainHeadRow {
  @PrimaryKey()
  late String streamId;

  /// `origin/nodeId/`, to find the latest epoch of a node.
  @Indexed()
  late String nodePrefix;

  late int seq;

  late String headHash;

  late String updatedAt;
}
