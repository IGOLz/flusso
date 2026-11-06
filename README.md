# Flusso

Dettatura vocale per macOS, gratuita e interamente locale. Una versione personale di
[Wispr Flow](https://wisprflow.ai), costruita sul motore di trascrizione di
[Handy](https://github.com/cjpais/handy).

Tieni premuto **fn**, parla, rilascia: il testo compare nel campo dove si trova il cursore.

## Funzionalità

- **Tieni premuto per dettare**: tieni premuto `fn`, rilascia per trascrivere e incollare.
- **Modalità mani libere**: `fn + Spazio` blocca la registrazione; premi di nuovo `fn + Spazio`,
  tocca `fn` oppure clicca ✓ per terminare. `Esc` o × annullano.
- **Incolla dove c'è il focus**: il testo viene incollato nel campo attivo dell'app in primo piano.
  Se nessun campo di testo è attivo compare un riquadro con il pulsante **Copia** (scompare dopo 5 s).
- **Avvio istantaneo**: il microfono resta pronto, quindi la registrazione parte in meno di 1 ms
  e include anche gli ultimi 300 ms *prima* della pressione del tasto: le prime parole non vanno mai perse.
- **Modello Parakeet Ultra** (quello consigliato da Handy): 25 lingue europee con riconoscimento
  automatico, italiano incluso. Si scarica dall'app (740 MB) e gira in locale su GPU (Metal):
  pochi secondi di parlato vengono trascritti in circa 40 ms.
- **Più lingue**: puoi parlare in qualsiasi lingua selezionata e passare da una all'altra.
- Cronologia delle trascrizioni, scelta del microfono, suoni, avvio al login.

Le scorciatoie si possono cambiare in **Impostazioni › Scorciatoie**.

> Consiglio: in **Impostazioni di Sistema › Tastiera** imposta *"Premi il tasto 🌐 per"* su
> *"Non fare nulla"*, altrimenti `fn` apre anche il pannello emoji.

## Requisiti

- macOS 26 o successivo, Mac con Apple Silicon
- Permessi: **Microfono** e **Accessibilità** (per la scorciatoia globale e per incollare)

## Compilare e installare

```bash
brew install xcodegen cmake ninja
git submodule update --init --recursive
./scripts/install.sh          # compila e installa in /Applications/Flusso.app
```

`scripts/build-engine.sh` compila [transcribe.cpp](https://github.com/handy-computer/transcribe.cpp)
(il motore di Handy, incluso come submodule in `Vendor/`) come libreria statica con Metal.
Il progetto Xcode viene generato da `project.yml` con XcodeGen.

## Struttura

| Percorso | Contenuto |
| --- | --- |
| `App/Sources/App` | Avvio, orchestrazione (`AppController`), finestra principale |
| `App/Sources/Audio` | Cattura microfono a 16 kHz con ring buffer e pre-roll |
| `App/Sources/Input` | Scorciatoie globali (`CGEventTap` su un thread dedicato) |
| `App/Sources/Engine` | Wrapper Swift di transcribe.cpp |
| `App/Sources/Output` | Rilevamento del campo attivo (Accessibility) e incolla |
| `App/Sources/Core` | Impostazioni, modelli, cronologia, permessi |
| `App/Sources/UI` | Widget di registrazione, finestra principale, onboarding |

## Licenze

Flusso usa transcribe.cpp (MIT) e i modelli Parakeet pubblicati da
[handy-computer](https://huggingface.co/handy-computer) (CC-BY-4.0).
