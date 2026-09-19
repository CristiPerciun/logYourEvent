import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:lye_core/lye_core.dart';
import 'package:meta/meta.dart';

/// What an archive holds once opened.
@immutable
class OpenedArchive {
  const OpenedArchive({
    required this.manifest,
    required this.events,
    required this.memberBytes,
    required this.readme,
  });

  final LyeArchiveManifest manifest;

  /// Every event of the package, in member order then sequence order.
  final List<LyeEvent> events;

  /// Raw bytes of each member, keyed by path inside the ZIP.
  final Map<String, Uint8List> memberBytes;

  final String readme;
}

/// Report of one archive.
@immutable
class ArchiveReport {
  const ArchiveReport({
    required this.fileName,
    required this.problems,
    this.manifest,
    this.eventCount = 0,
  });

  final String fileName;
  final LyeArchiveManifest? manifest;
  final int eventCount;
  final List<ChainProblem> problems;

  bool get ok => problems.isEmpty;

  /// Human-readable summary.
  String render() {
    final out = StringBuffer();
    final m = manifest;
    out.writeln('LYE archive $fileName');
    if (m != null) {
      out.writeln(
        'subject: ${m.subjectType.name}:${m.subjectRef}  '
        'class: ${m.retention.name}  #${m.archiveSeq} part ${m.part}',
      );
      out.writeln(
        'range: #${m.fromSeq}..#${m.toSeq} ($eventCount events)  '
        'day: ${m.day}',
      );
      out.writeln('chain: ${m.prevChainHash} -> ${m.chainHash}');
      out.writeln('archive_hash: ${m.archiveHash}');
      if (m.lateEventCount > 0) {
        out.writeln(
          'late events: ${m.lateEventCount}, oldest '
          '${m.lateOldestOccurredAt}',
        );
      }
    }
    out.writeln('result: ${ok ? 'OK' : 'BROKEN (${problems.length})'}');
    for (final problem in problems) {
      out.writeln('  ! $problem');
    }
    return out.toString();
  }
}

/// Opens and checks an archive without a database and without the other
/// archives of the same chain (ADR-009).
class ArchiveVerifier {
  ArchiveVerifier({this.signer});

  /// When given, the manifest signature is verified against it.
  final LyeSigner? signer;

  /// Reads the package. Throws [FormatException] when it is not one.
  static OpenedArchive open(List<int> zipBytes) {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(zipBytes);
    } catch (error) {
      throw FormatException('not a readable ZIP: $error');
    }
    final bytes = <String, Uint8List>{};
    for (final file in archive.files) {
      if (!file.isFile) continue;
      bytes[file.name] = Uint8List.fromList(file.readBytes() ?? <int>[]);
    }
    final manifestBytes = bytes['manifest.json'];
    if (manifestBytes == null) {
      throw const FormatException('the package has no manifest.json');
    }
    final manifest = LyeArchiveManifest.fromJsonText(utf8.decode(manifestBytes));
    final events = <LyeEvent>[];
    for (final member in manifest.members) {
      final data = bytes[member.path];
      if (data == null) continue;
      events.addAll(LyeCsv.decode(utf8.decode(data)));
    }
    final readme = bytes['README.txt'];
    return OpenedArchive(
      manifest: manifest,
      events: events,
      memberBytes: bytes,
      readme: readme == null ? '' : utf8.decode(readme),
    );
  }

  /// Verifies a package.
  ///
  /// [expectedPrevArchiveHash] and [expectedFromSeq] let a caller that knows
  /// the chain check that no archive is missing before this one; without
  /// them the package is still checked on its own.
  ArchiveReport verify(
    List<int> zipBytes, {
    String fileName = '',
    String? expectedPrevArchiveHash,
    int? expectedFromSeq,
    String? expectedZipSha256,
  }) {
    final problems = <ChainProblem>[];
    final OpenedArchive opened;
    try {
      opened = open(zipBytes);
    } on FormatException catch (e) {
      return ArchiveReport(
        fileName: fileName,
        problems: <ChainProblem>[ChainProblem(0, 'unreadable', e.message)],
      );
    }
    final manifest = opened.manifest;

    if (expectedZipSha256 != null &&
        HashChain.digestBytesHex(zipBytes) != expectedZipSha256) {
      problems.add(
        const ChainProblem(
          0,
          'zip_digest_mismatch',
          'the bytes do not match the digest recorded when they were stored',
        ),
      );
    }

    if (manifest.schema != LyeArchiveManifest.schemaVersion) {
      problems.add(
        ChainProblem(
          0,
          'unknown_schema',
          'manifest schema is ${manifest.schema}',
        ),
      );
    }

    // Members: every declared file present, with the declared digest.
    for (final member in manifest.members) {
      final data = opened.memberBytes[member.path];
      if (data == null) {
        problems.add(
          ChainProblem(0, 'member_missing', '${member.path} is not in the ZIP'),
        );
        continue;
      }
      if (data.length != member.bytes) {
        problems.add(
          ChainProblem(
            0,
            'member_size_mismatch',
            '${member.path} has ${data.length} bytes, manifest says '
                '${member.bytes}',
          ),
        );
      }
      if (HashChain.digestBytesHex(data) != member.sha256) {
        problems.add(
          ChainProblem(
            0,
            'member_digest_mismatch',
            '${member.path} does not match its digest',
          ),
        );
      }
    }
    // Files present but not declared: something was added.
    for (final path in opened.memberBytes.keys) {
      if (path == 'manifest.json' || path == 'README.txt') continue;
      final declared = manifest.members.any(
        (LyeArchiveMember m) => m.path == path,
      );
      if (!declared) {
        problems.add(
          ChainProblem(0, 'member_undeclared', '$path is not in the manifest'),
        );
      }
    }

    if (opened.events.length != manifest.eventCount) {
      problems.add(
        ChainProblem(
          0,
          'count_mismatch',
          'the package holds ${opened.events.length} events, the manifest '
              'says ${manifest.eventCount}',
        ),
      );
    }

    // Every row proves itself: sha256(prev_hash || canonical) == row_hash.
    // This works on a sparse set, which is the whole point.
    for (final event in opened.events) {
      if (!event.hasValidRowHash) {
        problems.add(
          ChainProblem(
            event.seq,
            'row_hash_mismatch',
            '${event.streamId}#${event.seq} does not match its own hash',
          ),
        );
      }
      if (event.subjectRef != manifest.subjectRef ||
          event.subjectType != manifest.subjectType) {
        problems.add(
          ChainProblem(
            event.seq,
            'foreign_subject',
            '${event.streamId}#${event.seq} belongs to '
                '${event.subjectType.name}:${event.subjectRef}',
          ),
        );
      }
      if (event.retention != manifest.retention) {
        problems.add(
          ChainProblem(
            event.seq,
            'foreign_class',
            '${event.streamId}#${event.seq} is ${event.retention.name}, the '
                'package is ${manifest.retention.name}',
          ),
        );
      }
    }

    // The subject chain: the accumulator over the row hashes, in the order
    // the manifest declares (members sorted, rows by stream sequence).
    final recomputed = SubjectChain.fold(
      _chainOrder(opened).map((LyeEvent e) => e.rowHash),
      from: manifest.prevChainHash,
    );
    if (recomputed != manifest.chainHash) {
      problems.add(
        const ChainProblem(
          0,
          'chain_hash_mismatch',
          'the chain recomputed over the rows does not end where the '
              'manifest says: a row was removed, added or reordered',
        ),
      );
    }

    if (manifest.toSeq - manifest.fromSeq + 1 != manifest.eventCount) {
      problems.add(
        ChainProblem(
          0,
          'range_not_contiguous',
          'range #${manifest.fromSeq}..#${manifest.toSeq} does not hold '
              '${manifest.eventCount} events',
        ),
      );
    }

    if (expectedFromSeq != null && manifest.fromSeq != expectedFromSeq) {
      problems.add(
        ChainProblem(
          0,
          'chain_gap',
          'this archive starts at #${manifest.fromSeq}, the chain expected '
              '#$expectedFromSeq',
        ),
      );
    }
    if (expectedPrevArchiveHash != null &&
        manifest.prevArchiveHash != expectedPrevArchiveHash) {
      problems.add(
        const ChainProblem(
          0,
          'archive_link_mismatch',
          'this archive does not link to the previous one of its chain',
        ),
      );
    }

    final s = signer;
    if (s != null && !manifest.verifySignature(s)) {
      problems.add(
        const ChainProblem(
          0,
          'signature_invalid',
          'the manifest signature is missing or invalid',
        ),
      );
    }

    return ArchiveReport(
      fileName: fileName.isEmpty ? manifest.fileName : fileName,
      manifest: manifest,
      eventCount: opened.events.length,
      problems: problems,
    );
  }

  /// The order in which the chain accumulator was folded when the archive
  /// was built: the order of the rows in the file, which is the order in
  /// which the store made them durable. It is recoverable precisely because
  /// the builder writes one member and does not regroup.
  static List<LyeEvent> _chainOrder(OpenedArchive opened) => opened.events;
}
