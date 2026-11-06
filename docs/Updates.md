# Aggiornamenti in-app

Flusso si aggiorna da solo con [Sparkle 2](https://sparkle-project.org), lo stesso sistema di
ImmichGallery.

## Cosa vede l'utente

- **Menu barra › Verifica aggiornamenti…** e **Generali › Aggiornamenti › Verifica aggiornamenti…**
  controllano subito e mostrano il risultato.
- In **Generali › Aggiornamenti**:
  - *Cerca aggiornamenti automaticamente* (attivo di default): un controllo all'avvio e uno al giorno.
  - *Scarica e installa automaticamente* (disattivo di default): l'aggiornamento viene scaricato in
    silenzio e installato alla chiusura dell'app.
- Quando c'è una nuova versione si apre la finestra di Sparkle con le note di rilascio e i pulsanti
  *Installa*, *Ricordamelo più tardi*, *Salta questa versione*.

Tutto è in `App/Sources/App/AppUpdater.swift`. Le build Debug non si aggiornano.

## Come funziona

- `App/Info.plist`: `SUFeedURL` (dal build setting `SPARKLE_FEED_URL`), `SUPublicEDKey`,
  `SUEnableAutomaticChecks`.
- Il feed è `https://github.com/IGOLz/flusso/releases/latest/download/appcast.xml`: il file
  `appcast.xml` allegato alla release GitHub **latest**. Pre-release e bozze non sono mai "latest".
- Ogni aggiornamento è lo `.zip` della release, firmato con una chiave EdDSA. Sparkle rifiuta un
  aggiornamento con firma diversa da `SUPublicEDKey` o con un team Developer ID diverso.
- Sparkle confronta `CFBundleVersion` (`CURRENT_PROJECT_VERSION` in `project.yml`): **aumenta il
  numero di build a ogni release**, insieme a `MARKETING_VERSION`.

## Pubblicare una versione

```sh
RELEASE_NOTES=note.md ./scripts/release.sh   # build universale, firma, notarizzazione, appcast.xml
./scripts/publish.sh                          # release GitHub con dmg, zip, appcast, checksum
```

`release.sh` firma gli helper di Sparkle con il Developer ID, notarizza app e DMG, scarica il feed
pubblicato e ci aggiunge la nuova versione con `generate_appcast` (le voci precedenti restano).
`publish.sh` crea la release come bozza, carica i file e solo dopo la pubblica, così le app
installate non vedono mai un feed che punta a uno `.zip` non ancora caricato. Usa `--prerelease`
per una versione di prova che le app installate non devono ricevere.

## La chiave di firma

La chiave privata EdDSA è nel portachiavi del Mac di release (elemento "Private key for signing
Sparkle updates", account `ed25519`), condivisa con ImmichGallery. La prima volta che
`generate_appcast` la usa, macOS chiede l'accesso: scegli **Consenti sempre**.

**Fanne un backup**: se va persa, le app installate non possono più aggiornarsi da sole.

```sh
build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys -x sparkle-private-key.txt
```
