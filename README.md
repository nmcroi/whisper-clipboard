# Whisper Clipboard

Lokale transcriptie met een sneltoets. Druk op de hotkey om opname te starten, druk opnieuw om te stoppen. De transcriptie wordt direct op je klembord gezet.

## Installeren

```bash
cd "/Users/nielscroiset/Documents/Development Niels/Whisper Clipboard"
./install.sh
```

## Starten

Dubbelklik voor normaal gebruik op `Whisper Clipboard.app`. Daarmee opent het
hoofdvenster zonder Terminal.

De technische ontwikkelstart blijft beschikbaar via:

```bash
./start.command
```

De standaard sneltoets is `Control + Space`. Deze gebruikt de native macOS
Hot Key API en heeft daarom geen Toegankelijkheidstoegang nodig.

In het hoofdvenster kun je de opname starten of stoppen, de actuele status zien
en de laatste twintig transcripties openen of opnieuw kopiëren. De interface
gebruikt de NightStory-huisstijl uit
`/Users/nielscroiset/Documents/Webdesign/Start_Map/NIGHTSTORY_HUISSTIJL.md`.

Met **Importeer bestand** kun je `mp3`, `mp4`, `m4a`, `wav` en `mov` lokaal
transcriberen. De uitkomst komt net als een microfoonopname in de geschiedenis
en op het klembord. Selecteer een transcriptie en kies **Exporteer .txt** om
haar als los tekstbestand te bewaren.

Daarnaast staat een microfoon in de macOS-menubalk. Die is donker wanneer de app
klaarstaat en rood tijdens een opname. Via dit icoon kun je opnemen, het
hoofdvenster openen of de app afsluiten.

## Belangrijk op macOS

Je Mac vraagt alleen om microfoontoegang wanneer je de eerste opname start.
Whisper Clipboard heeft geen Toegankelijkheidstoegang en geen toegang tot
Terminal nodig.

Gebruik opname alleen op plekken waar dat ok is en laat mensen weten dat je opneemt als het om gesprekken met anderen gaat.

## Model en kosten

Deze versie gebruikt lokaal Whisper via `faster-whisper`. Je betaalt dus geen abonnement en je audio hoeft niet naar een externe transcriptiedienst. De eerste keer wordt het gekozen model gedownload; daarna werkt het lokaal.

In `config.toml` kun je aanpassen:

- `hotkey`: de sneltoets.
- `model`: bijvoorbeeld `tiny`, `base`, `small` of `medium`.
- `models_dir`: waar gedownloade lokale modellen worden bewaard.
- `preload_model`: laadt het model direct bij starten, zodat de eerste opname sneller klaar is.
- `language`: standaard `nl`.
- `paste_after_copy`: zet op `true` als hij ook direct in de actieve app moet plakken.
- `save_recordings`: zet op `true` als je de audio-opnames wilt bewaren.
- `history_limit`: hoeveel recente transcripties in het geschiedenisvenster blijven staan.
- `save_transcripts`: zet op `true` als je naast de geschiedenis ook losse tekstbestanden wilt bewaren.

## Open-source inspiratie

Ik heb de aanpak naast open-source projecten gelegd. Zie `RESEARCH.md` voor de notities. De korte versie: Whispering/Epicenter is het beste voorbeeld voor de UX, `whisper.cpp` is interessant voor snelle lokale Apple Silicon-transcriptie, en Buzz is een volwassen voorbeeld voor offline transcriptie en transcriptgeschiedenis.

## Later versnellen met whisper.cpp

De app heeft alvast een optionele `whisper_cpp` engine-instelling. Voor de eerste versie is `faster_whisper` het makkelijkst, maar als we maximale lokale snelheid willen kunnen we later `whisper-cli` en een ggml-model toevoegen en dit in `config.toml` zetten:

```toml
engine = "whisper_cpp"
whisper_cpp_binary = "whisper-cli"
whisper_cpp_model_path = "/pad/naar/ggml-small.bin"
```

## App opnieuw bouwen

Na codewijzigingen bouw je de zelfstandige app reproduceerbaar met:

```bash
./scripts/build_app.sh
```
