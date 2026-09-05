import 'dart:convert';

import 'package:lye_core/lye_core.dart';
import 'package:realm_dart/realm.dart';

import 'models.dart';
import 'realm_keys.dart';

/// [LyeStore] on a local Realm file.
///
/// Every append is one Realm write transaction that checks the head, inserts
/// the row and moves the head, so a crash can never leave a row without its
/// head update. Realm is synchronous; the async signatures of [LyeStore] are
/// honoured without extra isolates because a single append is microseconds.
class RealmLyeStore implements LyeStore {
  RealmLyeStore._(this._realm);

  /// Opens (or creates) the store at [path]. With [encryptionKey] the file is
  /// AES-256 encrypted by Realm; opening an encrypted file without its key
  /// fails, which is the intended behaviour.
  factory RealmLyeStore.open({
    required String path,
    List<int>? encryptionKey,
    int schemaVersion = defaultSchemaVersion,
  }) {
    final config = Configuration.local(
      <SchemaObject>[LyeEventRow.schema, LyeChainHeadRow.schema],
      path: path,
      schemaVersion: schemaVersion,
      encryptionKey: encryptionKey == null
          ? null
          : RealmKeys.validate(encryptionKey),
    );
    return RealmLyeStore._(Realm(config));
  }

  /// In-memory Realm, for tests.
  factory RealmLyeStore.inMemory(String identifier) {
    final config = Configuration.inMemory(<SchemaObject>[
      LyeEventRow.schema,
      LyeChainHeadRow.schema,
    ], path: identifier);
    return RealmLyeStore._(Realm(config));
  }

  final Realm _realm;

  /// Schema version of the two Realm models. Bump together with a migration.
  static const int defaultSchemaVersion = 1;

  /// Path of the underlying file.
  String get path => _realm.config.path;

  bool get isClosed => _realm.isClosed;

  @override
  Future<StreamHead> head(String streamId) async {
    final row = _realm.find<LyeChainHeadRow>(streamId);
    if (row == null) return StreamHead.genesis(streamId);
    return StreamHead(streamId: streamId, seq: row.seq, headHash: row.headHash);
  }

  @override
  Future<void> append(LyeEvent event) async {
    _realm.write(() {
      final headRow = _realm.find<LyeChainHeadRow>(event.streamId);
      final head = headRow == null
          ? StreamHead.genesis(event.streamId)
          : StreamHead(
              streamId: event.streamId,
              seq: headRow.seq,
              headHash: headRow.headHash,
            );
      assertContinues(head, event);
      if (_realm.find<LyeEventRow>(event.eventId) != null) {
        throw ChainIntegrityException(
          'duplicate event_id ${event.eventId}',
          streamId: event.streamId,
          seq: event.seq,
        );
      }
      _realm.add(
        LyeEventRow(
          event.eventId,
          event.streamId,
          event.seq,
          event.occurredAt.toUtc().microsecondsSinceEpoch,
          false,
          event.rowHash,
          jsonEncode(event.toJson()),
        ),
      );
      final parts = event.streamId.split('/');
      final nodePrefix = parts.length >= 2
          ? '${parts[0]}/${parts[1]}/'
          : event.streamId;
      _realm.add(
        LyeChainHeadRow(
          event.streamId,
          nodePrefix,
          event.seq,
          event.rowHash,
          formatTimestampUtc(DateTime.now().toUtc()),
        ),
        update: true,
      );
    });
  }

  @override
  Future<List<LyeEvent>> readPending(String streamId, {int limit = 500}) async {
    // Realm Query Language accepts only a literal in LIMIT; the value is an
    // int, so interpolating it cannot inject anything.
    final rows = _realm.query<LyeEventRow>(
      'streamId == \$0 AND shipped == false SORT(seq ASC) LIMIT(${limit < 1 ? 1 : limit})',
      <Object?>[streamId],
    );
    return rows.map(_decode).toList();
  }

  @override
  Future<void> markShipped(
    String streamId,
    Iterable<String> eventIds,
    DateTime at,
  ) async {
    final stamp = formatTimestampUtc(at);
    _realm.write(() {
      for (final id in eventIds) {
        final row = _realm.find<LyeEventRow>(id);
        if (row != null && row.streamId == streamId) {
          row.shipped = true;
          row.shippedAt = stamp;
        }
      }
    });
  }

  @override
  Future<List<LyeEvent>> readRange(
    String streamId, {
    required int fromSeq,
    required int toSeq,
  }) async {
    final rows = _realm.query<LyeEventRow>(
      r'streamId == $0 AND seq >= $1 AND seq <= $2 SORT(seq ASC)',
      <Object?>[streamId, fromSeq, toSeq],
    );
    return rows.map(_decode).toList();
  }

  @override
  Future<List<String>> streamIds() async {
    return _realm
        .all<LyeChainHeadRow>()
        .map((LyeChainHeadRow r) => r.streamId)
        .toList()
      ..sort();
  }

  @override
  Future<StreamHead?> latestHeadForNode(String origin, String nodeId) async {
    final rows = _realm.query<LyeChainHeadRow>(
      r'nodePrefix == $0 SORT(streamId DESC) LIMIT(1)',
      <Object?>['$origin/$nodeId/'],
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    return StreamHead(
      streamId: row.streamId,
      seq: row.seq,
      headHash: row.headHash,
    );
  }

  @override
  Future<int> purgeShippedBefore(DateTime cutoff) async {
    final rows = _realm.query<LyeEventRow>(
      r'shipped == true AND occurredAtMicros < $0',
      <Object?>[cutoff.toUtc().microsecondsSinceEpoch],
    );
    final count = rows.length;
    if (count > 0) {
      _realm.write(() => _realm.deleteMany(rows));
    }
    return count;
  }

  @override
  Future<void> close() async {
    _realm.close();
  }

  /// Number of stored events (diagnostics).
  int get length => _realm.all<LyeEventRow>().length;

  /// Compacts the file on disk (call after a large purge).
  bool compact() => Realm.compact(_realm.config);

  static LyeEvent _decode(LyeEventRow row) {
    final decoded = jsonDecode(row.rowJson);
    if (decoded is! Map) {
      throw FormatException('Corrupt row ${row.eventId}');
    }
    return LyeEvent.fromJson(
      decoded.map((Object? k, Object? v) => MapEntry(k.toString(), v)),
    );
  }
}
