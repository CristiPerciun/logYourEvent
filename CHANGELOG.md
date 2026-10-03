# Changelog

Tutte le modifiche rilevanti sono registrate qui. Formato: [Keep a Changelog](https://keepachangelog.com/it/1.1.0/), versionamento [SemVer](https://semver.org/lang/it/). Il tag Git `vX.Y.Z` coincide con il campo `version` di **tutti** i pacchetti (`tool/check_versions.dart`).

## [0.4.0] — 2026-10-03

Il **jurnal da leggere di un giorno** e un **canale per gli errori**, richiesti da Compliance OS. Il file del giorno si crea solo nei giorni in cui la persona ha lavorato, si conserva compresso in uno ZIP e arriva al database a fine giornata. Un errore invece parte nel momento in cui succede ([ADR-012](docs/adr/012-jurnal-del-giorno.md)).

### Aggiunto
- `ReadableJournalDay` (`lye_archive`, Dart puro):
  - `pack` mette i passaggi di un giorno UTC, `[00:00, 24:00)`, in uno ZIP con un solo CSV, quello di `LyeReadableJournal.encode`. Lascia fuori gli eventi degli altri giorni, e per un giorno senza passaggi **restituisce null**: nessun file vuoto. Lo ZIP è riproducibile byte per byte, perché la data di modifica è l'inizio del giorno.
  - `open` legge il CSV di un pacchetto.
  - `dayOf` dice il giorno UTC di un istante, `dayStart` il primo istante di un giorno; un giorno che non esiste è rifiutato.
- `PackedJournalDay`: i byte, il nome dello ZIP e del CSV, le righe, gli eventi letti, la dimensione prima e dopo la compressione, il digest. Dice anche le classi di retention da cui vengono gli eventi, perché il file non viva più della più breve.
- `OpenedJournalDay`: il CSV letto da un pacchetto.
- `LyeEvent.isError` (`lye_core`): un esito `fail` o `denied`, o un evento della categoria `error`. `LyeJournalStep.isError`: lo stesso per un passaggio, sui due lati della chiamata.
- `ShippingScheduler.shipErrorsAtOnce`, attivo di serie: un errore si spedisce appena registrato, con ciò che era in attesa prima di lui, senza aspettare la soglia né l'intervallo. Un errore registrato durante una spedizione ottiene un giro suo. Il ritardo dopo un guasto di rete resta.

### Modificato
- ADR-011, punto 1: il file da leggere non si produce più quando qualcuno lo chiede, per un giorno qualunque, ma una volta per giorno con eventi, alla chiusura del giorno (ADR-012). Quando costruirlo resta del consumatore.

### Invariato
- `LyeReadableJournal`, le colonne e le righe. Gli archivi firmati: manifest `lye.archive.v1`, un CSV `lye.v2` per pacchetto.

## [0.3.0] — 2026-10-01

Un **solo CSV da leggere per conto**, richiesto da Compliance OS: un file che permetta di ricostruire tutti i passaggi di una persona prima di un errore, con la zona del prodotto nella prima colonna, la data nella seconda, l'evento o l'errore nella terza e non più di sei colonne ([ADR-011](docs/adr/011-jurnal-da-leggere.md)).

### Aggiunto
- `LyeReadableJournal` (`lye_core`, Dart puro): da eventi di qualunque provenienza — tabella calda, archivi delle tre classi, copie dello stesso file — un CSV con le colonne del consumatore, **al massimo sei**. Toglie i doppioni su `event_id` + `row_hash`, unisce in un passaggio il `rpc.call` della console e il `rpc.handle` del server della stessa chiamata (stesso attore, stesso `call_digest`, il più vicino entro due minuti), ordina per tempo. Separatore `;`, UTF-8 con BOM, celle su una riga e mai formule.
- `LyeJournalStep`: un passaggio, con l'esito, la durata e la classe d'errore del lato che conta (il server, quando ha risposto) e gli attributi dei due lati.
- `LyeJournalAreas` e `LyeAreaRule`: la zona del prodotto di un passaggio, chiesta in ordine all'endpoint, all'azione e alla pagina.

### Invariato
- Gli archivi: manifest `lye.archive.v1`, un CSV `lye.v2` per pacchetto. Il file da leggere non è una prova e non entra negli ZIP: uno ZIP è di una classe sola. Una tabella dentro ogni ZIP è stata provata e tolta prima del rilascio, perché sarebbero stati tre file per giorno, nessuno completo.

## [0.2.1] — 2026-09-19

> Il tag `v0.2.0` era già stato pubblicato sul commit di sola documentazione, il cui albero dichiara ancora `0.1.0` nei pubspec. Un tag pubblicato non si sposta: il codice della 0.2 esce quindi come **0.2.1**.

Il jurnal smette di essere il tracciato di un processo e diventa quello di un **conto**. Richiesto da Compliance OS per il profilo tecnico: scegliere un account, vederne il flusso, scaricarne gli archivi (`Compliance_OS_Progettazione_Jurnale_per_Conto5.1.md`).

### Aggiunto
- Schema **`lye.v2`**: tre colonne in coda al blocco firmato — `subject_type`, `subject_ref`, `level`. Quaranta colonne, trentasette nell'hash. I file `lye.v1` restano leggibili e **verificabili con la loro forma canonica**: un evento marcato `lye.v1` non guadagna le tre colonne nell'hash (ADR-008).
- **Catena per (soggetto, classe di retention)** accanto a quella per stream: `SubjectChain`, `SubjectChainKey`, `SubjectChainHead`. La catena per stream prova che il tracciato di un processo non è stato alterato; questa prova che l'insieme consegnato per un conto è completo. Tre catene per conto, una per classe, così ogni archivio copre un intervallo contiguo di una sola catena (ADR-008).
- **Cinque livelli di verbosità** al posto del filtro binario: `error`, `standard`, `verbose`, `forensic`, più lo spegnimento. `LyeLevelPolicy` mappa categoria, azione ed esito al livello minimo; il recorder scarta **prima di sigillare**, quindi le sequenze restano contigue e un buco non si confonde mai con una perdita. `LyeRecorder.applyLevel` registra ogni cambio come `lye.policy.applied` (ADR-010).
- `SubjectResolver`: attore → tenant → partner → nodo. Un evento ha **un solo soggetto**, quindi nessuna riga finisce in due archivi. Una bozza può nominare un soggetto diverso dall'attore: è il caso dell'operatore che crea un conto.
- Pacchetto **`lye_archive`** (Dart puro, gira anche sul web): `ArchiveBuilder` con rotazione sui byte **compressi**, `ArchiveVerifier`, manifest firmato `lye.archive.v1`. Il pacchetto si verifica da solo, senza database e senza gli altri archivi della stessa catena. La costruzione è riproducibile byte per byte (ADR-009).
- `lye_io`: comandi `lye verify-archive <file.zip>` e `lye timeline --archive <file.zip> --trace <id>`.
- Azioni nuove: `lye.archive.*`, `lye.policy.applied`, `lye.quota.exceeded`, `fn.enter`, `fn.exit`.

### Modificato
- **`LyeRecorder.record`, `point` e `start` restituiscono `Future<LyeEvent?>`**: null quando il livello in vigore non ammette la bozza. Stessa cosa per i quattro aiutanti di `ServerTracing` che inoltrano un evento puntuale. È una rottura di API, ed è voluta: il chiamante deve sapere che può non essere stato registrato nulla.
- La demo della CLI gira a livello `forensic`, altrimenti non mostrerebbe più la catena completa dal gesto allo statement.

### Corretto in fase di costruzione
- Il manifest **non** contiene il digest dello ZIP che lo trasporta: sarebbe circolare. `content_hash` copre i membri e sopravvive a una ricompressione; il digest dei byte appartiene a chi li conserva.
- Un archivio scrive **un solo CSV**, in ordine di catena, invece di uno per stream. La posizione nella catena non è un campo dell'evento — la assegna lo store, dopo la sigillatura — quindi l'unico modo di trasportarla è l'ordine del file. Raggruppare per stream avrebbe reso l'ordine irrecuperabile per chi verifica.
- La misura per la rotazione usa gli hash **reali** della catena, non quelli di genesi: sessantaquattro zeri si comprimono quasi a nulla, e il pacchetto sigillato usciva oltre il limite.

## [0.1.0] — 2026-09-05

### Aggiunto
- `lye_core`: modello dell'evento (`LyeEvent`, `LyeDraft`), schema CSV `lye.v1`, rappresentazione canonica e hash-chain SHA-256 per stream, UUIDv7, redazione e minimizzazione degli attributi con `payload_digest`, codec CSV RFC 4180 con protezione da formula injection, manifest firmato (HMAC-SHA256) e concatenato, verifica della catena, store in memoria, registratore con span e propagazione via `Zone`, correlazione delle chiamate RPC, batch e scheduler di spedizione.
- `lye_io`: sink CSV su file con rotazione e manifest, verifica di una cartella di export, ricostruzione della timeline di una operazione, CLI `lye` (`verify`, `timeline`, `inspect`, `demo`).
- `lye_realm`: `RealmLyeStore` su Realm 20 (locale, cifrato), con continuità della catena tra riavvii.
- `lye_server`: gestore di ingest dei batch client con verifica della catena, tracciamento di scope, statement SQL, eventi di audit e job, export giornaliero e ancoraggio delle teste.
- `lye_flutter`: `LyeNavigatorObserver`, `LyeProviderObserver` (Riverpod 3), tracciamento puntatore con `LyeTrackable`, hook degli errori e del ciclo di vita, `HttpBatchShipper`.
- Documento tecnico, ADR 001–006, guida di integrazione per Compliance OS.
