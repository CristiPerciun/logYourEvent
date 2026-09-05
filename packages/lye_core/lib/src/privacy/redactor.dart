import 'package:meta/meta.dart';

import '../canonical/canonical_json.dart';
import '../chain/hash_chain.dart';
import 'text_sanitizer.dart';

/// A pattern that must never reach the trace, with the label that replaces it.
@immutable
class RedactionPattern {
  const RedactionPattern(this.label, this.regex);

  final String label;
  final RegExp regex;

  /// E-mail addresses.
  static final RedactionPattern email = RedactionPattern(
    'email',
    RegExp(r'[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}'),
  );

  /// Moldovan personal number (IDNP): 13 digits starting with 2 or 0.
  static final RedactionPattern idnp = RedactionPattern(
    'idnp',
    RegExp(r'(?<!\d)[02]\d{12}(?!\d)'),
  );

  /// Moldovan IBAN: `MD`, two check digits, twenty alphanumerics (24 chars).
  static final RedactionPattern iban = RedactionPattern(
    'iban',
    RegExp(r'\bMD\d{2}[A-Z0-9]{20}\b'),
  );

  /// Phone numbers in international or national form (8+ digits with
  /// optional separators).
  static final RedactionPattern phone = RedactionPattern(
    'phone',
    RegExp(r'(?<![\w/.\-])\+?\d(?:[\d\s\-()]{6,}\d)(?![\w/.\-])'),
  );

  /// Bearer tokens and JWTs.
  static final RedactionPattern token = RedactionPattern(
    'token',
    RegExp(
      r'\beyJ[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\b|Bearer\s+\S+',
    ),
  );

  /// Patterns applied by [RedactionPolicy.standard].
  static final List<RedactionPattern> standard = <RedactionPattern>[
    token,
    email,
    iban,
    idnp,
    phone,
  ];
}

/// What may enter the `attrs` column.
///
/// The policy is applied to the raw attributes of a draft. Keys are matched
/// case-insensitively; values are sanitised, pattern-scrubbed and bounded.
/// A strict policy with an allow-list is recommended for categories whose
/// attributes come from user input.
@immutable
class RedactionPolicy {
  const RedactionPolicy({
    this.allowKeys,
    this.denyKeys = defaultDenyKeys,
    this.denyKeyFragments = defaultDenyKeyFragments,
    this.patterns,
    this.maxStringLength = 200,
    this.maxDepth = 3,
    this.maxListItems = 20,
    this.maxKeys = 40,
    this.maxCanonicalLength = 4096,
  });

  /// Keys that are always redacted, whatever the policy.
  static const Set<String> defaultDenyKeys = <String>{
    'password',
    'passcode',
    'pin',
    'otp',
    'totp',
    'secret',
    'token',
    'access_token',
    'refresh_token',
    'authorization',
    'cookie',
    'email',
    'e_mail',
    'mail',
    'name',
    'first_name',
    'last_name',
    'full_name',
    'surname',
    'phone',
    'telephone',
    'mobile',
    'idnp',
    'address',
    'iban',
    'card_number',
    'cvv',
    'ssn',
    'birth_date',
    'date_of_birth',
  };

  /// Key fragments that mark a key as sensitive (`user_password_hash`...).
  static const Set<String> defaultDenyKeyFragments = <String>{
    'password',
    'secret',
    'token',
    'otp',
    'cookie',
    'authorization',
    'credential',
  };

  /// If set, only these keys survive; every other key is dropped.
  final Set<String>? allowKeys;
  final Set<String> denyKeys;
  final Set<String> denyKeyFragments;

  /// Patterns scrubbed from string values; null means
  /// [RedactionPattern.standard].
  final List<RedactionPattern>? patterns;
  final int maxStringLength;
  final int maxDepth;
  final int maxListItems;
  final int maxKeys;

  /// Cap on the canonical JSON length; above it the attributes are replaced
  /// by a truncation marker (the digest still covers the full payload).
  final int maxCanonicalLength;

  /// Deny-list plus standard patterns.
  static const RedactionPolicy standard = RedactionPolicy();

  /// Allow-list only.
  factory RedactionPolicy.strict(Set<String> allowKeys) {
    return RedactionPolicy(allowKeys: allowKeys);
  }

  List<RedactionPattern> get effectivePatterns =>
      patterns ?? RedactionPattern.standard;

  bool isKeyDenied(String key) {
    final lower = key.toLowerCase();
    if (denyKeys.contains(lower)) return true;
    for (final fragment in denyKeyFragments) {
      if (lower.contains(fragment)) return true;
    }
    return false;
  }

  bool isKeyAllowed(String key) {
    final allowed = allowKeys;
    return allowed == null || allowed.contains(key);
  }
}

/// Result of minimising a map of attributes.
@immutable
class RedactionResult {
  const RedactionResult({
    required this.attrs,
    required this.attrsCanonical,
    required this.payloadDigest,
    required this.redactedCount,
    required this.truncated,
  });

  /// Minimised attributes.
  final Map<String, Object?> attrs;

  /// Canonical JSON of [attrs], the value written in the `attrs` column.
  final String attrsCanonical;

  /// SHA-256 of the canonical JSON of the original attributes, or empty
  /// when the original was empty. A commitment to the real content: a
  /// verifier holding the original data can prove it matches without the
  /// trace ever storing it.
  final String payloadDigest;

  /// Number of keys or values that were dropped or scrubbed.
  final int redactedCount;

  /// Whether the canonical form had to be cut.
  final bool truncated;

  /// True when nothing was hidden: `sha256(attrs)` equals [payloadDigest].
  bool get isComplete => redactedCount == 0 && !truncated;
}

/// Applies a [RedactionPolicy] to raw attributes. Stateless and reusable.
class Redactor {
  const Redactor([this.policy = RedactionPolicy.standard]);

  final RedactionPolicy policy;

  /// Value written in place of a denied key's value.
  static const String redactedKey = '[redacted:key]';

  /// Key added when the attributes had to be cut.
  static const String truncatedKey = '_truncated';

  RedactionResult redact(Map<String, Object?> input) {
    if (input.isEmpty) {
      return const RedactionResult(
        attrs: <String, Object?>{},
        attrsCanonical: '{}',
        payloadDigest: '',
        redactedCount: 0,
        truncated: false,
      );
    }
    final digest = HashChain.digestHex(canonicalJson(input));
    final counter = _Counter();
    final attrs = _scrubMap(input, 1, counter);
    var canonical = canonicalJson(attrs);
    var truncated = false;
    if (canonical.length > policy.maxCanonicalLength) {
      truncated = true;
      final originalLength = canonical.length;
      attrs
        ..clear()
        ..[truncatedKey] = true
        ..['_original_length'] = originalLength;
      canonical = canonicalJson(attrs);
    }
    return RedactionResult(
      attrs: attrs,
      attrsCanonical: canonical,
      payloadDigest: digest,
      redactedCount: counter.value,
      truncated: truncated,
    );
  }

  Map<String, Object?> _scrubMap(
    Map<Object?, Object?> map,
    int depth,
    _Counter counter,
  ) {
    final out = <String, Object?>{};
    var keys = 0;
    for (final entry in map.entries) {
      final key = LyeText.sanitize(entry.key.toString(), maxLength: 64);
      if (!policy.isKeyAllowed(key)) {
        counter.value++;
        continue;
      }
      if (keys >= policy.maxKeys) {
        counter.value++;
        out[truncatedKey] = true;
        break;
      }
      keys++;
      if (policy.isKeyDenied(key)) {
        counter.value++;
        out[key] = redactedKey;
        continue;
      }
      out[key] = _scrubValue(entry.value, depth, counter);
    }
    return out;
  }

  Object? _scrubValue(Object? value, int depth, _Counter counter) {
    if (value == null || value is bool || value is int) return value;
    if (value is double) return value.isFinite ? value : null;
    if (value is String) {
      var text = value;
      for (final pattern in policy.effectivePatterns) {
        if (pattern.regex.hasMatch(text)) {
          text = text.replaceAll(pattern.regex, '[redacted:${pattern.label}]');
          counter.value++;
        }
      }
      return LyeText.sanitize(text, maxLength: policy.maxStringLength);
    }
    if (value is DateTime || value is Enum) return value;
    if (depth >= policy.maxDepth) {
      counter.value++;
      return '[redacted:depth]';
    }
    if (value is Map) {
      return _scrubMap(value, depth + 1, counter);
    }
    if (value is Iterable) {
      final items = <Object?>[];
      var count = 0;
      final total = value.length;
      for (final item in value) {
        if (count >= policy.maxListItems) {
          counter.value++;
          items.add('[redacted:${total - count} more]');
          break;
        }
        items.add(_scrubValue(item, depth + 1, counter));
        count++;
      }
      return items;
    }
    return LyeText.sanitize(
      value.toString(),
      maxLength: policy.maxStringLength,
    );
  }
}

class _Counter {
  int value = 0;
}
