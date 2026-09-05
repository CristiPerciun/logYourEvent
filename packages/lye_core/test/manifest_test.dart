import 'dart:convert';

import 'package:lye_core/lye_core.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('LyeManifest', () {
    late List<LyeEvent> events;
    late List<int> fileBytes;
    final signer = HmacSha256Signer.fromSecret(
      'deployment-secret',
      keyId: 'k1',
    );
    final generatedAt = DateTime.utc(2026, 9, 5, 23, 59);

    setUp(() async {
      events = await recordMany(testRecorder(), 4);
      fileBytes = utf8.encode(LyeCsv.encode(events));
    });

    test('describes a file and verifies it', () {
      final manifest = LyeManifest.describe(
        file: 'a.csv',
        fileBytes: fileBytes,
        events: events,
        prevManifestHash: HashChain.genesisHex,
        generatedAt: generatedAt,
        signer: signer,
      );
      expect(manifest.count, 4);
      expect(manifest.headHash, events.last.rowHash);
      expect(manifest.prevHash, HashChain.genesisHex);
      expect(manifest.signature, isNotNull);
      expect(manifest.verifySignature(signer), isTrue);
      final problems = LyeManifest.check(
        manifest,
        fileBytes: fileBytes,
        events: events,
        signer: signer,
        expectedPrevManifestHash: HashChain.genesisHex,
      );
      expect(problems, isEmpty);
    });

    test('round-trips through JSON without changing its hash', () {
      final manifest = LyeManifest.describe(
        file: 'a.csv',
        fileBytes: fileBytes,
        events: events,
        prevManifestHash: HashChain.genesisHex,
        generatedAt: generatedAt,
        signer: signer,
      );
      final parsed = LyeManifest.fromJsonText(manifest.toJsonText());
      expect(parsed.manifestHash, manifest.manifestHash);
      expect(parsed.verifySignature(signer), isTrue);
      expect(parsed.toJson()['manifest_hash'], manifest.manifestHash);
    });

    test('detects altered bytes, wrong signer and broken manifest links', () {
      final manifest = LyeManifest.describe(
        file: 'a.csv',
        fileBytes: fileBytes,
        events: events,
        prevManifestHash: HashChain.genesisHex,
        generatedAt: generatedAt,
        signer: signer,
      );
      final altered = List<int>.of(fileBytes)..[fileBytes.length - 3] ^= 0x01;
      final codes = LyeManifest.check(
        manifest,
        fileBytes: altered,
        events: events,
        signer: HmacSha256Signer.fromSecret('other', keyId: 'k1'),
        expectedPrevManifestHash: 'ff' * 32,
      ).map((ChainProblem p) => p.code).toList();
      expect(
        codes,
        containsAll(<String>[
          'file_digest_mismatch',
          'signature_invalid',
          'manifest_link_mismatch',
        ]),
      );
    });

    test('detects a file whose events were trimmed', () {
      final manifest = LyeManifest.describe(
        file: 'a.csv',
        fileBytes: fileBytes,
        events: events,
        prevManifestHash: HashChain.genesisHex,
        generatedAt: generatedAt,
      );
      final trimmed = events.sublist(0, 3);
      final codes = LyeManifest.check(
        manifest,
        fileBytes: utf8.encode(LyeCsv.encode(trimmed)),
        events: trimmed,
      ).map((ChainProblem p) => p.code).toList();
      expect(
        codes,
        containsAll(<String>[
          'count_mismatch',
          'range_mismatch',
          'head_mismatch',
        ]),
      );
    });

    test('a forged signature never verifies', () {
      final manifest =
          LyeManifest.describe(
            file: 'a.csv',
            fileBytes: fileBytes,
            events: events,
            prevManifestHash: HashChain.genesisHex,
            generatedAt: generatedAt,
          ).copyWith(
            signature: const LyeSignature(
              algorithm: 'hmac-sha256',
              keyId: 'k1',
              value: 'zz',
            ),
          );
      expect(manifest.verifySignature(signer), isFalse);
    });
  });
}
