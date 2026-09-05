import 'package:lye_core/lye_core.dart';

/// Reduces a SQL statement to what may be traced: its shape, never its data.
///
/// compliance-os uses named parameters (`@tenantId`), so the statement text
/// carries no values; whitespace is collapsed and the template is digested.
/// The trace stores the digest and the first keyword; a reviewer with access
/// to the source can map digests back to statements, an attacker holding
/// only the CSV learns nothing about the rows.
abstract final class SqlTemplate {
  static final RegExp _whitespace = RegExp(r'\s+');
  static final RegExp _stringLiteral = RegExp(r"'(?:[^']|'')*'");
  static final RegExp _numberLiteral = RegExp(r'\b\d+(?:\.\d+)?\b');

  /// Collapsed whitespace, literals replaced by `?`, trimmed.
  static String normalize(String sql) {
    return sql
        .replaceAll(_stringLiteral, '?')
        .replaceAll(_numberLiteral, '?')
        .replaceAll(_whitespace, ' ')
        .trim();
  }

  /// First keyword in upper case (`SELECT`, `INSERT`, `UPDATE`, `WITH`...).
  static String kindOf(String sql) {
    final normalized = normalize(sql);
    if (normalized.isEmpty) return 'UNKNOWN';
    final firstToken = normalized.split(' ').first.toUpperCase();
    return firstToken.replaceAll(RegExp(r'[^A-Z_]'), '');
  }

  /// SHA-256 of the normalised template.
  static String digest(String sql) => HashChain.digestHex(normalize(sql));

  /// Table name after FROM/INTO/UPDATE/JOIN, when obvious; empty otherwise.
  static String tableOf(String sql) {
    final match = RegExp(
      r'\b(?:FROM|INTO|UPDATE|JOIN)\s+([A-Za-z_][A-Za-z0-9_.]*)',
      caseSensitive: false,
    ).firstMatch(normalize(sql));
    return match?.group(1) ?? '';
  }
}
