# Changelog

Tutte le modifiche rilevanti sono registrate qui. Formato: [Keep a Changelog](https://keepachangelog.com/it/1.1.0/), versionamento [SemVer](https://semver.org/lang/it/). Il tag Git `vX.Y.Z` coincide con il campo `version` di **tutti** i pacchetti (`tool/check_versions.dart`).

## [0.1.0] — 2026-09-05

### Aggiunto
- `lye_core`: modello dell'evento (`LyeEvent`, `LyeDraft`), schema CSV `lye.v1`, rappresentazione canonica e hash-chain SHA-256 per stream, UUIDv7, redazione e minimizzazione degli attributi con `payload_digest`, codec CSV RFC 4180 con protezione da formula injection, manifest firmato (HMAC-SHA256) e concatenato, verifica della catena, store in memoria, registratore con span e propagazione via `Zone`, correlazione delle chiamate RPC, batch e scheduler di spedizione.
- `lye_io`: sink CSV su file con rotazione e manifest, verifica di una cartella di export, ricostruzione della timeline di una operazione, CLI `lye` (`verify`, `timeline`, `inspect`, `demo`).
- `lye_realm`: `RealmLyeStore` su Realm 20 (locale, cifrato), con continuità della catena tra riavvii.
- `lye_server`: gestore di ingest dei batch client con verifica della catena, tracciamento di scope, statement SQL, eventi di audit e job, export giornaliero e ancoraggio delle teste.
- `lye_flutter`: `LyeNavigatorObserver`, `LyeProviderObserver` (Riverpod 3), tracciamento puntatore con `LyeTrackable`, hook degli errori e del ciclo di vita, `HttpBatchShipper`.
- Documento tecnico, ADR 001–006, guida di integrazione per Compliance OS.
