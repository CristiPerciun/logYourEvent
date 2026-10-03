import 'dart:convert';
import 'dart:math';

import 'package:archive/archive.dart';
import 'package:lye_archive/lye_archive.dart';
import 'package:lye_core/lye_core.dart';
import 'package:test/test.dart';

const String subjectRef = '3f2a91c4-1111-7000-8000-000000000001';

/// The console of one person, on a clock the test moves.
class _Console {
  _Console(DateTime start) : clock = FixedClock(start) {
    recorder = LyeRecorder(
      config: LyeConfig(
        origin: LyeOrigin.client,
        platform: LyePlatform.web,
        appId: 'console_flutter',
        appVersion: '1.0.0+1',
        nodeId: 'browser-1',
      ),
      store: MemoryLyeStore(),
      clock: clock,
      random: Random(7),
      level: LyeLevel.forensic,
    );
    recorder.context.update(
      scope: LyeScope.tenant,
      tenantId: '22222222-2222-2222-2222-222222222222',
      actorRef: subjectRef,
      actorRole: 'partner_owner',
    );
  }

  final FixedClock clock;
  late final LyeRecorder recorder;

  /// A page: an `application` event.
  Future<LyeEvent> page(String route) async => (await recorder.point(
    LyeCategory.navigation,
    LyeActions.navPush,
    outcome: LyeOutcome.ok,
    route: route,
  ))!;

  /// A call seen by the console: an `access` event.
  Future<LyeEvent> call(String route) async => (await recorder.point(
    LyeCategory.rpc,
    LyeActions.rpcCall,
    outcome: LyeOutcome.ok,
    route: route,
  ))!;
}

LyeReadableJournal journal() => LyeReadableJournal(<LyeJournalColumn>[
  LyeJournalColumn('Zona', (LyeJournalStep s) => s.event.route),
  LyeJournalColumn('Data', (LyeJournalStep s) => formatTimestampUtc(s.at)),
  LyeJournalColumn('Eveniment', (LyeJournalStep s) => s.event.action),
]);

void main() {
  test('a day without events has no file', () {
    expect(
      ReadableJournalDay.pack(
        journal: journal(),
        events: const <LyeEvent>[],
        day: '2026-10-02',
        baseName: 'jurnal_u3f2a91c4_20261002',
      ),
      isNull,
    );
  });

  test('a day whose events all happened on other days has no file', () async {
    final console = _Console(DateTime.utc(2026, 10, 1, 23, 59, 59));
    final before = await console.page('/home');
    console.clock.current = DateTime.utc(2026, 10, 3);
    final after = await console.page('/home');
    expect(
      ReadableJournalDay.pack(
        journal: journal(),
        events: <LyeEvent>[before, after],
        day: '2026-10-02',
        baseName: 'jurnal_u3f2a91c4_20261002',
      ),
      isNull,
      reason: '23:59:59 of the day before and 00:00 of the day after are not the day',
    );
  });

  test('the day is half-open: midnight belongs to the day that starts', () async {
    final console = _Console(DateTime.utc(2026, 10, 2));
    final first = await console.page('/home');
    console.clock.current = DateTime.utc(2026, 10, 2, 23, 59, 59, 999);
    final last = await console.call('/settings/license');
    console.clock.current = DateTime.utc(2026, 10, 3);
    final next = await console.page('/home');

    final packed = ReadableJournalDay.pack(
      journal: journal(),
      events: <LyeEvent>[next, last, first],
      day: '2026-10-02',
      baseName: 'jurnal_u3f2a91c4_20261002',
    )!;
    expect(packed.steps, 2);
    expect(packed.events, 2);
    expect(
      packed.retentions,
      <LyeRetention>{LyeRetention.application, LyeRetention.access},
    );
  });

  test('one ZIP with one CSV, the same CSV the journal renders', () async {
    final console = _Console(DateTime.utc(2026, 10, 2, 9));
    final events = <LyeEvent>[
      await console.page('/home'),
      await console.call('/settings/license'),
    ];
    final packed = ReadableJournalDay.pack(
      journal: journal(),
      events: events,
      day: '2026-10-02',
      baseName: 'jurnal_u3f2a91c4_20261002',
    )!;

    expect(packed.fileName, 'jurnal_u3f2a91c4_20261002.zip');
    expect(packed.csvName, 'jurnal_u3f2a91c4_20261002.csv');
    final members = ZipDecoder().decodeBytes(packed.bytes).files;
    expect(<String>[for (final f in members) f.name], <String>[packed.csvName]);

    final opened = ReadableJournalDay.open(packed.bytes);
    expect(opened.csvName, packed.csvName);
    expect(opened.csv, journal().encode(events));
    expect(packed.csvSize, opened.csv.length);
    expect(utf8.decode(opened.csv.sublist(3)).split('\r\n').first, 'Zona;Data;Eveniment');
    expect(packed.sha256, HashChain.digestBytesHex(packed.bytes));
  });

  test('the same events give the same bytes', () async {
    final console = _Console(DateTime.utc(2026, 10, 2, 9));
    final events = <LyeEvent>[
      await console.page('/home'),
      await console.call('/settings/license'),
    ];
    PackedJournalDay pack() => ReadableJournalDay.pack(
      journal: journal(),
      events: events.reversed,
      day: '2026-10-02',
      baseName: 'jurnal_u3f2a91c4_20261002',
    )!;
    expect(pack().bytes, pack().bytes);
  });

  test('a busy day takes a fraction of its CSV', () async {
    final console = _Console(DateTime.utc(2026, 10, 2, 8));
    final events = <LyeEvent>[];
    for (var i = 0; i < 400; i++) {
      console.clock.advance(const Duration(seconds: 30));
      events.add(await console.page('/documents/${i % 7}'));
    }
    final packed = ReadableJournalDay.pack(
      journal: journal(),
      events: events,
      day: '2026-10-02',
      baseName: 'jurnal_u3f2a91c4_20261002',
    )!;
    expect(packed.steps, 400);
    expect(packed.size, lessThan(packed.csvSize ~/ 3));
  });

  test('days and names that are not what they say are refused', () {
    PackedJournalDay? pack(String day, String baseName) => ReadableJournalDay.pack(
      journal: journal(),
      events: const <LyeEvent>[],
      day: day,
      baseName: baseName,
    );
    expect(() => pack('2026-02-30', 'jurnal'), throwsArgumentError);
    expect(() => pack('02.10.2026', 'jurnal'), throwsArgumentError);
    expect(() => pack('2026-10-02', '../jurnal'), throwsArgumentError);
    expect(() => pack('2026-10-02', 'jurnal ion@example.md'), throwsArgumentError);
    expect(() => pack('2026-10-02', ''), throwsArgumentError);
  });

  test('what is not a day package is refused when opened', () {
    expect(() => ReadableJournalDay.open(<int>[1, 2, 3]), throwsFormatException);
    final onlyText = ZipEncoder().encodeBytes(
      Archive()..add(ArchiveFile.string('README.txt', 'nimic')),
    );
    expect(() => ReadableJournalDay.open(onlyText), throwsFormatException);
  });

  test('dayOf and dayStart agree on UTC', () {
    expect(ReadableJournalDay.dayOf(DateTime.utc(2026, 10, 2, 23, 59)), '2026-10-02');
    expect(
      ReadableJournalDay.dayOf(DateTime.parse('2026-10-03T01:30:00+03:00')),
      '2026-10-02',
    );
    expect(ReadableJournalDay.dayStart('2026-10-02'), DateTime.utc(2026, 10, 2));
  });
}
