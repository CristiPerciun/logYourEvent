import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:lye_core/lye_core.dart';
import 'package:meta/meta.dart';

/// The readable journal of one subject for one UTC day, packed (0.4.0).
@immutable
class PackedJournalDay {
  const PackedJournalDay({
    required this.day,
    required this.fileName,
    required this.csvName,
    required this.bytes,
    required this.csvSize,
    required this.steps,
    required this.events,
    required this.retentions,
  });

  /// `YYYY-MM-DD`, UTC.
  final String day;

  /// The ZIP: `<base>.zip`.
  final String fileName;

  /// The one member of the ZIP: `<base>.csv`.
  final String csvName;

  final Uint8List bytes;

  /// Bytes of the CSV before compression.
  final int csvSize;

  /// Rows of the CSV, header excluded.
  final int steps;

  /// Events of the day that were read, before duplicates were dropped and
  /// calls joined.
  final int events;

  /// The retention classes the events came from. The file holds data of all
  /// of them, so it may live only as long as the shortest one.
  final Set<LyeRetention> retentions;

  /// Digest of [bytes], for whoever stores them.
  String get sha256 => HashChain.digestBytesHex(bytes);

  int get size => bytes.length;

  @override
  String toString() => 'PackedJournalDay($fileName $steps steps $size B)';
}

/// The member of a journal day package, read back.
@immutable
class OpenedJournalDay {
  const OpenedJournalDay(this.csvName, this.csv);

  final String csvName;

  /// UTF-8 with a byte order mark, as [LyeReadableJournal.encode] wrote it.
  final Uint8List csv;
}

/// One readable file per subject and UTC day, compressed, and only for a
/// day that has something in it (ADR-012).
///
/// 0.3.0 left the readable journal to be rendered whenever somebody asked
/// for it, for any day, empty ones included. A consumer that keeps one file
/// per day has to answer three questions every time: which events belong to
/// the day, whether there is a file at all, and how it is stored. They are
/// answered once, here:
///
/// - the day is UTC and half-open, `[00:00, 24:00)`: an event belongs to
///   exactly one day, and the same events always give the same file;
/// - a day without a single step has **no file**: [pack] returns null;
/// - the CSV travels in a ZIP with one member, deflated, with the day as its
///   modification time, so the same events always give the same bytes.
///
/// The file stays what ADR-011 made it: derived from the events and not
/// evidence. The signed packages of `ArchiveBuilder` remain the proof.
abstract final class ReadableJournalDay {
  /// Packs the steps of [events] that occurred on [day] (`YYYY-MM-DD`, UTC)
  /// into `<baseName>.zip`, holding `<baseName>.csv`. Events of other days
  /// are left out. Null when no step is left: a day without events has no
  /// file.
  ///
  /// [baseName] belongs to the consumer, and like the archive names it must
  /// not carry personal data: a slug of the subject and the day.
  static PackedJournalDay? pack({
    required LyeReadableJournal journal,
    required Iterable<LyeEvent> events,
    required String day,
    required String baseName,
    int level = DeflateLevel.bestCompression,
  }) {
    final DateTime from = dayStart(day);
    final DateTime to = from.add(const Duration(days: 1));
    if (!_baseName.hasMatch(baseName)) {
      throw ArgumentError.value(
        baseName,
        'baseName',
        'letters, digits, dot, dash and underscore only',
      );
    }

    final List<LyeEvent> ofDay = <LyeEvent>[
      for (final LyeEvent e in events)
        if (!e.occurredAt.isBefore(from) && e.occurredAt.isBefore(to)) e,
    ];
    final int steps = journal.steps(ofDay).length;
    if (steps == 0) return null;

    final Uint8List csv = journal.encode(ofDay);
    final String csvName = '$baseName.csv';
    final Archive archive = Archive()..add(ArchiveFile.bytes(csvName, csv));
    final Uint8List bytes = ZipEncoder().encodeBytes(
      archive,
      level: level,
      // A fixed modification time is what makes the file reproducible.
      modified: from,
    );
    return PackedJournalDay(
      day: day,
      fileName: '$baseName.zip',
      csvName: csvName,
      bytes: bytes,
      csvSize: csv.length,
      steps: steps,
      events: ofDay.length,
      retentions: <LyeRetention>{for (final LyeEvent e in ofDay) e.retention},
    );
  }

  /// The CSV inside a package made by [pack].
  ///
  /// Throws [FormatException] when [zip] is not a ZIP or holds no CSV.
  static OpenedJournalDay open(List<int> zip) {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(zip);
    } catch (error) {
      throw FormatException('not a readable ZIP: $error');
    }
    for (final ArchiveFile member in archive.files) {
      if (!member.isFile || !member.name.toLowerCase().endsWith('.csv')) {
        continue;
      }
      return OpenedJournalDay(
        member.name,
        Uint8List.fromList(member.readBytes() ?? <int>[]),
      );
    }
    throw const FormatException('the package holds no CSV');
  }

  /// The first instant of [day] (`YYYY-MM-DD`), in UTC.
  static DateTime dayStart(String day) {
    final Match? m = _day.firstMatch(day);
    if (m == null) {
      throw ArgumentError.value(day, 'day', 'expected YYYY-MM-DD');
    }
    final DateTime start = DateTime.utc(
      int.parse(m.group(1)!),
      int.parse(m.group(2)!),
      int.parse(m.group(3)!),
    );
    // 2026-02-30 would roll over to March: a day that does not exist is
    // refused, not moved.
    if (_dayOf(start) != day) {
      throw ArgumentError.value(day, 'day', 'not a calendar day');
    }
    return start;
  }

  /// `YYYY-MM-DD` of [instant], in UTC.
  static String dayOf(DateTime instant) => _dayOf(instant.toUtc());

  static String _dayOf(DateTime utc) =>
      '${utc.year.toString().padLeft(4, '0')}-'
      '${utc.month.toString().padLeft(2, '0')}-'
      '${utc.day.toString().padLeft(2, '0')}';

  static final RegExp _day = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$');
  static final RegExp _baseName = RegExp(r'^[A-Za-z0-9_-][A-Za-z0-9._-]{0,119}$');
}
