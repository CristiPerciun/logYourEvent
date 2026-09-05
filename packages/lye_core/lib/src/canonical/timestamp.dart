/// Timestamp rendering shared with the compliance-os audit chain.
///
/// Format: `YYYY-MM-DDTHH:MM:SS.ffffffZ` — always UTC, always six fractional
/// digits, exactly what PostgreSQL produces with
/// `to_char(ts AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')`.
String formatTimestampUtc(DateTime timestamp) {
  final t = timestamp.toUtc();
  final micros = t.millisecond * 1000 + t.microsecond;
  return '${_pad(t.year, 4)}-${_pad(t.month, 2)}-${_pad(t.day, 2)}'
      'T${_pad(t.hour, 2)}:${_pad(t.minute, 2)}:${_pad(t.second, 2)}'
      '.${_pad(micros, 6)}Z';
}

final RegExp _timestampPattern = RegExp(
  r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z$',
);

/// Parses a timestamp produced by [formatTimestampUtc]. Anything else is a
/// [FormatException]: a lenient parser would let a rewritten timestamp keep
/// the same hash.
DateTime parseTimestampUtc(String text) {
  if (!_timestampPattern.hasMatch(text)) {
    throw FormatException('Not a LYE timestamp: "$text"');
  }
  return DateTime.parse(text).toUtc();
}

String _pad(int value, int width) => value.toString().padLeft(width, '0');
