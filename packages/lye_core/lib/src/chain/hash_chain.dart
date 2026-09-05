import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../ids/hex.dart';

/// The hash-chain primitive shared by every stream.
///
/// The construction mirrors `audit.canonical_event_v1` of compliance-os:
/// the hashed columns of an event are joined by the ASCII Record Separator,
/// prefixed by the previous row hash as raw bytes and digested with SHA-256.
/// Field values can never contain the separator (the sanitizer strips it),
/// so the representation is unambiguous.
abstract final class HashChain {
  /// ASCII Record Separator (0x1E).
  static const String fieldSeparator = '';

  /// Genesis `prev_hash`: 32 zero bytes.
  static final List<int> genesis = List<int>.unmodifiable(
    List<int>.filled(32, 0),
  );

  /// Hex form of [genesis].
  static const String genesisHex =
      '0000000000000000000000000000000000000000000000000000000000000000';

  /// Canonical text of an event given its hashed columns, in schema order.
  static String canonicalEventV1(List<String> hashedFields) {
    for (final field in hashedFields) {
      if (field.contains(fieldSeparator)) {
        throw ArgumentError('A hashed field contains the record separator');
      }
    }
    return hashedFields.join(fieldSeparator);
  }

  /// `sha256(prev_hash || utf8(canonical))`.
  static List<int> rowHash(List<int> prevHash, String canonical) {
    return sha256.convert(<int>[...prevHash, ...utf8.encode(canonical)]).bytes;
  }

  /// Convenience over hex strings.
  static String rowHashHex(String prevHashHex, String canonical) {
    return bytesToHex(rowHash(hexToBytes(prevHashHex), canonical));
  }

  /// SHA-256 of an arbitrary UTF-8 text, as hex. Used for digests
  /// (payloads, error messages, SQL templates, call arguments).
  static String digestHex(String text) {
    return bytesToHex(sha256.convert(utf8.encode(text)).bytes);
  }

  /// SHA-256 of raw bytes, as hex (files, manifests).
  static String digestBytesHex(List<int> bytes) {
    return bytesToHex(sha256.convert(bytes).bytes);
  }
}
