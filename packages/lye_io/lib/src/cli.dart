import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:lye_core/lye_core.dart';
import 'package:path/path.dart' as p;

import 'directory_verifier.dart';
import 'stream_exporter.dart';
import 'timeline.dart';

/// Entry point of the `lye` command. Returns the process exit code:
/// 0 success, 1 integrity problems found, 2 usage error.
///
/// ```text
/// lye verify   <dir> [--key <secret> --key-id <id>]
/// lye inspect  <file.csv>
/// lye timeline <dir> (--trace <id> | --call <digest> | --actor <ref>)
/// lye demo     <dir> [--tamper]
/// ```
Future<int> runLye(
  List<String> args, {
  StringSink? out,
  StringSink? err,
}) async {
  final stdoutSink = out ?? stdout;
  final stderrSink = err ?? stderr;
  if (args.isEmpty) {
    stderrSink.writeln(usage);
    return 2;
  }
  final options = _Options.parse(args.sublist(1));
  switch (args.first) {
    case 'verify':
      return _verify(options, stdoutSink, stderrSink);
    case 'inspect':
      return _inspect(options, stdoutSink, stderrSink);
    case 'timeline':
      return _timeline(options, stdoutSink, stderrSink);
    case 'demo':
      return _demo(options, stdoutSink, stderrSink);
    case 'help':
    case '--help':
    case '-h':
      stdoutSink.writeln(usage);
      return 0;
    default:
      stderrSink.writeln('Unknown command "${args.first}"\n\n$usage');
      return 2;
  }
}

/// Usage text.
const String usage =
    '''
lye — Log Your Event $lyeVersion

Commands:
  verify   <dir> [--key <secret> --key-id <id>]   recompute every hash under <dir>
  inspect  <file.csv>                              summarise one CSV file
  timeline <dir> --trace <id>                      events of one trace, across client and server
  timeline <dir> --call <digest>                   events around one RPC call digest
  timeline <dir> --actor <ref> [--from <ts> --to <ts>]
  demo     <dir> [--tamper]                        write a sample client+server export (and break it)

Exit codes: 0 ok, 1 integrity problems, 2 usage error.''';

LyeSigner? _signerFrom(_Options options) {
  final key = options['key'];
  if (key == null) return null;
  return HmacSha256Signer.fromSecret(
    key,
    keyId: options['key-id'] ?? 'default',
  );
}

Future<int> _verify(_Options options, StringSink out, StringSink err) async {
  final dir = options.positional.firstOrNull;
  if (dir == null) {
    err.writeln('verify needs a directory\n\n$usage');
    return 2;
  }
  final report = await DirectoryVerifier(
    signer: _signerFrom(options),
  ).verify(dir);
  out.write(report.render());
  return report.ok ? 0 : 1;
}

Future<int> _inspect(_Options options, StringSink out, StringSink err) async {
  final path = options.positional.firstOrNull;
  if (path == null) {
    err.writeln('inspect needs a CSV file\n\n$usage');
    return 2;
  }
  final file = File(path);
  if (!await file.exists()) {
    err.writeln('No such file: $path');
    return 2;
  }
  final events = LyeCsv.decode(await file.readAsString());
  final report = ChainVerifier.verify(
    events,
    expectedPrevHash: events.isEmpty
        ? HashChain.genesisHex
        : events.first.prevHash,
    expectedFirstSeq: events.isEmpty ? 1 : events.first.seq,
  );
  out.writeln('file:     $path');
  out.writeln('stream:   ${report.streamId}');
  out.writeln(
    'events:   ${report.eventsChecked} (seq ${report.firstSeq}..${report.lastSeq})',
  );
  out.writeln('head:     ${report.headHash}');
  out.writeln('chain:    ${report.ok ? 'OK' : 'BROKEN'}');
  for (final problem in report.problems) {
    out.writeln('  ! $problem');
  }
  final byAction = <String, int>{};
  for (final e in events) {
    byAction[e.action] = (byAction[e.action] ?? 0) + 1;
  }
  out.writeln('actions:');
  for (final entry
      in byAction.entries.toList()..sort(
        (MapEntry<String, int> a, MapEntry<String, int> b) =>
            a.key.compareTo(b.key),
      )) {
    out.writeln('  ${entry.key.padRight(30)} ${entry.value}');
  }
  return report.ok ? 0 : 1;
}

Future<int> _timeline(_Options options, StringSink out, StringSink err) async {
  final dir = options.positional.firstOrNull;
  final trace = options['trace'];
  final call = options['call'];
  final actor = options['actor'];
  if (dir == null || (trace == null && call == null && actor == null)) {
    err.writeln(
      'timeline needs a directory and one of --trace, --call, --actor\n\n$usage',
    );
    return 2;
  }
  final timeline = await Timeline.load(dir);
  List<LyeEvent> events;
  if (trace != null) {
    events = timeline.operation(trace);
  } else if (call != null) {
    events = timeline.operation(call);
  } else {
    final from = options['from'];
    final to = options['to'];
    events = timeline.byActor(
      actor!,
      from: from == null ? null : parseTimestampUtc(from),
      to: to == null ? null : parseTimestampUtc(to),
    );
  }
  if (events.isEmpty) {
    out.writeln('No events found.');
    return 0;
  }
  out.write(Timeline.render(events));
  return 0;
}

/// Writes a small but realistic export: a client stream with a tap, an RPC
/// call and its answer; a server stream that handles the call inside a
/// scoped transaction with two statements and an audit append; both
/// exported to CSV with signed manifests. With `--tamper`, one row of the
/// server file is then rewritten in place so `verify` has something to find.
Future<int> _demo(_Options options, StringSink out, StringSink err) async {
  final dir = options.positional.firstOrNull;
  if (dir == null) {
    err.writeln('demo needs a target directory\n\n$usage');
    return 2;
  }
  final signer = HmacSha256Signer.fromSecret('demo-secret', keyId: 'demo');
  final store = MemoryLyeStore();
  final clock = FixedClock(DateTime.utc(2026, 9, 5, 9, 30));
  final random = Random(2026);

  final client = LyeRecorder(
    config: LyeConfig(
      origin: LyeOrigin.client,
      platform: LyePlatform.web,
      appId: 'console_flutter',
      appVersion: '1.0.0+12',
      nodeId: 'demo-browser',
    ),
    store: store,
    clock: clock,
    random: random,
  );
  final server = LyeRecorder(
    config: LyeConfig(
      origin: LyeOrigin.server,
      platform: LyePlatform.linux,
      appId: 'cos_server',
      appVersion: '1.0.0+12',
      nodeId: 'demo-app-1',
    ),
    store: store,
    clock: clock,
    random: random,
  );
  const partner = '11111111-1111-1111-1111-111111111111';
  const tenant = '22222222-2222-2222-2222-222222222222';
  const actor = '55555555-5555-5555-5555-555555555555';
  client.context.update(
    scope: LyeScope.tenant,
    partnerId: partner,
    tenantId: tenant,
    actorRef: actor,
    actorRole: 'partner_staff',
    sessionRef: 'a3f1c2',
    route: '/ropa',
  );
  final args = <String, Object?>{
    'entry': <String, Object?>{
      'tenantId': tenant,
      'activityName': 'HR',
      'legalBasis': 'art. 6',
    },
  };
  final digest = CallCorrelation.digest(
    endpoint: 'ropa',
    method: 'addEntry',
    jsonArgs: args,
  );

  await client.start();
  await client.point(
    LyeCategory.navigation,
    LyeActions.navPush,
    route: '/ropa',
  );
  clock.advance(const Duration(seconds: 2));
  await client.span<void>(
    'ropa.entry.save',
    category: LyeCategory.interaction,
    action: LyeActions.uiIntent,
    component: 'ropa.save_button',
    body: (LyeSpan span) async {
      clock.advance(const Duration(milliseconds: 40));
      await client.span<void>(
        'rpc.ropa.addEntry',
        category: LyeCategory.rpc,
        action: LyeActions.rpcCall,
        route: CallCorrelation.route('ropa', 'addEntry'),
        attrs: CallCorrelation.attrs(
          endpoint: 'ropa',
          method: 'addEntry',
          jsonArgs: args,
        ),
        body: (_) async {
          // Server side, as it would run in cos_server: another process,
          // hence another trace. Detaching from the client span reproduces
          // that; the two traces meet on the call digest.
          await LyeSpan.detached(
            () => server.withContext(
              const LyeContextSnapshot(
                scope: LyeScope.tenant,
                partnerId: partner,
                tenantId: tenant,
                actorRef: actor,
                actorRole: 'partner_staff',
                sessionRef: 'a3f1c2',
                route: 'ropa.addEntry',
              ),
              () => server.span<void>(
                'rpc.ropa.addEntry',
                category: LyeCategory.rpc,
                action: LyeActions.rpcHandle,
                route: CallCorrelation.route('ropa', 'addEntry'),
                attrs: CallCorrelation.attrs(
                  endpoint: 'ropa',
                  method: 'addEntry',
                  jsonArgs: args,
                ),
                body: (_) async {
                  clock.advance(const Duration(milliseconds: 5));
                  await server.span<void>(
                    LyeActions.dbScope,
                    category: LyeCategory.db,
                    attrs: const <String, Object?>{'scope': 'tenant'},
                    body: (_) async {
                      clock.advance(const Duration(milliseconds: 3));
                      await server.point(
                        LyeCategory.db,
                        LyeActions.dbStatement,
                        component: 'ropa_entries',
                        attrs: <String, Object?>{
                          'kind': 'INSERT',
                          'sql_digest': HashChain.digestHex(
                            'INSERT INTO ropa_entries ...',
                          ),
                          'rows': 1,
                          'ms': 3,
                        },
                      );
                      clock.advance(const Duration(milliseconds: 2));
                      await server.point(
                        LyeCategory.audit,
                        LyeActions.auditAppend,
                        outcome: LyeOutcome.ok,
                        targetType: 'ropa_entry',
                        targetId: '01924f3a-7d6e-7c9a-8f1b-3c2d1e0f9a8b',
                        auditRef:
                            '$tenant:17:'
                            '9b74c9897bac770ffc029102a200c5de3f0c1f1e8e2a3d6f4d5b6c7a8b9c0d1e',
                        attrs: const <String, Object?>{
                          'action': 'ropa.entry.added',
                        },
                      );
                    },
                  );
                },
              ),
            ),
          );
          clock.advance(const Duration(milliseconds: 20));
        },
      );
    },
  );
  await client.close();
  await server.close();

  final run = await StreamExporter(
    store: store,
    root: dir,
    signer: signer,
    clock: clock,
  ).exportPending();
  out.writeln(
    'demo: ${run.eventsWritten} events written, ${run.manifests.length} files under $dir',
  );
  out.writeln('demo: call digest $digest');
  out.writeln('demo: try  lye verify "$dir" --key demo-secret --key-id demo');
  out.writeln('demo: try  lye timeline "$dir" --call $digest');

  if (options.flag('tamper')) {
    final manifest = run.manifests.firstWhere(
      (LyeManifest m) => m.streamId == server.streamId,
    );
    final file = File(
      p.joinAll(<String>[dir, ...manifest.streamId.split('/'), manifest.file]),
    );
    final rows = LineSplitter.split(await file.readAsString()).toList();
    // Rewrite the actor of the audit row: the classic "who did it" forgery.
    final index = rows.indexWhere(
      (String r) => r.contains(LyeActions.auditAppend),
    );
    rows[index] = rows[index].replaceFirst(
      actor,
      '99999999-9999-9999-9999-999999999999',
    );
    await file.writeAsString('${rows.join('\r\n')}\r\n', flush: true);
    out.writeln(
      'demo: tampered ${file.path} (actor of the audit row rewritten)',
    );
  }
  return 0;
}

class _Options {
  _Options(this.positional, this._named, this._flags);

  final List<String> positional;
  final Map<String, String> _named;
  final Set<String> _flags;

  String? operator [](String name) => _named[name];

  bool flag(String name) => _flags.contains(name);

  static _Options parse(List<String> args) {
    final positional = <String>[];
    final named = <String, String>{};
    final flags = <String>{};
    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      if (arg.startsWith('--')) {
        final name = arg.substring(2);
        if (i + 1 < args.length && !args[i + 1].startsWith('--')) {
          named[name] = args[++i];
        } else {
          flags.add(name);
        }
      } else {
        positional.add(arg);
      }
    }
    return _Options(positional, named, flags);
  }
}
