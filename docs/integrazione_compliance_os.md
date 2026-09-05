# Integrazione di LYE in Compliance OS

**Versione LYE** 0.1.0 · **Destinatari** `apps/console_flutter`, `packages/cos_server` · **Stato** guida operativa, da eseguire nel blocco "Fondazioni" di F1 (DTA §13.2)

Questa guida contiene il codice degli adattatori che vivono nel repository `compliance-os` (ADR-002 di LYE). Le API di Serverpod citate sono quelle della versione in uso oggi (2.9.5); al passaggio a 3.x/4.x cambiano solo questi frammenti, non la libreria. I frammenti sono stati scritti leggendo il codice sorgente di `serverpod` 2.9.5, `serverpod_client` 2.9.5 e `riverpod` 3.1.0 presenti nella cache pub del progetto.

## 1. Dipendenze

```yaml
# apps/console_flutter/pubspec.yaml
dependencies:
  lye_core:
    git: {url: https://github.com/CristiPerciun/log-your-event.git, ref: v0.1.0, path: packages/lye_core}
  lye_flutter:
    git: {url: https://github.com/CristiPerciun/log-your-event.git, ref: v0.1.0, path: packages/lye_flutter}

# packages/cos_server/pubspec.yaml
dependencies:
  lye_core:
    git: {url: https://github.com/CristiPerciun/log-your-event.git, ref: v0.1.0, path: packages/lye_core}
  lye_io:
    git: {url: https://github.com/CristiPerciun/log-your-event.git, ref: v0.1.0, path: packages/lye_io}
  lye_server:
    git: {url: https://github.com/CristiPerciun/log-your-event.git, ref: v0.1.0, path: packages/lye_server}
  lye_realm:
    git: {url: https://github.com/CristiPerciun/log-your-event.git, ref: v0.1.0, path: packages/lye_realm}
```

Il repository è un pub workspace: aggiungere le dipendenze nei pubspec dei membri e rilanciare `flutter pub get` alla radice. Fino alla pubblicazione del remoto si può lavorare con `path: ../../../log-your-event/packages/lye_core` (stesso layout, cartelle sorelle) e passare al `git`/`ref` al primo tag.

Dockerfile di `cos_server`: dopo `dart pub get` aggiungere `RUN dart run realm_dart install` e, se si compila con `dart compile exe`, copiare la libreria nativa (`.dart_tool`/`binary/linux/librealm_dart.so`) accanto all'eseguibile o restare in modalità JIT (`dart run`). Da verificare nello spike di F0 (punto aperto §18 del documento tecnico).

## 2. Console Flutter

### 2.1 Bootstrap (`lib/main.dart` e `lib/core/lye/`)

Il recorder nasce **prima** di `runApp`, perché l'osservatore Riverpod va passato al `ProviderScope`; poi è esposto come provider `keepAlive` con `overrideWithValue`, così il resto dell'app lo legge con `ref.watch` senza singleton globali.

```dart
// lib/core/lye/lye_recorder_provider.dart
import 'dart:async';
import 'package:lye_core/lye_core.dart';
import 'package:lye_flutter/lye_flutter.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'lye_recorder_provider.g.dart';

/// Costruito in main(); il provider viene sovrascritto con l'istanza.
LyeRecorder createLyeRecorder({required String installationId, required String appVersion}) {
  return LyeRecorder(
    config: LyeConfig(
      origin: LyeOrigin.client,
      platform: LyeFlutterPlatform.current,
      appId: 'console_flutter',
      appVersion: appVersion,            // da package_info_plus: "1.0.0+12"
      nodeId: installationId,            // UUID casuale persistito da PlatformServices (§8.2 DTA)
    ),
    store: MemoryLyeStore(maxEvents: 5000),   // web: nessuna persistenza locale (§8.5 DTA)
  );
}

@Riverpod(keepAlive: true)
LyeRecorder lyeRecorder(Ref ref) => throw UnimplementedError('overridden in main()');
```

```dart
// lib/main.dart
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SemanticsBinding.instance.ensureSemantics();

  final platform = await PlatformServices.create();          // storage sicuro, installation id
  final recorder = createLyeRecorder(
    installationId: await platform.installationId(),
    appVersion: await platform.appVersion(),
  );
  LyeErrorHooks.install(recorder);                            // FlutterError + PlatformDispatcher
  LyePointerTracker(recorder).install();                      // tap sui LyeTrackable
  LyeLifecycleObserver(recorder).install();                   // resume/pause, lingua
  unawaited(recorder.start());                                // lye.stream.start

  runApp(ProviderScope(
    overrides: [lyeRecorderProvider.overrideWithValue(recorder)],
    observers: [
      LyeProviderObserver(recorder, include: (String name) => !name.startsWith('_')),
    ],
    child: const ComplianceOsApp(),
  ));
}
```

### 2.2 Navigazione (`lib/app/router/app_router.dart`)

```dart
final appRouterProvider = Provider<GoRouter>((ref) {
  final recorder = ref.watch(lyeRecorderProvider);
  return GoRouter(
    observers: [LyeNavigatorObserver(recorder)],   // nav.push/pop/replace + route nel contesto
    initialLocation: '/dashboard',
    // ...
  );
});
```

go_router riempie `RouteSettings.name` con il nome o il pattern della rotta: nel tracciato compare `/t/:tenantId/ropa/:id`, mai testo dello schermo.

### 2.3 Identità e tenant (`features/auth`, `features/tenancy`)

```dart
// AuthNotifier.login, dopo la risposta del server
ref.read(lyeRecorderProvider).context.update(
  scope: LyeScope.partner,
  partnerId: partnerId,
  actorRef: userId,                                    // UUID: pseudonimo, mai e-mail o nome
  actorRole: role,                                     // partner_owner, partner_staff, tenant_admin...
  sessionRef: HashChain.digestHex(sessionKey).substring(0, 16),   // mai il token
);
unawaited(ref.read(lyeRecorderProvider).point(LyeCategory.auth, LyeActions.authLogin, outcome: LyeOutcome.ok));

// AuthNotifier.logout
await ref.read(lyeShippingProvider).flush();          // spedisce quanto resta prima di dimenticare
recorder.context.clearIdentity();
unawaited(recorder.point(LyeCategory.auth, LyeActions.authLogout, outcome: LyeOutcome.ok));

// ActiveTenancyNotifier.selectTenant
recorder.context.update(scope: LyeScope.tenant, tenantId: tenantId, partnerId: partnerId);
unawaited(recorder.point(LyeCategory.auth, LyeActions.authTenantSwitch, outcome: LyeOutcome.ok,
    targetType: 'organization', targetId: tenantId));
```

### 2.4 Chiamate RPC: hook del client Serverpod (`lib/core/client/client_provider.dart`)

Il costruttore generato di `Client` espone `onSucceededCall` e `onFailedCall`. `formatArgs` scrive la chiave `method` nella stessa mappa che i callback ricevono: si toglie la busta con `CallCorrelation.stripEnvelope` e si serializza come sul filo con `SerializationManager.encode`, così il digest coincide con quello calcolato dal server.

```dart
@Riverpod(keepAlive: true)
Client client(Ref ref) {
  final recorder = ref.watch(lyeRecorderProvider);
  return Client(
    'http://localhost:8080/',
    onSucceededCall: (MethodCallContext ctx) => _recordCall(recorder, ctx),
    onFailedCall: (MethodCallContext ctx, Object error, StackTrace _) => _recordCall(recorder, ctx, error: error),
  );
}

Map<String, Object?> _wireArgs(MethodCallContext ctx) {
  final json = jsonDecode(SerializationManager.encode(ctx.arguments)) as Map<Object?, Object?>;
  return CallCorrelation.stripEnvelope(json);
}

void _recordCall(LyeRecorder recorder, MethodCallContext ctx, {Object? error}) {
  unawaited(recorder.record(LyeDraft(
    category: LyeCategory.rpc,
    action: LyeActions.rpcCall,
    outcome: error == null ? LyeOutcome.ok : LyeOutcome.fail,
    route: CallCorrelation.route(ctx.endpointName, ctx.methodName),
    attrs: CallCorrelation.attrs(endpoint: ctx.endpointName, method: ctx.methodName, jsonArgs: _wireArgs(ctx)),
    errorClass: error?.runtimeType.toString(),
    errorDigest: error == null ? null : HashChain.digestHex(error.toString()),
  )));
}
```

I callback scattano dentro la chiamata, quindi dentro la `Zone` dello span che la contiene: l'evento `rpc.call` eredita la traccia dell'intento utente. Per avere inizio, fine e durata, i repository avvolgono la chiamata in uno span:

```dart
// features/ropa/data/ropa_repository.dart
Future<RopaEntry> addEntry(RopaEntry entry) => _lye.span<RopaEntry>(
      'ropa.entry.add',
      category: LyeCategory.rpc,
      route: 'ropa.addEntry',
      targetType: 'ropa_entry',
      body: (_) => _client.ropa.addEntry(entry.copyWith(tenantId: _tenantId)),
    );
```

### 2.5 Controlli taggati (`features/*/ui`)

Solo `ConsumerWidget` (ARCHITECTURE_RULES §1): `LyeTrackable` è uno `StatelessWidget` senza stato proprio.

```dart
LyeTrackable(
  'ropa.save_button',
  intent: 'ropa.entry.save',          // → ui.intent con operation = ropa.entry.save
  child: CosButton(label: strings.save, onPressed: () => ref.read(ropaControllerProvider.notifier).saveEntry(entry)),
)
```

Convenzione degli identificativi: `<feature>.<controllo>` in inglese, mai etichette tradotte.

### 2.6 Spedizione (`lib/core/lye/lye_shipping_provider.dart`)

```dart
@Riverpod(keepAlive: true)
ShippingScheduler lyeShipping(Ref ref) {
  final recorder = ref.watch(lyeRecorderProvider);
  final client = ref.watch(clientProvider);
  final scheduler = ShippingScheduler(
    recorder: recorder,
    shipper: HttpBatchShipper(
      endpoint: Uri.parse('${client.host}lye/ingest'),
      headers: () async => <String, String>{
        'authorization': await client.authenticationKeyManager?.getHeaderValue() ?? '',
      },
    ),
    flushThreshold: 50,
    interval: const Duration(seconds: 5),
  )..start();
  ref.onDispose(scheduler.stop);
  return scheduler;
}
```

Il valore dell'header è lo stesso che il client Serverpod manda ai suoi endpoint (`AuthenticationKeyManager.toHeaderValue`, schema `Basic`). Il `ProviderScope` deve leggere il provider all'avvio (`ref.read(lyeShippingProvider)` nel widget radice) perché parta.

## 3. Server Serverpod

### 3.1 Bootstrap (`packages/cos_server/lib/src/lye/lye_server.dart`, chiamato da `server.dart` dopo `pod.start()`)

```dart
class LyeServer {
  static late final RealmLyeStore store;
  static late final LyeRecorder recorder;
  static late final ServerTracing tracing;
  static late final IngestHandler ingest;
  static late final LyeSigner signer;

  static Future<void> start(Serverpod pod) async {
    final env = Platform.environment;
    store = RealmLyeStore.open(
      path: env['LYE_STORE_PATH'] ?? '/var/lib/cos/lye/server.realm',
      encryptionKey: RealmKeys.fromSecret(env['LYE_STORE_KEY']!),      // Docker secret
    );
    recorder = LyeRecorder(
      config: LyeConfig(
        origin: LyeOrigin.server,
        platform: LyePlatform.linux,
        appId: 'cos_server',
        appVersion: env['COS_VERSION'] ?? 'dev',
        nodeId: env['LYE_NODE_ID'] ?? Platform.localHostname,
      ),
      store: store,
    );
    tracing = ServerTracing(recorder);
    signer = HmacSha256Signer.fromSecret(env['LYE_SIGNING_KEY']!, keyId: env['LYE_SIGNING_KEY_ID'] ?? 'prod-1');
    ingest = IngestHandler(store: store, recorder: recorder);
    await recorder.start();
    pod.webServer.addRoute(LyeIngestRoute(pod), '/lye/ingest');
  }
}
```

Il worker (`--role worker`, DTA §10.4) usa `LyeOrigin.worker` e lo stesso codice.

### 3.2 Rotta REST di ingest

`Route` di Serverpod 2.9.5: `handleCall(Session, HttpRequest)` restituisce `true` quando ha risposto. La `WebCallSession` legge la chiave di autenticazione solo da cookie o da `?auth=`, quindi la rotta la estrae dall'header `authorization` e la valida con l'`authenticationHandler` del pod.

```dart
class LyeIngestRoute extends Route {
  LyeIngestRoute(this.pod) : super(method: RouteMethod.post);
  final Serverpod pod;

  @override
  void setHeaders(HttpHeaders headers) => headers.contentType = ContentType.json;

  @override
  Future<bool> handleCall(Session session, HttpRequest request) async {
    final header = request.headers.value(HttpHeaders.authorizationHeader);
    final key = header != null && header.startsWith('Basic ')
        ? utf8.decode(base64.decode(header.substring(6)))
        : null;
    final info = key == null ? null : await pod.authenticationHandler?.call(session, key);
    if (info == null) {
      request.response.statusCode = HttpStatus.unauthorized;
      return true;
    }
    session.updateAuthenticated(info);
    final principal = await PrincipalStore.instance.current(session);

    final body = await utf8.decoder.bind(request).join();
    final result = await LyeServer.ingest.handle(IngestRequest(
      principal: IngestPrincipal(
        actorRef: principal.userId,
        partnerId: principal.partnerId,
        tenantId: principal.role == PrincipalRole.tenantUser ? principal.organizationId : '',
        scope: principal.role == PrincipalRole.tenantUser ? LyeScope.tenant : LyeScope.partner,
        actorRole: principal.role.name,
      ),
      batchJson: (jsonDecode(body) as Map<Object?, Object?>).map((k, v) => MapEntry(k.toString(), v)),
      bodyBytes: body.length,
    ));
    request.response.statusCode = result.statusCode;
    request.response.write(jsonEncode(result.toJson()));
    return true;
  }
}
```

Caddy (DTA §6.5) limita la dimensione del corpo a 1 MiB su `/lye/ingest`; l'handler applica gli stessi limiti e un rate limit per attore.

### 3.3 Endpoint: `handleCall` (`lib/src/endpoints/*.dart`)

```dart
Future<RopaEntry> addEntry(Session session, RopaEntry entry) async {
  final principal = await PrincipalStore.instance.current(session, requestedTenantId: entry.tenantId);
  final context = _resolver.resolve(principal: principal, requestedTenantId: entry.tenantId);
  return LyeServer.tracing.handleCall<RopaEntry>(
    endpoint: 'ropa',
    method: 'addEntry',
    jsonArgs: CallCorrelation.stripEnvelope((session as MethodCallSession).queryParameters),
    context: LyeServer.tracing.contextFor(
      scope: context.scope.name,
      partnerId: context.partnerId,
      tenantId: context.tenantId,
      actorId: context.actorId,
      actorRole: principal.role.name,
    ),
    body: () => withScope(session: ServerpodDbSession(session), context: context, callback: (tx) async {
      // ... come oggi ...
    }),
  );
}
```

`queryParameters` è il corpo JSON decodificato più la query string: `stripEnvelope` toglie `method`, `endpoint` e `auth`, e il digest coincide con quello del client. Un helper `tracedEndpoint(session, ...)` in `lib/src/lye/` evita di ripetere le sei righe in ogni metodo.

### 3.4 `withScope` e statement (`lib/src/tenancy/with_scope.dart`)

Ogni accesso al database passa da `withScope` (ARCHITECTURE_RULES §3): decorare qui copre tutto.

```dart
Future<T> withScope<T>({required DbSession session, required ScopeContext context, required TransactionScopeCallback<T> callback}) {
  return LyeServer.tracing.scopedTransaction<T>(
    scope: context.scope.name,
    partnerId: context.partnerId,
    tenantId: context.tenantId,
    body: () => session.transaction((tx) async {
      final traced = TracedDbTransaction(tx, LyeServer.tracing);
      await traced.query("SELECT set_config('app.scope', @scope, true)", substitutionValues: {'scope': context.scope.name});
      // ... le altre tre set_config ...
      return callback(traced);
    }),
  );
}

class TracedDbTransaction implements DbTransaction {
  TracedDbTransaction(this._inner, this._tracing);
  final DbTransaction _inner;
  final ServerTracing _tracing;

  @override
  Future<List<Map<String, dynamic>>> query(String sql, {Map<String, dynamic> substitutionValues = const {}}) =>
      _tracing.statement(sql, run: () => _inner.query(sql, substitutionValues: substitutionValues), rowCount: (rows) => rows.length);

  @override
  Future<int> execute(String sql, {Map<String, dynamic> substitutionValues = const {}}) =>
      _tracing.statement(sql, run: () => _inner.execute(sql, substitutionValues: substitutionValues), rowCount: (n) => n);
}
```

I parametri (`substitutionValues`) non entrano mai nel tracciato: solo il digest del template, il tipo di statement, la tabella, le righe e i millisecondi. In produzione, se il volume lo richiede, il decoratore può tracciare solo le mutazioni e le query oltre 100 ms e riportare il conteggio delle `SELECT` negli attributi dello scope (§2.2 del documento tecnico).

### 3.5 Audit (`lib/src/audit/audit_service.dart`)

Dentro `AuditService.appendEvent`, dopo `audit.append_event`, così nessun punto di chiamata può dimenticarlo:

```dart
final rowHash = /* bytes restituiti da audit.append_event */;
await LyeServer.tracing.auditAppended(orgId: orgId, action: action, rowHash: rowHash,
    targetType: payload['target_type']?.toString(), targetId: payload['id']?.toString());
return rowHash;
```

`audit_ref` diventa `org_id::row_hash` (il `seq` non è restituito dalla funzione SQL; una `SELECT seq FROM audit.events WHERE row_hash = @hash` nella stessa transazione lo aggiunge, se si vuole il riferimento completo).

### 3.6 Coda (`lib/src/queue/job_queue.dart`)

`JobQueueEngine.enqueue` → `tracing.jobEnqueued(queue, jobId, singletonKey)`; il worker esegue ogni handler dentro `tracing.runJob(queue, jobId, attempt, body)`. Le letture di documenti e i download passano da `tracing.documentAccessed(...)` (DTA §5.6); il break-glass da `tracing.breakGlass(...)` (DTA §6.3).

### 3.7 Job periodici (worker, leader con advisory lock, DTA §10.4)

```dart
// ogni notte 02:10, dopo la verifica della hash-chain di audit
final root = '/var/lib/cos/lye/export';
final run = await StreamExporter(store: LyeServer.store, root: root, signer: LyeServer.signer).exportPending();
final anchors = AnchorService(blobStore: S3BlobStore(bucket: 'cos-anchors-hel1', prefix: 'lye'), signer: LyeServer.signer, recorder: LyeServer.recorder);
await anchors.anchor(root);                       // teste firmate su Object Storage HEL1
final problems = await anchors.checkAgainstLatest(root);
if (problems.isNotEmpty) alert('LYE anchors', problems);   // Sentry/Grafana (DTA §11.4)
await RetentionPurger(root: root, recorder: LyeServer.recorder).purge();     // 6/12/24 mesi
await LyeServer.store.purgeShippedBefore(DateTime.now().toUtc().subtract(const Duration(days: 7)));
LyeServer.store.compact();
```

`S3BlobStore` implementa `BlobStore` con il client S3 già usato per i documenti (§10.8 DTA); la cartella `root` sta su un volume del server applicativo e viene copiata nel bucket documenti di FSN1 con `lye/export/` come prefisso.

### 3.8 Verifica continua e alert

- `dart run lye_io:lye verify /var/lib/cos/lye/export --key $LYE_SIGNING_KEY --key-id prod-1` in cron (o come job LYE) → exit code 1 = alert "verifica LYE fallita", stesso canale della verifica notturna della hash-chain di audit (DTA §11.4).
- Sentry: nel hook errori della console e nell'handler server, aggiungere il tag `lye.trace_id = LyeSpan.current?.traceId`, così l'errore in Sentry e la timeline LYE si trovano a vicenda.

## 4. Verifica dell'integrazione (Definition of Done, DTA §12.5)

- [ ] Un tap su un `LyeTrackable` produce, nell'export del giorno, una timeline che va da `ui.intent` a `audit.append` con lo stesso `call_digest` su client e server (`lye timeline --call`).
- [ ] `lye verify` sull'export di staging restituisce `OK`; un file alterato a mano restituisce exit code 1.
- [ ] Nessuna riga del CSV contiene e-mail, nomi, IDNP o argomenti di chiamata (grep sui pattern del `Redactor` in CI su un export di staging con dati sintetici).
- [ ] Il `RoPA` della piattaforma contiene il trattamento "tracciato tecnico LYE" con finalità, base giuridica e conservazione.
- [ ] Il Dockerfile installa i binari Realm e il container parte con `LYE_STORE_KEY` e `LYE_SIGNING_KEY` da Docker secret.
