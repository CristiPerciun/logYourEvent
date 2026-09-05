# ADR-007 — Minimizzazione by design: redazione, `payload_digest`, classi di retention

**Stato**: accettata · **Data**: 5 settembre 2026

## Contesto

La piattaforma è *persoană împuternicită* (art. 28 Legge 195/2024) e deve dimostrare le misure dell'art. 32. Il Documento Tecnico 5.1 impone log tecnici "senza dati personali in chiaro né corpi di richiesta", con identificativo pseudonimo dell'utente e ritenzioni differenziate (§6.6), payload di audit "senza dati eccedenti" (§5.6), e vieta dati sensibili nella cache del browser (§8.5). Il Concept Aziendale (§2.3, principio 6) fa del registro dei trattamenti dell'azienda stessa "il primo banco di prova del prodotto".

## Decisione

1. **Struttura prima del contenuto**: il tracciato registra *che cosa* è accaduto (azione, esito, durata, rotta, componente, entità per identificativo), *chi* (UUID pseudonimo, ruolo) e *dove* (partner, tenant); non registra mai valori di stato Riverpod, argomenti di chiamata, parametri SQL, messaggi di errore o testo dello schermo.
2. **Redazione degli attributi** (`Redactor`): chiavi vietate (password, token, email, name, phone, idnp, iban…), frammenti di chiave sensibili, pattern scrubbati nei valori (e-mail, IDNP a 13 cifre, IBAN moldavo, telefoni, JWT/Bearer), limiti di profondità, lunghezza e numero di chiavi; politica *strict* con allow-list disponibile per categoria.
3. **`payload_digest`**: SHA-256 della forma canonica degli attributi **originali**, prima della redazione. È un impegno: chi possiede il dato originale può provare che coincide, il tracciato non lo contiene. Quando nulla è stato redatto il digest coincide con quello di `attrs`, e il verificatore lo controlla.
4. **Errori**: solo il nome del tipo e il digest del messaggio; il messaggio resta in Sentry con il suo scrubbing.
5. **Classi di retention** dentro l'evento (`application` 6 mesi, `access` 12, `security` 24) derivate dalla categoria: la purga non deve conoscere la policy che ha prodotto l'evento.
6. **Web**: buffer in memoria, spedizione entro secondi, cancellazione al logout; nessuna persistenza locale.
7. LYE è a sua volta un trattamento della piattaforma: va iscritto nel RoPA della società (finalità: sicurezza e accountability, art. 32; base: obbligo legale e interesse legittimo; conservazione: come sopra).

## Alternative considerate

| Alternativa | Perché no |
|---|---|
| Registrare tutto e cifrare | Sposta il problema sulla chiave; contrario alla minimizzazione |
| Nessun attributo | Rende la ricostruzione povera; i digest e gli identificativi bastano a collegare senza rivelare |

## Conseguenze

- Alcune analisi ("quale valore aveva il campo") non sono possibili dal tracciato: è voluto. Il dato vive nei registri storicizzati e nell'audit con payload minimizzato.
- I pattern di redazione vanno estesi per verticale (SSM: numeri di matricola); sono dati di configurazione, non codice del core.
