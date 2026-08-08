# Privacy en gegevensstromen — WhisperClip

*Laatst technisch bijgewerkt: 1 augustus 2026 · werkdocument voor Personal en de af te leiden Public-build*

WhisperClip zet audio lokaal om in tekst. Er is geen backend van de maker en de
app bevat geen Firebase, analytics, advertenties, tracking of telemetry. Na de
eenmalige modeldownload werkt de lokale kern zonder internet.

Dit document onderscheidt twee producten:

- **WhisperClip Personal** is Niels' persoonlijke build en bevat de optionele
  PLAUD-koppeling.
- **WhisperClip Public** wordt pas na de Personal-review afgeleid en mag
  technisch geen PLAUD-code, tekst, instelling, credential of netwerkroute
  bevatten. Dit wordt vóór distributie op de uiteindelijke binary gecontroleerd.

## 1. Verwerking op het toestel

| Functie | Verwerking | Uitgaand verkeer |
|---|---|---|
| iPhone-opname en Notulist | Parakeet TDT 0.6b v3 via CoreML/FluidAudio | Geen |
| Pauzeren | De microfooncapture stopt; gepauzeerde audio wordt niet vastgelegd | Geen |
| Tekstopschoning en woordenlijst | In WhisperClip zelf | Geen |
| Geschiedenis, notities en zoeken | Lokale SQLite-database | Geen |
| AI-verwerking | Alleen tekst, rechtstreeks naar de gekozen provider | Alleen na een expliciete AI-opdracht |
| iCloud-sync | Apple CloudKit en iCloud key-value store | Alleen wanneer de gebruiker iCloud-sync inschakelt |
| PLAUD-import | Alleen Personal; tijdelijke download en lokale transcriptie | Alleen na eigen PLAUD-configuratie en syncactie |

Een Notulist-vergadering blijft één doorlopende transcriptie. WhisperClip voert
geen sprekerherkenning uit, maakt geen speakerlabels en koppelt uitspraken niet
automatisch aan deelnemers. Deelnemers zijn uitsluitend ontvangers van het
voorbereide e-mailverslag.

## 2. Lokaal bewaarde gegevens

- Transcripties, titels, bron, duur, taalmetadata en notitiekoppelingen staan in
  de lokale database in de appcontainer.
- Tijdens een gewone opname of Notulist-sessie schrijft WhisperClip de audio
  naar één beschermd tijdelijk bestand in de eigen appcontainer. Dit voorkomt
  dat het werkgeheugen met de opnameduur blijft groeien. Het bestand wordt na
  transcriptie of annuleren verwijderd. Bij een crash probeert WhisperClip het
  bestand bij de volgende start te transcriberen en in Geschiedenis te bewaren;
  pas na een geslaagde database-write wordt het op basis van WhisperClips eigen
  bestandsprefix verwijderd.
- AI-resultaten en een lokaal gebruiks-/kostenlog staan in lokale appbestanden.
  Kosten zijn schattingen; de providerfactuur blijft leidend.
- Instellingen, woordenlijst, vaste deelnemers en synchronisatiecheckpoints staan
  in de lokale appvoorkeuren.
- API-sleutels voor Anthropic, OpenAI en Google Gemini staan als drie
  afzonderlijke items in Apple's Keychain met
  `AfterFirstUnlockThisDeviceOnly`. Ze worden niet via iCloud gesynchroniseerd,
  niet in bestanden of `UserDefaults` geschreven en niet gelogd.
- PLAUD-wachtwoord of -token staat alleen in Personal in een afzonderlijk
  Keychain-item. Het zichtbare e-mailadres en syncstatus staan in de lokale
  voorkeuren.
- Het lokale Parakeet-model blijft op het toestel totdat de app of modelcache
  wordt verwijderd.

Een zichtbare naamswijziging naar WhisperClip verandert bestaande
opslaglocaties en sleutelnamen bewust niet; zo blijven bestaande gegevens bij
een update behouden.

## 3. Netwerkverbindingen van de iPhone-app

### 3a. Modeldownload

- **Wanneer:** alleen wanneer het lokale Parakeet-model ontbreekt en de gebruiker
  de download start.
- **Waarheen:** Hugging Face-hosting die FluidAudio voor het model gebruikt,
  altijd via HTTPS.
- **Inhoud:** alleen de normale downloadaanvraag. Audio, transcripties en
  gebruikerssleutels worden niet meegestuurd.

Na een geldige download blijft de lokale transcriptiekern offline bruikbaar.

### 3b. Externe AI met eigen sleutel

WhisperClip ondersteunt drie rechtstreeks aangeroepen diensten:

| Aanbieder | API-routes |
|---|---|
| Anthropic Claude | `https://api.anthropic.com/v1/messages` en `/v1/models` |
| OpenAI | `https://api.openai.com/v1/responses` en `/v1/models` |
| Google Gemini | `https://generativelanguage.googleapis.com/v1beta/models…` |

- **Wanneer:** alleen nadat de gebruiker zelf een sleutel voor die aanbieder
  opslaat en een AI-opdracht start. AI voor Notulist staat algemeen standaard
  uit en staat bovendien voor iedere vergadering opnieuw standaard uit.
- **Inhoud:** uitsluitend de gekozen transcripttekst en de instructie voor de
  gekozen AI-modus. Er wordt nooit audio of een audiobestand verzonden.
- **Authenticatie:** de eigen API-sleutel van de gebruiker gaat alleen in de
  HTTPS-header naar de gekozen provider.
- **Opslag bij OpenAI:** WhisperClip zet voor Responses API-aanvragen expliciet
  `store: false`.
- **Modellenlijst:** na een verbindingstest kan WhisperClip de beschikbare
  modellen bij de gekozen provider opvragen. Dat verzoek bevat geen transcript.
- **Voorwaarden:** verwerking en eventuele bewaartermijnen bij de aanbieder
  vallen onder het provideraccount en de voorwaarden die de gebruiker daarvoor
  zelf heeft geaccepteerd.

WhisperClip logt geen requestheaders, API-sleutels of transcriptinhoud. Er wordt
geen gedeelde sleutel of AI-proxy van de maker gebruikt.

### 3c. iCloud / CloudKit

- **Wanneer:** alleen na vrijwillige inschakeling. WhisperClip gebruikt het al
  op iOS aangemelde Apple-account en toont nooit een eigen iCloud-login.
- **Waarheen:** de private CloudKit-container
  `iCloud.nl.nielscroiset.whisperclipboard` en Apple's iCloud key-value store.
- **Inhoud:** transcripttekst en bijbehorende metadata, notities, woordenlijst
  en bewust bewaarde vaste deelnemers. Audio en API-sleutels synchroniseren niet.
- **Accountwissel:** een nieuw of gewijzigd iCloud-account vereist expliciete
  toestemming voordat lokale data wordt samengevoegd. Daarbij wordt niets lokaal
  verwijderd.

De Release-configuratie blijft uitgeschakeld totdat het CloudKit Production-
schema is uitgerold en op een distributiebouw is gecontroleerd.

### 3d. PLAUD — uitsluitend WhisperClip Personal

- **Wanneer:** alleen nadat de gebruiker zelf PLAUD-credentials instelt en een
  handmatige synchronisatie start.
- **Waarheen:** uitsluitend HTTPS-hosts onder `plaud.ai`, waaronder de VS-, EU-
  en APAC-API-hosts. Een serverredirect wordt alleen geaccepteerd wanneer die
  HTTPS gebruikt en de host `plaud.ai` of een subdomein daarvan is.
- **Inhoud:** authenticatie, opnamelijst en de gekozen opnamebestanden.
- **Lokale verwerking:** audio wordt naar een tijdelijk bestand gedownload,
  lokaal getranscribeerd en daarna verwijderd, ook via het foutpad.
- **Deduplicatie:** stabiele PLAUD-opname-id's voorkomen herimport.

Public moet deze volledige route missen; alleen een verborgen schakelaar is
niet voldoende.

### 3e. E-mailverslag

WhisperClip verstuurt zelf geen e-mail. De app opent Apple's mailcomposer, een
`mailto:`-route of het deelvenster met een vooringevuld verslag. De gebruiker
controleert het verslag en verstuurt het via de eigen mail-app en het eigen
mailaccount. Bij AI-notulen bevat de mail zowel het AI-verslag als de volledige
onbewerkte transcriptie.

## 4. iOS-permissies en systeemfuncties

| Toegang | Reden |
|---|---|
| Microfoon | Audio lokaal opnemen voor transcriptie |
| Achtergrondaudio | Een door de gebruiker gestarte opname laten doorlopen bij schermvergrendeling of tijdelijk verlaten van de app |
| Live Activity | Opnamestatus en stopbediening op vergrendelscherm/Dynamic Island |
| iCloud/CloudKit | Vrijwillige sync tussen de eigen apparaten |
| Keychain | Eigen AI-sleutels en, alleen in Personal, PLAUD-geheim veilig lokaal bewaren |

De iPhone-app vraagt geen toegang tot camera, locatie, foto's, contacten of
agenda. Nieuwe deelnemers worden alleen binnen WhisperClip ingevoerd en alleen
na de afzonderlijke keuze `Bewaren` aan de vaste deelnemers toegevoegd.

## 5. Privacy manifest en App Store-labels

Het iOS-privacymanifest vermeldt:

- geen tracking en geen trackingdomeinen;
- geen gegevensverzameling door de maker;
- required-reason gebruik van `UserDefaults` (`CA92.1`), systeem-boottijd
  (`35F9.1`) en metadata van bestanden in de appcontainer (`C617.1`) voor lokale
  appfunctionaliteit.

Het manifest is niet op zichzelf de volledige privacyverklaring. Voor
TestFlight/App Review worden de App Privacy-antwoorden opnieuw bepaald aan de
hand van de daadwerkelijk gearchiveerde **Public-binary**, inclusief de directe
AI-verwerking door de door de gebruiker gekozen derde partij.

## 6. macOS-aanvullingen

De Mac-app deelt lokale geschiedenis, notities, woordenlijst, vaste deelnemers,
AI-aanbieders en optionele iCloud-sync met de iPhone-app. Daarnaast kan de Mac:

- zelfgekozen audio-/videobestanden lokaal transcriberen;
- lokaal live ondertitelen en, waar gekozen, Apple's on-device vertaling
  gebruiken;
- via Accessibility getranscribeerde tekst in een andere app plakken;
- via Sparkle op updates controleren.

De huidige Sparkle-feed bevat nog een publicatie-placeholder en is daarom geen
releaseklare distributieroute. Voor een Mac-release moeten feed-URL,
ondertekening, notarisation en de afzonderlijke macOS-privacymanifesten opnieuw
worden geverifieerd.

## 7. Technische garanties voor deze final run

- Geen Firebase, analytics, advertenties, tracking-SDK of eigen backend.
- Geen audio naar AI, iCloud of e-mail.
- Geen API-key buiten Keychain of naar een andere bestemming dan de gekozen
  aanbieder.
- Lokale kern werkt zonder iCloud, zonder AI-key en offline nadat het model is
  gedownload.
- Transcripties worden niet automatisch verwijderd na mail; de gebruiker kiest
  na afloop bewaren of verwijderen.
- Public wordt pas vrijgegeven nadat statische en binary-scans aantonen dat
  PLAUD afwezig is uit symbolen, strings, resources, privacytekst en routes.
