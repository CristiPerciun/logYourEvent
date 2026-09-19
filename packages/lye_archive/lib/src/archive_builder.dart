import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:lye_core/lye_core.dart';
import 'package:meta/meta.dart';

import 'archive_row.dart';

/// Raised when a cut cannot be turned into archives.
class ArchiveBuildException implements Exception {
  ArchiveBuildException(this.message);

  final String message;

  @override
  String toString() => 'ArchiveBuildException: $message';
}

/// One sealed archive: the bytes and what they contain.
@immutable
class BuiltArchive {
  const BuiltArchive({
    required this.manifest,
    required this.bytes,
    required this.uncompressedSize,
  });

  final LyeArchiveManifest manifest;
  final Uint8List bytes;

  /// Sum of the member sizes before compression.
  final int uncompressedSize;

  /// Digest of the bytes handed over. It is not in the manifest, because the
  /// manifest travels inside these very bytes: it belongs to whoever stores
  /// them.
  String get zipSha256 => HashChain.digestBytesHex(bytes);

  String get fileName => manifest.fileName;

  int get compressedSize => bytes.length;

  @override
  String toString() =>
      'BuiltArchive($fileName ${manifest.eventCount} events $compressedSize B)';
}

/// Builds the ZIP packages of one subject chain (ADR-009).
///
/// The rows must be contiguous in the chain and in order. The builder fills
/// a package until the **compressed** size would pass [maxBytes], seals it,
/// and opens the next part from the following sequence number, so that the
/// ranges of two consecutive parts touch without overlapping.
///
/// The result is deterministic: members are written in a fixed order, with a
/// fixed modification time, so the same rows always produce the same bytes.
class ArchiveBuilder {
  ArchiveBuilder({
    this.maxBytes = defaultMaxBytes,
    this.signer,
    this.compressionLevel = DeflateLevel.bestCompression,
    String Function()? newArchiveId,
  }) : _newArchiveId = newArchiveId ?? _uuid.generate {
    if (maxBytes < minMaxBytes) {
      throw ArgumentError.value(maxBytes, 'maxBytes', 'too small to hold one');
    }
  }

  /// Eight mebibytes: the cap the consumer asked for.
  static const int defaultMaxBytes = 8 * 1024 * 1024;

  /// Below this a package could not even hold its own manifest.
  static const int minMaxBytes = 8 * 1024;

  static final UuidV7 _uuid = UuidV7();

  final int maxBytes;
  final LyeSigner? signer;
  final int compressionLevel;
  final String Function() _newArchiveId;

  /// Cuts [rows] into as many archives as the size cap requires.
  ///
  /// Returns an empty list when there is nothing to archive: a day without
  /// activity produces no file at all.
  List<BuiltArchive> build({
    required List<ArchiveRow> rows,
    required ArchiveCut cut,
  }) {
    if (rows.isEmpty) return const <BuiltArchive>[];
    _assertContiguous(rows, cut);

    final built = <BuiltArchive>[];
    var remaining = rows;
    var archiveSeq = cut.archiveSeq;
    var part = cut.part;
    var prevArchiveHash = cut.prevArchiveHash;
    var prevChainHash = cut.prevChainHash;

    while (remaining.isNotEmpty) {
      // The identifier is minted before measuring, and the real chain
      // hashes are used: a probe run on genesis hashes would measure
      // sixty-four zeros, which deflate all but erases, and the sealed
      // package would then come out bigger than the cap.
      final archiveId = _newArchiveId();
      final taken = _largestPrefixThatFits(
        remaining,
        cut: cut,
        archiveId: archiveId,
        archiveSeq: archiveSeq,
        part: part,
        prevArchiveHash: prevArchiveHash,
        prevChainHash: prevChainHash,
      );
      final archive = _seal(
        rows: remaining.sublist(0, taken),
        cut: cut,
        archiveId: archiveId,
        archiveSeq: archiveSeq,
        part: part,
        prevArchiveHash: prevArchiveHash,
        prevChainHash: prevChainHash,
      );
      built.add(archive);
      prevArchiveHash = archive.manifest.archiveHash;
      prevChainHash = archive.manifest.chainHash;
      archiveSeq++;
      part++;
      remaining = remaining.sublist(taken);
    }
    return built;
  }

  void _assertContiguous(List<ArchiveRow> rows, ArchiveCut cut) {
    for (var i = 1; i < rows.length; i++) {
      if (rows[i].chainSeq != rows[i - 1].chainSeq + 1) {
        throw ArchiveBuildException(
          'rows are not contiguous: #${rows[i - 1].chainSeq} is followed by '
          '#${rows[i].chainSeq}',
        );
      }
    }
    for (final row in rows) {
      if (row.event.subjectRef != cut.subjectRef ||
          row.event.subjectType != cut.subjectType) {
        throw ArchiveBuildException(
          'row #${row.chainSeq} belongs to '
          '${row.event.subjectType.name}:${row.event.subjectRef}, not to '
          '${cut.subjectType.name}:${cut.subjectRef}',
        );
      }
      if (row.event.retention != cut.retention) {
        throw ArchiveBuildException(
          'row #${row.chainSeq} is ${row.event.retention.name}, not '
          '${cut.retention.name}',
        );
      }
      if (row.event.schema != LyeCsvSchema.version) {
        throw ArchiveBuildException(
          'row #${row.chainSeq} is ${row.event.schema}, this builder writes '
          '${LyeCsvSchema.version}',
        );
      }
    }
  }

  /// How many of [rows] fit into one package, at least one.
  int _largestPrefixThatFits(
    List<ArchiveRow> rows, {
    required ArchiveCut cut,
    required String archiveId,
    required int archiveSeq,
    required int part,
    required String prevArchiveHash,
    required String prevChainHash,
  }) {
    int measure(int count) => _seal(
      rows: rows.sublist(0, count),
      cut: cut,
      archiveId: archiveId,
      archiveSeq: archiveSeq,
      part: part,
      prevArchiveHash: prevArchiveHash,
      prevChainHash: prevChainHash,
    ).compressedSize;

    if (measure(rows.length) <= maxBytes) return rows.length;

    // Seed the search with the ratio measured on the whole slice: the first
    // probe is then usually within a few percent of the answer.
    var lo = 1;
    var hi = rows.length - 1;
    var best = 0;
    var probe = (rows.length * maxBytes / measure(rows.length))
        .floor()
        .clamp(1, hi);
    while (lo <= hi) {
      if (measure(probe) <= maxBytes) {
        best = probe;
        lo = probe + 1;
      } else {
        hi = probe - 1;
      }
      probe = lo + ((hi - lo) >> 1);
    }
    if (best == 0) {
      throw ArchiveBuildException(
        'a single event does not fit in $maxBytes bytes: raise the cap',
      );
    }
    return best;
  }

  BuiltArchive _seal({
    required List<ArchiveRow> rows,
    required ArchiveCut cut,
    required String archiveId,
    required int archiveSeq,
    required int part,
    required String prevArchiveHash,
    required String prevChainHash,
  }) {
    final members = _members(rows, cut, part);
    final manifest = _manifest(
      rows: rows,
      cut: cut,
      members: members.descriptors,
      archiveSeq: archiveSeq,
      part: part,
      prevArchiveHash: prevArchiveHash,
      prevChainHash: prevChainHash,
      archiveId: archiveId,
    );
    final sealed = signer == null ? manifest : manifest.signedWith(signer!);
    final bytes = _encode(members.files, sealed, cut);
    return BuiltArchive(
      manifest: sealed,
      bytes: bytes,
      uncompressedSize: members.descriptors.fold<int>(
        0,
        (int sum, LyeArchiveMember m) => sum + m.bytes,
      ),
    );
  }

  /// Renders the rows into a single CSV, **in chain order**.
  ///
  /// One member and not one per stream: the chain accumulator is folded in
  /// the order the events were made durable, and that order has to be
  /// recoverable by whoever verifies the package. The position in the chain
  /// is not a field of the event — it is assigned by the store, after the
  /// row was sealed — so the only way to carry it is the order of the file.
  /// Splitting per stream would put the rows of two processes side by side
  /// with no way to say which came first.
  _Members _members(List<ArchiveRow> rows, ArchiveCut cut, int part) {
    final buffer = StringBuffer(LyeCsv.header);
    for (final row in rows) {
      buffer.write(row.row);
    }
    final data = utf8.encode(buffer.toString());
    final compactDay = cut.day.replaceAll('-', '');
    final path =
        'events/lye-$compactDay-${part.toString().padLeft(4, '0')}.csv';
    return _Members(
      files: <ArchiveFile>[ArchiveFile.bytes(path, data)],
      descriptors: <LyeArchiveMember>[
        LyeArchiveMember(
          path: path,
          sha256: HashChain.digestBytesHex(data),
          rows: rows.length,
          bytes: data.length,
        ),
      ],
    );
  }

  LyeArchiveManifest _manifest({
    required List<ArchiveRow> rows,
    required ArchiveCut cut,
    required List<LyeArchiveMember> members,
    required int archiveSeq,
    required int part,
    required String prevArchiveHash,
    required String prevChainHash,
    required String archiveId,
  }) {
    final chainHash = SubjectChain.fold(
      rows.map((ArchiveRow r) => r.event.rowHash),
      from: prevChainHash,
    );

    final organizations = <String>{};
    final levels = <String, int>{};
    final streamSpans = <String, List<int>>{};
    DateTime? occurredFrom;
    DateTime? occurredTo;
    var lateCount = 0;
    DateTime? lateOldest;

    for (final row in rows) {
      final event = row.event;
      if (event.tenantId.isNotEmpty) organizations.add(event.tenantId);
      if (event.partnerId.isNotEmpty) organizations.add(event.partnerId);
      levels[event.level.name] = (levels[event.level.name] ?? 0) + 1;
      final span = streamSpans.putIfAbsent(
        event.streamId,
        () => <int>[event.seq, event.seq, 0],
      );
      if (event.seq < span[0]) span[0] = event.seq;
      if (event.seq > span[1]) span[1] = event.seq;
      span[2]++;
      if (occurredFrom == null || event.occurredAt.isBefore(occurredFrom)) {
        occurredFrom = event.occurredAt;
      }
      if (occurredTo == null || event.occurredAt.isAfter(occurredTo)) {
        occurredTo = event.occurredAt;
      }
      final previousCut = cut.previousCutAt;
      if (previousCut != null && event.occurredAt.isBefore(previousCut)) {
        lateCount++;
        if (lateOldest == null || event.occurredAt.isBefore(lateOldest)) {
          lateOldest = event.occurredAt;
        }
      }
    }

    final streamIds = streamSpans.keys.toList()..sort();
    return LyeArchiveManifest(
      archiveId: archiveId,
      subjectType: cut.subjectType,
      subjectRef: cut.subjectRef,
      homeOrgId: cut.homeOrgId,
      partnerId: cut.partnerId,
      organizations: organizations.toList()..sort(),
      retention: cut.retention,
      archiveSeq: archiveSeq,
      part: part,
      day: cut.day,
      cutAt: cut.cutAt,
      fromSeq: rows.first.chainSeq,
      toSeq: rows.last.chainSeq,
      eventCount: rows.length,
      occurredFrom: occurredFrom,
      occurredTo: occurredTo,
      expiresAt: cut.expiresAt,
      lateEventCount: lateCount,
      lateOldestOccurredAt: lateOldest,
      levels: levels,
      streams: <LyeArchiveStream>[
        for (final id in streamIds)
          LyeArchiveStream(
            streamId: id,
            firstSeq: streamSpans[id]![0],
            lastSeq: streamSpans[id]![1],
            rows: streamSpans[id]![2],
          ),
      ],
      members: members,
      prevArchiveHash: prevArchiveHash,
      prevChainHash: prevChainHash,
      chainHash: chainHash,
    );
  }

  Uint8List _encode(
    List<ArchiveFile> members,
    LyeArchiveManifest manifest,
    ArchiveCut cut,
  ) {
    final archive = Archive();
    archive.add(ArchiveFile.string('manifest.json', manifest.toJsonText()));
    for (final member in members) {
      archive.add(member);
    }
    archive.add(ArchiveFile.string('README.txt', _readme(manifest)));
    return ZipEncoder().encodeBytes(
      archive,
      level: compressionLevel,
      // A fixed modification time is what makes the package reproducible.
      modified: cut.cutAt,
    );
  }

  static String _readme(LyeArchiveManifest manifest) {
    return '''
JURNAL ${manifest.subjectType.name.toUpperCase()} ${manifest.subjectRef}
clasa / класс: ${manifest.retention.name}
interval / интервал: #${manifest.fromSeq}-#${manifest.toSeq} (${manifest.eventCount})
creat / создан: ${manifest.day}

RO  Acest pachet contine evenimente in format CSV ${manifest.eventSchema},
    impreuna cu manifest.json semnat. Pentru verificare:
        lye verify-archive <acest fisier>
    Verificarea recalculeaza amprenta fiecarui rand, lantul contului si
    legatura cu pachetul precedent. Nu este nevoie de baza de date.

RU  Этот пакет содержит события в формате CSV ${manifest.eventSchema} и
    подписанный manifest.json. Для проверки:
        lye verify-archive <этот файл>
    Проверка пересчитывает хэш каждой строки, цепочку учётной записи и
    связь с предыдущим пакетом. База данных не требуется.

manifest: ${manifest.schema}
generator: ${manifest.generator}
''';
  }
}

@immutable
class _Members {
  const _Members({required this.files, required this.descriptors});

  final List<ArchiveFile> files;
  final List<LyeArchiveMember> descriptors;
}
