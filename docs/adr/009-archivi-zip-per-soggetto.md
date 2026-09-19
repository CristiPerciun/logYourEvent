# ADR-009 — Archivi ZIP per soggetto: rotazione, manifest `lye.archive.v1`, pacchetto `lye_archive`

**Stato**: accettata · **Data**: 19 settembre 2026 · **Versione**: 0.2.0

## Contesto

`lye_io` sa già scrivere gli stream su disco: un CSV per giorno e parte, un manifest firmato per file, rotazione a dimensione, ripresa dopo un arresto ([ADR-003](003-csv-lye-v1-come-formato-canonico.md)). È l'export di un **processo**.

Il consumatore ha bisogno di un'altra unità di consegna: un pacchetto **per soggetto**, che raccolga gli eventi di un account presi da più stream, non più grande di una soglia fissa (8 MiB nel caso di Compliance OS), prodotto una volta al giorno, salvato dentro un database e scaricato da una console. Il pacchetto deve potersi verificare fuori da quel database e senza gli altri pacchetti.

Oggi il consumatore comprime un CSV nudo con `package:archive` e ne salva lo SHA-256 in colonna: lo ZIP non contiene nulla che dica che cosa dovrebbe contenere, quindi un terzo non può verificarlo — può solo ricalcolare un digest di cui si fida sulla parola.

## Decisione

Nasce **`lye_archive`**, pacchetto Dart puro (gira anche sul web, così una console può verificare ciò che ha appena scaricato), dipendente da `lye_core`, `archive` e `crypto`.

**Struttura del pacchetto**:

```
<prefisso>_<classe>_<slug-soggetto>_<AAAAMMGG>_<NN>.zip
├── manifest.json                      lye.archive.v1, firmato
├── events/<origin>/<node_id>/<epoch>/lye-<AAAAMMGG>-<NNNN>.csv
└── README.txt
```

Il percorso `events/` replica `ExportLayout`, così l'albero estratto resta leggibile dagli strumenti di stream. Il nome contiene la data di creazione e mai un dato personale: lo `slug-soggetto` sono le prime otto cifre esadecimali dell'identificativo, precedute dal tipo.

**Manifest `lye.archive.v1`**: identificativo, soggetto, classe, progressivo dell'archivio e parte, intervallo `from_seq`–`to_seq` sulla catena del soggetto, conteggi, estremi temporali, eventi arrivati in ritardo, ripartizione per livello, elenco degli stream attraversati, elenco dei membri con digest e dimensioni, `content_hash` sui membri, `zip_sha256` sui byte consegnati, `prev_archive_hash`, `prev_chain_hash`, `chain_hash`, generatore e firma HMAC-SHA256 con `key_id`. `archive_hash = sha256(canonico(campi firmati))` è ciò a cui si aggancia il pacchetto successivo.

Due digest e non uno: `zip_sha256` prova che i byte consegnati sono quelli, `content_hash` sopravvive a una ricompressione e prova che il **contenuto** è quello.

**Rotazione**: `ArchiveBuilder` accumula le righe e chiude la parte quando i byte compressi raggiungono la soglia meno la riserva per manifest e README; la parte successiva riparte dal `chain_seq` immediatamente seguente. Una catena senza eventi non produce alcun file.

**Determinismo**: ordine dei membri fisso, date di modifica fisse, nessun metadato dipendente dalla macchina. Lo ZIP è riproducibile byte per byte a parità di contenuto e di versione dell'encoder.

**Verifica**: `ArchiveVerifier` controlla, nell'ordine, firma del manifest, digest dei membri, `row_hash` riga per riga, `chain_hash` ricalcolato sull'intero pacchetto, aggancio a `prev_archive_hash`. `lye_io` espone i comandi `lye verify-archive <zip>` (uscita 0/1/2) e `lye timeline --archive <zip> --trace <id>`.

**Che cosa resta fuori da `lye_archive`**: come si scelgono le righe, dove si conservano i byte, quando parte il taglio. Sono decisioni del consumatore, e restano nel consumatore ([ADR-002](002-nessuna-dipendenza-da-serverpod-e-flutter-nel-core.md)). `lye_archive` riceve righe e restituisce pacchetti.

## Alternative considerate

| Alternativa | Perché no |
|---|---|
| Estendere `CsvFileSink` invece di un pacchetto nuovo | Il sink è per stream, presuppone la contiguità dei `seq` e scrive su disco. Un pacchetto per soggetto è sparso, multi-stream e in memoria: forzarli nella stessa classe avrebbe reso entrambi peggiori |
| Un solo digest (`zip_sha256`) | Una ricompressione innocente — un altro livello di deflate, un altro encoder — invaliderebbe la prova pur non toccando il contenuto |
| Tar + gzip | Nessun accesso casuale ai membri, e sul Windows di chi verifica lo ZIP si apre con due clic |
| zstd nello ZIP (metodo 93) | Dal 20 al 30 per cento in meno, ma nessuna implementazione Dart pura e un archivio che molti strumenti non aprono |
| Nessun README dentro il pacchetto | Chi lo riceve fra due anni non saprebbe come verificarlo; costa poche centinaia di byte |
| Mettere il manifest **fuori** dallo ZIP, come per gli stream | Per gli stream il sidecar è comodo perché i file restano su un volume; qui il pacchetto viaggia da solo dentro un database e poi in un browser, e un manifest separato si perde |

## Conseguenze

- Il consumatore non scrive più codice di compressione: passa righe, soglia, chiave di firma e riceve pacchetti sigillati.
- Il limite di dimensione è sui byte **compressi**, quindi il numero di eventi per pacchetto varia con la comprimibilità delle righe. Il costruttore comprime in modo incrementale per sapere quando fermarsi, il che costa qualche ricompressione ai bordi.
- La firma HMAC richiede un segreto sul server che costruisce i pacchetti: chi lo possiede può fabbricare un manifest valido. È lo stesso limite dei manifest di stream ([ADR-004](004-hash-chain-per-stream-compatibile-con-audit-v1.md)), e la mitigazione è la stessa: ancoraggio delle teste fuori dal database, marca temporale MSign in F2.
- `lye_archive` è puro Dart ma dipende da `package:archive`: è la prima dipendenza esterna della libreria oltre a `crypto`, `meta` e `path`, e va dichiarata in `NOTICE.md`.
