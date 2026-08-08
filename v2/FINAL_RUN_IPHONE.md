# WhisperClip iPhone — masterplan final run

Bijgewerkt: 1 augustus 2026

## Doel en harde volgorde

Eerst wordt `WhisperClip Personal` in Niels' huidige ontwerp volledig afgemaakt.
Deze versie bevat PLAUD en alle AI-aanbieders. Daarna volgen onafhankelijke
controles door een aparte Codex-chat, Fable5 en Sol. Bevindingen worden in één
reparatieronde verwerkt. Pas daarna wordt uit dezelfde code een openbare
`WhisperClip Public`-configuratie zonder PLAUD gemaakt en gereedgemaakt voor
TestFlight en uiteindelijk App Review. Een GHX-designvariant valt volledig
buiten deze run.

De run wordt als één doorlopend traject uitgevoerd. Alleen externe blokkades
(ontbrekend testmateriaal, accounttoegang, fysieke toesteltest of een expliciete
productbeslissing) mogen hem onderbreken.

## Vastgestelde productkeuzes

- Appnaam overal zichtbaar als `WhisperClip`, zonder spatie.
- Thuisschermnaam zonder emoji; de gele stip blijft onderdeel van de visuele
  identiteit in woordmerk/icoon.
- Geen Firebase, analytics, advertenties, tracking of eigen backend.
- Eén complete app, geen kunstmatige Pro-versie.
- AI uitsluitend BYOK: Claude, OpenAI en Google Gemini.
- API-sleutels alleen in Keychain, per aanbieder, nooit via iCloud.
- Eén standaard-AI-aanbieder en model; model kan per aanbieder worden gekozen.
- Notulist-AI blijft dubbel opt-in en verstuurt nooit audio.
- Interface: Systeem, Nederlands, English, Deutsch.
- Transcriptietaal: Automatisch, Nederlands, English, Deutsch.
- Persoonlijke standaard transcriptietaal: Nederlands. Openbare standaard:
  Automatisch. Laatste keuze wordt onthouden en per opname overschrijfbaar.
- Notulist-transcript wordt niet automatisch na mail verwijderd; de gebruiker
  kiest na afloop bewaren of verwijderen.
- iOS 17 blijft voorlopig het softwareminimum. Prestatiedoel: volledige werking
  vanaf iPhone 12; als dat aantoonbaar niet betrouwbaar kan, wordt iPhone 15 de
  minimale ondersteunde hardware met een duidelijke technische onderbouwing.
- `Personal` bevat PLAUD; `Public` compileert zonder PLAUD-code, teksten,
  credentials en netwerkroute.

## Releasepoorten

### Poort 0 — veilige uitgangspositie

- Werkboom en bestaande wijzigingen inventariseren zonder reset/checkout.
- Huidige werkende Personal-build reproduceerbaar bouwen.
- Bestaande lokale geschiedenis, instellingen, Keychain en iCloud-schema's
  documenteren.
- Een herstelbare bronmomentopname maken na expliciete toestemming voor de
  daarvoor gekozen git-handeling; zonder toestemming uitsluitend niet-
  destructieve patch-/diffback-up gebruiken.
- De voorlopige Notulist-tekst in NL/EN/DE opnemen. Definitieve tekst en
  voice-overbestanden mogen later zonder blokkade worden vervangen.

### Poort 1 — architectuur en twee configuraties

- Gedeelde kern behouden voor Personal en Public.
- Compile-time featureconfiguratie invoeren voor PLAUD, zonder verspreide
  losse controles in schermcode.
- Controleren dat Public werkelijk geen PLAUD-symbolen, URL's, credentials,
  instellingen of privacyverwijzingen bevat.
- Migraties toevoegen zodat bestaande Personal-data behouden blijft.
- Versie- en buildnummerstrategie vastleggen.

### Poort 2 — één consistent designsysteem

- Alle schermen inventariseren: Opnemen, Notulen, Notities, Geschiedenis,
  detailpagina's, AI, Instellingen, modeldownload, lege toestanden, fouten,
  sheets, mail en PLAUD.
- Een vaste visuele grammatica afdwingen:
  - geel = primaire of aanklikbare actie;
  - wit = titel/hoofdinhoud;
  - grijs = toelichting, status of opgeslagen waarde;
  - identieke acties krijgen identieke hoogte, vorm, typografie en states;
  - vaste titelgroottes, kaartkleuren, marges, iconframes en scheidingsregels;
  - geen onnodige subpagina's of dubbele koppen.
- Licht, donker en systeemthema nalopen.
- Kleine en grote iPhones, Dynamic Type, liggend waar relevant, toetsenbord,
  veilige gebieden en lange vertalingen testen.
- VoiceOver-labels, focusvolgorde, contrast en tikdoelen controleren.
- Visuele screenshots per hoofdscherm bewaren voor de onafhankelijke review.

### Poort 3 — lokalisatie

- String Catalog invoeren en alle zichtbare hard-coded teksten migreren.
- Volledige Nederlandse, Engelse en Duitse vertaling van interface,
  foutmeldingen, privacyuitleg, e-mails, AI-toestemming en VoiceOver.
- Systeemtaal volgen, plus in-app overschrijving Systeem/NL/EN/DE.
- Getallen, valuta, datum, tijd en meervoud correct lokaliseren.
- Geen tekstafbreking of te kleine automatische schaal in Duits testen.
- App Store-metadata later in dezelfde drie talen opleveren.

### Poort 4 — transcriptietaal en lokale transcriptie

- Automatisch/NL/EN/DE als afzonderlijke instelling bouwen.
- Snelle keuze vóór iedere gewone opname en Notulist-opname aanbieden zonder
  het startscherm druk te maken.
- Laatste keuze onthouden en taalmetadata per transcript bewaren.
- Automatische detectie met korte, lange en gemengde audio testen.
- Vaste taal als hint/constraint gebruiken waar de engine dit betrouwbaar
  ondersteunt; anders transparant documenteren dat het een voorkeurs-/metadata-
  keuze is.
- Eén doorlopende Notulist-transcriptie garanderen, zonder speakerlabels,
  diarization of automatische namen.
- Modeldownload, hervatten, onvoldoende opslag, offlinegebruik, onderbrekingen,
  pauzeren en tijdelijke audioverwijdering testen.
- Snelheid, geheugen, thermiek en nauwkeurigheid meten op iPhone 12 en 15.

### Poort 5 — Claude, OpenAI en Gemini

- Gemeenschappelijk providerprotocol bouwen voor tekstverwerking, streaming,
  foutmapping, annuleren, retries en gebruiksregistratie.
- Per provider: eigen Keychain-item, invoeren, vervangen, verwijderen en
  verbinding testen.
- Modellen na geldige key bij de provider opvragen waar mogelijk; veilige
  ingebouwde fallbacklijst en aanbevolen standaard behouden.
- Eén globale standaardprovider/model, zichtbaar bij elke AI-opdracht.
- Bestaande AI-modi providerneutraal maken.
- Token- en kostenregistratie per provider/model; duidelijk aangeven dat dit
  schattingen zijn en providerfacturen leidend blijven.
- Lange transcripties gecontroleerd chunken, onderdelen samenvoegen en op
  verlies/dubbelingen testen.
- Time-outs, rate limits, ongeldige key, onvoldoende tegoed, offline, annuleren
  en retry volledig afhandelen.
- Nooit audio, API-key of onnodige metadata versturen of loggen.
- AI-output toetsen op verzonnen feiten, namen, besluiten en eigenaren.

### Poort 6 — Notulist definitief

- Goedgekeurde aanwezigen-uitleg zichtbaar én als voice-over aanbieden.
- Voice-over nooit automatisch starten en nooit een opname starten.
- Basisuitleg zonder AI; afzonderlijk optioneel AI-fragment alleen wanneer AI
  voor die vergadering werkelijk aanstaat.
- Deelnemersroute testen: eigen ontvanger, nieuwe ontvanger, vaste ontvanger,
  verwijderen met kruisje, Bewaren standaard uit en geen ontvangers.
- Dubbele AI-toestemming behouden.
- Bij AI-mail zowel AI-notulen als volledige onbewerkte transcriptie opnemen.
- Actie-eigenaar uitsluitend bij letterlijk genoemde naam; anders exact de
  gelokaliseerde variant van `Eigenaar: niet duidelijk genoemd.`
- Mail sent/saved/cancelled/failed en mailto-/deelvensterfallback testen.
- Na afloop duidelijke keuze bewaren/verwijderen; nooit automatisch wissen op
  basis van een onbetrouwbaar mailsignaal.

### Poort 7 — bestaande functies en gegevens

- Opnemen: start, pauze, hervat, stop, interruptie, achtergrond, Live Activity,
  lege opname, lange opname en crashherstel.
- Notities: maken, aanvullen, hernoemen, koppelen, verwijderen en samenvatten.
- Geschiedenis: zoeken, filters, sorteren, titels, kopiëren, delen, Markdown,
  verwijderen en lege/fouttoestanden.
- Woordenlijst en vaste deelnemers lokaal en via iCloud.
- iCloud opt-in, accountwissel, eerste merge, offline wijzigingen, conflicten,
  duplicaten, verwijderingen en herstel.
- PLAUD Personal: credentials, test, periode, ophalen, stoppen, retry,
  deduplicatie, correcte titel/datum, tijdelijke audio verwijderen en iCloud
  naar Mac.
- Update/migratie vanaf de huidige op de iPhone geïnstalleerde build zonder
  verlies van geschiedenis, notities, deelnemers of woordenlijst.

### Poort 8 — automatische kwaliteit

- Core-, Shared-, Mac- en iOS-tests groen.
- Nieuwe unit-tests voor providers, modellen, lokalisatie, taalmetadata,
  Notulist, migraties, featureflags, iCloud-conflicten en PLAUD-deduplicatie.
- Integratietests met gesimuleerde providerresponses en netwerkfouten.
- UI-smoketests voor alle hoofdroutes en drie talen.
- Build warnings inventariseren en alle releasekritieke concurrency-, privacy-
  en lifecyclewaarschuwingen oplossen.
- Release-build, archive, codesign, entitlements en privacymanifest valideren.

### Poort 9 — fysieke regressieronde

- Schone installatie én update over bestaande app testen.
- Volledige matrix op Niels' iPhone uitvoeren met aangeleverd materiaal.
- iPhone ↔ Mac iCloud-routes controleren.
- Offline, vliegtuigstand, slechte verbinding, weinig opslag, schermvergrendeling,
  inkomend gesprek, audio-interruptie en geforceerd afsluiten testen.
- Batterij, temperatuur, geheugen en transcriptiesnelheid vastleggen.
- iPhone 12 en iPhone 15 fysiek of representatief beschikbaar maken; simulator
  alleen geldt niet als prestatiebewijs.

### Poort 10 — onafhankelijke review en reparatie

- Een aparte Codex-chat krijgt een schone reviewbrief zonder aannames uit deze
  bouwchat.
- Fable5 en Sol krijgen dezelfde functionele, visuele, privacy- en Apple-
  checklist.
- Bevindingen samenvoegen, duplicaten verwijderen en prioriteren op blokkade,
  gegevensverlies, privacy, toegankelijkheid en cosmetiek.
- Eén reparatieronde uitvoeren en alle relevante tests herhalen.

### Poort 11 — Public zonder PLAUD

- Public-build genereren uit dezelfde geteste kern.
- Bewijzen dat PLAUD niet in binary, UI, strings, privacytekst of netwerkverkeer
  aanwezig is.
- Zonder iCloud, zonder AI-key en offline moet de lokale kern volledig werken.
- Public-onboarding, privacykeuzes en ondersteuningsinformatie nalopen.
- Definitief verdienmodel kiezen vóór App Store-metadata en aankoopconfiguratie.

### Poort 12 — TestFlight en Apple

- Appnaam in App Store Connect verifiëren en merk-/icooncontrole afronden.
- Privacyverklaring, support-URL en productpagina publiceren.
- App Privacy-labels invullen op basis van de Public-binary.
- PrivacyInfo.xcprivacy en required-reason API's van app én dependencies auditen.
- Microfoontoestemming, iCloud, Keychain, netwerkproviders en modeldownload
  helder beschrijven.
- Nederlandse, Engelse en Duitse metadata en screenshots maken.
- Betaomschrijving, testinstructies, feedbackadres en reviewinformatie invullen.
- Eerst interne TestFlight, daarna externe Beta App Review en testgroep.
- Alleen na opgeloste TestFlight-bevindingen indienen voor App Review.

## Aanleverlijst voor Niels

### Voor de bouwrun

- De Nederlandse, Engelse en Duitse definitieve voice-overbestanden mogen
  tijdens of na de grote bouwrun worden aangeleverd; ze blokkeren de start niet.
- Per taal twee volledige opnames: zonder AI en met AI.
- Voice-overbestanden als onbewerkte WAV of M4A, zonder muziek, galm of ruis;
  vóór en na de stem circa 0,25 seconde stilte.
- OpenAI- en Gemini-API-key beschikbaar hebben om uitsluitend zelf in de app in
  te voeren. Sleutels nooit in chat of document plaatsen.
- Toegang tot het bestaande Claude-account/key op de iPhone.
- Bevestigen welke iPhone 12 en iPhone 15 fysiek voor prestatietests beschikbaar
  zijn; anders een externe tester met zo'n toestel regelen.

### Testaudio

- NL kort: 20–30 seconden natuurlijk spreken.
- NL lang: minimaal 10 minuten, met pauzes, cijfers, namen en correcties.
- EN kort en lang: 30 seconden en minimaal 5 minuten.
- DE kort en lang: 30 seconden en minimaal 5 minuten.
- Gemengde taal: circa 2 minuten met duidelijke taalwissels.
- Stille/zeer korte opname en opname met achtergrondgeluid.
- Eén lange opname van minimaal 45–60 minuten voor geheugen en thermiek.

### Notulist-scenario's

- Vergadering met twee of meer e-mailontvangers.
- Vergadering zonder ontvangers.
- Nieuwe deelnemer die wel en niet wordt bewaard.
- Actie met letterlijk genoemde eigenaar en termijn.
- Actie zonder genoemde eigenaar en zonder termijn.
- Vergadering met pauze en hervatten.
- Vergadering met AI uit en met AI dubbel aangezet.
- Testmail die mag worden verstuurd, plus annuleren en concept bewaren.

### Sync en import

- Mac met hetzelfde iCloud-account bereikbaar.
- Eén nieuwe gewone iPhone-opname voor iCloud iPhone → Mac.
- Eén nieuw Mac-dictaat voor iCloud Mac → iPhone.
- Eén nieuwe PLAUD-opname die nog nooit door WhisperClip is opgehaald.
- Toestemming om tijdens de test een testitem op beide apparaten te wijzigen en
  te verwijderen.

## Voorlopige Notulist-uitleg voor de grote run

Deze tekst mag nu in de app worden opgenomen en naar Engels en Duits worden
vertaald. Hij is nadrukkelijk nog niet definitief. Wanneer Niels tijdens het
inspreken verbeteringen aanbrengt, worden de geschreven tekst en vertalingen
later gelijkgetrokken met de definitieve opnames. De productnaam wordt wel
consequent geschreven als `WhisperClip` zonder spatie.

### Zonder AI

> Dit is de WhisperClip Notulist. De app helpt vergaderingen notuleren door het
> gesproken Nederlandse gesprek lokaal op deze zichtbare telefoon te
> transcriberen.
>
> Wil iemand iets buiten de notulen bespreken, dan wordt de opname gepauzeerd.
> Wat tijdens die pauze wordt gezegd, wordt niet opgenomen en komt dus niet in
> de transcriptie.
>
> Aan het einde van de vergadering wordt de transcriptie afgerond. De
> geluidsopname wordt daarna van de telefoon verwijderd. Vervolgens wordt een
> e-mail voorbereid voor iedereen die voor deze vergadering een e-mailadres
> heeft opgegeven; iedereen ontvangt hetzelfde verslag nadat de gebruiker de
> e-mail heeft verstuurd.
>
> De notulist verwerkt alleen geluid. Beschrijf daarom kort wat op een scherm of
> whiteboard gebeurt en spel bijzondere namen of termen. Een lokaal
> transcriptiemodel kan woorden verkeerd of fonetisch uitschrijven, maar zulke
> fouten zijn bij het nalezen meestal uit de context te herstellen.
>
> Nergens tijdens dit proces wordt AI gebruikt.

### Met AI beschikbaar én voor deze vergadering aangezet

> Dit is de WhisperClip Notulist. De app helpt vergaderingen notuleren door het
> gesproken Nederlandse gesprek lokaal op deze zichtbare telefoon te
> transcriberen.
>
> Wil iemand iets buiten de notulen bespreken, dan wordt de opname gepauzeerd.
> Wat tijdens die pauze wordt gezegd, wordt niet opgenomen en komt dus niet in
> de transcriptie.
>
> Aan het einde van de vergadering wordt de transcriptie afgerond. De
> geluidsopname wordt daarna van de telefoon verwijderd. Vervolgens wordt een
> e-mail voorbereid voor iedereen die voor deze vergadering een e-mailadres
> heeft opgegeven; iedereen ontvangt hetzelfde verslag nadat de gebruiker de
> e-mail heeft verstuurd.
>
> De notulist verwerkt alleen geluid. Beschrijf daarom kort wat op een scherm of
> whiteboard gebeurt en spel bijzondere namen of termen. Een lokaal
> transcriptiemodel kan woorden verkeerd of fonetisch uitschrijven, maar zulke
> fouten zijn bij het nalezen meestal uit de context te herstellen.
>
> Voor deze vergadering is aanvullend AI-verslag aangezet. De transcriptietekst
> wordt daarom na afloop ook door een externe AI-dienst verwerkt tot bijvoorbeeld
> een samenvatting en actiepunten. De volledige oorspronkelijke transcriptie
> blijft onderdeel van het verslag.

De tweede versie verschijnt en wordt alleen voorgelezen wanneer in Instellingen
`AI bij Notulen toestaan` aanstaat én voor die specifieke vergadering
`Maak ook AI-notulen` is aangevinkt.

### Opnamevoorstel

- `notulist-nl-zonder-ai.m4a` en `notulist-nl-met-ai.m4a`.
- `notulist-en-without-ai.m4a` en `notulist-en-with-ai.m4a`.
- `notulist-de-ohne-ki.m4a` en `notulist-de-mit-ki.m4a`.
- Rustig, feitelijk en gastvrij; geen verkoopstem.
- De app kiest exact één van beide bestanden op basis van de dubbele AI-keuze.

## Expliciet buiten deze run

- GHX-naam, huisstijl, bundel-id en distributie.
- iPad-, Apple Watch- en Android-versie.
- Eigen AI-backend, inbegrepen AI-bundel, abonnement of advertenties.
- Medische claims of klinische beslisondersteuning.
