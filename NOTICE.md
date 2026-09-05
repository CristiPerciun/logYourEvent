# Inventario delle licenze di terze parti

Richiesto dal Concept aziendale §5.6 ("inventario delle licenze open source usate nel prodotto").
Ogni pacchetto qui elencato è usato come dipendenza non modificata.

| Pacchetto | Versione minima | Licenza | Uso in LYE | Note |
|---|---|---|---|---|
| `realm_dart` / `realm` (Realm Core) | 20.2.0 | Apache-2.0 | store locale durevole (`lye_realm`) | SDK deprecato da MongoDB (EOL 30 settembre 2025); linea 20.x senza sync, manutenzione comunitaria. Sta dietro l'interfaccia `LyeStore`: sostituibile (vedi ADR-001) |
| `crypto` | 3.0.7 | BSD-3-Clause | SHA-256, HMAC | pacchetto ufficiale Dart |
| `meta` | 1.18.0 | BSD-3-Clause | annotazioni | pacchetto ufficiale Dart |
| `path` | 1.9.1 | BSD-3-Clause | percorsi file (`lye_io`) | pacchetto ufficiale Dart |
| `http` | 1.6.0 | BSD-3-Clause | spedizione dei batch dal client (`lye_flutter`) | pacchetto ufficiale Dart |
| `flutter_riverpod` | 3.1.0 | MIT | `ProviderObserver` (`lye_flutter`) | |
| Flutter SDK | 3.44+ | BSD-3-Clause | `NavigatorObserver`, binding puntatore (`lye_flutter`) | |
| `lints`, `test`, `flutter_test`, `build_runner` | — | BSD-3-Clause | solo sviluppo | non distribuiti |

Nessuna dipendenza da Serverpod: l'aggancio al framework avviene nel progetto che consuma la libreria (ADR-002).
