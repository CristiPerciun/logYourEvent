import 'dart:async';
import 'dart:math';

import 'package:meta/meta.dart';

import '../ids/hex.dart';

/// A unit of work inside a trace.
///
/// Spans are propagated through Dart [Zone]s: code running inside
/// `LyeRecorder.span` finds its span with [LyeSpan.current] without passing
/// it around, and every event recorded there inherits `trace_id`, `span_id`
/// and `parent_span_id`. That is what makes the lifecycle of an operation
/// reconstructible from the CSV: a tap, the provider mutation it triggered,
/// the RPC call and the error, if any, share one `trace_id`.
@immutable
class LyeSpan {
  const LyeSpan({
    required this.traceId,
    required this.spanId,
    required this.parentSpanId,
    required this.operation,
    required this.startedAt,
  });

  final String traceId;
  final String spanId;
  final String parentSpanId;
  final String operation;
  final DateTime startedAt;

  static const Symbol zoneKey = #lye_span;

  /// The span of the current zone, if any.
  static LyeSpan? get current => Zone.current[zoneKey] as LyeSpan?;

  /// Runs [body] with [span] as the current span.
  static R run<R>(LyeSpan span, R Function() body) {
    return runZoned<R>(body, zoneValues: <Object?, Object?>{zoneKey: span});
  }

  /// Runs [body] with no current span, so a span started inside it is a
  /// root with a fresh trace. Used where one process simulates another
  /// (tests, demos) or where work must not be attributed to the caller's
  /// operation (background flushes).
  static R detached<R>(R Function() body) {
    return runZoned<R>(body, zoneValues: <Object?, Object?>{zoneKey: null});
  }

  /// A child of this span.
  LyeSpan child(
    String childOperation, {
    required String spanId,
    required DateTime now,
  }) {
    return LyeSpan(
      traceId: traceId,
      spanId: spanId,
      parentSpanId: this.spanId,
      operation: childOperation,
      startedAt: now,
    );
  }
}

/// Generates 64-bit random span identifiers as 16 hex digits.
class SpanIdGenerator {
  SpanIdGenerator([Random? random]) : _random = random ?? Random.secure();

  final Random _random;

  String next() {
    final bytes = List<int>.generate(8, (_) => _random.nextInt(256));
    return bytesToHex(bytes);
  }
}
