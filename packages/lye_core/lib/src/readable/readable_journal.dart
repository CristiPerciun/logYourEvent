import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../model/enums.dart';
import '../model/lye_actions.dart';
import '../model/lye_event.dart';
import '../privacy/text_sanitizer.dart';
import '../rpc/call_correlation.dart';

/// One step of what a subject did, as a person reads it (0.3.0).
///
/// Usually one event. A call is the exception: the console records
/// `rpc.call`, the server records `rpc.handle`, and for whoever reconstructs
/// what happened they are the same step. When both were recorded they meet
/// here — [event] is where the person was, [handling] is what the server
/// did with it.
@immutable
class LyeJournalStep {
  const LyeJournalStep(this.event, {this.handling});

  /// The event where the person was: for a call, the console's `rpc.call`.
  final LyeEvent event;

  /// The server's `rpc.handle` of the same call, when both were recorded.
  final LyeEvent? handling;

  DateTime get at => event.occurredAt;

  /// The outcome that counts: a failure on either side is a failure, and the
  /// server's refusal says more than the console's "it failed".
  LyeOutcome get outcome {
    final h = handling;
    if (h != null && _isFailure(h.outcome)) return h.outcome;
    return event.outcome;
  }

  bool get failed => _isFailure(outcome);

  /// The server's measure when there is one: the console's includes the
  /// network, and is usually not recorded.
  int? get durationMs => handling?.durationMs ?? event.durationMs;

  /// The error class of the side that failed, the server's first.
  String get errorClass {
    final h = handling;
    if (h != null && h.errorClass.isNotEmpty) return h.errorClass;
    return event.errorClass;
  }

  /// The attributes of [event], with those of [handling] over them: the
  /// server knows the error code, the console knows the page.
  Map<String, Object?> get attrs => <String, Object?>{
    ...attrsOf(event),
    if (handling != null) ...attrsOf(handling!),
  };

  /// The attributes of [e] as a map; empty when they are not a JSON object.
  static Map<String, Object?> attrsOf(LyeEvent e) {
    if (e.attrs.isEmpty) return const <String, Object?>{};
    try {
      final decoded = jsonDecode(e.attrs);
      if (decoded is Map) {
        return <String, Object?>{
          for (final entry in decoded.entries) entry.key.toString(): entry.value,
        };
      }
    } on FormatException {
      // Attributes that are not JSON are shown as they are by the consumer.
    }
    return const <String, Object?>{};
  }

  static bool _isFailure(LyeOutcome o) =>
      o == LyeOutcome.fail || o == LyeOutcome.denied;
}

/// One column of a journal for people: a name and how to fill it.
@immutable
class LyeJournalColumn {
  const LyeJournalColumn(this.name, this.cell);

  final String name;
  final String Function(LyeJournalStep step) cell;
}

/// A journal for people (0.3.0): **one** CSV with every step of one subject,
/// in time order, in a handful of named columns.
///
/// The signed `lye.v2` files are for the verifier: forty columns in the
/// order the row hash needs, split by retention class because each class
/// expires on its own date. Whoever has to understand what a person did
/// before an error needs the opposite: one file, the three classes together,
/// few columns with names. This is that file. It is derived from the events
/// and it is not evidence: nothing is verified on it, and it can be produced
/// again from the archives at any time.
///
/// Between the events and the rows:
/// - the same event read twice — from the hot table and from an archive, or
///   from two copies of a file — counts once (`event_id` + `row_hash`);
/// - a console `rpc.call` and the server `rpc.handle` of the same call become
///   one step: same actor, same `call_digest`, the nearest in time within
///   [joinWindow]. A handling without its call stays a step of its own, and
///   so does a call the server never received;
/// - steps are sorted by time, then stream, then sequence.
///
/// The cells belong to the consumer, which knows the areas of its product,
/// its pages and its errors. The library sanitizes every cell (one line per
/// row, no formula a spreadsheet would run) and refuses more than
/// [maxColumns] columns: a table for people that needs more is two tables.
class LyeReadableJournal {
  LyeReadableJournal(
    List<LyeJournalColumn> columns, {
    this.delimiter = ';',
    this.joinWindow = const Duration(minutes: 2),
    this.maxCellLength = 1024,
  }) : columns = List<LyeJournalColumn>.unmodifiable(columns) {
    if (columns.isEmpty) {
      throw ArgumentError.value(0, 'columns', 'a journal needs a column');
    }
    if (columns.length > maxColumns) {
      throw ArgumentError.value(
        columns.length,
        'columns',
        'a journal for people has at most $maxColumns columns',
      );
    }
    if (delimiter.length != 1 || '"\r\n'.contains(delimiter)) {
      throw ArgumentError.value(delimiter, 'delimiter', 'one plain character');
    }
  }

  /// The most columns a person reads without scrolling sideways.
  static const int maxColumns = 6;

  final List<LyeJournalColumn> columns;

  /// `;` by default: it is what a spreadsheet expects wherever the decimal
  /// separator is a comma — Romania, Moldova, Italy, Russia — and a comma
  /// there puts the whole row in the first cell.
  final String delimiter;

  /// How far apart in time the two ends of a call may be recorded. The
  /// clocks are not the same: one is the browser's.
  final Duration joinWindow;

  final int maxCellLength;

  /// The steps of [events]: duplicates removed, calls joined, in time order.
  List<LyeJournalStep> steps(Iterable<LyeEvent> events) {
    final seen = <String>{};
    final unique = <LyeEvent>[
      for (final e in events)
        if (seen.add('${e.eventId}:${e.rowHash}')) e,
    ]..sort(_byTime);

    // The handlings waiting for their call, by actor and digest.
    final waiting = <String, List<LyeEvent>>{};
    for (final e in unique) {
      final key = _joinKey(e, LyeActions.rpcHandle);
      if (key != null) waiting.putIfAbsent(key, () => <LyeEvent>[]).add(e);
    }

    final handlingOf = <String, LyeEvent>{};
    final used = <String>{};
    for (final call in unique) {
      final key = _joinKey(call, LyeActions.rpcCall);
      if (key == null) continue;
      LyeEvent? best;
      Duration? bestGap;
      for (final h in waiting[key] ?? const <LyeEvent>[]) {
        if (used.contains(h.eventId)) continue;
        final gap = h.occurredAt.difference(call.occurredAt).abs();
        if (gap > joinWindow) continue;
        if (bestGap == null || gap < bestGap) {
          best = h;
          bestGap = gap;
        }
      }
      if (best != null) {
        used.add(best.eventId);
        handlingOf[call.eventId] = best;
      }
    }

    return <LyeJournalStep>[
      for (final e in unique)
        if (!used.contains(e.eventId))
          LyeJournalStep(e, handling: handlingOf[e.eventId]),
    ];
  }

  /// The CSV text: the header, then one row per step, rows ending in CRLF.
  String render(Iterable<LyeEvent> events) {
    final out = StringBuffer()
      ..write(_row(<String>[for (final c in columns) c.name]));
    for (final step in steps(events)) {
      out.write(_row(<String>[for (final c in columns) c.cell(step)]));
    }
    return out.toString();
  }

  /// [render] as UTF-8 with a byte order mark: without it a spreadsheet
  /// reads ă, ș, ț and Cyrillic as two strange characters each.
  Uint8List encode(Iterable<LyeEvent> events) {
    return Uint8List.fromList(<int>[
      0xEF,
      0xBB,
      0xBF,
      ...utf8.encode(render(events)),
    ]);
  }

  String _row(List<String> cells) =>
      '${cells.map(_field).join(delimiter)}\r\n';

  String _field(String raw) {
    final text = LyeText.sanitize(raw, maxLength: maxCellLength);
    final quote =
        text.contains(delimiter) ||
        text.contains('"') ||
        text.startsWith(' ') ||
        text.endsWith(' ');
    return quote ? '"${text.replaceAll('"', '""')}"' : text;
  }

  /// `actor|digest` for an event of [action] that carries a call digest.
  static String? _joinKey(LyeEvent e, String action) {
    if (e.category != LyeCategory.rpc || e.action != action) return null;
    final digest = LyeJournalStep.attrsOf(e)[CallCorrelation.attrKey];
    if (digest is! String || digest.isEmpty) return null;
    return '${e.actorRef}|$digest';
  }

  static int _byTime(LyeEvent a, LyeEvent b) {
    final byTime = a.occurredAt.compareTo(b.occurredAt);
    if (byTime != 0) return byTime;
    final byStream = a.streamId.compareTo(b.streamId);
    if (byStream != 0) return byStream;
    return a.seq.compareTo(b.seq);
  }
}
