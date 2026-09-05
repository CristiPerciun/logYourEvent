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

## Struttura

```text
log-your-event/
├── packages/            lye_core, lye_io, lye_realm, lye_server, lye_flutter
├── docs/                documento tecnico, ADR, guida di integrazione
├── tool/                check_versions.dart, bootstrap.ps1, test_all.sh
├── .github/workflows/   ci.yml (analisi, test, demo end-to-end), release.yml (tag → release)
├── CHANGELOG.md · LICENSE (proprietaria) · NOTICE.md (licenze di terze parti)
```

## Primo rilascio

```bash
git init && git add -A && git commit -m "feat: Log Your Event 0.1.0"
git tag -a v0.1.0 -m "LYE 0.1.0"
git remote add origin https://github.com/CristiPerciun/log-your-event.git
git push -u origin main --tags
```
