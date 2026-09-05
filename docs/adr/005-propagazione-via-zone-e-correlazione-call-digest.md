# ADR-005 — Propagazione del contesto via `Zone` e correlazione client–server con `call_digest`

**Stato**: accettata · **Data**: 5 settembre 2026

## Contesto

Ricostruire "l'intero ciclo di ogni operazione" richiede che il tap sulla console, la mutazione Riverpod, la chiamata RPC, la gestione sul server, la transazione con scope, gli statement SQL e l'evento di audit condividano un identificatore. Dentro un processo Dart questo si ottiene senza passare parametri; tra client e server serve un canale. Verifica del 5 settembre 2026 su `serverpod_client` 2.9.5: `callServerEndpoint` espone `onSucceededCall(MethodCallContext)` e `onFailedCall(...)` con `endpointName`, `methodName`, `arguments`, ma **nessun modo di aggiungere un header** alla chiamata (il client HTTP è privato).

## Decisione

1. **Dentro il processo**: `LyeRecorder.span` esegue il corpo in una `Zone` che porta lo `LyeSpan` corrente; ogni `record` legge `LyeSpan.current` e riempie `trace_id`, `span_id`, `parent_span_id`, `operation`. Lo stesso meccanismo (`withContext`) porta il contesto di tenancy per richiesta sul server, così un unico recorder serve richieste concorrenti senza confondere i tenant. `LyeSpan.detached` interrompe la propagazione dove serve.
2. **Tra client e server**: entrambi calcolano `call_digest = sha256(canonical({e: endpoint, m: method, a: argomenti JSON}))`. Il client lo fa in `onSucceededCall`/`onFailedCall` con gli argomenti serializzati come sul filo; il server lo fa su `queryParameters` privato delle chiavi di busta (`method`, `endpoint`). L'evento `rpc.call` del client e `rpc.handle` del server portano il digest negli attributi; lo strumento `lye timeline` unisce le due tracce su `(call_digest)` entro una finestra temporale, e `actor_ref` disambigua.
3. Gli **argomenti entrano solo nel digest**, mai nel tracciato.

## Alternative considerate

| Alternativa | Perché no |
|---|---|
| Header `X-Lye-Trace` | Non supportato dal client Serverpod 2.9.5 senza fork; da riconsiderare se una versione futura esporrà gli header |
| `trace_id` come argomento di ogni metodo endpoint | Invasivo sul contratto API; sporca i modelli condivisi |
| Correlazione solo temporale | Ambigua con più utenti e chiamate identiche |

## Conseguenze

- Due chiamate identiche dello stesso attore entro pochi secondi (stesso endpoint, stessi argomenti) condividono il digest: la timeline le mostra insieme, l'ordine temporale le distingue. Accettabile per un console d'ufficio.
- Se in futuro il client permetterà header, `trace_id` viaggerà direttamente e `call_digest` resterà come conferma indipendente.
