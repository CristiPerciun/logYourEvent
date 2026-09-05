/// Lower-case hexadecimal helpers used for hashes and span identifiers.
library;

const String _digits = '0123456789abcdef';

/// Encodes [bytes] as lower-case hexadecimal.
String bytesToHex(List<int> bytes) {
  final out = StringBuffer();
  for (final b in bytes) {
    out.write(_digits[(b >> 4) & 0x0f]);
    out.write(_digits[b & 0x0f]);
  }
  return out.toString();
}

/// Decodes lower- or upper-case hexadecimal. Throws [FormatException] on odd
/// length or non-hex characters.
List<int> hexToBytes(String hex) {
  if (hex.length.isOdd) {
    throw FormatException('Odd-length hex string: "$hex"');
  }
  final out = List<int>.filled(hex.length ~/ 2, 0);
  for (var i = 0; i < out.length; i++) {
    final byte = int.tryParse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    if (byte == null) {
      throw FormatException('Not a hex string: "$hex"');
    }
    out[i] = byte;
  }
  return out;
}

/// Constant-time comparison: never short-circuit on integrity material.
bool constantTimeEquals(List<int> a, List<int> b) {
  var diff = a.length ^ b.length;
  final n = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < n; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

final RegExp _hex64 = RegExp(r'^[0-9a-f]{64}$');

/// Whether [value] is a lower-case 64-digit hex string (a SHA-256).
bool isSha256Hex(String value) => _hex64.hasMatch(value);
