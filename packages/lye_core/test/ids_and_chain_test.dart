import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:lye_core/lye_core.dart';
import 'package:test/test.dart';

void main() {
  group('UuidV7', () {
    test('produces well-formed version 7 identifiers', () {
      final generator = UuidV7(random: Random(1));
      for (var i = 0; i < 100; i++) {
        final id = generator.generate();
        expect(UuidV7.isValid(id), isTrue, reason: id);
        expect(id[14], '7');
        expect('89ab'.contains(id[19]), isTrue);
      }
    });

    test('is monotonic inside the same millisecond', () {
      final clock = FixedClock(DateTime.utc(2026, 9, 5));
      final generator = UuidV7(random: Random(7), clock: clock);
      final ids = List<String>.generate(5000, (_) => generator.generate());
      for (var i = 1; i < ids.length; i++) {
        expect(
          ids[i].compareTo(ids[i - 1]) > 0,
          isTrue,
          reason: '${ids[i - 1]} -> ${ids[i]}',
        );
      }
      expect(ids.toSet().length, ids.length);
    });

    test('encodes the clock', () {
      final clock = FixedClock(DateTime.utc(2026, 9, 5, 12));
      final id = UuidV7(random: Random(3), clock: clock).generate();
      expect(UuidV7.timestampOf(id), clock.now().millisecondsSinceEpoch);
    });
  });

  group('hex', () {
    test('round-trips and compares in constant time', () {
      final bytes = List<int>.generate(32, (int i) => (i * 7) & 0xff);
      final hex = bytesToHex(bytes);
      expect(hex.length, 64);
      expect(hexToBytes(hex), bytes);
      expect(constantTimeEquals(bytes, hexToBytes(hex)), isTrue);
      expect(
        constantTimeEquals(bytes, hexToBytes(hex.replaceRange(0, 1, 'f'))),
        isFalse,
      );
      expect(() => hexToBytes('abc'), throwsFormatException);
      expect(() => hexToBytes('zz'), throwsFormatException);
    });
  });

  group('HashChain', () {
    test('uses the same construction as audit.canonical_event_v1', () {
      final fields = <String>['lye.v1', '1', 'x'];
      final canonical = HashChain.canonicalEventV1(fields);
      expect(canonical, 'lye.v11x');
      final expected = sha256.convert(<int>[
        ...HashChain.genesis,
        ...utf8.encode(canonical),
      ]).bytes;
      expect(
        HashChain.rowHashHex(HashChain.genesisHex, canonical),
        bytesToHex(expected),
      );
    });

    test('refuses a field containing the separator', () {
      expect(
        () => HashChain.canonicalEventV1(<String>['ab']),
        throwsArgumentError,
      );
    });

    test('genesis is 32 zero bytes', () {
      expect(HashChain.genesis.length, 32);
      expect(HashChain.genesis.every((int b) => b == 0), isTrue);
      expect(bytesToHex(HashChain.genesis), HashChain.genesisHex);
    });
  });
}
