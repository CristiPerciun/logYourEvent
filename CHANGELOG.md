# Changelog

Tutte le modifiche rilevanti sono registrate qui. Formato: [Keep a Changelog](https://keepachangelog.com/it/1.1.0/), versionamento [SemVer](https://semver.org/lang/it/). Il tag Git `vX.Y.Z` coincide con il campo `version` di **tutti** i pacchetti (`tool/check_versions.dart`).

## [0.2.0] — 2026-09-19

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
