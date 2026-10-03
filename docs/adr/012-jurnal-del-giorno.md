# ADR-012 — Il jurnal da leggere di un giorno, compresso e solo nei giorni con eventi; gli errori su un canale loro

**Stato**: accettata · **Data**: 3 ottobre 2026 · **Versione**: 0.4.0 · **Modifica**: [ADR-011](011-jurnal-da-leggere.md), punto 1

## Contesto

La 0.3 lasciava il file da leggere al consumatore, da produrre quando qualcuno lo chiede ([ADR-011](011-jurnal-da-leggere.md), punto 1). Compliance OS lo offriva così per ciascuno degli ultimi trenta giorni. La tendina della consolă elencava ogni giorno, anche quelli in cui il conto non aveva fatto nulla, e un giorno vuoto dava un file con la sola intestazione. A chi la apriva sembrava che si creasse e si salvasse un file al giorno, per qualunque giorno.

Il founder di Compliance OS, il 3 ottobre 2026, ha chiesto il contrario:

- il file si crea **solo** nei giorni in cui la persona ha lavorato e sono stati registrati eventi;
- si salva **compresso in uno ZIP**, per lo spazio del database;
- arriva al database **a fine giornata, oppure il giorno dopo, quando si riapre la consolă**.

Gli errori invece non aspettano la fine del giorno: «un JSON per gli errori, che viene inviato nel momento in cui si verifica l'errore», in una scheda accanto agli archivi, per poterli correggere subito. Niente invii a intervalli.

## Decisione

1. **Un file per soggetto e per giorno UTC**, `[00:00, 24:00)`. Il giorno è quello degli archivi, e un evento appartiene a un giorno solo: gli stessi eventi danno sempre lo stesso file.
2. **Nessun passaggio, nessun file.** `ReadableJournalDay.pack` restituisce null per un giorno senza passaggi, anche quando riceve eventi di altri giorni. Il consumatore non può salvare un file vuoto per sbaglio.
3. **Il CSV viaggia in uno ZIP con un solo membro**, `<nome>.csv`, compresso al massimo. La data di modifica è l'inizio del giorno, quindi gli stessi eventi danno gli stessi byte. Il CSV è quello di `LyeReadableJournal.encode`, invariato.
4. **Nessun manifest dentro.** Il file non è una prova ([ADR-011](011-jurnal-da-leggere.md), punto 6), e un manifest firmato lo farebbe sembrare tale. Il digest dei byte (`PackedJournalDay.sha256`) appartiene a chi li conserva, come per gli archivi.
5. **Il nome è del consumatore**, come per gli archivi ([ADR-009](009-archivi-zip-per-soggetto.md)), e non contiene dati personali: la libreria accetta solo lettere, cifre, punto, trattino e trattino basso.
6. **`PackedJournalDay.retentions`** dice da quali classi vengono gli eventi del file. Il file contiene dati di tutte quelle classi, quindi può vivere solo quanto la più breve: un giorno con la navigazione dura sei mesi, anche se le chiamate dello stesso giorno ne durano dodici.
7. **Quando costruirlo resta del consumatore** ([ADR-002](002-nessuna-dipendenza-da-serverpod-e-flutter-nel-core.md)). Compliance OS lo costruisce al taglio delle 00:10 UTC. Un server addormentato lo recupera alla prima scansione dopo il risveglio, cioè quando qualcuno riapre la consolă. Lo rifà se arrivano eventi in ritardo per quel giorno, rileggendo tutti gli eventi del giorno: lo storico non si perde.
8. **Gli errori hanno un canale loro.** `LyeEvent.isError` dice che cos'è un errore: un esito `fail` o `denied`, o un evento della categoria `error`. `LyeJournalStep.isError` dice lo stesso di un passaggio, guardando i due lati della chiamata. `ShippingScheduler` spedisce un errore **appena è registrato**, con ciò che era in attesa prima di lui, invece di aspettare la soglia o l'intervallo (`shipErrorsAtOnce`, attivo di serie). Un errore registrato mentre una spedizione è in corso ottiene un giro suo. Il ritardo dopo un guasto di rete resta, perché martellare un destinatario che non risponde non aiuta nessuno. Che cosa fare dell'errore all'arrivo è del consumatore: Compliance OS lo scrive subito nel JSON degli errori del giorno.

## Conseguenze

- Il punto 1 di ADR-011 cambia: il file non si produce più quando qualcuno lo chiede, ma alla chiusura del giorno, e di nuovo solo se il giorno riceve eventi dopo.
- Il consumatore conserva un file per giorno attivo invece di nessuno. Compresso, pesa una piccola parte del CSV, perché le righe si ripetono: stesse zone, stesse pagine, stesse azioni.
- Un errore arriva al destinatario in una frazione di secondo invece che entro l'intervallo (cinque secondi di serie), o la soglia di cinquanta eventi. Il prezzo è un lotto in più per errore.
- Gli archivi firmati restano come sono: manifest `lye.archive.v1`, un CSV `lye.v2` per pacchetto. Un verificatore della 0.2 legge ancora tutto.
- `LyeReadableJournal` non cambia: la 0.4 aggiunge il giorno, la compressione e il riconoscimento degli errori, non tocca le colonne né le righe.

## Alternative scartate

- **Il file dentro gli archivi firmati.** Già scartata da ADR-011: uno ZIP è di una classe sola, e sarebbero tre file per giorno, nessuno completo.
- **Il CSV senza compressione.** È ciò che il founder ha chiesto di non fare. Un giorno normale pesa qualche decina di kilobyte, uno a livello `verbose` molto di più, e la base gratuita di Compliance OS ha mezzo gigabyte.
- **Costruirlo nella consolă e spedirlo.** La consolă non ha gli eventi del server, che sono metà dei passaggi. Inoltre un browser chiuso prima di mezzanotte non spedirebbe nulla. Il server riceve già tutti gli eventi della consolă, lotto per lotto, e li ha tutti.
- **Aggiornare il file del giorno dieci minuti dopo un errore.** Proposta e ritirata dal founder lo stesso giorno: niente invii a intervalli. Un errore va subito sul suo canale, e il file del giorno resta quello di fine giornata.
- **Un file per ogni giorno, vuoto compreso, per avere un calendario senza buchi.** È proprio ciò che sembrava succedere e che il founder ha chiesto di togliere: un giorno senza passaggi non ha nulla da leggere.
