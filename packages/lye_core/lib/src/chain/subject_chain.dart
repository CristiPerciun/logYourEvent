import 'package:meta/meta.dart';

import '../model/enums.dart';
import '../model/lye_event.dart';
import 'hash_chain.dart';

/// The chain of one subject and one retention class (ADR-008).
///
/// The chain of a stream proves that the trail of a *process* was not
/// altered. It cannot prove that the set of rows handed over for one
/// account is complete, because inside a server stream the events of every
/// account are interleaved: the subset of one of them is sparse, its
/// sequence numbers have holes and its `prev_hash` values point at rows
/// belonging to others.
///
/// This second chain is built where the event becomes durable, with the
/// construction of `audit.append_event`: a contiguous counter assigned
/// under a row lock, and an accumulator over the row hashes.
///
/// ```text
/// chain_hash_0 = 32 zero bytes
/// chain_hash_k = sha256(chain_hash_{k-1} || utf8(row_hash_k))
/// ```
///
/// Three chains per subject and not one, because archives are cut per
/// retention class: each archive then covers a contiguous range of a single
/// chain and verifies on its own, without the other two files.
abstract final class SubjectChain {
  /// Value of the accumulator before the first event.
  static const String genesisHex = HashChain.genesisHex;

  /// The accumulator after appending [rowHashHex] to [prevChainHashHex].
  static String next(String prevChainHashHex, String rowHashHex) {
    return HashChain.rowHashHex(prevChainHashHex, rowHashHex);
  }

  /// Folds [rowHashes] into the accumulator, starting from [from].
  static String fold(
    Iterable<String> rowHashes, {
    String from = genesisHex,
  }) {
    var hash = from;
    for (final rowHash in rowHashes) {
      hash = next(hash, rowHash);
    }
    return hash;
  }

  /// Folds the row hashes of [events], in the order given.
  static String foldEvents(
    Iterable<LyeEvent> events, {
    String from = genesisHex,
  }) {
    return fold(events.map((LyeEvent e) => e.rowHash), from: from);
  }

  /// The key of the chain an event belongs to.
  static SubjectChainKey keyOf(LyeEvent event) => SubjectChainKey(
    subjectType: event.subjectType,
    subjectRef: event.subjectRef,
    retention: event.retention,
  );
}

/// Identifies one chain: a subject and a retention class.
@immutable
class SubjectChainKey {
  const SubjectChainKey({
    required this.subjectType,
    required this.subjectRef,
    required this.retention,
  });

  final LyeSubjectType subjectType;
  final String subjectRef;
  final LyeRetention retention;

  /// Stable text form, usable as a map key or a job singleton key.
  String get id => '${subjectType.name}:$subjectRef:${retention.name}';

  @override
  bool operator ==(Object other) =>
      other is SubjectChainKey &&
      other.subjectType == subjectType &&
      other.subjectRef == subjectRef &&
      other.retention == retention;

  @override
  int get hashCode => Object.hash(subjectType, subjectRef, retention);

  @override
  String toString() => 'SubjectChainKey($id)';
}

/// Head of one subject chain: how many events it holds and where it ends.
@immutable
class SubjectChainHead {
  const SubjectChainHead({
    required this.key,
    required this.seq,
    required this.chainHash,
  });

  /// Head of a chain nobody has written to yet.
  factory SubjectChainHead.genesis(SubjectChainKey key) =>
      SubjectChainHead(key: key, seq: 0, chainHash: SubjectChain.genesisHex);

  final SubjectChainKey key;

  /// Last `chain_seq` assigned; 0 before the first event.
  final int seq;

  /// Accumulator after the last event.
  final String chainHash;

  /// The head after appending an event with [rowHashHex].
  SubjectChainHead append(String rowHashHex) => SubjectChainHead(
    key: key,
    seq: seq + 1,
    chainHash: SubjectChain.next(chainHash, rowHashHex),
  );

  @override
  String toString() => 'SubjectChainHead(${key.id} #$seq $chainHash)';
}
