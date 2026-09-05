# ADR-001 — Realm come store locale, dietro l'interfaccia `LyeStore`

**Stato**: accettata · **Data**: 5 settembre 2026 · **Versione LYE**: 0.1.0

## Contesto

Il committente ha chiesto una libreria proprietaria "basata su Realm" che registri ogni movimento e produca file CSV. Il Documento Tecnico di Architettura 5.1 (§4.1, principio 3) impone che ogni componente esterno stia "dietro un'interfaccia Dart con una seconda implementazione documentata"; §8.5 vieta dati sensibili nella cache del browser e promette un'esperienza *online-first*; §9.6 cita Drift come coda offline già nello stack del founder.

Verifiche del 5 settembre 2026: `realm` e `realm_dart` 20.2.0 (24 settembre 2025) sono su pub.dev, licenza Apache-2.0, piattaforme iOS, Android, Windows, macOS, Linux e Dart standalone; **nessun supporto web**. MongoDB ha dichiarato la deprecazione degli Atlas Device SDK (settembre 2024) con fine supporto il **30 settembre 2025**; la linea 20.x senza sync e il ramo `community` restano disponibili come progetto open source senza manutenzione del produttore.

## Decisione

1. Realm è lo store durevole di LYE (`lye_realm`, `RealmLyeStore`) per server Dart, desktop e mobile: file locale, cifratura AES-256 con chiave a 64 byte fuori dal repository, una transazione di scrittura per ogni append che verifica la testa, inserisce la riga e aggiorna la testa.
2. Lo store sta dietro l'interfaccia `LyeStore` di `lye_core` (nove metodi). Il pacchetto cuore non conosce Realm; nessun altro pacchetto lo importa.
3. Sul web, dove Realm non esiste e la cache non deve contenere dati sensibili, lo store è `MemoryLyeStore`: buffer limitato, spedizione al server entro pochi secondi, svuotato al logout.
4. La **copia durevole non è lo store**: sono i file CSV con manifest firmati e le ancore delle teste. Lo store è un buffer tra due spedizioni o due export. Perdere il file Realm non perde prove già esportate.
5. Il rischio di fine vita di Realm è iscritto nel registro dei rischi con un criterio di uscita: se entro il gate di F1 un difetto bloccante di Realm non ha una correzione comunitaria, oppure se Dart 4 rompe la linea 20.x, si scrive `DriftLyeStore` (SQLite via Drift, già nello stack) contro la stessa interfaccia e la stessa suite di test del contratto (`realm_lye_store_test.dart` è scritta contro `LyeStore`, non contro Realm).

## Alternative considerate

| Alternativa | Perché no, oggi |
|---|---|
| Drift/SQLite dal primo giorno | Contraddice la richiesta esplicita; resta la seconda implementazione documentata |
| Tabella PostgreSQL `lye.events` | Mescola il log tecnico con il perimetro dati; raddoppia il volume del DB; il log tecnico deve sopravvivere a un DB compromesso (§5.6) |
| Solo file CSV in append | Nessuna query per stream, nessun `pending`, nessuna atomicità testa+riga |
| Hive/Isar | Isar è fermo dal 2023, Hive non ha query indicizzate |

## Conseguenze

- Il consumer deve eseguire `dart run realm_dart install` (server, Dockerfile) o dipendere da `realm` (Flutter nativo). Il file `models.realm.dart` generato è versionato nel repository, così una dipendenza git non richiede code generation.
- `realm_generator` 20.x ancora `analyzer ^7`: il pacchetto `lye_realm` usa `test ^1.26` in sviluppo. Nessun impatto sui consumer.
- I test di `lye_realm` hanno il tag `realm` e richiedono i binari nativi; la CI li installa in un job dedicato.
