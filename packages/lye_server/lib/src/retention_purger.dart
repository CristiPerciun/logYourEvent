import 'dart:io';

import 'package:lye_core/lye_core.dart';
import 'package:lye_io/lye_io.dart';
import 'package:path/path.dart' as p;

/// How long each retention class is kept (§6.6 of the architecture
/// document: application 6 months, access 12, security 24).
class RetentionDurations {
  const RetentionDurations({
    this.application = const Duration(days: 183),
    this.access = const Duration(days: 366),
    this.security = const Duration(days: 731),
  });

  final Duration application;
  final Duration access;
  final Duration security;

  Duration of(LyeRetention retention) {
    switch (retention) {
      case LyeRetention.application:
        return application;
      case LyeRetention.access:
        return access;
      case LyeRetention.security:
        return security;
    }
  }

  static const RetentionDurations standard = RetentionDurations();
}

/// One file the purger decided about.
class PurgeDecision {
  PurgeDecision({
    required this.path,
    required this.expired,
    required this.reason,
  });

  final String path;
  final bool expired;
  final String reason;
}

/// Removes exported files whose every row is past its retention.
///
/// Files are the unit of deletion because rows are chained: removing rows
/// would break the hashes of the survivors. A file expires when its newest
/// row, under the longest retention class it contains, is older than now.
/// Deletion proceeds from the oldest file of a stream and stops at the first
/// file still alive, so what remains is always a contiguous tail that the
/// verifier reports as a `partial_stream` rather than as damage. Heads
/// survive in the anchors.
class RetentionPurger {
  RetentionPurger({
    required this.root,
    this.durations = RetentionDurations.standard,
    this.recorder,
    LyeClock? clock,
  }) : clock = clock ?? const SystemClock();

  final String root;
  final RetentionDurations durations;
  final LyeRecorder? recorder;
  final LyeClock clock;

  /// Decides without deleting.
  Future<List<PurgeDecision>> plan() async {
    final now = clock.now();
    final decisions = <PurgeDecision>[];
    final rootDir = Directory(root);
    if (!await rootDir.exists()) return decisions;
    final streamDirs = <String>{};
    await for (final entity in rootDir.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is File && ExportLayout.isCsvName(p.basename(entity.path))) {
        streamDirs.add(entity.parent.path);
      }
    }
    for (final dir in streamDirs) {
      final files = await CsvFileSink.listCsvFiles(Directory(dir));
      for (final file in files) {
        final events = LyeCsv.decode(await file.readAsString());
        if (events.isEmpty) {
          decisions.add(
            PurgeDecision(
              path: file.path,
              expired: false,
              reason: 'empty file',
            ),
          );
          break;
        }
        var expiresAt = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
        for (final event in events) {
          final candidate = event.occurredAt.add(durations.of(event.retention));
          if (candidate.isAfter(expiresAt)) expiresAt = candidate;
        }
        final expired = expiresAt.isBefore(now);
        decisions.add(
          PurgeDecision(
            path: file.path,
            expired: expired,
            reason: 'expires ${formatTimestampUtc(expiresAt)}',
          ),
        );
        if (!expired) break; // keep the tail contiguous
      }
    }
    return decisions;
  }

  /// Deletes the expired files (and their manifests) found by [plan].
  Future<List<PurgeDecision>> purge() async {
    final decisions = await plan();
    var removed = 0;
    for (final decision in decisions.where((PurgeDecision d) => d.expired)) {
      final file = File(decision.path);
      final manifest = File(
        p.join(
          file.parent.path,
          ExportLayout.manifestNameFor(p.basename(file.path)),
        ),
      );
      if (await file.exists()) await file.delete();
      if (await manifest.exists()) await manifest.delete();
      removed++;
    }
    if (removed > 0) {
      await recorder?.point(
        LyeCategory.system,
        LyeActions.retentionPurged,
        outcome: LyeOutcome.ok,
        attrs: <String, Object?>{'files': removed},
      );
    }
    return decisions;
  }
}
