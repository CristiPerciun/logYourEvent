# ADR-003 — CSV `lye.v1` come formato canonico di export e verifica

**Stato**: accettata · **Data**: 5 settembre 2026

## Contesto

Il committente richiede "file CSV contenenti ogni tipo di azione effettuata". Il Documento Tecnico 5.1 chiede "auditabilità: ogni azione rilevante tracciata e verificabile da terzi" (§2.2) e prevede l'export CSV delle tabelle come mitigazione web (§8.5). Chi verifica è spesso un ispettore, un legale o un consulente che apre un foglio di calcolo, non un ingegnere con un database.

## Decisione

- Un solo schema, `lye.v1`, 37 colonne in ordine fisso; le prime 34 formano la rappresentazione canonica hashata, seguono `prev_hash`, `row_hash` e `received_at` (metadato del server, non hashato).
- Codifica RFC 4180: UTF-8 senza BOM, CRLF, quoting solo dove serve, virgolette raddoppiate. Un file per stream, giorno UTC e parte; un manifest JSON firmato per file.
- L'hash copre i **campi canonici**, non i byte del file: il CSV può essere ricodificato (quoting diverso, LF al posto di CRLF) senza invalidare le firme delle righe; l'integrità dei byte è garantita separatamente dal manifest (`file_sha256`).
- Protezione da *CSV formula injection* applicata **prima** dell'hash: il valore che entra nella catena è il valore scritto nel file, così il verificatore non deve indovinare come un valore è stato neutralizzato.
- Lo stesso evento ha una forma JSON (chiavi = nomi delle colonne) usata dai batch client→server e dai manifest; CSV e JSON sono intercambiabili senza perdita.
- Cambiare lo schema significa un nuovo tag (`lye.v2`) con lettore proprio; nessuna colonna viene mai rinominata o riordinata dentro una versione.

## Alternative considerate

| Alternativa | Perché no |
|---|---|
| JSON Lines | Non apribile da chi verifica; nessun vantaggio per il verificatore automatico che già usa la forma canonica |
| Parquet/Arrow | Nessun lettore Dart maturo; binario opaco per il legale |
| Solo tabella nel database | La prova deve sopravvivere al database (§5.6: tamper-evident vs tamper-proof) |

## Conseguenze

- Le colonne libere sono limitate in lunghezza (512 caratteri, `attrs` 4 KiB) e rese su una riga: un CSV di 50 MB contiene ordine di 100–200 mila eventi.
- Chi legge il CSV con Excel vede i valori che iniziano con `=`, `+`, `-`, `@` preceduti da apostrofo: è voluto.
