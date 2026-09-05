import 'package:lye_core/lye_core.dart';
import 'package:test/test.dart';

void main() {
  group('canonicalJson', () {
    test('sorts keys and removes whitespace at every level', () {
      final value = <String, Object?>{
        'b': 1,
        'a': <String, Object?>{
          'z': true,
          'y': <Object?>[1, 'two', null],
        },
      };
      expect(canonicalJson(value), '{"a":{"y":[1,"two",null],"z":true},"b":1}');
    });

    test('is identical to the compliance-os audit canonicalization', () {
      // Same input, same output as AuditService.canonicalizeJson.
      final value = <String, Object?>{
        'id': 'x',
        'activity_name': 'HR',
        'legal_basis': 'art. 6',
      };
      expect(
        canonicalJson(value),
        '{"activity_name":"HR","id":"x","legal_basis":"art. 6"}',
      );
    });

    test('normalises non-JSON values deterministically', () {
      final when = DateTime.utc(2026, 9, 5, 10, 20, 30, 123, 456);
      expect(
        canonicalJson(<String, Object?>{
          't': when,
          'e': LyeScope.tenant,
          'd': double.nan,
        }),
        '{"d":null,"e":"tenant","t":"2026-09-05T10:20:30.123456Z"}',
      );
    });

    test('escapes strings like jsonEncode', () {
      expect(canonicalJson('a"b\n'), '"a\\"b\\n"');
    });
  });

  group('timestamps', () {
    test('formats UTC with six fractional digits', () {
      final when = DateTime.utc(2026, 1, 2, 3, 4, 5, 6, 7);
      expect(formatTimestampUtc(when), '2026-01-02T03:04:05.006007Z');
    });

    test('converts local time to UTC', () {
      final local = DateTime(2026, 1, 2, 3, 4, 5);
      expect(formatTimestampUtc(local), formatTimestampUtc(local.toUtc()));
    });

    test('round-trips', () {
      final when = DateTime.utc(2026, 12, 31, 23, 59, 59, 999, 999);
      expect(parseTimestampUtc(formatTimestampUtc(when)), when);
    });

    test('rejects lenient forms', () {
      expect(
        () => parseTimestampUtc('2026-01-02T03:04:05Z'),
        throwsFormatException,
      );
      expect(
        () => parseTimestampUtc('2026-01-02 03:04:05.000000Z'),
        throwsFormatException,
      );
      expect(
        () => parseTimestampUtc('2026-01-02T03:04:05.000000+02:00'),
        throwsFormatException,
      );
    });
  });
}
