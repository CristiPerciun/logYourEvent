import 'package:lye_core/lye_core.dart';
import 'package:test/test.dart';

void main() {
  group('CsvCodec', () {
    test('quotes only when needed', () {
      expect(CsvCodec.encodeField('plain'), 'plain');
      expect(CsvCodec.encodeField(''), '');
      expect(CsvCodec.encodeField('a,b'), '"a,b"');
      expect(CsvCodec.encodeField('say "hi"'), '"say ""hi"""');
      expect(CsvCodec.encodeField('line\nbreak'), '"line\nbreak"');
      expect(CsvCodec.encodeField(' padded '), '" padded "');
    });

    test('rows end with CRLF', () {
      expect(CsvCodec.encodeRow(<String>['a', 'b']), 'a,b\r\n');
    });

    test('round-trips difficult content including RO and RU text', () {
      final rows = <List<String>>[
        <String>['id', 'text', 'json'],
        <String>['1', 'Ș ț Ă â î — Привет, мир', '{"a":"x,y","b":"q\\"r"}'],
        <String>['2', 'multi\r\nline', ''],
        <String>['3', '""', ' spaced '],
      ];
      final text = CsvCodec.encodeRows(rows);
      expect(CsvCodec.decode(text), rows);
    });

    test('accepts LF-only input and ignores a trailing newline', () {
      expect(CsvCodec.decode('a,b\nc,d\n'), <List<String>>[
        <String>['a', 'b'],
        <String>['c', 'd'],
      ]);
    });

    test('rejects malformed quoting', () {
      expect(() => CsvCodec.decode('a,"b'), throwsFormatException);
      expect(() => CsvCodec.decode('a,b"c'), throwsFormatException);
    });
  });
}
