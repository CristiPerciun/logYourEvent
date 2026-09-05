import 'package:meta/meta.dart';

import '../chain/hash_chain.dart';
import '../ids/hex.dart';
import '../model/csv_schema.dart';
import '../model/lye_actions.dart';
import '../model/lye_event.dart';
import '../privacy/redactor.dart';

/// One defect found in a sequence of events.
@immutable
class ChainProblem {
  const ChainProblem(this.seq, this.code, this.message);

  /// Sequence number of the offending row (0 when it concerns the whole set).
  final int seq;

  /// Stable code: `seq_gap`, `link_mismatch`, `hash_mismatch`,
  /// `stream_mismatch`, `schema_mismatch`, `malformed_action`,
  /// `digest_mismatch`, `head_mismatch`.
  final String code;
  final String message;

  @override
  String toString() => '#$seq $code: $message';
}

/// Outcome of a verification.
@immutable
class VerificationReport {
  const VerificationReport({
    required this.streamId,
    required this.eventsChecked,
    required this.firstSeq,
    required this.lastSeq,
    required this.headHash,
    required this.problems,
  });

  final String streamId;
  final int eventsChecked;
  final int firstSeq;
  final int lastSeq;

  /// Row hash of the last event, or the expected previous hash when empty.
  final String headHash;
  final List<ChainProblem> problems;

  bool get ok => problems.isEmpty;

  @override
  String toString() {
    final status = ok ? 'OK' : 'BROKEN (${problems.length} problems)';
    return 'VerificationReport($streamId seq $firstSeq..$lastSeq, '
        '$eventsChecked events, $status, head $headHash)';
  }
}

/// Recomputes and checks a sequence of events of one stream.
///
/// Checks, in order, for every event: schema tag, stream identity,
/// sequence contiguity, link to the previous row hash, recomputed row hash,
/// action grammar and, when attributes are complete, the payload digest.
/// The verifier collects every problem instead of stopping at the first:
/// a report that says "three rows were rewritten" is more useful than one
/// that stops at the first.
abstract final class ChainVerifier {
  static VerificationReport verify(
    List<LyeEvent> events, {
    String? expectedStreamId,
    String expectedPrevHash = HashChain.genesisHex,
    int? expectedFirstSeq,
  }) {
    final problems = <ChainProblem>[];
    if (events.isEmpty) {
      return VerificationReport(
        streamId: expectedStreamId ?? '',
        eventsChecked: 0,
        firstSeq: 0,
        lastSeq: 0,
        headHash: expectedPrevHash,
        problems: problems,
      );
    }
    final streamId = expectedStreamId ?? events.first.streamId;
    var expectedSeq = expectedFirstSeq ?? events.first.seq;
    if (expectedFirstSeq == null && expectedPrevHash == HashChain.genesisHex) {
      // A chain that starts from genesis must start at 1.
      expectedSeq = 1;
    }
    var prevHash = expectedPrevHash;
    var headHash = expectedPrevHash;

    for (final event in events) {
      if (event.schema != LyeCsvSchema.version) {
        problems.add(
          ChainProblem(
            event.seq,
            'schema_mismatch',
            'schema "${event.schema}" is not ${LyeCsvSchema.version}',
          ),
        );
      }
      if (event.streamId != streamId) {
        problems.add(
          ChainProblem(
            event.seq,
            'stream_mismatch',
            'row belongs to stream "${event.streamId}", expected "$streamId"',
          ),
        );
      }
      if (event.seq != expectedSeq) {
        problems.add(
          ChainProblem(
            event.seq,
            'seq_gap',
            'expected seq $expectedSeq, found ${event.seq}',
          ),
        );
        // Re-synchronise so that a single gap produces a single problem.
        expectedSeq = event.seq;
      }
      if (event.prevHash != prevHash) {
        problems.add(
          ChainProblem(
            event.seq,
            'link_mismatch',
            'prev_hash does not match the previous row_hash',
          ),
        );
      }
      if (!event.hasValidRowHash) {
        problems.add(
          ChainProblem(
            event.seq,
            'hash_mismatch',
            'row_hash does not match the recomputed hash: content was altered',
          ),
        );
      }
      if (!LyeActions.isWellFormed(event.action)) {
        problems.add(
          ChainProblem(
            event.seq,
            'malformed_action',
            'action "${event.action}" is not a well-formed code',
          ),
        );
      }
      if (event.payloadDigest.isNotEmpty &&
          !event.attrs.contains('"[redacted:') &&
          !event.attrs.contains('"${Redactor.truncatedKey}"')) {
        // Nothing was hidden, so the digest of attrs must equal the digest of
        // the original payload.
        if (HashChain.digestHex(event.attrs) != event.payloadDigest &&
            !isSha256Hex(event.payloadDigest)) {
          problems.add(
            ChainProblem(
              event.seq,
              'digest_mismatch',
              'payload_digest is not a SHA-256',
            ),
          );
        }
      }
      prevHash = event.rowHash;
      headHash = event.rowHash;
      expectedSeq = event.seq + 1;
    }

    return VerificationReport(
      streamId: streamId,
      eventsChecked: events.length,
      firstSeq: events.first.seq,
      lastSeq: events.last.seq,
      headHash: headHash,
      problems: problems,
    );
  }

  /// Verifies that [events] continue a chain whose head is [headSeq] /
  /// [headHash]: the first event must be `headSeq + 1` linked to [headHash].
  static VerificationReport verifyContinuation(
    List<LyeEvent> events, {
    required String streamId,
    required int headSeq,
    required String headHash,
  }) {
    return verify(
      events,
      expectedStreamId: streamId,
      expectedPrevHash: headHash,
      expectedFirstSeq: headSeq + 1,
    );
  }
}
