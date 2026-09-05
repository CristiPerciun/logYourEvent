/// Minimal RFC 4180 codec.
///
/// Fields are quoted when they contain a comma, a double quote, CR, LF or
/// leading/trailing spaces; quotes are doubled; rows end with CRLF. The
/// decoder accepts CRLF and LF, quoted fields spanning lines and doubled
/// quotes, and rejects a quote in the middle of an unquoted field.
abstract final class CsvCodec {
  static const String delimiter = ',';
  static const String quote = '"';
  static const String rowTerminator = '\r\n';

  /// Whether [field] must be quoted.
  static bool needsQuoting(String field) {
    if (field.isEmpty) return false;
    if (field.startsWith(' ') || field.endsWith(' ')) return true;
    for (final unit in field.codeUnits) {
      if (unit == 0x2c || unit == 0x22 || unit == 0x0d || unit == 0x0a) {
        return true;
      }
    }
    return false;
  }

  /// Encodes one field.
  static String encodeField(String field) {
    if (!needsQuoting(field)) return field;
    return '$quote${field.replaceAll(quote, '$quote$quote')}$quote';
  }

  /// Encodes one row, terminator included.
  static String encodeRow(Iterable<String> fields) {
    return '${fields.map(encodeField).join(delimiter)}$rowTerminator';
  }

  /// Encodes many rows.
  static String encodeRows(Iterable<Iterable<String>> rows) {
    final out = StringBuffer();
    for (final row in rows) {
      out.write(encodeRow(row));
    }
    return out.toString();
  }

  /// Decodes a whole document into rows of fields. Empty trailing lines are
  /// ignored; other empty lines produce a row with one empty field.
  static List<List<String>> decode(String text) {
    final rows = <List<String>>[];
    var row = <String>[];
    final field = StringBuffer();
    var inQuotes = false;
    var fieldStarted = false;
    var i = 0;
    final n = text.length;

    void endField() {
      row.add(field.toString());
      field.clear();
      fieldStarted = false;
    }

    void endRow() {
      endField();
      rows.add(row);
      row = <String>[];
    }

    while (i < n) {
      final c = text[i];
      if (inQuotes) {
        if (c == quote) {
          if (i + 1 < n && text[i + 1] == quote) {
            field.write(quote);
            i += 2;
            continue;
          }
          inQuotes = false;
          i++;
          continue;
        }
        field.write(c);
        i++;
        continue;
      }
      if (c == quote) {
        if (fieldStarted) {
          throw FormatException('Unexpected quote at offset $i');
        }
        inQuotes = true;
        fieldStarted = true;
        i++;
        continue;
      }
      if (c == delimiter) {
        endField();
        i++;
        continue;
      }
      if (c == '\r') {
        if (i + 1 < n && text[i + 1] == '\n') i++;
        endRow();
        i++;
        continue;
      }
      if (c == '\n') {
        endRow();
        i++;
        continue;
      }
      field.write(c);
      fieldStarted = true;
      i++;
    }
    if (inQuotes) {
      throw const FormatException('Unterminated quoted field');
    }
    if (fieldStarted || row.isNotEmpty) {
      endRow();
    }
    return rows;
  }
}
