import 'dart:convert';

import 'package:meta/meta.dart';

import '../canonical/canonical_json.dart';
import '../canonical/timestamp.dart';
import '../chain/hash_chain.dart';
import '../model/enums.dart';
import '../version.dart';
import 'signer.dart';

/// One file inside an archive.
@immutable
class LyeArchiveMember {
  const LyeArchiveMember({
    required this.path,
    required this.sha256,
    required this.rows,
    required this.bytes,
  });

  /// Path inside the ZIP, always with forward slashes.
  final String path;
  final String sha256;
  final int rows;
  final int bytes;

  Map<String, Object?> toJson() => <String, Object?>{
    'path': path,
    'sha256': sha256,
    'rows': rows,
    'bytes': bytes,
  };

  static LyeArchiveMember fromJson(Map<String, Object?> json) =>
      LyeArchiveMember(
        path: (json['path'] ?? '').toString(),
        sha256: (json['sha256'] ?? '').toString(),
        rows: int.parse((json['rows'] ?? '0').toString()),
        bytes: int.parse((json['bytes'] ?? '0').toString()),
      );
}

/// The span of one stream inside an archive.
@immutable
class LyeArchiveStream {
  const LyeArchiveStream({
    required this.streamId,
    required this.firstSeq,
    required this.lastSeq,
    required this.rows,
  });

  final String streamId;
  final int firstSeq;
  final int lastSeq;
  final int rows;

  Map<String, Object?> toJson() => <String, Object?>{
    'stream_id': streamId,
    'first_seq': firstSeq,
    'last_seq': lastSeq,
    'rows': rows,
  };

  static LyeArchiveStream fromJson(Map<String, Object?> json) =>
      LyeArchiveStream(
        streamId: (json['stream_id'] ?? '').toString(),
        firstSeq: int.parse((json['first_seq'] ?? '0').toString()),
        lastSeq: int.parse((json['last_seq'] ?? '0').toString()),
        rows: int.parse((json['rows'] ?? '0').toString()),
      );
}

/// Descriptor of one archive of one subject chain (ADR-009).
///
/// It says what the package contains, which contiguous range of which chain
/// it covers, the digest of every member, and how it hooks onto the archive
/// before it. It lives **inside** the ZIP, which is why it cannot carry the
/// digest of the ZIP itself: that one is computed after sealing and belongs
/// to whoever stores the bytes.
@immutable
class LyeArchiveManifest {
  const LyeArchiveManifest({
    required this.archiveId,
    required this.subjectType,
    required this.subjectRef,
    required this.retention,
    required this.archiveSeq,
    required this.part,
    required this.day,
    required this.cutAt,
    required this.fromSeq,
    required this.toSeq,
    required this.eventCount,
    required this.prevArchiveHash,
    required this.prevChainHash,
    required this.chainHash,
    required this.members,
    this.streams = const <LyeArchiveStream>[],
    this.organizations = const <String>[],
    this.homeOrgId = '',
    this.partnerId = '',
    this.occurredFrom,
    this.occurredTo,
    this.expiresAt,
    this.lateEventCount = 0,
    this.lateOldestOccurredAt,
    this.levels = const <String, int>{},
    this.schema = schemaVersion,
    this.eventSchema = 'lye.v2',
    this.generator = 'lye@$lyeVersion',
    this.signature,
  });

  static const String schemaVersion = 'lye.archive.v1';

  final String schema;
  final String eventSchema;
  final String archiveId;

  final LyeSubjectType subjectType;
  final String subjectRef;
  final String homeOrgId;
  final String partnerId;

  /// Every organisation touched by the events inside, so a reader can
  /// filter a consultant's archive by client without splitting it.
  final List<String> organizations;

  final LyeRetention retention;

  /// Progressive number of this archive inside its chain, starting at 1.
  final int archiveSeq;

  /// Part of the day, starting at 1; a new part opens at the size cap.
  final int part;

  /// Creation day, `YYYY-MM-DD` UTC: what the file name carries.
  final String day;

  /// When the chain was cut.
  final DateTime cutAt;

  /// Contiguous range of the chain covered here.
  final int fromSeq;
  final int toSeq;
  final int eventCount;

  final DateTime? occurredFrom;
  final DateTime? occurredTo;

  /// When the archive may be deleted.
  final DateTime? expiresAt;

  /// Events whose `occurred_at` precedes the previous cut: they reached the
  /// server late, from a client that had been offline.
  final int lateEventCount;
  final DateTime? lateOldestOccurredAt;

  /// How many events per verbosity level.
  final Map<String, int> levels;

  final List<LyeArchiveStream> streams;
  final List<LyeArchiveMember> members;

  /// Hash of the previous archive of the same chain; genesis for the first.
  final String prevArchiveHash;

  /// Subject chain accumulator before the first event of this archive.
  final String prevChainHash;

  /// Subject chain accumulator after the last event of this archive.
  final String chainHash;

  final String generator;

  final LyeSignature? signature;

  /// Digest over the members: survives a recompression of the ZIP, unlike
  /// the digest of the bytes.
  String get contentHash => HashChain.digestHex(
    canonicalJson(<String, Object?>{
      'members': <Object?>[for (final member in members) member.toJson()],
    }),
  );

  /// The fields covered by the archive hash and by the signature.
  Map<String, Object?> get signedFields => <String, Object?>{
    'schema': schema,
    'event_schema': eventSchema,
    'archive_id': archiveId,
    'subject_type': subjectType.name,
    'subject_ref': subjectRef,
    'home_org_id': homeOrgId,
    'partner_id': partnerId,
    'organizations': organizations,
    'retention_class': retention.name,
    'archive_seq': archiveSeq,
    'part': part,
    'day': day,
    'cut_at': formatTimestampUtc(cutAt),
    'from_seq': fromSeq,
    'to_seq': toSeq,
    'event_count': eventCount,
    'occurred_from': occurredFrom == null
        ? ''
        : formatTimestampUtc(occurredFrom!),
    'occurred_to': occurredTo == null ? '' : formatTimestampUtc(occurredTo!),
    'expires_at': expiresAt == null ? '' : formatTimestampUtc(expiresAt!),
    'late_event_count': lateEventCount,
    'late_oldest_occurred_at': lateOldestOccurredAt == null
        ? ''
        : formatTimestampUtc(lateOldestOccurredAt!),
    'levels': levels,
    'streams': <Object?>[for (final stream in streams) stream.toJson()],
    'members': <Object?>[for (final member in members) member.toJson()],
    'content_hash': contentHash,
    'prev_archive_hash': prevArchiveHash,
    'prev_chain_hash': prevChainHash,
    'chain_hash': chainHash,
    'generator': generator,
  };

  /// Canonical JSON of the signed fields.
  String get canonical => canonicalJson(signedFields);

  /// SHA-256 of [canonical]: what the next archive of the chain links to.
  String get archiveHash => HashChain.digestHex(canonical);

  LyeArchiveManifest signedWith(LyeSigner signer) =>
      copyWith(signature: signer.sign(utf8.encode(canonical)));

  bool verifySignature(LyeSigner signer) {
    final sig = signature;
    return sig != null && signer.verify(utf8.encode(canonical), sig);
  }

  LyeArchiveManifest copyWith({LyeSignature? signature}) => LyeArchiveManifest(
    schema: schema,
    eventSchema: eventSchema,
    archiveId: archiveId,
    subjectType: subjectType,
    subjectRef: subjectRef,
    homeOrgId: homeOrgId,
    partnerId: partnerId,
    organizations: organizations,
    retention: retention,
    archiveSeq: archiveSeq,
    part: part,
    day: day,
    cutAt: cutAt,
    fromSeq: fromSeq,
    toSeq: toSeq,
    eventCount: eventCount,
    occurredFrom: occurredFrom,
    occurredTo: occurredTo,
    expiresAt: expiresAt,
    lateEventCount: lateEventCount,
    lateOldestOccurredAt: lateOldestOccurredAt,
    levels: levels,
    streams: streams,
    members: members,
    prevArchiveHash: prevArchiveHash,
    prevChainHash: prevChainHash,
    chainHash: chainHash,
    generator: generator,
    signature: signature ?? this.signature,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    ...signedFields,
    'archive_hash': archiveHash,
    if (signature != null) 'signature': signature!.toJson(),
  };

  String toJsonText() => const JsonEncoder.withIndent('  ').convert(toJson());

  static LyeArchiveManifest fromJson(Map<String, Object?> json) {
    String text(String key) => (json[key] ?? '').toString();
    int number(String key) {
      final value = text(key);
      return value.isEmpty ? 0 : int.parse(value);
    }

    DateTime? time(String key) {
      final value = text(key);
      return value.isEmpty ? null : parseTimestampUtc(value);
    }

    List<Map<String, Object?>> objects(String key) {
      final value = json[key];
      if (value is! List) return const <Map<String, Object?>>[];
      return <Map<String, Object?>>[
        for (final item in value)
          if (item is Map)
            item.map((Object? k, Object? v) => MapEntry(k.toString(), v)),
      ];
    }

    final organizationsJson = json['organizations'];
    final levelsJson = json['levels'];
    final sigJson = json['signature'];
    return LyeArchiveManifest(
      schema: text('schema'),
      eventSchema: text('event_schema'),
      archiveId: text('archive_id'),
      subjectType: enumFromWire(
        LyeSubjectType.values,
        text('subject_type'),
        'subject_type',
      ),
      subjectRef: text('subject_ref'),
      homeOrgId: text('home_org_id'),
      partnerId: text('partner_id'),
      organizations: <String>[
        if (organizationsJson is List)
          for (final item in organizationsJson) item.toString(),
      ],
      retention: enumFromWire(
        LyeRetention.values,
        text('retention_class'),
        'retention_class',
      ),
      archiveSeq: number('archive_seq'),
      part: number('part'),
      day: text('day'),
      cutAt: parseTimestampUtc(text('cut_at')),
      fromSeq: number('from_seq'),
      toSeq: number('to_seq'),
      eventCount: number('event_count'),
      occurredFrom: time('occurred_from'),
      occurredTo: time('occurred_to'),
      expiresAt: time('expires_at'),
      lateEventCount: number('late_event_count'),
      lateOldestOccurredAt: time('late_oldest_occurred_at'),
      levels: <String, int>{
        if (levelsJson is Map)
          for (final entry in levelsJson.entries)
            entry.key.toString(): int.parse(entry.value.toString()),
      },
      streams: <LyeArchiveStream>[
        for (final item in objects('streams')) LyeArchiveStream.fromJson(item),
      ],
      members: <LyeArchiveMember>[
        for (final item in objects('members')) LyeArchiveMember.fromJson(item),
      ],
      prevArchiveHash: text('prev_archive_hash'),
      prevChainHash: text('prev_chain_hash'),
      chainHash: text('chain_hash'),
      generator: text('generator'),
      signature: sigJson is Map
          ? LyeSignature.fromJson(
              sigJson.map((Object? k, Object? v) => MapEntry(k.toString(), v)),
            )
          : null,
    );
  }

  static LyeArchiveManifest fromJsonText(String text) {
    final decoded = jsonDecode(text);
    if (decoded is! Map) {
      throw const FormatException('Archive manifest is not a JSON object');
    }
    return fromJson(
      decoded.map((Object? k, Object? v) => MapEntry(k.toString(), v)),
    );
  }

  /// File name of the archive: the class, the subject slug and the creation
  /// day, then the part. Never a personal datum.
  String get fileName => nameFor(
    retention: retention,
    subjectType: subjectType,
    subjectRef: subjectRef,
    day: day,
    part: part,
  );

  /// Builds an archive file name.
  static String nameFor({
    required LyeRetention retention,
    required LyeSubjectType subjectType,
    required String subjectRef,
    required String day,
    required int part,
    String prefix = 'jurnal',
  }) {
    final compact = day.replaceAll('-', '');
    final letter = switch (subjectType) {
      LyeSubjectType.user => 'u',
      LyeSubjectType.org => 'o',
      LyeSubjectType.platform => 'p',
    };
    final hex = subjectRef.replaceAll(RegExp('[^0-9a-fA-F]'), '').toLowerCase();
    final slug = hex.length >= 8 ? hex.substring(0, 8) : hex.padRight(8, '0');
    final suffix = part.toString().padLeft(2, '0');
    return '${prefix}_${retention.name}_$letter${slug}_${compact}_$suffix.zip';
  }

  @override
  String toString() =>
      'LyeArchiveManifest(${subjectType.name}:$subjectRef/${retention.name} '
      '#$archiveSeq $fromSeq..$toSeq)';
}
