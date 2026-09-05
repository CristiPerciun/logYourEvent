# ADR-004 — Hash-chain per stream, costruzione identica a `audit.canonical_event_v1`, manifest concatenati e ancoraggio

**Stato**: accettata · **Data**: 5 settembre 2026

## Contesto

Compliance OS ha già una catena probatoria: `audit.events` con `row_hash = sha256(prev_hash || canonical_event_v1)` calcolata da PostgreSQL, separatore ASCII Record Separator, timestamp UTC a microsecondi, verificata in Dart e in SQL (`VERIFICATION_LOG.md`, §3). Il documento tecnico (§5.6) ricorda che una catena interna è *tamper-evident* e non *tamper-proof*, e prescrive l'export giornaliero della testa fuori dal database e, in F2, la marca temporale MSign.

## Decisione

1. **Stessa costruzione**: LYE usa `sha256(prev_hash_bytes || utf8(campi canonici uniti da 0x1E))`, genesi a 32 byte zero, timestamp `YYYY-MM-DDTHH:MM:SS.ffffffZ`, canonicalizzazione JSON identica a `AuditService.canonicalizeJson`. Chi sa verificare l'audit sa verificare LYE, e un digest calcolato da LYE su una mappa coincide con quello dell'audit sulla stessa mappa.
2. **Una catena per stream**, dove lo stream è `origin/node_id/epoch` e l'*epoch* è un UUIDv7 nuovo a ogni avvio del processo. Nessuna catena globale: niente collo di bottiglia, niente coordinamento tra processi, e il primo evento di ogni epoch (`lye.stream.start`) cita stream, seq e testa dell'epoch precedente dello stesso nodo, così le catene si collegano nel tempo e il verificatore controlla anche quel legame (`epoch_link_mismatch`).
3. **Tre livelli di prova**: la riga (hash e link), il file (manifest con digest dei byte, intervallo di seq, testa e link al manifest precedente: rimuovere un file è visibile quanto rimuovere una riga) e l'ancora (record firmato con tutte le teste, scritto in un Object Storage in altra sede, oggi HMAC-SHA256 con chiave di deployment, in F2 marca temporale MSign come per le teste dell'audit).
4. **Sequenza contigua da 1** garantita da un unico scrittore per stream (il `LyeRecorder` serializza le chiamate concorrenti) e ricontrollata dallo store ad ogni append: la contiguità non dipende dalla disciplina del chiamante.

## Alternative considerate

| Alternativa | Perché no |
|---|---|
| Albero di Merkle per file | Più efficiente per prove parziali, ma il caso d'uso è la verifica completa e la lettura umana; il costo cognitivo per il legale non è giustificato in v0.1 |
| Firma per riga (Ed25519) | Costo e gestione chiavi sul client; il client non è un'autorità: la sua catena viene verificata e ri-firmata dal server nel manifest |
| Catena unica cross-processo | Richiederebbe un coordinatore; contraria al monolite stateless (§4.1) |

## Conseguenze

- Un file può essere ricodificato senza rompere le righe, ma non senza rompere il manifest: è il comportamento voluto (il manifest attesta i byte, la riga attesta il contenuto).
- La purga per retention cancella file interi dal più vecchio: il residuo è una coda contigua segnalata come `partial_stream`; le teste restano nelle ancore.
