import 'package:lye_core/lye_core.dart';
import 'package:meta/meta.dart';

/// One event with the place it occupies in its subject chain.
///
/// [csvRow] is the row as it was stored, terminator included. Passing it
/// keeps the archive a concatenation rather than a re-serialisation: no byte
/// can change between the moment the row was signed and the moment it is
/// written into the file. When it is null the builder encodes the event.
@immutable
class ArchiveRow {
  const ArchiveRow({
    required this.chainSeq,
    required this.event,
    this.csvRow,
  });

  final int chainSeq;
  final LyeEvent event;
  final String? csvRow;

  String get row => csvRow ?? LyeCsv.encodeRow(event);

  @override
  String toString() => 'ArchiveRow(#$chainSeq ${event.action})';
}

/// Where the chain of a subject stands, and how the next archives are cut.
@immutable
class ArchiveCut {
  const ArchiveCut({
    required this.subjectType,
    required this.subjectRef,
    required this.retention,
    required this.day,
    required this.cutAt,
    this.homeOrgId = '',
    this.partnerId = '',
    this.archiveSeq = 1,
    this.part = 1,
    this.prevArchiveHash = HashChain.genesisHex,
    this.prevChainHash = SubjectChain.genesisHex,
    this.expiresAt,
    this.previousCutAt,
    this.namePrefix = 'jurnal',
  });

  final LyeSubjectType subjectType;
  final String subjectRef;
  final LyeRetention retention;

  /// Home organisation of the subject, for attribution and for row-level
  /// security in the consumer. Never a personal datum.
  final String homeOrgId;
  final String partnerId;

  /// `YYYY-MM-DD` UTC of the creation day: what the file name carries.
  final String day;

  /// When the chain is cut.
  final DateTime cutAt;

  /// Cut that produced the previous archive, used to count the events that
  /// arrived late from a client that had been offline.
  final DateTime? previousCutAt;

  /// Progressive number the first archive produced by this cut will carry.
  final int archiveSeq;

  /// Part number the first archive produced by this cut will carry.
  final int part;

  /// Hash of the last archive of this chain; genesis when there is none.
  final String prevArchiveHash;

  /// Chain accumulator after the last archived event.
  final String prevChainHash;

  /// When the archives produced here may be deleted.
  final DateTime? expiresAt;

  final String namePrefix;
}
