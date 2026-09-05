import 'dart:convert';
import 'dart:io';

import 'package:lye_core/lye_core.dart';
import 'package:path/path.dart' as p;

import 'csv_file_sink.dart';
import 'export_layout.dart';

/// Verification of one CSV file and its manifest.
class FileReport {
  FileReport({
    required this.path,
    required this.manifest,
    required this.events,
    required this.problems,
  });

  final String path;
  final LyeManifest? manifest;
  final List<LyeEvent> events;
  final List<ChainProblem> problems;

  bool get ok => problems.isEmpty;
}

/// Verification of one stream directory.
class StreamReport {
  StreamReport({
    required this.streamId,
    required this.files,
    required this.problems,
    required this.warnings,
  });

  final String streamId;
  final List<FileReport> files;

  /// Cross-file problems (links between files, manifests, gaps).
  final List<ChainProblem> problems;

  /// Non-fatal observations (a stream whose oldest file was purged...).
  final List<ChainProblem> warnings;

  int get eventCount =>
      files.fold(0, (int n, FileReport f) => n + f.events.length);

  bool get ok => problems.isEmpty && files.every((FileReport f) => f.ok);

  int? get firstSeq => files.isEmpty || files.first.events.isEmpty
      ? null
      : files.first.events.first.seq;

  int? get lastSeq => files.isEmpty || files.last.events.isEmpty
      ? null
      : files.last.events.last.seq;

  String? get headHash => files.isEmpty || files.last.events.isEmpty
      ? null
      : files.last.events.last.rowHash;

  List<ChainProblem> get allProblems => <ChainProblem>[
    for (final file in files) ...file.problems,
    ...problems,
  ];
}

/// Verification of a whole export directory.
class DirectoryReport {
  DirectoryReport({
    required this.root,
    required this.streams,
    required this.problems,
  });

  final String root;
  final List<StreamReport> streams;

  /// Problems spanning streams (epoch links).
  final List<ChainProblem> problems;

  bool get ok => problems.isEmpty && streams.every((StreamReport s) => s.ok);

  int get eventCount =>
      streams.fold(0, (int n, StreamReport s) => n + s.eventCount);

  int get problemCount =>
      problems.length +
      streams.fold(0, (int n, StreamReport s) => n + s.allProblems.length);

  /// Human-readable summary.
  String render() {
    final out = StringBuffer();
    out.writeln('LYE verification of $root');
    out.writeln(
      'streams: ${streams.length}, events: $eventCount, '
      'result: ${ok ? 'OK' : 'BROKEN ($problemCount problems)'}',
    );
    for (final stream in streams) {
      out.writeln('');
      out.writeln(
        '- ${stream.streamId}: ${stream.files.length} files, '
        '${stream.eventCount} events, seq ${stream.firstSeq ?? '-'}..${stream.lastSeq ?? '-'}, '
        '${stream.ok ? 'OK' : 'BROKEN'}',
      );
      if (stream.headHash != null) out.writeln('  head: ${stream.headHash}');
      for (final file in stream.files) {
        final name = p.basename(file.path);
        final status = file.ok
            ? 'ok'
            : file.problems.map((ChainProblem x) => x.code).join(',');
        out.writeln(
          '  ${file.ok ? ' ' : '!'} $name (${file.events.length} events) $status',
        );
        for (final problem in file.problems) {
          out.writeln('      $problem');
        }
      }
      for (final problem in stream.problems) {
        out.writeln('  ! $problem');
      }
      for (final warning in stream.warnings) {
        out.writeln('  ~ $warning');
      }
    }
    for (final problem in problems) {
      out.writeln('! $problem');
    }
    return out.toString();
  }
}

/// Recomputes every hash of every file of every stream under a directory.
///
/// Checks: file digest and size against the manifest, chain inside each file,
/// links between consecutive files, manifest chain, missing manifests, and
/// the `lye.stream.start` link between epochs of the same node when both
/// epochs are present.
class DirectoryVerifier {
  DirectoryVerifier({this.signer});

  /// When given, every manifest signature is verified against it.
  final LyeSigner? signer;

  Future<DirectoryReport> verify(String root) async {
    final streamDirs = await _findStreamDirectories(Directory(root));
    final streams = <StreamReport>[];
    for (final dir in streamDirs) {
      streams.add(await verifyStream(root, dir));
    }
    streams.sort(
      (StreamReport a, StreamReport b) => a.streamId.compareTo(b.streamId),
    );
    return DirectoryReport(
      root: root,
      streams: streams,
      problems: _checkEpochLinks(streams),
    );
  }

  /// Verifies one stream directory.
  Future<StreamReport> verifyStream(String root, Directory dir) async {
    final streamId = ExportLayout.streamIdFromPath(root, dir.path);
    final files = <FileReport>[];
    final problems = <ChainProblem>[];
    final warnings = <ChainProblem>[];
    var prevManifestHash = HashChain.genesisHex;
    String? expectedPrevHash;
    int? expectedSeq;

    final csvFiles = await CsvFileSink.listCsvFiles(dir);
    for (final file in csvFiles) {
      final name = p.basename(file.path);
      final fileProblems = <ChainProblem>[];
      final bytes = await file.readAsBytes();
      var events = <LyeEvent>[];
      try {
        events = LyeCsv.decode(utf8.decode(bytes));
      } on FormatException catch (e) {
        fileProblems.add(ChainProblem(0, 'unreadable', e.message));
      }
      LyeManifest? manifest;
      final manifestFile = File(
        p.join(dir.path, ExportLayout.manifestNameFor(name)),
      );
      if (await manifestFile.exists()) {
        try {
          manifest = LyeManifest.fromJsonText(
            await manifestFile.readAsString(),
          );
        } on FormatException catch (e) {
          fileProblems.add(ChainProblem(0, 'manifest_unreadable', e.message));
        }
      } else {
        fileProblems.add(
          const ChainProblem(0, 'manifest_missing', 'no manifest sidecar'),
        );
      }

      if (manifest != null) {
        // The first surviving file of a purged stream links to a manifest
        // that no longer exists: its link is checked only when the stream
        // starts at genesis. The missing prefix is reported as a warning
        // below (`partial_stream`), and the anchors keep the old heads.
        final firstOfStream = files.isEmpty;
        final startsAtGenesis =
            manifest.firstSeq == 1 && manifest.prevHash == HashChain.genesisHex;
        fileProblems.addAll(
          LyeManifest.check(
            manifest,
            fileBytes: bytes,
            events: events,
            signer: signer,
            expectedPrevManifestHash: firstOfStream && !startsAtGenesis
                ? null
                : prevManifestHash,
          ),
        );
        if (manifest.streamId != streamId) {
          fileProblems.add(
            ChainProblem(
              0,
              'stream_mismatch',
              'manifest is for ${manifest.streamId}, directory is $streamId',
            ),
          );
        }
        prevManifestHash = manifest.manifestHash;
      } else if (events.isNotEmpty) {
        // No manifest: still verify the rows themselves.
        fileProblems.addAll(
          ChainVerifier.verify(
            events,
            expectedStreamId: streamId,
            expectedPrevHash: expectedPrevHash ?? events.first.prevHash,
            expectedFirstSeq: expectedSeq ?? events.first.seq,
          ).problems,
        );
      }

      if (events.isNotEmpty) {
        final first = events.first;
        if (expectedSeq == null) {
          if (first.seq != 1 || first.prevHash != HashChain.genesisHex) {
            warnings.add(
              ChainProblem(
                first.seq,
                'partial_stream',
                'stream does not start at genesis: older files were purged or are elsewhere',
              ),
            );
          }
        } else {
          if (first.seq != expectedSeq) {
            problems.add(
              ChainProblem(
                first.seq,
                'file_seq_gap',
                '$name starts at seq ${first.seq}, expected $expectedSeq',
              ),
            );
          }
          if (first.prevHash != expectedPrevHash) {
            problems.add(
              ChainProblem(
                first.seq,
                'file_link_mismatch',
                '$name does not link to the head of the previous file',
              ),
            );
          }
        }
        expectedSeq = events.last.seq + 1;
        expectedPrevHash = events.last.rowHash;
      }
      files.add(
        FileReport(
          path: file.path,
          manifest: manifest,
          events: events,
          problems: fileProblems,
        ),
      );
    }

    // Manifests without a CSV.
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (!name.endsWith('.manifest.json')) continue;
      final csv = File(
        p.join(
          dir.path,
          p.setExtension(name.replaceAll('.manifest.json', '.csv'), '.csv'),
        ),
      );
      if (!await csv.exists()) {
        problems.add(ChainProblem(0, 'file_missing', '$name has no CSV file'));
      }
    }

    return StreamReport(
      streamId: streamId,
      files: files,
      problems: problems,
      warnings: warnings,
    );
  }

  List<ChainProblem> _checkEpochLinks(List<StreamReport> streams) {
    final heads = <String, StreamReport>{
      for (final s in streams) s.streamId: s,
    };
    final problems = <ChainProblem>[];
    for (final stream in streams) {
      final first = stream.files.isEmpty || stream.files.first.events.isEmpty
          ? null
          : stream.files.first.events.first;
      if (first == null || first.action != LyeActions.streamStart) continue;
      final Object? decoded;
      try {
        decoded = jsonDecode(first.attrs);
      } on FormatException {
        continue;
      }
      if (decoded is! Map) continue;
      final prevStream = decoded['prev_stream_id'];
      final prevHead = decoded['prev_head'];
      final prevSeq = decoded['prev_seq'];
      if (prevStream is! String || prevHead is! String) continue;
      final previous = heads[prevStream];
      if (previous == null) continue;
      if (previous.headHash != prevHead || previous.lastSeq != prevSeq) {
        problems.add(
          ChainProblem(
            1,
            'epoch_link_mismatch',
            '${stream.streamId} claims $prevStream ended at #$prevSeq $prevHead, '
                'but its files end at #${previous.lastSeq} ${previous.headHash}',
          ),
        );
      }
    }
    return problems;
  }

  Future<List<Directory>> _findStreamDirectories(Directory root) async {
    final result = <Directory>[];
    if (!await root.exists()) return result;
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is File && ExportLayout.isCsvName(p.basename(entity.path))) {
        final dir = entity.parent;
        if (!result.any((Directory d) => d.path == dir.path)) result.add(dir);
      }
    }
    return result;
  }
}
