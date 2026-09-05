import '../model/lye_event.dart';
import 'lye_store.dart';

/// In-memory store: the only option on Flutter Web (§8.5 of the
/// architecture document forbids sensitive data in browser caches and Realm
/// has no web build), and the natural store for tests.
///
/// Bounded: when [maxEvents] is exceeded, the oldest *shipped* events are
/// evicted. Unshipped events are never evicted silently; if they alone
/// exceed the cap the store keeps accepting them and exposes the overflow
/// through [overflowCount] so the recorder can emit `lye.stream.overflow`.
class MemoryLyeStore implements LyeStore {
  MemoryLyeStore({this.maxEvents = 10000});

  final int maxEvents;

  final Map<String, List<_Row>> _streams = <String, List<_Row>>{};
  final Set<String> _eventIds = <String>{};
  final Map<String, StreamHead> _heads = <String, StreamHead>{};
  int _overflowCount = 0;
  bool _closed = false;

  /// Number of times the unshipped backlog exceeded [maxEvents].
  int get overflowCount => _overflowCount;

  /// Total events currently held.
  int get length =>
      _streams.values.fold(0, (int n, List<_Row> rows) => n + rows.length);

  @override
  Future<StreamHead> head(String streamId) async {
    _checkOpen();
    return _heads[streamId] ?? StreamHead.genesis(streamId);
  }

  @override
  Future<void> append(LyeEvent event) async {
    _checkOpen();
    final head = _heads[event.streamId] ?? StreamHead.genesis(event.streamId);
    assertContinues(head, event);
    if (_eventIds.contains(event.eventId)) {
      throw ChainIntegrityException(
        'duplicate event_id ${event.eventId}',
        streamId: event.streamId,
        seq: event.seq,
      );
    }
    final rows = _streams.putIfAbsent(event.streamId, () => <_Row>[]);
    rows.add(_Row(event));
    _eventIds.add(event.eventId);
    _heads[event.streamId] = StreamHead(
      streamId: event.streamId,
      seq: event.seq,
      headHash: event.rowHash,
    );
    _evictIfNeeded();
  }

  void _evictIfNeeded() {
    var total = length;
    if (total <= maxEvents) return;
    // Evict shipped rows, oldest first, across streams.
    for (final rows in _streams.values) {
      while (total > maxEvents &&
          rows.isNotEmpty &&
          rows.first.shippedAt != null) {
        _eventIds.remove(rows.removeAt(0).event.eventId);
        total--;
      }
    }
    if (total > maxEvents) {
      _overflowCount++;
    }
  }

  @override
  Future<List<LyeEvent>> readPending(String streamId, {int limit = 500}) async {
    _checkOpen();
    final rows = _streams[streamId] ?? const <_Row>[];
    return rows
        .where((_Row r) => r.shippedAt == null)
        .take(limit)
        .map((_Row r) => r.event)
        .toList();
  }

  @override
  Future<void> markShipped(
    String streamId,
    Iterable<String> eventIds,
    DateTime at,
  ) async {
    _checkOpen();
    final ids = eventIds.toSet();
    for (final row in _streams[streamId] ?? const <_Row>[]) {
      if (ids.contains(row.event.eventId)) {
        row.shippedAt = at;
      }
    }
    _evictIfNeeded();
  }

  @override
  Future<List<LyeEvent>> readRange(
    String streamId, {
    required int fromSeq,
    required int toSeq,
  }) async {
    _checkOpen();
    return (_streams[streamId] ?? const <_Row>[])
        .where((_Row r) => r.event.seq >= fromSeq && r.event.seq <= toSeq)
        .map((_Row r) => r.event)
        .toList();
  }

  @override
  Future<List<String>> streamIds() async {
    _checkOpen();
    return _heads.keys.toList()..sort();
  }

  @override
  Future<StreamHead?> latestHeadForNode(String origin, String nodeId) async {
    _checkOpen();
    final prefix = '$origin/$nodeId/';
    StreamHead? latest;
    for (final head in _heads.values) {
      if (!head.streamId.startsWith(prefix)) continue;
      // Epochs are UUIDv7: lexical order is time order.
      if (latest == null || head.streamId.compareTo(latest.streamId) > 0) {
        latest = head;
      }
    }
    return latest;
  }

  @override
  Future<int> purgeShippedBefore(DateTime cutoff) async {
    _checkOpen();
    var removed = 0;
    for (final rows in _streams.values) {
      final before = rows.length;
      rows.removeWhere((_Row r) {
        final drop = r.shippedAt != null && r.event.occurredAt.isBefore(cutoff);
        if (drop) _eventIds.remove(r.event.eventId);
        return drop;
      });
      removed += before - rows.length;
    }
    return removed;
  }

  @override
  Future<void> close() async {
    _closed = true;
  }

  void _checkOpen() {
    if (_closed) throw StateError('MemoryLyeStore is closed');
  }
}

class _Row {
  _Row(this.event);

  final LyeEvent event;
  DateTime? shippedAt;
}
