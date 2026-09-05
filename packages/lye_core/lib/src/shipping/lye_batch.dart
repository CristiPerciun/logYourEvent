import 'package:meta/meta.dart';

import '../model/lye_event.dart';

/// A contiguous slice of one stream, as shipped from a client to the server.
///
/// The batch repeats the boundaries (`from_seq`, `to_seq`, `prev_hash`,
/// `head_hash`) so the receiver can check the envelope before it decodes a
/// single event, and refuse an oversize or out-of-order batch cheaply.
@immutable
class LyeBatch {
  LyeBatch._({
    required this.streamId,
    required this.fromSeq,
    required this.toSeq,
    required this.prevHash,
    required this.headHash,
    required this.events,
  });

  static const String schemaVersion = 'lye.batch.v1';

  /// Builds a batch from consecutive events of one stream. Throws
  /// [ArgumentError] when the events are empty, mixed or not contiguous.
  factory LyeBatch.fromEvents(List<LyeEvent> events) {
    if (events.isEmpty) {
      throw ArgumentError('A batch needs at least one event');
    }
    final streamId = events.first.streamId;
    for (var i = 0; i < events.length; i++) {
      final event = events[i];
      if (event.streamId != streamId) {
        throw ArgumentError('Mixed streams in batch: ${event.streamId}');
      }
      if (i > 0 && event.seq != events[i - 1].seq + 1) {
        throw ArgumentError(
          'Batch is not contiguous at seq ${event.seq} (previous ${events[i - 1].seq})',
        );
      }
    }
    return LyeBatch._(
      streamId: streamId,
      fromSeq: events.first.seq,
      toSeq: events.last.seq,
      prevHash: events.first.prevHash,
      headHash: events.last.rowHash,
      events: List<LyeEvent>.unmodifiable(events),
    );
  }

  final String streamId;
  final int fromSeq;
  final int toSeq;

  /// `prev_hash` of the first event.
  final String prevHash;

  /// `row_hash` of the last event.
  final String headHash;
  final List<LyeEvent> events;

  int get count => events.length;

  Iterable<String> get eventIds => events.map((LyeEvent e) => e.eventId);

  Map<String, Object?> toJson() => <String, Object?>{
    'schema': schemaVersion,
    'stream_id': streamId,
    'from_seq': fromSeq,
    'to_seq': toSeq,
    'prev_hash': prevHash,
    'head_hash': headHash,
    'count': count,
    'events': <Object?>[for (final event in events) event.toJson()],
  };

  /// Structural decoding: schema, envelope consistency and contiguity.
  /// Hashes are verified by the ingest handler, which also knows the head.
  static LyeBatch fromJson(Map<String, Object?> json) {
    if (json['schema'] != schemaVersion) {
      throw FormatException('Unsupported batch schema "${json['schema']}"');
    }
    final rawEvents = json['events'];
    if (rawEvents is! List) {
      throw const FormatException('Batch has no events list');
    }
    final events = <LyeEvent>[];
    for (final raw in rawEvents) {
      if (raw is! Map) {
        throw const FormatException('Batch event is not an object');
      }
      events.add(
        LyeEvent.fromJson(
          raw.map((Object? k, Object? v) => MapEntry(k.toString(), v)),
        ),
      );
    }
    final LyeBatch batch;
    try {
      batch = LyeBatch.fromEvents(events);
    } on ArgumentError catch (e) {
      throw FormatException(e.message.toString());
    }
    if (json['stream_id'] != batch.streamId ||
        _asInt(json['from_seq']) != batch.fromSeq ||
        _asInt(json['to_seq']) != batch.toSeq ||
        json['prev_hash'] != batch.prevHash ||
        json['head_hash'] != batch.headHash ||
        _asInt(json['count']) != batch.count) {
      throw const FormatException('Batch envelope does not match its events');
    }
    return batch;
  }

  static int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is String) return int.tryParse(value);
    return null;
  }
}
