import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Helpers for the 64-byte Realm encryption key.
///
/// The key never lives in the repository or in the trace. On the server it
/// comes from the environment or a Docker secret; on a device from the
/// platform secure storage (`PlatformServices` in the console). Losing the
/// key makes the local buffer unreadable, which is acceptable: the events
/// already exported or shipped are the durable copy.
abstract final class RealmKeys {
  /// Length Realm requires.
  static const int keyLength = 64;

  /// Derives a 64-byte key from a secret string (SHA-512).
  static List<int> fromSecret(String secret) {
    if (secret.length < 16) {
      throw ArgumentError('Realm key secret must be at least 16 characters');
    }
    return sha512.convert(utf8.encode(secret)).bytes;
  }

  /// Validates a raw key.
  static List<int> validate(List<int> key) {
    if (key.length != keyLength) {
      throw ArgumentError(
        'Realm encryption key must be exactly $keyLength bytes',
      );
    }
    return key;
  }
}
