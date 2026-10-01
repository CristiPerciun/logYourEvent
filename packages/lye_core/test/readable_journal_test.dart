import 'dart:convert';

import 'package:lye_core/lye_core.dart';
import 'package:test/test.dart';

import 'support.dart';

const String user = '3f2a91c4-1111-7000-8000-000000000001';

/// The console and the server of one person, on two clocks.
class _TwoSides {
  _TwoSides()
    : consoleClock = FixedClock(DateTime.utc(2026, 10, 1, 9)),
      serverClock = FixedClock(DateTime.utc(2026, 10, 1, 9)) {
    console = testRecorder(clock: consoleClock, nodeId: 'browser-1');
    server = testRecorder(
      clock: serverClock,
      origin: LyeOrigin.server,
      nodeId: 'app-1',
    );
    for (final r in <LyeRecorder>[console, server]) {
      r.context.update(
        scope: LyeScope.tenant,
        tenantId: 'org-1',
        actorRef: user,
        actorRole: 'partner_owner',
      );
    }
  }

  final FixedClock consoleClock;
  final FixedClock serverClock;
  late final LyeRecorder console;
  late final LyeRecorder server;

  void advance(Duration by) {
    consoleClock.advance(by);
    serverClock.advance(by);
  }

  Future<LyeEvent> page(String route) => console.mustRecord(
    LyeDraft(
      category: LyeCategory.navigation,
      action: LyeActions.navPush,
      outcome: LyeOutcome.ok,
      route: route,
    ),
  );

  Future<LyeEvent> tap(String route, String id) => console.mustRecord(
    LyeDraft(
      category: LyeCategory.interaction,
      action: LyeActions.uiTap,
      route: route,
      component: id,
      attrs: const <String, Object?>{'control': 'switch'},
    ),
  );

  /// The two ends of one call: the server handles it, the console sees the
  /// answer [late] afterwards.
  Future<List<LyeEvent>> call(
    String endpoint,
    String method, {
    required String page,
    LyeOutcome outcome = LyeOutcome.ok,
    String? code,
    Duration late = const Duration(milliseconds: 300),
  }) async {
    final attrs = CallCorrelation.attrs(
      endpoint: endpoint,
      method: method,
      jsonArgs: const <String, Object?>{'enabled': true},
    );
    final handle = await server.mustRecord(
      LyeDraft(
        category: LyeCategory.rpc,
        action: LyeActions.rpcHandle,
        outcome: outcome,
        route: CallCorrelation.route(endpoint, method),
        durationMs: 41,
        errorClass: outcome == LyeOutcome.ok ? null : 'CosServerException',
        attrs: <String, Object?>{...attrs, 'error_code': ?code},
      ),
    );
    consoleClock.advance(late);
    final call = await console.mustRecord(
      LyeDraft(
        category: LyeCategory.rpc,
        action: LyeActions.rpcCall,
        outcome: outcome,
        route: page,
        operation: 'rpc.$endpoint.$method',
        errorClass: outcome == LyeOutcome.ok ? null : 'minified:Class2683',
        attrs: attrs,
      ),
    );
    serverClock.advance(late);
    return <LyeEvent>[handle, call];
  }
}

LyeReadableJournal journal() => LyeReadableJournal(<LyeJournalColumn>[
  LyeJournalColumn('Zona', (LyeJournalStep s) => s.event.route),
  LyeJournalColumn('Data', (LyeJournalStep s) => formatTimestampUtc(s.at)),
  LyeJournalColumn(
    'Eveniment',
    (LyeJournalStep s) => s.failed
        ? 'Eroare ${s.attrs['error_code'] ?? s.errorClass}'
        : s.event.action,
  ),
  LyeJournalColumn('Rezultat', (LyeJournalStep s) => s.outcome.name),
  LyeJournalColumn(
    'Durata',
    (LyeJournalStep s) => s.durationMs == null ? '' : '${s.durationMs} ms',
  ),
]);

void main() {
  test('one call is one step, with the server outcome and duration', () async {
    final sides = _TwoSides();
    final events = <LyeEvent>[
      await sides.page('/settings/license'),
      ...await sides.call(
        'license',
        'setAutoRenew',
        page: '/settings/license',
        outcome: LyeOutcome.fail,
        code: 'LIC_RENEWAL_BLOCKED',
      ),
    ];
    final steps = journal().steps(events);
    expect(steps.length, 2, reason: 'the page, then the call');
    final call = steps.last;
    expect(call.event.action, LyeActions.rpcCall);
    expect(call.handling?.action, LyeActions.rpcHandle);
    expect(call.outcome, LyeOutcome.fail);
    expect(call.durationMs, 41);
    expect(call.errorClass, 'CosServerException');
    expect(call.attrs['error_code'], 'LIC_RENEWAL_BLOCKED');
  });

  test('the three classes come back together, in time order', () async {
    final sides = _TwoSides();
    final page = await sides.page('/settings/license'); // application
    sides.advance(const Duration(seconds: 2));
    final tap = await sides.tap('/settings/license', 'license_auto_renew_switch');
    sides.advance(const Duration(seconds: 1));
    final call = await sides.call('license', 'setAutoRenew', page: '/settings/license');
    expect(page.retention, LyeRetention.application);
    expect(call.first.retention, LyeRetention.access);

    // As the server reads them: one class at a time, newest archive first.
    final mixed = <LyeEvent>[...call, tap, page];
    final steps = journal().steps(mixed);
    expect(
      steps.map((LyeJournalStep s) => s.event.action),
      <String>[LyeActions.navPush, LyeActions.uiTap, LyeActions.rpcCall],
    );
  });

  test('an event read twice counts once', () async {
    final sides = _TwoSides();
    final a = await sides.page('/home');
    final b = await sides.tap('/home', 'open_settings');
    final steps = journal().steps(<LyeEvent>[a, b, a, b]);
    expect(steps.length, 2);
  });

  test('a call the server never received stays a step of its own', () async {
    final sides = _TwoSides();
    final attrs = CallCorrelation.attrs(
      endpoint: 'billing',
      method: 'getInvoicePdf',
      jsonArgs: const <String, Object?>{'invoiceId': 'x'},
    );
    final lonely = await sides.console.mustRecord(
      LyeDraft(
        category: LyeCategory.rpc,
        action: LyeActions.rpcCall,
        outcome: LyeOutcome.fail,
        route: '/billing',
        attrs: <String, Object?>{...attrs, 'status': -1},
      ),
    );
    final steps = journal().steps(<LyeEvent>[lonely]);
    expect(steps.single.handling, isNull);
    expect(steps.single.failed, isTrue);
  });

  test('two ends too far apart in time are not joined', () async {
    final sides = _TwoSides();
    final ends = await sides.call(
      'license',
      'getActiveLicense',
      page: '/home',
      late: const Duration(minutes: 5),
    );
    final steps = journal().steps(ends);
    expect(steps.length, 2);
    expect(steps.every((LyeJournalStep s) => s.handling == null), isTrue);
  });

  test('repeated identical calls pair with their own handling', () async {
    final sides = _TwoSides();
    final first = await sides.call('license', 'getActiveLicense', page: '/home');
    sides.advance(const Duration(seconds: 30));
    final second = await sides.call('license', 'getActiveLicense', page: '/home');
    final steps = journal().steps(<LyeEvent>[...first, ...second]);
    expect(steps.length, 2);
    expect(steps[0].handling?.eventId, first[0].eventId);
    expect(steps[1].handling?.eventId, second[0].eventId);
  });

  test('the CSV has the header, one row per step, and ";"', () async {
    final sides = _TwoSides();
    final events = <LyeEvent>[
      await sides.page('/settings/license'),
      ...await sides.call(
        'license',
        'setAutoRenew',
        page: '/settings/license',
        outcome: LyeOutcome.fail,
        code: 'LIC_RENEWAL_BLOCKED',
      ),
    ];
    final text = journal().render(events);
    final lines = text.split('\r\n')..removeLast();
    expect(lines.first, 'Zona;Data;Eveniment;Rezultat;Durata');
    expect(lines.length, 3);
    expect(lines[2], contains(';Eroare LIC_RENEWAL_BLOCKED;fail;41 ms'));
  });

  test('the bytes start with a byte order mark and are UTF-8', () async {
    final sides = _TwoSides();
    final bytes = LyeReadableJournal(<LyeJournalColumn>[
      LyeJournalColumn('Zonă', (LyeJournalStep s) => 'Configurări'),
    ]).encode(<LyeEvent>[await sides.page('/settings')]);
    expect(bytes.sublist(0, 3), <int>[0xEF, 0xBB, 0xBF]);
    expect(utf8.decode(bytes.sublist(3)), 'Zonă\r\nConfigurări\r\n');
  });

  test('cells are quoted, kept on one line and never run as formulas', () async {
    final sides = _TwoSides();
    final event = await sides.page('/home');
    final text = LyeReadableJournal(<LyeJournalColumn>[
      LyeJournalColumn('a', (LyeJournalStep s) => '=HYPERLINK("x")'),
      LyeJournalColumn('b', (LyeJournalStep s) => 'unu; doi'),
      LyeJournalColumn('c', (LyeJournalStep s) => 'rând\nnou'),
    ]).render(<LyeEvent>[event]);
    final row = text.split('\r\n')[1];
    expect(row, '"\'=HYPERLINK(""x"")";"unu; doi";rând\\nnou');
  });

  group('areas', () {
    const areas = LyeJournalAreas(<LyeAreaRule>[
      LyeAreaRule('Licență', endpoints: <String>['license'], routes: <String>['/licenses']),
      LyeAreaRule('Facturare', endpoints: <String>['billing'], routes: <String>['/billing']),
      LyeAreaRule('Acces', actions: <String>['auth.']),
      LyeAreaRule('Licență (setări)', routes: <String>['/settings/license']),
      LyeAreaRule('Configurări', routes: <String>['/settings']),
    ], fallback: 'Sistem');

    test('a call is about its endpoint, not the page it came from', () async {
      final sides = _TwoSides();
      final steps = journal().steps(
        await sides.call('license', 'getActiveLicense', page: '/billing'),
      );
      expect(areas.of(steps.single), 'Licență');
    });

    test('a handling without its call is found through the operation', () async {
      final sides = _TwoSides();
      final handle = await sides.server.mustRecord(
        const LyeDraft(
          category: LyeCategory.audit,
          action: 'invitation.created',
          operation: 'rpc.billing.createCheckout',
        ),
      );
      expect(areas.of(LyeJournalStep(handle)), 'Facturare');
    });

    test('an action wins over the page', () async {
      final sides = _TwoSides();
      final login = await sides.console.mustRecord(
        const LyeDraft(
          category: LyeCategory.auth,
          action: LyeActions.authLogin,
          outcome: LyeOutcome.ok,
          route: '/billing',
        ),
      );
      expect(areas.of(LyeJournalStep(login)), 'Acces');
    });

    test('a tap belongs to its page, the narrower route first', () async {
      final sides = _TwoSides();
      final tap = await sides.tap('/settings/license', 'license_auto_renew_switch');
      final other = await sides.tap('/settings/brand', 'brand_upload');
      final lookalike = await sides.tap('/settingsx', 'x');
      expect(areas.of(LyeJournalStep(tap)), 'Licență (setări)');
      expect(areas.of(LyeJournalStep(other)), 'Configurări');
      expect(areas.of(LyeJournalStep(lookalike)), 'Sistem');
    });

    test('a server route is not a page', () async {
      final sides = _TwoSides();
      final job = await sides.server.mustRecord(
        const LyeDraft(
          category: LyeCategory.job,
          action: LyeActions.jobComplete,
          outcome: LyeOutcome.ok,
          route: '/billing',
        ),
      );
      expect(areas.of(LyeJournalStep(job)), 'Sistem');
    });
  });

  test('more than six columns is two tables, not one', () {
    expect(
      () => LyeReadableJournal(<LyeJournalColumn>[
        for (var i = 0; i < 7; i++)
          LyeJournalColumn('c$i', (LyeJournalStep s) => ''),
      ]),
      throwsArgumentError,
    );
    expect(
      () => LyeReadableJournal(const <LyeJournalColumn>[]),
      throwsArgumentError,
    );
    expect(
      () => LyeReadableJournal(<LyeJournalColumn>[
        LyeJournalColumn('a', (LyeJournalStep s) => ''),
      ], delimiter: '"'),
      throwsArgumentError,
    );
  });
}
