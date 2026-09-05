import 'dart:convert';
import 'dart:io';

import 'package:lye_core/lye_core.dart';
import 'package:path/path.dart' as p;

import 'export_layout.dart';

/// Raised when the files on disk do not form a valid chain.
class ExportIntegrityException implements Exception {
  ExportIntegrityException(
    this.message, {
    this.problems = const <ChainProblem>[],
  });

  final String message;
  final List<ChainProblem> problems;

  @override
  String toString() =>
      'ExportIntegrityException: $message ${problems.join('; ')}';
}

/// Appends the events of one stream to CSV files, one UTC day per file with
/// a size cap, and seals every finished file with a signed, chained manifest.
///
/// The sink enforces contiguity: an event must be `expectedSeq` linked to
/// `expectedPrevHash`, otherwise it is refused. On [open] it scans the
/// existing files of the stream, finalises a file left without manifest by a
/// crash (after verifying it), and resumes where the last file ended.
class CsvFileSink {
  CsvFileSink({
    required this.root,
    required this.streamId,
    this.maxBytesPerFile = 50 * 1024 * 1024,
    this.signer,
    LyeClock? clock,
  }) : clock = clock ?? const SystemClock();

  final String root;
  final String streamId;
  final int maxBytesPerFile;
  final LyeSigner? signer;
  final LyeClock clock;

  /// Manifests written by this sink instance, in order.
  final List<LyeManifest> written = <LyeManifest>[];

  IOSink? _sink;
  File? _file;
  int _bytes = 0;
  String _day = '';
  int _part = 0;
  int _fileFirstSeq = 0;
  int _fileLastSeq = 0;
  int _fileCount = 0;
  String _filePrevHash = '';
  String _fileHeadHash = '';
  DateTime? _fileFirstAt;
  DateTime? _fileLastAt;

  String _lastDay = '';
  int _lastPart = 0;
  int _expectedSeq = 1;
  String _expectedPrevHash = HashChain.genesisHex;
  String _prevManifestHash = HashChain.genesisHex;
  bool _open = false;

  /// Directory of the stream.
  Directory get directory => Directory(ExportLayout.streamPath(root, streamId));

  /// Sequence number the next written event must have.
  int get expectedSeq => _expectedSeq;

  /// Row hash the next written event must link to.
  String get expectedPrevHash => _expectedPrevHash;

  /// Hash of the last manifest of the stream (genesis when none).
  String get prevManifestHash => _prevManifestHash;

  bool get isOpen => _open;

  /// Scans existing files and prepares to append.
  Future<void> open() async {
    if (_open) return;
    await directory.create(recursive: true);
    final csvFiles = await listCsvFiles(directory);
    for (final file in csvFiles) {
      final name = p.basename(file.path);
      final parsed = ExportLayout.parseCsvName(name)!;
      final manifestFile = File(
        p.join(directory.path, ExportLayout.manifestNameFor(name)),
      );
      LyeManifest manifest;
      if (await manifestFile.exists()) {
        manifest = LyeManifest.fromJsonText(await manifestFile.readAsString());
      } else {
        manifest = await _recover(file, name);
        await manifestFile.writeAsString(manifest.toJsonText(), flush: true);
      }
      if (manifest.prevManifestHash != _prevManifestHash) {
        throw ExportIntegrityException(
          'manifest of $name does not link to the previous manifest',
        );
      }
      _prevManifestHash = manifest.manifestHash;
      _expectedSeq = manifest.lastSeq + 1;
      _expectedPrevHash = manifest.headHash;
      _lastDay = parsed.day;
      _lastPart = parsed.part;
    }
    _open = true;
  }

  /// Rebuilds the manifest of a CSV left without one. The file must be a
  /// valid continuation of the chain, otherwise nothing is written and the
  /// exception carries the problems.
  Future<LyeManifest> _recover(File file, String name) async {
    final bytes = await file.readAsBytes();
    final List<LyeEvent> events;
    try {
      events = LyeCsv.decode(utf8.decode(bytes));
    } on FormatException catch (e) {
      throw ExportIntegrityException('cannot recover $name: ${e.message}');
    }
    if (events.isEmpty) {
      throw ExportIntegrityException(
        'cannot recover $name: file has no events',
      );
    }
    final report = ChainVerifier.verify(
      events,
      expectedStreamId: streamId,
      expectedPrevHash: _expectedPrevHash,
      expectedFirstSeq: _expectedSeq,
    );
    if (!report.ok) {
      throw ExportIntegrityException(
        'cannot recover $name',
        problems: report.problems,
      );
    }
    return LyeManifest.describe(
      file: name,
      fileBytes: bytes,
      events: events,
      prevManifestHash: _prevManifestHash,
      generatedAt: clock.now(),
      signer: signer,
    );
  }

  /// Appends one event. Throws [ChainIntegrityException] if it does not
  /// continue the chain on disk.
  Future<void> write(LyeEvent event) async {
    if (!_open) throw StateError('CsvFileSink is not open');
    if (event.streamId != streamId) {
      throw ChainIntegrityException(
        'event belongs to ${event.streamId}',
        streamId: streamId,
        seq: event.seq,
      );
    }
    if (event.seq != _expectedSeq) {
      throw ChainIntegrityException(
        'expected seq $_expectedSeq',
        streamId: streamId,
        seq: event.seq,
      );
    }
    if (event.prevHash != _expectedPrevHash) {
      throw ChainIntegrityException(
        'prev_hash does not match the file head',
        streamId: streamId,
        seq: event.seq,
      );
    }
    if (!event.hasValidRowHash) {
      throw ChainIntegrityException(
        'row_hash does not match the content',
        streamId: streamId,
        seq: event.seq,
      );
    }
    final day = ExportLayout.dayOf(event.occurredAt);
    if (_sink != null && (day != _day || _bytes >= maxBytesPerFile)) {
      await rotate();
    }
    if (_sink == null) {
      await _openNewFile(day);
      _fileFirstSeq = event.seq;
      _filePrevHash = event.prevHash;
      _fileFirstAt = event.occurredAt;
    }
    final row = LyeCsv.encodeRow(event);
    _sink!.write(row);
    _bytes += utf8.encode(row).length;
    _fileLastSeq = event.seq;
    _fileHeadHash = event.rowHash;
    _fileLastAt = event.occurredAt;
    _fileCount++;
    _expectedSeq = event.seq + 1;
    _expectedPrevHash = event.rowHash;
  }

  /// Pushes buffered rows to the operating system.
  Future<void> flush() async {
    await _sink?.flush();
  }

  /// Closes the current file and writes its manifest. Returns null when no
  /// file is open.
  Future<LyeManifest?> rotate() async {
    final sink = _sink;
    final file = _file;
    if (sink == null || file == null) return null;
    await sink.flush();
    await sink.close();
    _sink = null;
    _file = null;
    final bytes = await file.readAsBytes();
    final manifest = LyeManifest(
      file: p.basename(file.path),
      fileSha256: HashChain.digestBytesHex(bytes),
      fileSize: bytes.length,
      streamId: streamId,
      firstSeq: _fileFirstSeq,
      lastSeq: _fileLastSeq,
      count: _fileCount,
      firstOccurredAt: _fileFirstAt,
      lastOccurredAt: _fileLastAt,
      prevHash: _filePrevHash,
      headHash: _fileHeadHash,
      prevManifestHash: _prevManifestHash,
      generatedAt: clock.now(),
    );
    final sealed = signer == null ? manifest : manifest.signedWith(signer!);
    final manifestFile = File(
      p.join(
        directory.path,
        ExportLayout.manifestNameFor(p.basename(file.path)),
      ),
    );
    await manifestFile.writeAsString(sealed.toJsonText(), flush: true);
    _prevManifestHash = sealed.manifestHash;
    written.add(sealed);
    _fileCount = 0;
    _bytes = 0;
    return sealed;
  }

  /// Rotates and marks the sink closed.
  Future<void> close() async {
    await rotate();
    _open = false;
  }

  Future<void> _openNewFile(String day) async {
    final part = day == _lastDay ? _lastPart + 1 : 1;
    _day = day;
    _part = part;
    _lastDay = day;
    _lastPart = part;
    final file = File(p.join(directory.path, ExportLayout.csvName(day, part)));
    if (await file.exists()) {
      throw ExportIntegrityException('file ${file.path} already exists');
    }
    _file = file;
    _sink = file.openWrite(encoding: utf8);
    final header = LyeCsv.header;
    _sink!.write(header);
    _bytes = utf8.encode(header).length;
  }

  /// CSV files of a stream directory, in chain order.
  static Future<List<File>> listCsvFiles(Directory directory) async {
    if (!await directory.exists()) return <File>[];
    final files = <File>[];
    await for (final entity in directory.list()) {
      if (entity is File && ExportLayout.isCsvName(p.basename(entity.path))) {
        files.add(entity);
      }
    }
    files.sort(
      (File a, File b) => p.basename(a.path).compareTo(p.basename(b.path)),
    );
    return files;
  }

  /// Current part number, for diagnostics.
  int get currentPart => _part;
}
