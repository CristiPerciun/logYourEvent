# Log Your Event (LYE)

> Libreria Dart proprietaria che registra **ogni azione** di Compliance OS — sul frontend Flutter e sul server — in stream di eventi concatenati con hash, li salva in **file CSV verificabili** e permette di **ricostruire il ciclo completo di un'operazione**, dal gesto sulla console alla riga di audit nel database. Progetto separato, versionato con tag, incluso nei prodotti come dipendenza Git.

Fonti di verità della progettazione: `Compliance_OS_Documento_Tecnico_Architettura5.1.md` e `Concept_Aziendale_SRL_Moldova5.1.md` del repository `compliance-os`. Il documento tecnico di LYE è [docs/LYE_Documento_Tecnico.md](docs/LYE_Documento_Tecnico.md); le decisioni sono in [docs/adr/](docs/adr/); l'integrazione in Compliance OS in [docs/integrazione_compliance_os.md](docs/integrazione_compliance_os.md).

## Pacchetti

| Pacchetto | Dipendenze | Dove gira | Cosa fa |
|---|---|---|---|
| [`lye_core`](packages/lye_core) | `crypto`, `meta` | ovunque (anche web) | Evento `lye.v1`, hash-chain per stream, UUIDv7, redazione, codec CSV, manifest firmati, verificatore, registratore con span, batch e scheduler di spedizione, store in memoria |
| [`lye_io`](packages/lye_io) | `lye_core`, `path`, `dart:io` | server, desktop, mobile | File CSV con rotazione e manifest concatenati, verifica di una cartella, timeline di un'operazione, CLI `lye` |
| [`lye_realm`](packages/lye_realm) | `lye_core`, `realm_dart` | server, desktop, mobile | Store durevole cifrato su Realm 20 |
| [`lye_server`](packages/lye_server) | `lye_core`, `lye_io` | server | Ingest dei batch client con verifica della catena, tracer per endpoint, transazioni con scope, statement SQL, audit e job; export, ancoraggio delle teste, purga per retention |
| [`lye_flutter`](packages/lye_flutter) | Flutter, `flutter_riverpod`, `http` | console (web, mobile, desktop) | Osservatori di navigazione e di stato Riverpod, tap su widget taggati, errori, ciclo di vita, spedizione HTTP |

Nessun pacchetto dipende da Serverpod: gli adattatori vivono nel progetto che consuma la libreria ([ADR-002](docs/adr/002-nessuna-dipendenza-da-serverpod-e-flutter-nel-core.md)).

## Provare in tre comandi

```bash
cd packages/lye_io && dart pub get
dart run bin/lye.dart demo   /tmp/lye-demo                      # export dimostrativo client + server
dart run bin/lye.dart verify /tmp/lye-demo --key demo-secret --key-id demo
dart run bin/lye.dart timeline /tmp/lye-demo --call <digest stampato dalla demo>
dart run bin/lye.dart demo   /tmp/lye-tampered --tamper && dart run bin/lye.dart verify /tmp/lye-tampered   # exit 1
```

## Includere in un progetto

```yaml
dependencies:
  lye_core:
    git:
      url: https://github.com/CristiPerciun/log-your-event.git
      ref: v0.1.0
      path: packages/lye_core
  lye_server:            # solo server
    git: {url: https://github.com/CristiPerciun/log-your-event.git, ref: v0.1.0, path: packages/lye_server}
  lye_realm:             # server, desktop, mobile
    git: {url: https://github.com/CristiPerciun/log-your-event.git, ref: v0.1.0, path: packages/lye_realm}
  lye_flutter:           # console Flutter
    git: {url: https://github.com/CristiPerciun/log-your-event.git, ref: v0.1.0, path: packages/lye_flutter}
```

Il tag `vX.Y.Z` coincide con la versione di tutti i pacchetti (`dart tool/check_versions.dart v0.1.0`). Chi usa `lye_realm` esegue una volta `dart run realm_dart install` (anche nel Dockerfile). Le dipendenze interne del repository sono `path`, risolte da pub dentro il checkout Git.

## Sviluppo

```bash
pwsh tool/bootstrap.ps1        # pub get, binari Realm, generazione modelli
bash tool/test_all.sh          # analisi stretta (--fatal-infos) e test di ogni pacchetto, come in CI
```

Stato della v0.1.0: 5 pacchetti, analisi statica stretta pulita, 112 test verdi (70 core, 15 io, 11 server, 6 realm, 10 flutter), più la verifica end-to-end della demo in CI.

## Struttura del repository

```text
log-your-event/
├── README.md                     questo file
├── CHANGELOG.md                  una sezione per versione; il tag vX.Y.Z coincide con la versione dei pacchetti
├── LICENSE                       licenza proprietaria (titolarità del founder fino alla cessione alla SRL)
├── NOTICE.md                     inventario delle licenze di terze parti (Realm Apache-2.0, pacchetti Dart BSD-3, Riverpod MIT)
├── analysis_options.yaml         regole di analisi stretta condivise (le stesse di compliance-os)
├── .gitignore
├── .github/workflows/
│   ├── ci.yml                    analisi + test per pacchetto, job Realm, job Flutter, controllo versioni, demo end-to-end
│   └── release.yml               dal tag alla release GitHub con la sezione del CHANGELOG
├── tool/
│   ├── check_versions.dart       verifica che pubspec, lyeVersion e tag coincidano
│   ├── bootstrap.ps1             pub get di ogni pacchetto, binari Realm, generazione modelli
│   └── test_all.sh               analisi e test di ogni pacchetto come in CI
├── docs/
│   ├── LYE_Documento_Tecnico.md  documento tecnico di progettazione (requisiti, architettura, schema, verifica, rischi)
│   ├── integrazione_compliance_os.md   codice degli adattatori per console_flutter e cos_server
│   └── adr/                      001 Realm dietro LyeStore · 002 nessuna dipendenza da Serverpod · 003 CSV lye.v1
│                                 004 hash-chain per stream · 005 Zone e call_digest · 006 repo separato e tag · 007 minimizzazione
└── packages/
    ├── lye_core/                 Dart puro, nessun I/O (gira anche sul web)
    │   ├── lib/lye_core.dart     export pubblici
    │   └── lib/src/
    │       ├── model/            enums.dart (origine, fase, categoria, esito, scope, retention) · lye_actions.dart (catalogo codici)
    │       │                     csv_schema.dart (37 colonne di lye.v1) · lye_event.dart (evento sigillato) · lye_draft.dart (bozza)
    │       ├── canonical/        canonical_json.dart (RFC 8785, identico all'audit) · timestamp.dart (UTC a microsecondi)
    │       ├── chain/            hash_chain.dart (separatore 0x1E, sha256(prev ‖ canonico), digest)
    │       ├── ids/              uuid_v7.dart (RFC 9562, monotono) · hex.dart (hex e confronto a tempo costante)
    │       ├── privacy/          redactor.dart (deny-list, pattern, limiti, payload_digest) · text_sanitizer.dart (CSV injection, controlli)
    │       ├── csv/              csv_codec.dart (RFC 4180) · lye_csv.dart (documento lye.v1)
    │       ├── manifest/         manifest.dart (lye.manifest.v1, catena dei file) · signer.dart (LyeSigner, HMAC-SHA256)
    │       ├── verify/           chain_verifier.dart (codici di problema, continuazione da una testa)
    │       ├── store/            lye_store.dart (contratto + assertContinues) · memory_lye_store.dart (web e test)
    │       ├── recorder/         lye_recorder.dart (scrittore unico, span, withContext) · lye_span.dart (Zone) · lye_context.dart
    │       │                     lye_config.dart (identità, RetentionPolicy) · lye_clock.dart (System/Fixed)
    │       ├── rpc/              call_correlation.dart (call_digest, busta Serverpod)
    │       ├── shipping/         lye_batch.dart (lye.batch.v1) · shipping_scheduler.dart (soglia, intervallo, backoff, rifiuto)
    │       └── version.dart      lyeVersion
    │   └── test/                 70 test (canonical, ids_and_chain, privacy, csv_codec, csv_and_verify, memory_store, recorder, manifest, shipping)
    ├── lye_io/                   dart:io — server, desktop, mobile
    │   ├── bin/lye.dart          eseguibile `lye`
    │   ├── lib/src/
    │   │   ├── export_layout.dart      <root>/<origin>/<node>/<epoch>/lye-AAAAMMGG-NNNN.csv + .manifest.json
    │   │   ├── csv_file_sink.dart      append con rotazione per giorno e dimensione, manifest, ripresa e recupero
    │   │   ├── stream_exporter.dart    da LyeStore ai file, idempotente dopo un'interruzione
    │   │   ├── directory_verifier.dart verifica righe, file, catena dei file, link tra epoch; rapporto leggibile
    │   │   ├── timeline.dart           ricostruzione di un'operazione per traccia, digest di chiamata, attore
    │   │   └── cli.dart                comandi demo · verify · timeline · inspect (exit 0/1/2)
    │   └── test/                 15 test
    ├── lye_realm/                store durevole (Realm 20, cifrato) — non web
    │   ├── lib/src/
    │   │   ├── models.dart             LyeEventRow, LyeChainHeadRow (annotati @RealmModel)
    │   │   ├── models.realm.dart       generato, versionato (una dipendenza git non richiede build_runner)
    │   │   ├── realm_lye_store.dart    RealmLyeStore: append atomico riga + testa, query, purga, compattazione
    │   │   └── realm_keys.dart         chiave a 64 byte da segreto (SHA-512)
    │   └── test/                 6 test (tag `realm`, richiedono `dart run realm_dart install`)
    ├── lye_server/               lato server, indipendente dal framework
    │   ├── lib/src/
    │   │   ├── ingest_handler.dart     IngestPrincipal, IngestRequest, IngestResult, IngestHandler (verifica e limiti)
    │   │   ├── stream_ownership.dart   stream legato al primo attore
    │   │   ├── rate_limiter.dart       token bucket per attore
    │   │   ├── server_tracing.dart     handleCall, scopedTransaction, statement, auditAppended, documentAccessed, job, breakGlass
    │   │   ├── sql_template.dart       normalizzazione, tipo, tabella e digest degli statement (mai i valori)
    │   │   ├── blob_store.dart         BlobStore + LocalDirectoryBlobStore (S3 nel consumer)
    │   │   ├── anchor_service.dart     lye.anchor.v1 firmato, checkAgainstLatest
    │   │   └── retention_purger.dart   cancella i file interamente scaduti dal più vecchio (6/12/24 mesi)
    │   └── test/                 11 test
    └── lye_flutter/              adattatori Flutter, solo Riverpod
        ├── lib/src/
        │   ├── lye_navigator_observer.dart   nav.* e rotta corrente nel contesto
        │   ├── lye_provider_observer.dart    state.* senza valori (Riverpod 3)
        │   ├── lye_trackable.dart            LyeTag, LyeTrackable (StatelessWidget con MetaData)
        │   ├── lye_pointer_tracker.dart      ui.tap / ui.intent dal percorso di hit-test
        │   ├── lye_error_hooks.dart          FlutterError.onError e PlatformDispatcher.onError
        │   ├── lye_lifecycle_observer.dart   app.resume/pause/detach, cambio lingua
        │   ├── http_batch_shipper.dart       BatchShipper su HTTPS (package:http)
        │   └── lye_flutter_platform.dart     piattaforma → colonna platform
        └── test/                 10 widget test
```

Regola di dipendenza: `lye_io`, `lye_realm`, `lye_server` e `lye_flutter` dipendono da `lye_core`; `lye_server` anche da `lye_io`; nessun pacchetto dipende da un altro adattatore né da Serverpod.

## Primo rilascio

```bash
git init && git add -A && git commit -m "feat: Log Your Event 0.1.0"
git tag -a v0.1.0 -m "LYE 0.1.0"
git remote add origin https://github.com/CristiPerciun/log-your-event.git
git push -u origin main --tags
```
