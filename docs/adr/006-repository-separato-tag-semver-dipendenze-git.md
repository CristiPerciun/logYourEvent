# ADR-006 — Repository separato, tag SemVer, consumo tramite dipendenze Git

**Stato**: accettata · **Data**: 5 settembre 2026

## Contesto

Il committente vuole la libreria "inclusa nel progetto tramite un tag/versione e mantenuta come progetto separato, così da poter essere importata e utilizzata negli altri progetti". Il Concept Aziendale (§2.4, §3.4) definisce il motore come asset della casa madre "concesso in licenza interna" ai verticali e chiede "contratti cedibili" e "licenza interna del motore documentata". Il codice è oggi proprietario e non pubblicabile su pub.dev.

## Decisione

1. Repository Git dedicato `log-your-event` con cinque pacchetti in `packages/`, ciascuno con il proprio `pubspec.yaml` e **senza** `resolution: workspace`: una dipendenza Git verso un membro di un pub workspace costringerebbe il consumer a risolvere anche i pacchetti Flutter del workspace. Le dipendenze interne sono `path: ../lye_core`, che pub risolve dentro lo stesso checkout Git.
2. Versionamento SemVer; il tag `vX.Y.Z` coincide con il campo `version` di tutti i pubspec e con `lyeVersion` in `lye_core/lib/src/version.dart` (`tool/check_versions.dart`, eseguito dalla CI e obbligatorio sui tag).
3. Consumo:

   ```yaml
   dependencies:
     lye_core:
       git:
         url: https://github.com/CristiPerciun/log-your-event.git
         ref: v0.1.0
         path: packages/lye_core
   ```

   Il `pubspec.lock` del consumer fissa il commit: build riproducibili. L'aggiornamento è un cambio di `ref` in una pull request, revisionabile con il CHANGELOG.
4. Compatibilità: schema CSV e manifest immutabili dentro una versione di schema; API pubblica soggetta a SemVer; `lye_core` senza dipendenze da framework (ADR-002) così i major dei framework non impongono major a LYE.
5. Licenza proprietaria con titolarità del founder fino alla cessione alla SRL (Concept §5.6, §6.4), poi della SRL; inventario delle licenze di terze parti in `NOTICE.md`.

## Alternative considerate

| Alternativa | Perché no, oggi |
|---|---|
| Pacchetto dentro il monorepo `compliance-os` | Non riusabile dagli altri prodotti né dal gateway; nessuna versione indipendente |
| Server pub privato (unpub, Cloudsmith) | Un componente stateful in più da mantenere (§2.3 vincoli); da rivalutare quando i consumer saranno più di due |
| pub.dev pubblico | Il codice è proprietario |
| Git submodule | Meno ergonomico di una dipendenza pub; nessun lock per pacchetto |

## Conseguenze

- Il consumer di `lye_realm` deve installare i binari Realm (`dart run realm_dart install`) nel proprio ambiente e nel Dockerfile.
- I file generati (`models.realm.dart`) sono versionati, così un checkout Git è utilizzabile senza `build_runner`.
