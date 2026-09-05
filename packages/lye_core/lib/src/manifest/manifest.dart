import 'dart:convert';

import 'package:meta/meta.dart';

import '../canonical/canonical_json.dart';
import '../canonical/timestamp.dart';
import '../chain/hash_chain.dart';
import '../model/lye_event.dart';
import '../verify/chain_verifier.dart';
import '../version.dart';
import 'signer.dart';

/// Sidecar of a CSV file: what the file contains, its digest, the chain
/// head it ends with, and a link to the previous manifest of the stream.
///
/// Manifests form their own chain (`prev_manifest_hash`), so removing a
/// whole file from an export is as detectable as removing a row from a
/// file. The `head_hash` of the last manifest of the day is what gets
/// anchored outside the database (§5.6 of the architecture document).
@immutable
class LyeManifest {
  const LyeManifest({
    required this.file,
    required this.fileSha256,
    required this.fileSize,
    required this.streamId,
    required this.firstSeq,
    required this.lastSeq,
    required this.count,
    required this.firstOccurredAt,
    required this.lastOccurredAt,
    required this.prevHash,
    required this.headHash,
    required this.prevManifestHash,
    required this.generatedAt,
    this.schema = schemaVersion,
    this.eventSchema = 'lye.v1',
    this.generator = 'lye@$lyeVersion',
    this.signature,
  });

  static const String schemaVersion = 'lye.manifest.v1';

  final String schema;
  final String eventSchema;

  /// File name (no directory).
  final String file;
  final String fileSha256;
  final int fileSize;
  final String streamId;
  final int firstSeq;
  final int lastSeq;
  final int count;
  final DateTime? firstOccurredAt;
  final DateTime? lastOccurredAt;

  /// `prev_hash` of the first event in the file.
  final String prevHash;

  /// `row_hash` of the last event in the file.
  final String headHash;

  /// Hash of the previous manifest of the same stream; genesis for the first.
  final String prevManifestHash;
  final DateTime generatedAt;
  final String generator;
  final LyeSignature? signature;

  /// Builds the manifest of [events] (already verified, contiguous) given
  /// the bytes of the file that contains them.
  static LyeManifest describe({
    required String file,
    required List<int> fileBytes,
    required List<LyeEvent> events,
    required String prevManifestHash,
    required DateTime generatedAt,
    LyeSigner? signer,
  }) {
    if (events.isEmpty) {
      throw ArgumentError('A manifest needs at least one event');
    }
    final manifest = LyeManifest(
      file: file,
      fileSha256: HashChain.digestBytesHex(fileBytes),
      fileSize: fileBytes.length,
      streamId: events.first.streamId,
      firstSeq: events.first.seq,
      lastSeq: events.last.seq,
      count: events.length,
      firstOccurredAt: events.first.occurredAt,
      lastOccurredAt: events.last.occurredAt,
      prevHash: events.first.prevHash,
      headHash: events.last.rowHash,
      prevManifestHash: prevManifestHash,
      generatedAt: generatedAt.toUtc(),
    );
    return signer == null ? manifest : manifest.signedWith(signer);
  }

  /// The fields covered by the manifest hash and by the signature.
  Map<String, Object?> get signedFields => <String, Object?>{
    'schema': schema,
    'event_schema': eventSchema,
    'file': file,
    'file_sha256': fileSha256,
    'file_size': fileSize,
    'stream_id': streamId,
    'first_seq': firstSeq,
    'last_seq': lastSeq,
    'count': count,
    'first_occurred_at': firstOccurredAt == null
        ? ''
        : formatTimestampUtc(firstOccurredAt!),
    'last_occurred_at': lastOccurredAt == null
        ? ''
        : formatTimestampUtc(lastOccurredAt!),
    'prev_hash': prevHash,
    'head_hash': headHash,
    'prev_manifest_hash': prevManifestHash,
    'generated_at': formatTimestampUtc(generatedAt),
    'generator': generator,
  };

  /// Canonical JSON of the signed fields.
  String get canonical => canonicalJson(signedFields);

  /// SHA-256 of [canonical]: the value the next manifest links to.
  String get manifestHash => HashChain.digestHex(canonical);

  LyeManifest signedWith(LyeSigner signer) {
    return copyWith(signature: signer.sign(utf8.encode(canonical)));
  }

  bool verifySignature(LyeSigner signer) {
    final sig = signature;
    return sig != null && signer.verify(utf8.encode(canonical), sig);
  }

  LyeManifest copyWith({LyeSignature? signature}) => LyeManifest(
    schema: schema,
    eventSchema: eventSchema,
    file: file,
    fileSha256: fileSha256,
    fileSize: fileSize,
    streamId: streamId,
    firstSeq: firstSeq,
    lastSeq: lastSeq,
    count: count,
    firstOccurredAt: firstOccurredAt,
    lastOccurredAt: lastOccurredAt,
    prevHash: prevHash,
    headHash: headHash,
    prevManifestHash: prevManifestHash,
    generatedAt: generatedAt,
    generator: generator,
    signature: signature ?? this.signature,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    ...signedFields,
    'manifest_hash': manifestHash,
    if (signature != null) 'signature': signature!.toJson(),
  };

  /// Pretty JSON for the sidecar file.
  String toJsonText() => const JsonEncoder.withIndent('  ').convert(toJson());

  static LyeManifest fromJson(Map<String, Object?> json) {
    String text(String key) => (json[key] ?? '').toString();
    int number(String key) => int.parse(text(key));
    DateTime? time(String key) {
      final value = text(key);
      return value.isEmpty ? null : parseTimestampUtc(value);
    }

    final sigJson = json['signature'];
    return LyeManifest(
      schema: text('schema'),
      eventSchema: text('event_schema'),
      file: text('file'),
      fileSha256: text('file_sha256'),
      fileSize: number('file_size'),
      streamId: text('stream_id'),
      firstSeq: number('first_seq'),
      lastSeq: number('last_seq'),
      count: number('count'),
      firstOccurredAt: time('first_occurred_at'),
      lastOccurredAt: time('last_occurred_at'),
      prevHash: text('prev_hash'),
      headHash: text('head_hash'),
      prevManifestHash: text('prev_manifest_hash'),
      generatedAt: parseTimestampUtc(text('generated_at')),
      generator: text('generator'),
      signature: sigJson is Map<String, Object?>
          ? LyeSignature.fromJson(sigJson)
          : sigJson is Map
          ? LyeSignature.fromJson(
              sigJson.map((Object? k, Object? v) => MapEntry(k.toString(), v)),
            )
          : null,
    );
  }

  static LyeManifest fromJsonText(String text) {
    final decoded = jsonDecode(text);
    if (decoded is! Map) {
      throw const FormatException('Manifest is not a JSON object');
    }
    return fromJson(
      decoded.map((Object? k, Object? v) => MapEntry(k.toString(), v)),
    );
  }

  /// Checks a manifest against the file bytes and the decoded events:
  /// digest, size, count, boundaries, chain within the file and, if a
  /// signer is given, the signature.
  static List<ChainProblem> check(
    LyeManifest manifest, {
    required List<int> fileBytes,
    required List<LyeEvent> events,
    LyeSigner? signer,
    String? expectedPrevManifestHash,
  }) {
    final problems = <ChainProblem>[];
    if (HashChain.digestBytesHex(fileBytes) != manifest.fileSha256) {
      problems.add(
        const ChainProblem(
          0,
          'file_digest_mismatch',
          'file bytes do not match manifest file_sha256',
        ),
      );
    }
    if (fileBytes.length != manifest.fileSize) {
      problems.add(
        ChainProblem(
          0,
          'file_size_mismatch',
          'file has ${fileBytes.length} bytes, manifest says ${manifest.fileSize}',
        ),
      );
    }
    if (events.length != manifest.count) {
      problems.add(
        ChainProblem(
          0,
          'count_mismatch',
          'file has ${events.length} events, manifest says ${manifest.count}',
        ),
      );
    }
    if (events.isNotEmpty) {
      if (events.first.seq != manifest.firstSeq ||
          events.last.seq != manifest.lastSeq) {
        problems.add(
          ChainProblem(
            0,
            'range_mismatch',
            'events span ${events.first.seq}..${events.last.seq}, manifest says '
                '${manifest.firstSeq}..${manifest.lastSeq}',
          ),
        );
      }
      if (events.last.rowHash != manifest.headHash) {
        problems.add(
          const ChainProblem(
            0,
            'head_mismatch',
            'last row_hash does not match manifest head_hash',
          ),
        );
      }
      final report = ChainVerifier.verify(
        events,
        expectedStreamId: manifest.streamId,
        expectedPrevHash: manifest.prevHash,
        expectedFirstSeq: manifest.firstSeq,
      );
      problems.addAll(report.problems);
    }
    if (expectedPrevManifestHash != null &&
        manifest.prevManifestHash != expectedPrevManifestHash) {
      problems.add(
        const ChainProblem(
          0,
          'manifest_link_mismatch',
          'prev_manifest_hash does not match the previous manifest',
        ),
      );
    }
    if (signer != null && !manifest.verifySignature(signer)) {
      problems.add(
        const ChainProblem(
          0,
          'signature_invalid',
          'manifest signature is missing or invalid',
        ),
      );
    }
    return problems;
  }
}
