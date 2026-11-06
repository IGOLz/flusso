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
- **Dizionario**: aggiungi nomi, marchi e termini tecnici; dopo ogni dettatura le parole che
  suonano o si scrivono in modo simile vengono corrette (stesso algoritmo di Handy). Puoi anche
  indicare come il modello scrive una parola per sostituirla sempre (es. "igol punto dev" → "igol.dev").
- **Avvio istantaneo** (opzionale, Impostazioni › Microfono): il microfono resta pronto, quindi la
  registrazione parte in meno di 1 ms e include anche gli ultimi 300 ms *prima* della pressione del tasto.
- **Modello Parakeet Ultra** (quello consigliato da Handy): 25 lingue europee con riconoscimento
  automatico, italiano incluso. Si scarica dall'app (740 MB) e gira in locale su GPU (Metal):
  pochi secondi di parlato vengono trascritti in circa 40 ms.
- **Più lingue**: puoi parlare in qualsiasi lingua selezionata e passare da una all'altra.
- Cronologia delle trascrizioni, scelta del microfono, suoni, avvio al login.

Le scorciatoie si possono cambiare in **Impostazioni › Scorciatoie**.

> Consiglio: in **Impostazioni di Sistema › Tastiera** imposta *"Premi il tasto 🌐 per"* su
> *"Non fare nulla"*, altrimenti `fn` apre anche il pannello emoji.

## Requisiti

- macOS 14 Sonoma o successivo (Liquid Glass su macOS 26, aspetto standard sulle versioni precedenti)
- Apple Silicon (GPU Metal) o Intel (CPU)
- Permessi: **Microfono** e **Accessibilità** (per la scorciatoia globale e per incollare)

## Condividere l'app

```bash
./scripts/release.sh   # build universale, firmata Developer ID e notarizzata → build/release/Flusso-<versione>.dmg
```

Chi riceve il DMG lo apre, trascina Flusso in Applicazioni e lo avvia normalmente.

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
