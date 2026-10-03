# ADR-011 — Un solo CSV da leggere per conto, al massimo sei colonne; la prova resta negli archivi

**Stato**: accettata; il punto 1 è modificato da [ADR-012](012-jurnal-del-giorno.md) (0.4.0: un file per giorno, compresso, solo nei giorni con eventi) · **Data**: 1 ottobre 2026 · **Versione**: 0.3.0

## Contesto

Gli archivi della 0.2 sono fatti per chi verifica: un CSV `lye.v2` di quaranta colonne, nell'ordine che serve all'hash della riga, e uno ZIP per **classe** di retention, perché ogni classe scade alla sua data ([ADR-008](008-catena-per-soggetto-e-classe.md), [ADR-009](009-archivi-zip-per-soggetto.md)). Una giornata di un conto produce quindi fino a tre pacchetti: la navigazione e i clic in `application`, le chiamate in `access`, la sicurezza in `security`.

Chi deve capire che cosa ha fatto una persona prima di un errore ha bisogno del contrario. Il founder di Compliance OS lo ha detto così: *un unico file che mi permetta di ricostruire tutti i passaggi dell'utente nel caso dell'errore, leggibile, con una struttura chiara e pulita, diviso in colonne*; la zona del prodotto nella prima colonna, la data nella seconda, l'evento o l'errore nella terza, **non più di sei** in tutto. Aprendo lo ZIP aveva trovato le quaranta colonne, e i clic registrati a verbosità alta in un pacchetto diverso da quello delle chiamate.

## Decisione

1. **Il file da leggere è uno solo per conto** e unisce le tre classi. Non sta dentro gli archivi: uno ZIP è di una classe sola e un file in ogni ZIP sarebbero tre file per giorno, nessuno dei quali completo. Lo produce il consumatore quando qualcuno lo chiede, da tutto ciò che ha del conto: la tabella calda e gli archivi.
2. **Al massimo sei colonne** (`LyeReadableJournal.maxColumns`). Le colonne sono del consumatore, che conosce le zone del suo prodotto, le sue pagine e i suoi errori; la libreria rifiuta la settima: una tabella per persone che ne chiede di più sono due tabelle.
3. **Un passaggio, una riga.** Lo stesso evento letto due volte (dalla tabella calda e da un archivio) conta una volta, su `event_id` + `row_hash`. Il `rpc.call` della console e il `rpc.handle` del server della stessa chiamata diventano **un** passaggio: stesso attore, stesso `call_digest` ([ADR-005](005-propagazione-via-zone-e-correlazione-call-digest.md)), il più vicino nel tempo entro due minuti, perché gli orologi sono due e uno è quello del browser. Esito, durata e classe d'errore sono quelli del server quando ci sono: dice più del «non è andata» della console. Una chiamata che il server non ha mai ricevuto resta un passaggio, ed è proprio quella che spiega un errore di rete.
4. **La zona** si riconosce con domande in ordine, dalla più precisa: l'endpoint della chiamata (una chiamata alla licenza fatta dalla pagina delle fatture riguarda la licenza), poi l'azione (`auth.login` è accesso ovunque avvenga), poi la pagina (un clic appartiene alla pagina su cui è stato fatto). Regole e nomi sono del consumatore (`LyeJournalAreas`).
5. **Leggibile da un foglio di calcolo così com'è**: separatore `;`, che è quello atteso dove la virgola è il separatore decimale (Romania, Moldova, Italia, Russia); UTF-8 con BOM, senza il quale ă, ș, ț e il cirillico diventano due caratteri strani ciascuno; ogni cella su una riga e mai una formula (`LyeText.sanitize`): le celle vengono anche da eventi spediti da un client.
6. **Non è una prova.** È derivato dagli eventi, nessuno lo verifica e si può rifare in ogni momento dagli archivi, che restano come sono: il manifest resta `lye.archive.v1` e un verificatore della 0.2 legge ancora tutto.

## Conseguenze

- I clic registrati a verbosità `verbose` stanno nello stesso file delle chiamate e delle pagine, nell'ordine in cui sono avvenuti.
- Il consumatore paga una lettura degli archivi del giorno quando qualcuno chiede il file; con il taglio notturno sono pochi pacchetti per conto.
- La parola «evento» del file è quella del consumatore: la libreria non traduce azioni in frasi, perché non conosce il prodotto.

## Alternative scartate

- **Una tabella da leggere dentro ogni ZIP.** Provata e tolta prima del rilascio: tre file per giorno, ciascuno con un pezzo dei passaggi, e un manifest `v2` che i verificatori della 0.2 non avrebbero letto.
- **Ridurre le colonne del CSV firmato.** L'hash della riga copre trentasette colonne: toglierle significa non poter più verificare nulla.
- **Un pacchetto per conto con le tre classi.** Le classi scadono a 6, 12 e 24 mesi: un pacchetto unico andrebbe cancellato tutto alla prima scadenza o tenuto oltre il dovuto.
