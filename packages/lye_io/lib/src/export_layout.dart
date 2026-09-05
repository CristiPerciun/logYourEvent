import 'package:path/path.dart' as p;

/// Where files live and how they are named.
///
/// ```text
/// <root>/<origin>/<node_id>/<epoch>/lye-YYYYMMDD-NNNN.csv
/// <root>/<origin>/<node_id>/<epoch>/lye-YYYYMMDD-NNNN.manifest.json
/// ```
///
/// The stream identifier `origin/node_id/epoch` maps directly to a
/// directory, one CSV per UTC day and part, and one manifest per CSV. Names
/// sort lexically in chain order, so a verifier never needs an index.
abstract final class ExportLayout {
  static final RegExp _csvName = RegExp(r'^lye-(\d{8})-(\d{4})\.csv$');

  /// Directory of a stream under [root].
  static String streamPath(String root, String streamId) {
    return p.joinAll(<String>[root, ...streamId.split('/')]);
  }

  /// Stream identifier from a stream directory under [root].
  static String streamIdFromPath(String root, String streamDirectory) {
    return p.split(p.relative(streamDirectory, from: root)).join('/');
  }

  /// `YYYYMMDD` of a UTC instant.
  static String dayOf(DateTime instant) {
    final t = instant.toUtc();
    return '${t.year.toString().padLeft(4, '0')}'
        '${t.month.toString().padLeft(2, '0')}'
        '${t.day.toString().padLeft(2, '0')}';
  }

  /// `lye-YYYYMMDD-NNNN.csv`.
  static String csvName(String day, int part) {
    return 'lye-$day-${part.toString().padLeft(4, '0')}.csv';
  }

  /// `lye-YYYYMMDD-NNNN.manifest.json` for a CSV name.
  static String manifestNameFor(String csvName) {
    return p.setExtension(csvName, '.manifest.json');
  }

  /// Whether [name] is a LYE CSV file name.
  static bool isCsvName(String name) => _csvName.hasMatch(name);

  /// `(day, part)` of a CSV file name, or null.
  static ({String day, int part})? parseCsvName(String name) {
    final match = _csvName.firstMatch(name);
    if (match == null) return null;
    return (day: match.group(1)!, part: int.parse(match.group(2)!));
  }
}
