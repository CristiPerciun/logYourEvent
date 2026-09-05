import '../model/csv_schema.dart';
import '../model/lye_event.dart';
import 'csv_codec.dart';

/// Reads and writes LYE CSV documents (`lye.v1`).
///
/// A document is the header row followed by one row per event, encoded
/// with [CsvCodec]. UTF-8 without BOM.
abstract final class LyeCsv {
  /// The header row, terminator included.
  static String get header => CsvCodec.encodeRow(LyeCsvSchema.columns);

  /// One event as a CSV row, terminator included.
  static String encodeRow(LyeEvent event) =>
      CsvCodec.encodeRow(event.toCsvFields());

  /// A whole document.
  static String encode(Iterable<LyeEvent> events) {
    final out = StringBuffer(header);
    for (final event in events) {
      out.write(encodeRow(event));
    }
    return out.toString();
  }

  /// Parses a document, validating the header against the schema.
  ///
  /// Row hashes are not verified here: use `ChainVerifier`.
  static List<LyeEvent> decode(String text) {
    final rows = CsvCodec.decode(text);
    if (rows.isEmpty) {
      throw const FormatException('Empty CSV document');
    }
    final header = rows.first;
    if (header.length != LyeCsvSchema.columns.length) {
      throw FormatException(
        'Header has ${header.length} columns, schema ${LyeCsvSchema.version} '
        'has ${LyeCsvSchema.columns.length}',
      );
    }
    for (var i = 0; i < header.length; i++) {
      if (header[i] != LyeCsvSchema.columns[i]) {
        throw FormatException(
          'Column $i is "${header[i]}", expected "${LyeCsvSchema.columns[i]}"',
        );
      }
    }
    final events = <LyeEvent>[];
    for (var r = 1; r < rows.length; r++) {
      final row = rows[r];
      if (row.length == 1 && row.first.isEmpty) continue;
      try {
        events.add(LyeEvent.fromCsvFields(row));
      } on FormatException catch (e) {
        throw FormatException('Row ${r + 1}: ${e.message}');
      }
    }
    return events;
  }
}
