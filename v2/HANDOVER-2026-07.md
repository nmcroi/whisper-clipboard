# Handover — werkbatch juli 2026 (branch `claude/work-from-france-mg34bf`)

Alles uit het prioriteitendocument "WhisperClip — Technisch document voor
Claude Code" (vakantie Frankrijk, juli 2026) is gebouwd, gecommit en door CI
geverifieerd (CoreTests op Linux + Mac-build-en-tests + iOS-Simulator-build bij
elke push). Dit document is de blijvende samenvatting: wat er is gebouwd, waar
de code staat, welke keuzes zijn gemaakt, wat jij nog moet doen, en de backlog.

---

## 1. Wat er is gebouwd

### Prio 1.1 — Pauzeknop (Mac + iOS)
**Gedrag:** pauze haalt de microfoon-tap er *onmiddellijk* af — niets van ná de
druk kan de opname in (het "buffer loopt nog leeg"-probleem raakt alleen audio
van vóór het pauzemoment, en die hoort bij de opname). Hervatten installeert
dezelfde tap opnieuw op dezelfde engine-sessie; de samples plakken automatisch
aan elkaar: **één opname, één transcript**. De klok telt alleen echte
opnametijd (dit fixte ook een oude iOS-bug: de teller liep door tijdens een
telefoon-onderbreking).
- Kern: `Packages/Core/Sources/Core/Model/RecordingStopwatch.swift` (puur, getest).
- Mac: `WhisperClipboard/Audio/AudioEngine.swift` (`pause()`/`resume()`),
  `Dictation/DictationController.swift` (nieuwe fase `.paused`),
  `UI/HUD/RecordingHUDView.swift` (pauzeknop + "Gepauzeerd"-staat).
- iOS: `WhisperClipboardiOS/Record/IOSAudioEngine.swift` — de bestaande
  onderbrekings-pauze (telefoontje/Siri) is veralgemeend naar
  `PauseReason { user, interruption }`. Een **gebruikers**pauze wordt nooit
  automatisch hervat door het einde van een onderbreking.
  UI: `Record/RecordView.swift`, `Notes/NoteDetailiOSView.swift`,
  gedeelde knop `Shared/PauseToggleButton.swift`; Live Activity toont de
  pauzestand (`setPaused`).

### Prio 1.2 — Auto-clear laatste transcriptie na 5 minuten (iOS)
Het resultaat op het Opnemen-tabblad wordt gewist zodra de app in beeld komt
(scenePhase → `.active`, of terugkeer naar het tabblad) én het ouder is dan
vijf minuten. Geen achtergrond-timer.
- Beleid: `Core/Model/TransientResultPolicy.swift` (getest, incl. klok-terugloop).
- Wiring: `RecordController.clearResultIfExpired()` + scenePhase in `RecordView`.
- Mac: bewust niets — de HUD verdwijnt al vanzelf; er is geen blijvend veld.

### Prio 1.3 — Woordenlijst op iPhone + iCloud-sync met de Mac
- iOS heeft nu dezelfde woordenlijst als de Mac: Instellingen ▸ **Woordenlijst**
  (`WhisperClipboardiOS/App/DictionaryiOSView.swift`), lokaal bewaard in
  UserDefaults (`ios.replacements`) en toegepast op elke transcriptie
  (`RecordController` geeft `app.replacements` door aan `TextProcessor`).
- Sync via **iCloud key-value store** — bewust los van de (uitstaande)
  CKSyncEngine-geschiedenis-sync; geen CloudKit-schema nodig:
  - Pure conflictlogica: `Core/TextProcessing/ReplacementSyncLogic.swift` —
    last-writer-wins op de hele lijst; bij gelijke timestamps wint de langste
    lijst; alleen strikt-nieuwere remote payloads worden toegepast (geen
    sync-lus). Volledig getest, ook lege-lijst-propagatie.
  - OS-koppelstuk: `Packages/Shared/.../ReplacementsCloudSync.swift` —
    gedebounced publiceren (1 s typrust), eigen timestamp-administratie,
    degradeert stil zonder entitlement/account.
  - Entitlement `com.apple.developer.ubiquity-kvstore-identifier` toegevoegd
    aan `WhisperClipboardiOS.entitlements` en `WhisperClipboard-iCloud.entitlements`
    — **zelfde identifier op beide platforms** (vereist om één store te delen).
  - Consumenten: `AppModel.replacements` (iOS), `AppEnvironment` (Mac, schrijft
    binnenkomende lijsten in `settings.replacements`).

### Prio 1.4 — Icoon-consistentie opnameknop (iOS)
Het microfoon-glyph is uit `NewNoteRecordButton` (Notities-lijst); alle
opnameknoppen zijn nu ring + afgerond vierkant, zoals het app-icoon.

### Prio 1.5 — Undo bij verwijderen notitie (iOS)
Swipe-verwijderen verbergt de rij direct en toont vijf seconden een toast
"Notitie verwijderd — Ongedaan maken" (patroon Apple Mail/Notities); de échte
DB-verwijdering gebeurt pas daarna (of direct bij het verlaten van scherm/app).
Sneuvelt de app binnen het venster, dan bestaat de notitie nog — veilige
faalmodus. De bevestigingsdialoog in de detailweergave is bewust ongewijzigd.
- Component: `WhisperClipboardiOS/Shared/UndoToast.swift` (herbruikbaar).
- Logica: `Notes/NotesListiOSView.swift` (`requestDelete`/`undoDelete`/
  `commitPendingDelete`).

### Prio 2 — Private notulist (iOS én Mac)
**Proces (conform het document):** deelnemers invoeren (naam + e-mail, of
anoniem) → lokale opname met pauze → lokale transcriptie → audio weg (bestond
nooit als bestand; samples worden na de transcriptie uit het geheugen gewist)
→ verslag in de Geschiedenis (bron "Notulen") → vooringevulde mail naar alle
adressen, **iedereen exact dezelfde tekst**, met de vaste transparantie-uitleg
(zes punten). Versturen gebeurt via het eigen mailaccount — er is bewust geen
externe verzenddienst (privacy-principe); jij drukt zelf op versturen.
- Gedeelde kern: `Core/Meeting/MeetingMinutes.swift` — `MeetingParticipant`
  (validatie, anoniem), `MeetingMinutesComposer` (onderwerp, ontvangers,
  berichttekst, `transparencyText`, mailto-fallback). Volledig getest.
  **De exacte formulering van de transparantietekst staat dáár — even nalezen.**
- iOS: `WhisperClipboardiOS/Meeting/` — `MeetingSetupView`, `MeetingRecordView`
  (auto-start, pauzeknop, terugknop uit tijdens opname), `MailComposeView`
  (MFMailCompose → mailto → deelvenster). Ingang: knop "Notulen" op het
  Opnemen-tabblad.
- Mac: `WhisperClipboard/Meeting/` — `MeetingController` (eigen `AudioEngine`,
  gedeelde ParakeetEngine, géén klembord/invoegen/HUD) en `MeetingSheet`
  (deelnemers → opname → versturen via NSSharingService/mailto/klembord).
  Ingang: kaart "Notulen" op Home. Wederzijdse uitsluiting met dicteren,
  import, ondertitels en automatiseringen via de bestaande busy-guards in
  `AppEnvironment`.

### Fundament — CI (`.github/workflows/ci.yml`)
Bij elke push: **CoreTests op een Linux-runner** (goedkoop en snel — alle
nieuwe pure logica staat bewust in `Packages/Core` zodat hij hier draait),
plus **Mac-build + volledige testsuite** en een **iOS-Simulator-build** op een
`macos-26`-runner (XcodeGen → xcodebuild, geen signing). De E2E-smoketests
(`WC_E2E=1`) blijven handmatig. `xcodebuild -quiet` zodat compileerfouten
altijd zichtbaar zijn in het log.

---

## 2. Belangrijke ontwerpkeuzes (kort)

1. **Pauze = tap eraf, sessie blijft leven.** Simpelste correcte model: geen
   segmenten-administratie nodig, stitching is impliciet, en de belofte
   "gepauzeerde stukken bestaan nergens" is letterlijk waar op audio-niveau.
2. **Woordenlijst-sync via iCloud KV-store, niet via CKSyncEngine.** Geen
   schema/portal-afhankelijkheid, geen samenhang met de uitstaande
   geschiedenis-sync, en `NSUbiquitousKeyValueStore` kan — anders dan
   `CKContainer` — niet crashen op een ontbrekend entitlement.
3. **Notulen-mail via het eigen mailaccount.** Écht automatisch versturen kan
   alleen met een externe maildienst en dat botst met het kernprincipe van de
   app. De composer opent vooringevuld; de gebruiker verstuurt.
4. **Undo = uitgesteld verwijderen**, niet terugzetten: een re-insert zou
   moeten vechten met sort-keys en (toekomstige) sync-emissies; uitstellen is
   triviaal correct en faalt veilig.
5. **Alle nieuwe logica in Core** (stopwatch, expiry, sync-conflicten,
   mail-compositie) zodat de Linux-CI hem test zonder macOS-runner.

## 3. Wat jij nog moet doen (kan niet zonder jou)

**Eenmalig in de Developer-portal** (stappen staan ook in
`Packaging/RELEASING.md`):
- iCloud **key-value storage** aanzetten op beide App IDs
  (`nl.nielscroiset.whisperclipboard` en `…​.ios`) + profiles verversen.
  Zonder dit synct de woordenlijst stil niet (geen crash).

**Handmatige tests op echte hardware:**
1. Mac-pauze: hervatten na een lange pauze; hervatten na wisselen van
   audio-input (AirPods in/uit) — mislukt hervatten rondt netjes af.
2. iOS-pauze: telefoontje tijdens een handmatige pauze (mag niet vanzelf
   hervatten); pauzeren en app naar de achtergrond.
3. Live Activity: pauzeweergave op lockscreen/Dynamic Island.
4. Woordenlijst-sync Mac ↔ iPhone: signed builds mét het nieuwe entitlement,
   zelfde iCloud-account; bewerking verschijnt binnen ± een minuut op het
   andere toestel.
5. Notulist (beide platforms): mail-composer mét en zonder geconfigureerd
   mailaccount; lang transcript via de mailto-fallback (mailto-URL's hebben
   lengtelimieten — dan is er het deelvenster/klembord-vangnet).
6. Undo-toast: voelt 5 seconden goed; VoiceOver kan erbij.
7. Transparantietekst nalezen: `Core/Meeting/MeetingMinutes.swift`
   (`transparencyText`) — formulering is van Claude, gebaseerd op jouw zes
   punten.
8. Auto-clear: transcriptie maken, >5 min wachten, app naar voren halen.

## 4. Backlog (bewust niet in deze batch)

- **iCloud-geschiedenis-sync afmaken** (stond al open van vóór de vakantie):
  CloudKit Production-schema uitrollen, een betrouwbare *binary*-entitlement-
  check op iOS (de huidige leest het provisioning profile — oorzaak van de
  eerdere launch-crash), toggle weer standaard aan, en daarna notities +
  AI-resultaten mee-syncen (nu synct alleen het `Transcript`-recordtype, en
  alles staat uit).
- **Prio 3 uit het document:** vertaal-ondertiteling in blokken (10–15 s) en de
  gesprek-modus met gespiegeld scherm. Open punt daarbij blijft de keuze
  on-device-vertaling (minder taaldekking) vs. het loslaten van het
  lokaal-principe voor die modus.
- Klein: `formatElapsed`/opnameknop-views zijn per scherm licht gedupliceerd
  (bewust — samenvoegen koppelt schermen aan elkaar); `MeetingRecordView` (iOS)
  heeft geen stop-on-disappear (bewust — zie commit-historie voor waarom).

## 5. Verificatiestand bij oplevering

- Branch: `claude/work-from-france-mg34bf`, 17 commits bovenop `main`.
- CI groen op elke relevante run; de laatste run dekt de volledige stapel.
- Testsuite uitgebreid met: `RecordingStopwatchTests`,
  `TransientResultPolicyTests`, `ReplacementSyncLogicTests`,
  `MeetingMinutesTests` (alle in `Packages/Core/Tests/CoreTests`).
- Een code-review over de hele diff vond geen correctness-bugs; de twee
  gevonden verbeterpunten (debounce, CI-logzichtbaarheid) zijn verwerkt.
