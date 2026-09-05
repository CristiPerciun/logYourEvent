import 'package:lye_core/lye_core.dart';

import 'csv_file_sink.dart';

/// Result of one export run.
class ExportRun {
  ExportRun({
    required this.eventsWritten,
    required this.eventsSkipped,
    required this.manifests,
  });

  /// Events appended to CSV files.
  final int eventsWritten;

  /// Pending events that were already on disk (an earlier run crashed
  /// between writing and marking) and were only marked.
  final int eventsSkipped;

  /// Manifests sealed during the run.
  final List<LyeManifest> manifests;
}

/// Moves pending events from a [LyeStore] to CSV files, stream by stream.
///
/// "Pending" means not yet handed to the next hop: for a server store that
/// is the daily export, for a desktop client it is the local archive. Events
/// are marked in the store only after they are on disk and flushed, and a
/// resumed run skips what an interrupted one already wrote, so a crash at any
/// point produces at most a repeated mark, never a lost or duplicated row.
class StreamExporter {
  StreamExporter({
    required this.store,
    required this.root,
    this.signer,
    this.batchSize = 1000,
    this.maxBytesPerFile = 50 * 1024 * 1024,
    LyeClock? clock,
  }) : clock = clock ?? const SystemClock();

  final LyeStore store;
  final String root;
  final LyeSigner? signer;
  final int batchSize;
  final int maxBytesPerFile;
  final LyeClock clock;

  /// Exports every pending event of every stream (or of [streamIds]).
  Future<ExportRun> exportPending({Iterable<String>? streamIds}) async {
    final ids = streamIds?.toList() ?? await store.streamIds();
    var written = 0;
    var skipped = 0;
    final manifests = <LyeManifest>[];
    for (final streamId in ids) {
      final sink = CsvFileSink(
        root: root,
        streamId: streamId,
        signer: signer,
        maxBytesPerFile: maxBytesPerFile,
        clock: clock,
      );
      await sink.open();
      try {
        while (true) {
          final pending = await store.readPending(streamId, limit: batchSize);
          if (pending.isEmpty) break;
          final marked = <String>[];
          for (final event in pending) {
            if (event.seq < sink.expectedSeq) {
              // Already on disk from an interrupted run.
              skipped++;
              marked.add(event.eventId);
              continue;
            }
            await sink.write(event);
            written++;
            marked.add(event.eventId);
          }
          await sink.flush();
          await store.markShipped(streamId, marked, clock.now());
          if (pending.length < batchSize) break;
        }
      } finally {
        await sink.close();
      }
      manifests.addAll(sink.written);
    }
    return ExportRun(
      eventsWritten: written,
      eventsSkipped: skipped,
      manifests: manifests,
    );
  }
}
