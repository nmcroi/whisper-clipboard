# Privacy & gegevensstromen — Whisper Clipboard

*Laatst bijgewerkt: 14 juli 2026 · versie 2.0.0 + werkbatch juli 2026 (pauzeknop, woordenlijst-sync, notulist)*

Dit document beschrijft eerlijk en volledig wat Whisper Clipboard met gegevens
doet. Het is bedoeld zodat een IT-/security-beoordelaar de app kan goedkeuren
voor gebruik op een (beheerde) werk-Mac. Kort samengevat:

> **Alle spraakherkenning, vertaling, sprekerherkenning en het opschonen van
> tekst gebeuren 100% lokaal op je Mac. De app stuurt standaard niets naar
> internet. Er is geen telemetrie, geen analytics, geen accountsysteem en geen
> tracking.**

De enige momenten waarop de app naar buiten praat, zijn drie duidelijk
afgebakende gevallen (hieronder volledig beschreven): een *optionele* AI-functie
die je zelf aanzet, een *eenmalige* modeldownload bij het eerste gebruik, en de
*update-controle*.

---

## 1. Wat de app doet

Whisper Clipboard is een menubalk-app voor dicteren en transcriberen:

- **Dicteren** — je spraak via de microfoon lokaal omzetten naar tekst en op het
  klembord (of direct invoegen in de app waarin je werkt).
- **Bestanden transcriberen** — audio-/videobestanden die je zelf kiest lokaal
  omzetten naar tekst, optioneel met **sprekerherkenning** (diarisatie).
- **Live ondertitels** — systeemaudio (bijv. een videocall) lokaal ondertitelen,
  optioneel **naar het Nederlands vertaald**.
- **Opschonen** — optioneel stopwoordjes ("eh", "ehm") weghalen en woorden
  vervangen via je eigen woordenlijst.
- **Pauzeren** — elke opname kan gepauzeerd worden. De microfoon-tap gaat er op
  het pauzemoment onmiddellijk af: audio uit de gepauzeerde periode wordt
  nergens vastgelegd en kan dus ook nergens in een transcript belanden.
- **Notulen (private notulist)** — een gesprek lokaal opnemen en transcriberen
  en het verslag per e-mail naar de deelnemers sturen. De audio wordt nooit als
  bestand opgeslagen (samples bestaan alleen in het geheugen en worden na de
  transcriptie gewist); de deelnemerslijst wordt nergens bewaard; de mail gaat
  via het **eigen mailaccount van de gebruiker** (de Mail-app opent vooringevuld
  en de gebruiker drukt zelf op versturen — er is geen verzenddienst van de
  maker). Elk verslag bevat een vaste transparantie-uitleg met precies deze
  punten.
- **AI-modus (optioneel)** — een transcript laten samenvatten/herschrijven door
  Claude. **Dit is de enige functie die tekst naar een externe dienst stuurt en
  gebeurt alleen als jij er expliciet op klikt** (zie §3a).

### Waar draait de verwerking?

| Functie | Technologie | Waar |
|---|---|---|
| Spraak → tekst | NVIDIA **Parakeet** (CoreML) via FluidAudio, óf Apple **SpeechAnalyzer** | **Lokaal** |
| Sprekerherkenning (diarisatie) | FluidAudio (CoreML) | **Lokaal** |
| Vertalen (ondertitels → NL) | Apple **Translation**-framework | **Lokaal** (Apple on-device) |
| Stopwoorden/woordenlijst | Eigen tekstverwerking in de app | **Lokaal** |
| AI-samenvatting e.d. | Claude API (Anthropic) | **Extern, alleen op jouw verzoek** (§3a) |

---

## 2. Welke gegevens bewaart de app (lokaal)

Alles blijft op de Mac, in de map van de app onder je gebruikersaccount:

- **Transcripties/geschiedenis** — in een lokale SQLite-database (GRDB), met
  full-text-zoeken. Je kunt items verwijderen of een bewaartermijn instellen.
- **Instellingen** — sneltoets, taal, woordenlijst enz. in de standaard macOS
  `UserDefaults` van de app.
- **Claude API-key (alleen als je AI gebruikt)** — opgeslagen in de macOS
  **Keychain**, niet in een bestand of in de database.
- **Gedownloade modellen** — de CoreML-modelbestanden (zie §3b).

Er worden **geen** gegevens naar een server van de maker of van derden
gekopieerd. Transcripties en geschiedenis synchroniseren niet naar de cloud
(de voorbereide iCloud-geschiedenis-sync staat uit). De enige uitzondering is
klein en expliciet: de **woordenlijst** (alleen de eigen find → replace-regels,
géén transcripties of audio) kan via **Apple's iCloud key-value store** tussen
je eigen Mac en iPhone synchroniseren — binnen je eigen iCloud-account, zonder
server van de maker (zie §3d).

---

## 3. Alle netwerkverbindingen (uitputtend)

De app maakt uitsluitend de volgende drie soorten verbindingen. Er zijn geen
andere.

### 3a. Claude API — alléén als je een AI-modus start (opt-in)

- **Wanneer:** alleen wanneer je zelf een AI-modus uitvoert op een transcript
  (menu "AI-modus op laatste transcript…" of de AI-knop). Zet je dit nooit aan,
  dan gebeurt dit nooit.
- **Waarheen:** `https://api.anthropic.com/v1/messages` (Anthropic), over HTTPS.
- **Wat wordt verstuurd:** uitsluitend de transcript-tekst die je kiest te
  verwerken, plus de instructie van de gekozen modus. Geen audio, geen
  bestanden, geen metadata over je systeem.
- **Met welke sleutel:** je **eigen** Claude API-key, die jij invoert en die in
  de Keychain staat. Zonder key doet de functie niets.
- **Belangrijk voor IT:** dit is optioneel. Wil de organisatie geen enkele
  externe verwerking van tekst, laat de AI-functie dan simpelweg ongebruikt (er
  is geen key ingesteld → geen verkeer). De functie kan niet "per ongeluk"
  afgaan; er is altijd een expliciete actie van de gebruiker voor nodig.

### 3b. Eenmalige modeldownload bij eerste gebruik

- **Wanneer:** één keer, wanneer je een transcriptie-engine voor het eerst
  gebruikt en het model nog niet lokaal staat. Daarna nooit meer (offline
  bruikbaar).
- **Waarheen:**
  - **Parakeet** (het standaardmodel, ca. 494 MB): van **Hugging Face**
    (`https://huggingface.co/…`, via FluidAudio).
  - **Apple SpeechAnalyzer / Translation**: als je die kiest, laadt macOS de
    bijbehorende on-device taalassets via **Apple's** eigen mechanisme.
- **Wat wordt verstuurd:** een gewone download-aanvraag voor de modelbestanden.
  Er gaat geen persoonlijke data of audio mee.
- **Wil de organisatie geen downloads?** De modellen kunnen vooraf worden
  klaargezet/meegeleverd; na installatie werkt de app volledig offline.

### 3c. Update-controle (Sparkle)

- **Wanneer:** periodiek en wanneer je "Controleer op updates…" kiest.
- **Waarheen:** het appcast-bestand op **GitHub Releases**
  (`https://github.com/USER/whisper-clipboard/releases/latest/download/appcast.xml`;
  de definitieve URL wordt bij publicatie ingevuld).
- **Wat wordt verstuurd:** een gewoon HTTPS-verzoek om te kijken of er een
  nieuwere versie is. Updates worden **cryptografisch geverifieerd** (EdDSA)
  tegen een publieke sleutel in de app; een niet-ondertekende update wordt
  geweigerd. Er wordt geen identificerende informatie meegestuurd.
- **Uit te zetten:** automatische controle kan in de instellingen uit; de app
  blijft dan volledig werken.

### 3d. iCloud key-value store — alleen de woordenlijst (opt-out door iCloud uit te laten)

- **Wanneer:** wanneer je de woordenlijst bewerkt op een toestel dat met een
  iCloud-account is aangemeld én de app met het iCloud-entitlement is
  ondertekend. Zonder account of entitlement gebeurt er niets (de app werkt
  gewoon door, lokaal).
- **Waarheen:** Apple's **iCloud key-value store**, binnen het eigen
  iCloud-account van de gebruiker. Er is geen server van de maker bij betrokken.
- **Wat wordt gesynchroniseerd:** uitsluitend de find → replace-regels van de
  woordenlijst (bijv. "klot" → "Claude") als één klein JSON-object. **Geen**
  transcripties, geen audio, geen geschiedenis, geen instellingen.
- **Waarom:** zodat dezelfde correctielijst op Mac en iPhone werkt zonder hem
  twee keer bij te houden.

**Over de notulen-mail:** het versturen van een notulen-verslag is géén
netwerkverbinding van de app zelf. De app opent de Mail-app (of een
mailto-koppeling) vooringevuld; verzending gebeurt door het eigen mailprogramma
en mailaccount van de gebruiker, pas nadat die zelf op versturen drukt.

**Wat er níet gebeurt:** geen analytics, geen crash-/telemetrieverzending naar
de maker, geen advertenties, geen tracking-SDK's, geen fingerprinting, geen
account/login.

---

## 4. macOS-permissies die de app vraagt (en waarom)

De app is **niet gesandboxed** (nodig om tekst in andere apps te kunnen invoegen
en zelfgekozen mappen te bewaken) en draait met de **hardened runtime**, en is
**Developer-ID-ondertekend en door Apple genotariseerd**.

| Permissie | Waarvoor | Wanneer gevraagd |
|---|---|---|
| **Microfoon** (`NSMicrophoneUsageDescription`) | Je spraak opnemen om lokaal te dicteren. | Bij de eerste opname. |
| **Systeemaudio-opname voor ondertitels** (`NSAudioCaptureUsageDescription`) | Systeemaudio (bijv. een call) opnemen om lokaal live ondertitels te maken. | Bij het eerste gebruik van live ondertitels. |
| **Toegankelijkheid (Accessibility)** | De getranscribeerde tekst **direct invoegen** in de app waarin je werkt (simuleert plakken). Alleen nodig als je "direct invoegen" gebruikt; anders volstaat het klembord. | Bij het inschakelen van direct invoegen. Heeft geen Info.plist-tekst; macOS regelt dit via Systeeminstellingen ▸ Privacy & beveiliging ▸ Toegankelijkheid. |

Alle drie de permissies dienen uitsluitend het lokaal verwerken van audio/tekst
op de Mac zelf. Geen ervan geeft de app netwerktoegang tot je gegevens.

De app vraagt **geen** toegang tot camera, contacten, agenda, locatie, foto's of
bestanden buiten wat je zelf kiest (open-dialoog of een map die je zelf instelt
om te bewaken).

---

## 5. Voor de IT-/security-beoordelaar (samenvatting)

- **Distributie:** direct (buiten de App Store), **Developer-ID-ondertekend en
  genotariseerd** door Apple → Gatekeeper keurt de app goed; de handtekening is
  verifieerbaar met `codesign`/`spctl`.
- **Integriteit van updates:** Sparkle verifieert elke update met EdDSA tegen een
  ingebakken publieke sleutel; manipulatie onderweg wordt geweigerd.
- **Dataminimalisatie:** standaard geen uitgaand verkeer met persoonlijke data.
  De enige uitzondering (Claude API) is opt-in, met de eigen sleutel van de
  gebruiker, en stuurt alleen door de gebruiker gekozen tekst.
- **Geen persistentie buiten het toestel:** alle transcripties en instellingen
  blijven lokaal; de API-key staat in de Keychain.
- **Privacymanifest:** de app bevat een `PrivacyInfo.xcprivacy` met
  "geen tracking, geen dataverzameling" en de reden-codes voor de door macOS
  gevraagde required-reason API's (UserDefaults, bestands-timestamps, vrije
  schijfruimte, systeem-boottijd) — allemaal voor lokale werking, niet voor het
  verzamelen van gegevens.
- **Volledig offline te gebruiken:** na de eenmalige modeldownload (of
  vooraf-klaarzetten) werkt de kernfunctionaliteit zonder internet; update-
  controle en AI zijn uit te zetten/niet te gebruiken.

Vragen of wens tot verificatie? De broncode, entitlements en het
packaging-script (`v2/Packaging/build_release.sh`) zijn beschikbaar ter inzage.
