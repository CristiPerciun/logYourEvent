import 'dart:convert';

import 'package:lye_core/lye_core.dart';
import 'package:lye_io/lye_io.dart';
import 'package:meta/meta.dart';

import 'blob_store.dart';

/// Head of one stream at anchoring time.
@immutable
class AnchoredStream {
  const AnchoredStream({
    required this.streamId,
    required this.lastSeq,
    required this.headHash,
    required this.lastManifestHash,
    required this.files,
    required this.ok,
  });

  final String streamId;
  final int lastSeq;
  final String headHash;
  final String lastManifestHash;
  final int files;

  /// Whether the stream verified at anchoring time.
  final bool ok;

  Map<String, Object?> toJson() => <String, Object?>{
    'stream_id': streamId,
    'last_seq': lastSeq,
    'head_hash': headHash,
    'last_manifest_hash': lastManifestHash,
    'files': files,
    'ok': ok,
  };

  static AnchoredStream fromJson(Map<String, Object?> json) => AnchoredStream(
    streamId: json['stream_id'].toString(),
    lastSeq: int.parse(json['last_seq'].toString()),
    headHash: json['head_hash'].toString(),
    lastManifestHash: json['last_manifest_hash'].toString(),
    files: int.parse(json['files'].toString()),
    ok: json['ok'] == true,
  );
}

/// A signed snapshot of every stream head, stored outside the database.
///
/// This is the LYE counterpart of the daily export of the audit chain heads
/// (§5.6 of the architecture document): a chain is tamper-evident only
/// against a copy of its head kept where the database administrator cannot
/// rewrite it. In F2 the record is additionally timestamped through MSign.
@immutable
class AnchorRecord {
  const AnchorRecord({
    required this.anchoredAt,
    required this.root,
    required this.streams,
    this.schema = schemaVersion,
    this.generator = 'lye@$lyeVersion',
    this.signature,
  });

  static const String schemaVersion = 'lye.anchor.v1';

  final String schema;
  final DateTime anchoredAt;

  /// Export root the anchor describes (informational).
  final String root;
  final List<AnchoredStream> streams;
  final String generator;
  final LyeSignature? signature;

  Map<String, Object?> get signedFields => <String, Object?>{
    'schema': schema,
    'anchored_at': formatTimestampUtc(anchoredAt),
    'root': root,
    'generator': generator,
    'streams': <Object?>[for (final s in streams) s.toJson()],
  };

  String get canonical => canonicalJson(signedFields);

  String get anchorHash => HashChain.digestHex(canonical);

  AnchorRecord signedWith(LyeSigner signer) => AnchorRecord(
    schema: schema,
    anchoredAt: anchoredAt,
    root: root,
    streams: streams,
    generator: generator,
    signature: signer.sign(utf8.encode(canonical)),
  );

  bool verifySignature(LyeSigner signer) {
    final sig = signature;
    return sig != null && signer.verify(utf8.encode(canonical), sig);
  }

  Map<String, Object?> toJson() => <String, Object?>{
    ...signedFields,
    'anchor_hash': anchorHash,
    if (signature != null) 'signature': signature!.toJson(),
  };

  String toJsonText() => const JsonEncoder.withIndent('  ').convert(toJson());

  static AnchorRecord fromJsonText(String text) {
    final decoded = jsonDecode(text);
    if (decoded is! Map) {
      throw const FormatException('Anchor is not a JSON object');
    }
    final json = decoded.map(
      (Object? k, Object? v) => MapEntry(k.toString(), v),
    );
    final rawStreams = json['streams'];
    final sig = json['signature'];
    return AnchorRecord(
      schema: json['schema'].toString(),
      anchoredAt: parseTimestampUtc(json['anchored_at'].toString()),
      root: json['root'].toString(),
      generator: json['generator'].toString(),
      streams: <AnchoredStream>[
        if (rawStreams is List)
          for (final s in rawStreams)
            if (s is Map)
              AnchoredStream.fromJson(
                s.map((Object? k, Object? v) => MapEntry(k.toString(), v)),
              ),
      ],
      signature: sig is Map
          ? LyeSignature.fromJson(
              sig.map((Object? k, Object? v) => MapEntry(k.toString(), v)),
            )
          : null,
    );
  }
}

/// Verifies the export directory and writes a signed anchor to a blob store.
class AnchorService {
  AnchorService({
    required this.blobStore,
    required this.signer,
    this.recorder,
    this.keyPrefix = 'lye/anchors',
    LyeClock? clock,
  }) : clock = clock ?? const SystemClock();

  final BlobStore blobStore;
  final LyeSigner signer;

  /// Optional server recorder: the anchoring is itself an event.
  final LyeRecorder? recorder;
  final String keyPrefix;
  final LyeClock clock;

  /// Verifies [root], anchors every stream head and returns the record.
  /// The record says which streams verified; a broken stream is anchored
  /// too, flagged, so the evidence of the break is itself preserved.
  Future<AnchorRecord> anchor(String root) async {
    final report = await DirectoryVerifier(signer: signer).verify(root);
    final streams = <AnchoredStream>[
      for (final s in report.streams)
        if (s.lastSeq != null)
          AnchoredStream(
            streamId: s.streamId,
            lastSeq: s.lastSeq!,
            headHash: s.headHash!,
            lastManifestHash: s.files.last.manifest?.manifestHash ?? '',
            files: s.files.length,
            ok: s.ok,
          ),
    ];
    final now = clock.now();
    final record = AnchorRecord(
      anchoredAt: now,
      root: root,
      streams: streams,
    ).signedWith(signer);
    final bytes = utf8.encode(record.toJsonText());
    final day = ExportLayout.dayOf(now);
    final stamp = formatTimestampUtc(now).replaceAll(RegExp(r'[:.]'), '');
    await blobStore.put(
      '$keyPrefix/${day.substring(0, 4)}/${day.substring(4, 6)}/${day.substring(6, 8)}/anchor-$stamp.json',
      bytes,
      contentType: 'application/json',
    );
    await blobStore.put(
      '$keyPrefix/latest.json',
      bytes,
      contentType: 'application/json',
    );
    await recorder?.point(
      LyeCategory.system,
      LyeActions.anchorExported,
      outcome: report.ok ? LyeOutcome.ok : LyeOutcome.fail,
      attrs: <String, Object?>{
        'streams': streams.length,
        'broken': streams.where((AnchoredStream s) => !s.ok).length,
        'anchor_hash': record.anchorHash,
      },
    );
    return record;
  }

  /// Compares the latest anchor with the current state of [root]: every
  /// anchored stream must still verify and end at or after its anchored
  /// head with the same hash at that position.
  Future<List<ChainProblem>> checkAgainstLatest(String root) async {
    final bytes = await blobStore.get('$keyPrefix/latest.json');
    if (bytes == null) {
      return const <ChainProblem>[
        ChainProblem(0, 'anchor_missing', 'no anchor found'),
      ];
    }
    final record = AnchorRecord.fromJsonText(utf8.decode(bytes));
    final problems = <ChainProblem>[];
    if (!record.verifySignature(signer)) {
      problems.add(
        const ChainProblem(
          0,
          'anchor_signature_invalid',
          'anchor signature does not verify',
        ),
      );
    }
    final report = await DirectoryVerifier(signer: signer).verify(root);
    final byId = <String, StreamReport>{
      for (final s in report.streams) s.streamId: s,
    };
    for (final anchored in record.streams) {
      final current = byId[anchored.streamId];
      if (current == null || current.lastSeq == null) {
        problems.add(
          ChainProblem(
            anchored.lastSeq,
            'anchored_stream_missing',
            '${anchored.streamId} was anchored but is no longer exported',
          ),
        );
        continue;
      }
      if (current.lastSeq! < anchored.lastSeq) {
        problems.add(
          ChainProblem(
            anchored.lastSeq,
            'anchored_stream_truncated',
            '${anchored.streamId} ends at ${current.lastSeq}, anchor says ${anchored.lastSeq}',
          ),
        );
        continue;
      }
      final atAnchor = current.files
          .expand((FileReport f) => f.events)
          .where((LyeEvent e) => e.seq == anchored.lastSeq)
          .toList();
      if (atAnchor.isEmpty || atAnchor.first.rowHash != anchored.headHash) {
        problems.add(
          ChainProblem(
            anchored.lastSeq,
            'anchored_head_mismatch',
            '${anchored.streamId} #${anchored.lastSeq} does not match the anchored head',
          ),
        );
      }
    }
    return problems;
  }
}
