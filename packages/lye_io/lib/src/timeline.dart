import 'dart:convert';
import 'dart:io';

import 'package:lye_core/lye_core.dart';
import 'package:path/path.dart' as p;

import 'csv_file_sink.dart';
import 'export_layout.dart';

/// Every event of an export directory, queryable by trace, call and actor.
///
/// The timeline is what turns a pile of CSV files into the story of one
/// operation: the tap on the client, the RPC call, the server handling, the
/// scoped transaction, every SQL statement, the audit event and the answer,
/// in time order and with their span hierarchy.
class Timeline {
  Timeline(Iterable<LyeEvent> events)
    : events = List<LyeEvent>.unmodifiable(_dedupe(events)..sort(_byTime));

  /// The same file copied twice (backups, mirrored exports) must not show
  /// an operation twice: identical rows collapse on `event_id` + `row_hash`.
  static List<LyeEvent> _dedupe(Iterable<LyeEvent> events) {
    final seen = <String>{};
    final out = <LyeEvent>[];
    for (final event in events) {
      if (seen.add('${event.eventId}:${event.rowHash}')) out.add(event);
    }
    return out;
  }

  /// All events in time order.
  final List<LyeEvent> events;

  /// Loads every CSV file under [root] (no verification: use the verifier).
  static Future<Timeline> load(String root) async {
    final all = <LyeEvent>[];
    final rootDir = Directory(root);
    if (!await rootDir.exists()) return Timeline(all);
    final dirs = <String>{};
    await for (final entity in rootDir.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is File && ExportLayout.isCsvName(p.basename(entity.path))) {
        dirs.add(entity.parent.path);
      }
    }
    for (final dir in dirs) {
      for (final file in await CsvFileSink.listCsvFiles(Directory(dir))) {
        all.addAll(LyeCsv.decode(await file.readAsString()));
      }
    }
    return Timeline(all);
  }

  static int _byTime(LyeEvent a, LyeEvent b) {
    final byTime = a.occurredAt.compareTo(b.occurredAt);
    if (byTime != 0) return byTime;
    final byStream = a.streamId.compareTo(b.streamId);
    if (byStream != 0) return byStream;
    return a.seq.compareTo(b.seq);
  }

  /// Events of one trace.
  List<LyeEvent> byTrace(String traceId) {
    return events.where((LyeEvent e) => e.traceId == traceId).toList();
  }

  /// Events of one actor in an optional window.
  List<LyeEvent> byActor(String actorRef, {DateTime? from, DateTime? to}) {
    return events.where((LyeEvent e) {
      if (e.actorRef != actorRef) return false;
      if (from != null && e.occurredAt.isBefore(from)) return false;
      if (to != null && e.occurredAt.isAfter(to)) return false;
      return true;
    }).toList();
  }

  /// Traces that carry [callDigest] in their attributes: the client trace
  /// with the `rpc.call` and the server trace with the `rpc.handle`.
  Set<String> tracesForCall(
    String callDigest, {
    Duration window = const Duration(minutes: 5),
  }) {
    final anchors = events
        .where((LyeEvent e) => _callDigestOf(e) == callDigest)
        .toList();
    if (anchors.isEmpty) return <String>{};
    final first = anchors.first.occurredAt;
    return <String>{
      for (final e in anchors)
        if (e.occurredAt.difference(first).abs() <= window) e.traceId,
    };
  }

  /// The whole operation around [traceOrCallDigest]: the events of the trace
  /// itself plus, when it contains RPC calls, the server traces that handled
  /// them (and vice versa).
  List<LyeEvent> operation(String traceOrCallDigest) {
    final traces = <String>{
      traceOrCallDigest,
      ...tracesForCall(traceOrCallDigest),
    };
    // Expand through call digests found in the collected traces.
    var changed = true;
    while (changed) {
      changed = false;
      for (final event in events) {
        if (!traces.contains(event.traceId)) continue;
        final digest = _callDigestOf(event);
        if (digest == null) continue;
        for (final t in tracesForCall(digest)) {
          if (traces.add(t)) changed = true;
        }
      }
    }
    return events.where((LyeEvent e) => traces.contains(e.traceId)).toList();
  }

  static String? _callDigestOf(LyeEvent event) {
    if (event.category != LyeCategory.rpc) return null;
    if (!event.attrs.contains(CallCorrelation.attrKey)) return null;
    try {
      final decoded = jsonDecode(event.attrs);
      if (decoded is Map) {
        final digest = decoded[CallCorrelation.attrKey];
        return digest is String ? digest : null;
      }
    } on FormatException {
      return null;
    }
    return null;
  }

  /// Fixed-width text rendering of [events].
  static String render(List<LyeEvent> events) {
    final out = StringBuffer();
    out.writeln(
      'occurred_at (UTC)          origin  seq    phase  action                     '
      'outcome  ms     operation                 route / component',
    );
    for (final e in events) {
      final depth = e.parentSpanId.isEmpty ? 0 : 1;
      final indent = '  ' * depth;
      out.writeln(
        '${formatTimestampUtc(e.occurredAt)} '
        '${e.origin.name.padRight(7)} '
        '${e.seq.toString().padLeft(6)} '
        '${e.phase.name.padRight(6)} '
        '$indent${e.action.padRight(26 - indent.length)} '
        '${(e.outcome == LyeOutcome.none ? '' : e.outcome.name).padRight(8)} '
        '${(e.durationMs?.toString() ?? '').padLeft(6)} '
        '${e.operation.padRight(25)} '
        '${e.route}${e.component.isEmpty ? '' : ' / ${e.component}'}'
        '${e.auditRef.isEmpty ? '' : '  audit=${e.auditRef}'}',
      );
    }
    return out.toString();
  }
}
