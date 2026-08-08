# Startprompt — WhisperClip iPhone final run

We werken aan **WhisperClip** in:

`/Users/nielscroiset/Documents/Development Niels/Whisper Clipboard/v2`

Dit is de uitvoeringschat voor de grote final run. Werk doelgericht en voer
het volledige traject uit volgens `FINAL_RUN_IPHONE.md`. Lees vóór wijzigingen
volledig:

1. `FINAL_RUN_IPHONE.md`
2. `TODO.md`
3. `OBSIDIAN_PROJECT_STATUS.md`
4. `HANDOVER_2026-07-31.md`
5. `PRIVACY.md`

## Werkwijze

- Werk in één doorlopend traject, maar bouw en test technisch in kleine veilige
  stappen.
- Bouw, installeer en open WhisperClip op Niels' fysieke iPhone zodra dat voor
  een stap zinvol is. Er is blijvende toestemming voor uitsluitend deze app.
- Geen `git reset`, `git checkout`, commit of push zonder expliciete opdracht.
- Bewaar bestaande data en wijzigingen; de werkboom kan al wijzigingen bevatten.
- Geef korte voortgangsupdates, maar stel alleen vragen wanneer een ontbrekende
  keuze de architectuur of externe publicatie werkelijk blokkeert.
- GHX-design en -distributie vallen buiten deze run.

## Doel en volgorde

1. Eerst `WhisperClip Personal`: Niels' huidige iPhone-ontwerp, volledig,
   inclusief PLAUD en Claude/OpenAI/Gemini met eigen API-sleutels.
2. Volledige design-, functie-, privacy-, toegankelijkheids-, prestatie- en
   regressiecontrole.
3. Onafhankelijke review voorbereiden voor aparte Codex-chat, Fable5 en Sol;
   bevindingen daarna in één reparatieronde verwerken.
4. Pas daarna `WhisperClip Public` afleiden: zelfde kern, maar PLAUD technisch
   volledig afwezig uit binary, interface, teksten, privacy en netwerkroute.
5. Daarna TestFlight- en Apple/App Review-voorbereiding.

## Vaste productkeuzes

- Naam overal zichtbaar: `WhisperClip`, zonder spatie.
- Thuisschermnaam: `WhisperClip`, zonder emoji. De gele stip blijft onderdeel
  van woordmerk/icoon, niet van de systeemnaam.
- Geen Firebase, analytics, advertenties, tracking of eigen backend.
- Eén complete app, geen Pro-versie.
- iCloud vrijwillig; bestaande Apple-iCloud-account, nooit iCloud-inlog in app.
- AI uitsluitend met eigen API-key van gebruiker; sleutels alleen in Keychain,
  nooit syncen/loggen.
- Aanbieders: Anthropic Claude, OpenAI en Google Gemini.
- Eén globale standaardaanbieder en model, met modelkeuze per aanbieder.
- Interface: Systeem/Nederlands/English/Deutsch.
- Transcriptietaal: Automatisch/Nederlands/English/Deutsch. Persoonlijke
  standaard Nederlands; openbare standaard Automatisch. Laatste keuze onthouden
  en per opname overschrijfbaar; taal per transcript opslaan.
- iOS 17 blijft voorlopig minimum. Prestatiedoel is iPhone 12; als dat niet
  betrouwbaar kan, minimaal iPhone 15 met meetbare onderbouwing.
- `Personal` bevat PLAUD. `Public` bevat nooit PLAUD.

## Notulist: niet opnieuw ontwerpen

- Altijd één doorlopende lokale transcriptie.
- Nooit sprekerherkenning, speakerlabels, segmenten of automatische namen.
- Deelnemers zijn uitsluitend e-mailontvangers.
- Nieuwe, nog niet opgeslagen deelnemer: `Bewaren` standaard uit. Eigen
  voorgeselecteerde deelnemer en vaste deelnemer: geen Bewaren-schakelaar.
- AI algemeen standaard uit én per vergadering opnieuw standaard uit.
- Alleen tekst naar AI, nooit audio.
- Een actie mag alleen aan een persoon worden gekoppeld wanneer diens naam
  letterlijk is genoemd; anders exact: `Eigenaar: niet duidelijk genoemd.`
- Bij AI-notulen mail altijd AI-verslag plus volledige onbewerkte transcriptie.
- Notulist-transcript niet automatisch verwijderen na mail; gebruiker kiest
  na afloop bewaren of verwijderen.
- Voorlopige NL-tekst voor aanwezigen staat in `FINAL_RUN_IPHONE.md`. Vertaal
  deze naar EN/DE. De gebruiker levert later zes definitieve voice-overs aan
  (NL/EN/DE, elk zonder/met AI); dat blokkeert de run niet.

## Designregels

- Geel = aanklikbare primaire actie.
- Wit = titel/hoofdinhoud.
- Grijs = toelichting, status of opgeslagen/invoerwaarde.
- Gelijke acties hebben identieke hoogte, vorm, typografie en states.
- Consistente kaarten, marges, pictogramruimte, koppen en fout-/lege staten.
- Audit alle iPhone-schermen, niet alleen Instellingen.

## Testmateriaal dat Niels later kan leveren

- NL/EN/DE korte en lange audio, gemengde taal, rumoer/stilte, lange opname.
- Notulist-scenario's, testmail, nieuwe PLAUD-opname, iPhone–Mac iCloud-test.
- OpenAI- en Gemini-key worden uitsluitend door Niels zelf in de app ingevoerd.
- iPhone 12 en iPhone 15 fysiek of via testers voor prestatiemetingen.

Begin met Poort 0 uit `FINAL_RUN_IPHONE.md`: veilige uitgangspositie,
reproduceerbare Personal-build en technische inventarisatie. Voer daarna de
poorten in volgorde uit en houd het plan actueel.
