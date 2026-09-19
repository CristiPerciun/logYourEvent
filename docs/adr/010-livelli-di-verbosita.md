# ADR-010 — Cinque livelli di verbosità; `forensic` registra le funzioni, non i valori

**Stato**: accettata · **Data**: 19 settembre 2026 · **Versione**: 0.2.0

## Contesto

La 0.1 registra tutto ciò che gli adattatori le passano: il governo del volume è affidato al consumatore, che decide quali provider osservare e quali statement tracciare (LYE §18, punto 4). Funziona finché c'è una sola configurazione per l'intero sistema, e smette di funzionare appena serve accendere il dettaglio **su un account solo** per capire un difetto che riguarda lui.

Il consumatore ha già tre livelli nel proprio dominio (`disabled`, `errorOnly`, `verbose`) ma vivono fuori dalla libreria, in una mappa in memoria, e il filtro è un booleano `isError`. Servono livelli veri, conosciuti dalla libreria, applicati prima della sigillatura, e serve un gradino in più: registrare **tutte le funzioni** attraversate, perché è così che si ricostruisce un processo che ha sbagliato.

Il vincolo che non si tocca: nel tracciato non entrano valori ([ADR-007](007-minimizzazione-by-design.md)). «Registrare tutte le funzioni» deve quindi significare registrare il **percorso di esecuzione**, non gli argomenti.

## Decisione

Cinque livelli ordinati, in `lye_core`:

```
LyeLevel { error(10), standard(20), verbose(30), forensic(40) }
```

con lo spegnimento espresso dal consumatore come assenza di livello. La corrispondenza con l'enumerazione del consumatore è: `disabled` → niente, `errorOnly` → `error`, `standard` → `standard`, `verbose` → `verbose`, `forensic` → `forensic`.

| Livello | Che cosa entra |
|---|---|
| *(spento)* | solo `security.*`, `auth.*` e la manutenzione `lye.*`: sono obbligo di legge nel dominio del consumatore e la libreria non li lascia cadere |
| `error` | + ogni esito `fail`/`denied`, `error.*` |
| `standard` | + `rpc.*`, `audit.*`, `document.*`, `export.*`, `job.*`, `app.*`, `nav.*` |
| `verbose` | + `ui.tap`, `ui.intent`, `ui.form.*`, `state.mutation.*`, `db.scope`, `db.statement` di mutazione e query lente |
| `forensic` | + `fn.enter`/`fn.exit`, `ui.pointer_*`, tutte le transizioni di stato, tutti gli statement |

Regole:

1. **Il livello è una colonna** di `lye.v2`: l'archivio dice da sé a quale livello ogni riga è stata emessa, e quindi perché qualcosa manca.
2. **Il filtro sta nel recorder, prima di sigillare.** Una bozza scartata non consuma un numero di sequenza: le catene restano contigue e un buco non si confonde mai con una perdita.
3. **`LyeLevelPolicy`** mappa `(categoria, azione, esito)` al livello minimo. È un dato, non codice: il consumatore può sostituirla per il proprio verticale.
4. **Ogni cambio di livello è un evento**, `lye.policy.applied`, con livello, origine (`user`, `fleet`, `grant`), autore e causale. Senza, un'ora povera di eventi è indistinguibile da un'ora di silenzio.
5. **`LyeTrace.fn`** avvolge una funzione ed emette `fn.enter`/`fn.exit` con nome qualificato, **nomi e tipi dei parametri**, digest degli argomenti, durata ed esito. Mai i valori.
6. **`forensic` è a termine.** La libreria espone la scadenza nella configurazione e il recorder retrocede da solo quando scade; la concessione, la causale e chi l'ha data appartengono al consumatore.
7. **Tetto di volume.** Superato il tetto giornaliero configurato, il recorder emette `lye.quota.exceeded` e retrocede di un livello invece di scrivere all'infinito.

## Alternative considerate

| Alternativa | Perché no |
|---|---|
| Restare a tre livelli | `verbose` doveva significare due cose diverse — «vedo i clic» e «vedo ogni funzione» — e chi accende il secondo non vuole quasi mai lasciarlo acceso |
| Filtro a valle, allo store o all'export | Le sequenze avrebbero buchi, e un buco è indistinguibile da una riga persa: si distruggerebbe la sola proprietà che rende utile una catena |
| Livelli come soglie numeriche libere, in stile syslog | Nessuno ricorda che cosa significhi `warning` per un clic; una tabella di livelli nominati è più onesta |
| Registrare anche gli argomenti al livello `forensic` | Sarebbe un trattamento nuovo di dati personali: va nel registro dei trattamenti e nel DPA prima che nel codice. I digest permettono già a chi possiede il dato di dimostrare la coincidenza ([ADR-007](007-minimizzazione-by-design.md)) |
| Strumentazione automatica di tutte le funzioni tramite generazione di codice | `build_runner` su ogni pacchetto del consumatore, per un livello acceso poche ore l'anno. Un decoratore esplicito sui servizi che contano costa meno e si legge meglio |

## Conseguenze

- Una colonna in più in `lye.v2` e un campo in più in `LyeDraft`.
- Il consumatore deve propagare il livello al client e applicarlo lì: il filtro sul server non impedisce al client di produrre e spedire, e spedire per poi scartare sarebbe spreco di rete e di batteria.
- `fn.enter`/`fn.exit` raddoppiano gli eventi di ogni chiamata e vanno attivati solo dove servono. Con la scadenza obbligatoria, il tetto di volume e il livello scritto sulla riga, il costo resta circoscritto e visibile.
- L'enumerazione del consumatore passa da tre a cinque valori: i tre nomi esistenti non cambiano e la conversione da stringa conserva le mappature già scritte, così le configurazioni esistenti continuano a valere.
