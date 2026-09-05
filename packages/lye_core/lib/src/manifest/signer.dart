import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';

import '../ids/hex.dart';

/// A detached signature over a manifest.
@immutable
class LyeSignature {
  const LyeSignature({
    required this.algorithm,
    required this.keyId,
    required this.value,
  });

  /// `hmac-sha256` today; `msign-xades-t` when MSign timestamps arrive (F2).
  final String algorithm;

  /// Identifier of the key, never the key.
  final String keyId;

  /// Hex signature.
  final String value;

  Map<String, Object?> toJson() => <String, Object?>{
    'alg': algorithm,
    'key_id': keyId,
    'value': value,
  };

  static LyeSignature fromJson(Map<String, Object?> json) => LyeSignature(
    algorithm: (json['alg'] ?? '').toString(),
    keyId: (json['key_id'] ?? '').toString(),
    value: (json['value'] ?? '').toString(),
  );
}

/// Signs and verifies byte strings.
abstract class LyeSigner {
  String get algorithm;
  String get keyId;
  LyeSignature sign(List<int> bytes);
  bool verify(List<int> bytes, LyeSignature signature);
}

/// HMAC-SHA256 with a deployment key. Proves that a manifest was produced by
/// a holder of the key (the server), which is what a client-side tamper
/// cannot forge. It is not a third-party timestamp: that is the MSign
/// anchoring of F2.
class HmacSha256Signer implements LyeSigner {
  HmacSha256Signer({required List<int> key, required this.keyId})
    : _hmac = Hmac(sha256, key) {
    if (key.length < 32) {
      throw ArgumentError('HMAC key must be at least 32 bytes');
    }
  }

  /// Derives the key from a UTF-8 secret (for configuration files).
  factory HmacSha256Signer.fromSecret(String secret, {required String keyId}) {
    return HmacSha256Signer(
      key: sha256.convert(utf8.encode(secret)).bytes,
      keyId: keyId,
    );
  }

  final Hmac _hmac;

  @override
  final String keyId;

  @override
  String get algorithm => 'hmac-sha256';

  @override
  LyeSignature sign(List<int> bytes) => LyeSignature(
    algorithm: algorithm,
    keyId: keyId,
    value: bytesToHex(_hmac.convert(bytes).bytes),
  );

  @override
  bool verify(List<int> bytes, LyeSignature signature) {
    if (signature.algorithm != algorithm || signature.keyId != keyId) {
      return false;
    }
    final expected = _hmac.convert(bytes).bytes;
    List<int> given;
    try {
      given = hexToBytes(signature.value);
    } on FormatException {
      return false;
    }
    return constantTimeEquals(expected, given);
  }
}
