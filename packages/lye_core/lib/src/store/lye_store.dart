import 'package:meta/meta.dart';

import '../chain/hash_chain.dart';
import '../model/lye_event.dart';

/// Position of the head of a stream.
@immutable
class StreamHead {
  const StreamHead({
    required this.streamId,
    required this.seq,
    required this.headHash,
  });

  /// Head of a stream that has no events yet.
  const StreamHead.genesis(this.streamId)
    : seq = 0,
      headHash = HashChain.genesisHex;

  final String streamId;

  /// Sequence number of the last event, 0 when empty.
  final int seq;

  /// `row_hash` of the last event, genesis when empty.
  final String headHash;

  bool get isGenesis => seq == 0;

  @override
  String toString() => 'StreamHead($streamId#$seq $headHash)';
}

/// Raised when an append would break the chain of its stream.
class ChainIntegrityException implements Exception {
  ChainIntegrityException(
    this.message, {
    required this.streamId,
    required this.seq,
  });

  final String message;
  final String streamId;
  final int seq;

  @override
  String toString() => 'ChainIntegrityException($streamId#$seq): $message';
}

/// Durable, append-only home of sealed events.
///
/// Implementations: `MemoryLyeStore` (web, tests), `RealmLyeStore`
/// (server, desktop, mobile). The contract is deliberately small so a third
/// implementation (Drift/SQLite, IndexedDB) is a day of work, not a design.
///
/// [append] must refuse an event whose `seq` is not `head.seq + 1` or whose
/// `prev_hash` is not `head.headHash`: the store is the last line of defence
/// of contiguity, whatever the recorder does.
abstract class LyeStore {
  /// Current head of [streamId]; genesis when unknown.
  Future<StreamHead> head(String streamId);

  /// Appends one sealed event. Throws [ChainIntegrityException] on any
  /// discontinuity or on a duplicate `event_id`.
  Future<void> append(LyeEvent event);

  /// Events of [streamId] not yet shipped, in sequence order.
  Future<List<LyeEvent>> readPending(String streamId, {int limit = 500});

  /// Marks events as shipped (or exported) at [at].
  Future<void> markShipped(
    String streamId,
    Iterable<String> eventIds,
    DateTime at,
  );

  /// Events of [streamId] with `fromSeq <= seq <= toSeq`, in order.
  Future<List<LyeEvent>> readRange(
    String streamId, {
    required int fromSeq,
    required int toSeq,
  });

  /// Every stream the store knows about.
  Future<List<String>> streamIds();

  /// Most recent head among the streams of a node (`origin/nodeId/*`), used
  /// to link a new epoch to the previous one. Null when the node is new.
  Future<StreamHead?> latestHeadForNode(String origin, String nodeId);

  /// Removes shipped events that occurred before [cutoff]. Returns the count.
  Future<int> purgeShippedBefore(DateTime cutoff);

  /// Releases resources; the store must not be used afterwards.
  Future<void> close();
}

/// Contiguity check shared by every store implementation.
void assertContinues(StreamHead head, LyeEvent event) {
  if (event.streamId != head.streamId) {
    throw ChainIntegrityException(
      'event belongs to ${event.streamId}',
      streamId: head.streamId,
      seq: event.seq,
    );
  }
  if (event.seq != head.seq + 1) {
    throw ChainIntegrityException(
      'expected seq ${head.seq + 1}',
      streamId: head.streamId,
      seq: event.seq,
    );
  }
  if (event.prevHash != head.headHash) {
    throw ChainIntegrityException(
      'prev_hash does not match the head hash',
      streamId: head.streamId,
      seq: event.seq,
    );
  }
  if (!event.hasValidRowHash) {
    throw ChainIntegrityException(
      'row_hash does not match the content',
      streamId: head.streamId,
      seq: event.seq,
    );
  }
}
