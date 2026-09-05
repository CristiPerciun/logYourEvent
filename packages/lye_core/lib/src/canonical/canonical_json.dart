import 'dart:convert';

import 'timestamp.dart';

/// Canonical JSON rendering (RFC 8785 principles): object keys sorted by
/// UTF-16 code units, no whitespace, scalars rendered by `jsonEncode`.
///
/// It is deliberately identical to `AuditService.canonicalizeJson` in
/// compliance-os, so a digest computed by LYE over the same map equals the
/// digest computed by the audit module.
///
/// Non-JSON values are normalised before encoding: [DateTime] becomes the
/// ISO-8601 UTC timestamp with microseconds, [Enum] becomes its name,
/// non-finite doubles become `null`, anything else becomes its `toString()`.
String canonicalJson(Object? value) {
  final buffer = StringBuffer();
  _write(value, buffer);
  return buffer.toString();
}

void _write(Object? value, StringBuffer out) {
  if (value == null) {
    out.write('null');
  } else if (value is Map) {
    final keys = value.keys.map((Object? k) => k.toString()).toList()..sort();
    // Duplicate keys after toString() are collapsed on purpose: the last one
    // wins, exactly as PostgreSQL jsonb would do.
    final byKey = <String, Object?>{};
    for (final entry in value.entries) {
      byKey[entry.key.toString()] = entry.value;
    }
    out.write('{');
    var first = true;
    for (final key in keys.toSet()) {
      if (!first) out.write(',');
      first = false;
      out.write(jsonEncode(key));
      out.write(':');
      _write(byKey[key], out);
    }
    out.write('}');
  } else if (value is Iterable) {
    out.write('[');
    var first = true;
    for (final item in value) {
      if (!first) out.write(',');
      first = false;
      _write(item, out);
    }
    out.write(']');
  } else if (value is String) {
    out.write(jsonEncode(value));
  } else if (value is bool) {
    out.write(value ? 'true' : 'false');
  } else if (value is int) {
    out.write(value.toString());
  } else if (value is double) {
    out.write(value.isFinite ? jsonEncode(value) : 'null');
  } else if (value is DateTime) {
    out.write(jsonEncode(formatTimestampUtc(value)));
  } else if (value is Enum) {
    out.write(jsonEncode(value.name));
  } else {
    out.write(jsonEncode(value.toString()));
  }
}
