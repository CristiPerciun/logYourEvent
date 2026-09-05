import 'dart:math';

import '../recorder/lye_clock.dart';

/// UUID version 7 generator (RFC 9562): 48-bit Unix milliseconds, 12 bits of
/// counter, 62 random bits. Time-ordered like the identifiers used by the
/// compliance-os database (`app.uuid_generate_v7()`), so events sort by
/// identifier and by time alike.
///
/// Monotonic within one generator: two identifiers minted in the same
/// millisecond differ by the counter, and a counter overflow borrows the next
/// millisecond instead of repeating a value.
class UuidV7 {
  UuidV7({Random? random, LyeClock? clock})
    : _random = random ?? Random.secure(),
      _clock = clock ?? const SystemClock();

  final Random _random;
  final LyeClock _clock;

  int _lastMillis = -1;
  int _counter = 0;

  /// Mints a new identifier in the canonical `8-4-4-4-12` lower-case form.
  String generate() {
    var millis = _clock.now().toUtc().millisecondsSinceEpoch;
    if (millis <= _lastMillis) {
      millis = _lastMillis;
      _counter++;
      if (_counter > 0x0fff) {
        millis++;
        _counter = 0;
      }
    } else {
      _counter = _random.nextInt(0x0800);
    }
    _lastMillis = millis;

    final bytes = List<int>.filled(16, 0);
    // 48-bit timestamp, big-endian.
    for (var i = 5; i >= 0; i--) {
      bytes[i] = millis & 0xff;
      millis >>= 8;
    }
    // Version 7 in the high nibble, counter in the low 12 bits.
    bytes[6] = 0x70 | ((_counter >> 8) & 0x0f);
    bytes[7] = _counter & 0xff;
    // 62 random bits with the RFC 4122 variant.
    for (var i = 8; i < 16; i++) {
      bytes[i] = _random.nextInt(256);
    }
    bytes[8] = 0x80 | (bytes[8] & 0x3f);

    return format(bytes);
  }

  /// Formats 16 bytes as a canonical UUID string.
  static String format(List<int> bytes) {
    final hex = StringBuffer();
    for (var i = 0; i < 16; i++) {
      if (i == 4 || i == 6 || i == 8 || i == 10) hex.write('-');
      hex.write(bytes[i].toRadixString(16).padLeft(2, '0'));
    }
    return hex.toString();
  }

  static final RegExp _pattern = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  );

  /// Whether [value] is a well-formed lower-case UUID of any RFC version.
  static bool isValid(String value) => _pattern.hasMatch(value);

  /// Milliseconds since epoch encoded in a version 7 identifier.
  static int? timestampOf(String uuid) {
    if (!isValid(uuid) || uuid[14] != '7') return null;
    return int.parse(uuid.substring(0, 8) + uuid.substring(9, 13), radix: 16);
  }
}
