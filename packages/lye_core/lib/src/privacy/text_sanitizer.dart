/// Normalisation of free-text fields before they are hashed and written.
///
/// Applied by the recorder to every string column and to every string inside
/// the attributes, so that the value that enters the hash is exactly the
/// value that lands in the CSV. Verification therefore never has to guess
/// how a value was escaped.
abstract final class LyeText {
  /// Default cap for a single column.
  static const int defaultMaxLength = 512;

  /// Marker appended when a value is cut.
  static const String truncationMarker = '…';

  static final RegExp _controlChars = RegExp(
    '[\\x00-\\x08\\x0B\\x0C\\x0E-\\x1F\\x7F]',
  );

  /// Characters that make a spreadsheet interpret a cell as a formula.
  static const String formulaLeaders = '=+-@';

  /// Returns a single-line, spreadsheet-safe, bounded copy of [input].
  ///
  /// - CR/LF become the two characters `\n`, so a row is always one line;
  /// - tabs become spaces, other control characters (including the record
  ///   separator 0x1E) are removed;
  /// - a leading `=`, `+`, `-` or `@` is prefixed with an apostrophe, the
  ///   OWASP mitigation against CSV formula injection;
  /// - values longer than [maxLength] are cut and marked.
  static String sanitize(String input, {int maxLength = defaultMaxLength}) {
    var text = input
        .replaceAll('\r\n', r'\n')
        .replaceAll('\r', r'\n')
        .replaceAll('\n', r'\n')
        .replaceAll('\t', ' ')
        .replaceAll(_controlChars, '');
    if (text.isNotEmpty && formulaLeaders.contains(text[0])) {
      text = "'$text";
    }
    if (text.length > maxLength) {
      text = '${text.substring(0, maxLength - 1)}$truncationMarker';
    }
    return text;
  }

  /// Whether [input] would come back unchanged from [sanitize].
  static bool isClean(String input, {int maxLength = defaultMaxLength}) {
    return sanitize(input, maxLength: maxLength) == input;
  }
}
