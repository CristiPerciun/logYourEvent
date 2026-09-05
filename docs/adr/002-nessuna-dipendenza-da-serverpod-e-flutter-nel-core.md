# ADR-002 — Nessuna dipendenza da Serverpod nel core e nel pacchetto server

**Stato**: accettata · **Data**: 5 settembre 2026

## Contesto

Il Documento Tecnico di Architettura 5.1 elenca come rischio n. 1 (§13.3) "Serverpod: vendor piccolo, major con rotture ogni 9–12 mesi" e come mitigazione "dominio in `cos_domain` e sicurezza in SQL fuori dall'ORM". Il repository usa oggi Serverpod 2.9.5; il documento prevede 3.4.x o 4.0. Una libreria trasversale che importasse Serverpod dovrebbe rilasciare a ogni major del framework, e non potrebbe servire il gateway TypeScript, gli script di `tools/` o un eventuale piano B NestJS con contratto OpenAPI (§3.6).

## Decisione

- `lye_core` dipende solo da `crypto` e `meta`. `lye_io` aggiunge `path` e `dart:io`. `lye_server` dipende da `lye_core` e `lye_io`. Nessuno di questi importa Serverpod, Relic, `postgres` o Flutter.
- `lye_flutter` dipende da Flutter e `flutter_riverpod` (necessari per `NavigatorObserver` e `ProviderObserver`), non da `serverpod_client`: gli hook `onSucceededCall`/`onFailedCall` del client Serverpod vengono collegati nel progetto consumer con poche righe, passando a LYE solo nomi e argomenti in forma JSON.
- I punti di aggancio lato server sono funzioni pure che il consumer chiama dai propri concentratori di comportamento: l'endpoint (`ServerTracing.handleCall`), l'helper `withScope` (`scopedTransaction`), il decoratore di `DbTransaction` (`statement`), `AuditService.appendEvent` (`auditAppended`), la coda (`jobEnqueued`, `runJob`).
- La rotta REST di ingest è un `IngestHandler` che riceve principal e JSON e restituisce un `IngestResult` con codice HTTP: la classe `Route` di Serverpod (o qualunque server HTTP) è un adattatore di dieci righe nel consumer.

## Alternative considerate

| Alternativa | Perché no |
|---|---|
| Modulo Serverpod (`serverpod.yaml type: module`) con endpoint e client generati | Lega LYE al codegen e alla major di Serverpod; richiede una coppia di pacchetti `_server`/`_client`; rompe al passaggio 2.x → 4.x |
| `DiagnosticEventHandler` sperimentale di Serverpod come sorgente unica | Copre solo eccezioni e messaggi, non chiamate e statement; API marcata sperimentale |
| Scrivere un `LogWriter` di Serverpod | Le tabelle `serverpod_log` sono log tecnici del framework, senza catena né contesto di tenancy |

## Conseguenze

- L'integrazione in `cos_server` e `console_flutter` è codice del consumer (documentato in `docs/integrazione_compliance_os.md`), circa 150 righe in tutto.
- Un cambio di framework backend non tocca LYE; un cambio di major Serverpod tocca solo gli adattatori nel consumer.
