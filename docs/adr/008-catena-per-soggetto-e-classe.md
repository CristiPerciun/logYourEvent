# ADR-008 — Catena per soggetto e classe accanto alla catena per stream

**Stato**: accettata · **Data**: 19 settembre 2026 · **Versione**: 0.2.0

## Contesto

La catena di `lye.v1` è **per stream**, cioè per processo: `origin/node_id/epoch`. È la scelta giusta per dimostrare che il tracciato di un'istanza non è stato alterato, ed è ciò che [ADR-004](004-hash-chain-per-stream-compatibile-con-audit-v1.md) ha fissato.

Il consumatore ha però bisogno di una prova diversa: dato un **account**, dimostrare che l'insieme dei suoi eventi consegnato in un archivio è completo e senza ripetizioni. Dentro lo stream di un server si alternano gli eventi di tutti gli account, quindi il sottoinsieme di uno solo è **sparso**: i `seq` hanno buchi e i `prev_hash` puntano a righe che appartengono ad altri. Una catena sparsa non dimostra né la completezza né l'assenza di duplicati.

Il consumatore separa inoltre gli archivi per **classe di conservazione** (`application`, `access`, `security`), perché la purga deve cancellare esattamente ciò che è scaduto e non sovra-conservare i log applicativi per contagio.

## Decisione

Si aggiunge una **seconda catena**, indipendente da quella per stream e calcolata nel momento in cui l'evento viene reso durevole nello store del consumatore. La chiave della catena è la coppia **(soggetto, classe di conservazione)**:

```
chain_key    = (subject_ref, retention)
chain_seq    = contatore contiguo 1..N, assegnato sotto blocco della riga di testa
chain_hash₀  = 32 byte a zero
chain_hashₖ  = sha256(chain_hashₖ₋₁ ‖ utf8(row_hashₖ))
```

La costruzione è la stessa di `audit.append_event` di Compliance OS: si blocca la riga di testa, si incrementa il progressivo, si accumula l'hash. La serializzazione avviene per catena, non globalmente.

Regole:

- La catena per stream **non cambia**: `prev_hash` e `row_hash` restano quelli di `lye.v1`, e `row_hash` continua a essere ricalcolabile **riga per riga**, senza bisogno delle righe vicine. È questa proprietà che rende verificabile una riga in un archivio sparso.
- `chain_seq` e `chain_hash` **non entrano** nella rappresentazione canonica dell'evento: sono assegnati dopo, dallo store, e vivono accanto all'evento. Un evento spedito da un client non può portarli, perché il client non sa quale posto occuperà.
- Tre catene per soggetto e non una: così **ogni archivio copre un intervallo contiguo di una sola catena** e si verifica da solo, senza avere sotto mano gli altri archivi dello stesso giorno.
- `lye_core` espone `SubjectChain.next(prevHex, rowHashHex)` e la verifica `SubjectChain.verify(rows)`; il calcolo è puro, così lo stesso codice gira nello store, nel costruttore di archivi e nel verificatore.

## Alternative considerate

| Alternativa | Perché no |
|---|---|
| Nessuna seconda catena: allegare all'archivio l'elenco dei `seq` esclusi | Per uno stream di server sono milioni di valori: il "documento di esclusione" peserebbe più delle righe che accompagna |
| Una sola catena per soggetto, con archivi divisi per classe | Gli intervalli di una classe non sarebbero contigui: la continuità si verificherebbe solo tenendo insieme tutti e tre i file del giorno, e un archivio che ha bisogno degli altri per essere creduto è un archivio più debole |
| Rendere lo stream stesso per soggetto (`origin/node/epoch/subject`) | Moltiplicherebbe gli stream per il numero di account attivi su ogni istanza, con una testa da mantenere per ciascuno e file minuscoli sul disco; e non funzionerebbe sul client, dove l'account può cambiare durante la sessione |
| Albero di Merkle per soggetto invece dell'accumulatore lineare | Permetterebbe prove di inclusione compatte, ma qui l'archivio contiene comunque tutte le righe: la prova compatta non serve, e l'accumulatore lineare è più semplice da verificare a mano |
| Mettere `chain_seq` dentro i campi hashati di `lye.v2` | Il client non può conoscerlo al momento di sigillare, e ricalcolare `row_hash` dopo l'assegnazione significherebbe riscrivere l'evento dopo averlo firmato |

## Conseguenze

- Una riga di testa per coppia (soggetto, classe): tre righe per account, con un blocco di riga sul percorso di scrittura. La scrittura è a lotti, quindi il costo è una `UPDATE ... RETURNING` per catena toccata, non per evento.
- La numerazione riflette l'ordine di **persistenza**, non quello di accadimento: gli eventi di un client rimasto offline ricevono numeri più alti pur avendo `occurred_at` più vecchio. È una proprietà voluta — permette di non riscrivere archivi già firmati — e il manifest la dichiara.
- Chi verifica ha ora due prove distinte, e deve sapere quale sta usando: la catena per stream dimostra la posizione della riga nel tracciato del processo, la catena per soggetto dimostra la completezza dell'insieme consegnato.
- Lo store in memoria e quello su Realm devono implementare l'assegnazione degli ordinali per restare intercambiabili con quello su PostgreSQL del consumatore.
